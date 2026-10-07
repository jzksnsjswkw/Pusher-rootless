import Foundation

/// The SpringBoard hook's entry point and the push pipeline's orchestrator.
///
/// `handle(bulletin:)` is called from the `BBServer` hook with the raw
/// `BBBulletin`. It is the only place in Core that handles a BulletinBoard
/// type, and it immediately converts it once into a ``BulletinContext``. From
/// there on — the filters, the request sender and the service payload builders
/// — everything works on that value type.
///
/// Exposed to ObjC so the Logos hook (`Sources/Hooks/PusherHooks.xm`) can call
/// straight into it; the hook layer itself holds no pipeline logic.
@objc(NSPushEngine)
public final class PushEngine: NSObject {
    @objc(sharedInstance)
    public static let shared = PushEngine()

    /// The Darwin notification the hook observes to reload the configuration.
    /// Duplicated from ``Pusher/prefsNotification`` because that is a Swift
    /// `String` and the hook needs a `CFStringRef` at compile time.
    @objc public static let prefsChangedNotification = Pusher.prefsNotification

    /// IPC names for the test-push message, mirrored for the ObjC hook that
    /// registers the server (`Sources/Hooks/TestPush.xm`).
    @objc public static let testPushCenterName = Pusher.messagingCenterName
    @objc public static let testPushMessageName = Pusher.testPushMessageName

    /// The configuration the pipeline is currently running on.
    ///
    /// Only ever replaced wholesale by ``reloadConfig()``, and only read
    /// afterwards, so callers can hold a reference to it across the async send
    /// without it changing underneath them.
    public private(set) var config = ConfigSnapshot()

    /// Recent bulletin contents, used to detect forwarding loops.
    private var recentContent: [String] = []
    private let lock = NSLock()

    /// Guards against forwarding before the first config load has completed.
    private var hasLoadedConfig = false

    private override init() {
        super.init()
    }

/// Re-reads every preference and swaps in the new snapshot.
    ///
    /// Exposed to ObjC for the Darwin notification observer in the hook layer.
    @objc(reloadConfig)
    public func reloadConfig() {
        let snapshot = ConfigLoader.loadSnapshot()
        lock.lock()
        config = snapshot
        hasLoadedConfig = true
        lock.unlock()
    }

    /// The current snapshot, loading it on first use. Called from the Darwin
    /// notification observer and once at hook setup.
    private func currentConfig() -> ConfigSnapshot {
        lock.lock()
        let loaded = hasLoadedConfig
        let snapshot = config
        lock.unlock()
        if loaded { return snapshot }
        reloadConfig()
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    // MARK: - Bulletin entry point

    /// Called from the `BBServer` hook for every published bulletin.
    @objc(handleBulletin:)
    public func handle(bulletin: BBBulletin?) {
        guard let bulletin else {
            PusherLog.debug("Bulletin nil")
            return
        }

        let context = BulletinAdapter.context(for: bulletin)

        // A bulletin SpringBoard never presented (no lastInterruptDate) is a
        // queued bulletin being replayed, e.g. right after a SpringBoard
        // restart.
        guard BulletinAdapter.wasPresented(bulletin) else {
            PusherLog.debug("Not forwarding, bulletin was never presented")
            PushLog.add(service: "", context: context,
                        label: "Last interrupt date nil (this should only happen if SpringBoard "
                            + "just restarted; if some other time, there is a problem)")
            return
        }

        guard BulletinAdapter.isSpringBoardReady else {
            PusherLog.debug("SpringBoard not ready")
            PushLog.add(service: "", context: context, label: "SpringBoard not ready")
            return
        }

        let config = currentConfig()

        if let reason = PushFilter.globalReason(context: context, config: config) {
            PusherLog.debug("Prefs say no: \(reason)")
            PushLog.add(service: "", context: context, label: "Global prefs: \(reason)")
            return
        }

        // The global app list is evaluated before loop prevention: a blocked app
        // should not consume a slot in the loop-prevention window.
        if let reason = PushFilter.globalAppListReason(config: config, appID: context.appID) {
            PusherLog.debug("[Global] \(reason): \(context.appID)")
            PushLog.add(service: "", context: context,
                        label: "Blocked by global app list "
                            + "(\(config.globalAppListIsBlacklist ? "blacklist" : "whitelist"))")
            return
        }

        guard !isLooping(context) else {
            PusherLog.debug("Prevented loop")
            PushLog.add(service: "", context: context, label: "Prevented loop")
            return
        }

        // SEAM: the "received a notification" hook runs here — after the
        // global gates have passed and before any per-instance filter, so a
        // script sees every notification the pipeline would otherwise forward.

        guard !config.enabledInstances.isEmpty else {
            PusherLog.debug("No services enabled!")
            return
        }

        for instance in config.enabledInstances {
            send(to: instance, context: context, config: config)
        }
    }

    /// Records this bulletin's content and reports whether it looks like a
    /// forwarding loop.
    ///
    /// A forwarded push can itself produce a notification that would be
    /// forwarded again. The count of identical contents in the recent window is
    /// compared against the threshold, so a legitimate single duplicate is not
    /// mistaken for a loop.
    private func isLooping(_ context: BulletinContext) -> Bool {
        let signature = context.contentSignature
        lock.lock()
        defer { lock.unlock() }

        let count = recentContent.filter { $0 == signature }.count
        guard count < Pusher.loopPreventionThreshold else { return true }

        // Slide the window rather than clearing it: clearing would reset the
        // duplicate count mid-loop, so a genuine loop (the threshold within the
        // last window) could never be detected.
        while recentContent.count >= Pusher.loopPreventionWindow {
            recentContent.removeFirst()
        }
        recentContent.append(signature)
        return false
    }

    // MARK: - Per-service pipeline

    /// Applies the filters and then builds and sends the request for one
    /// instance.
    public func send(to id: String, context: BulletinContext, config: ConfigSnapshot? = nil) {
        let snapshot = config ?? currentConfig()
        guard let instance = snapshot.instance(id: id) else { return }
        send(to: instance, context: context, config: snapshot)
    }

    /// Applies the app-list / SNS / device-condition filters and then builds and
    /// sends the request for one instance.
    private func send(to instance: ServiceInstance, context: BulletinContext, config: ConfigSnapshot) {
        let id = instance.id
        guard let serviceConfig = config.config(forID: id) else { return }
        let serviceType = instance.descriptor
        // The log is keyed by instance id, so two instances of one service keep
        // separate logs.
        let service = id

        // A test push is explicitly requested by the user, so the per-app
        // filters (which exist to suppress *unwanted* pushes) do not apply.
        var effectiveConfig = serviceConfig
        if !context.isTest {
            if let reason = PushFilter.appListReason(config: serviceConfig, appID: context.appID) {
                PusherLog.debug("[S:\(service)] Blocked by app list: \(context.appID)")
                PushLog.add(service: service, context: context, label: reason)
                return
            }

            // The settings were snapshotted from BBSectionInfo by the adapter;
            // the global filter already rejected a bulletin without them, so
            // this only guards callers that skip it.
            guard let settings = context.notificationSettings else {
                PusherLog.debug("[S:\(service),A:\(context.appID)] sectionInfo nil")
                let reason = context.notificationSettingsUnavailableReason
                    ?? "sectionInfo is nil, it should not be"
                PushLog.add(service: service, context: context, label: reason)
                return
            }

            PusherLog.debug("[S:\(service),A:\(context.appID)] Doing SNS")
            if let reason = PushFilter.snsReason(
                sns: serviceConfig.sns,
                settings: settings,
                isAnd: serviceConfig.snsIsAnd,
                requireANWithOR: serviceConfig.snsRequireANWithOR
            ) {
                PusherLog.debug("[S:\(service),A:\(context.appID)] SNS said no: \(reason)")
                PushLog.add(service: service, context: context, label: reason)
                return
            }
            PusherLog.debug("[S:\(service),A:\(context.appID)] SNS ok")

            PusherLog.debug("[S:\(service),A:\(context.appID)] Doing Device Conditions")
            let state = BulletinAdapter.currentDeviceState()
            if let reason = PushFilter.deviceReason(
                whenToPush: serviceConfig.whenToPush,
                whatNetwork: serviceConfig.whatNetwork,
                deviceState: state
            ) {
                PusherLog.debug("[S:\(service),A:\(context.appID)] Device Conditions said no: \(reason)")
                PushLog.add(service: service, context: context, label: reason)
                return
            }
            PusherLog.debug("[S:\(service),A:\(context.appID)] Device Conditions ok")

            // Per-app overrides replace the instance-wide prefs for this app.
            effectiveConfig = serviceConfig.effective(forAppID: context.appID)
        }

        // SEAM: the "passed the filters" hook runs here — every gate above has
        // already said yes, and nothing has been sent yet.

        // Build and send on a background queue: the filter decision above ran on
        // the main thread where the SpringBoard objects live, but building the
        // payload can do heavy work (decoding and shrinking the attachment,
        // generating the icon) that must not stall SpringBoard.
        //
        // Everything used below is thread-safe: the context and config are
        // read-only value types, the log and the retry map lock internally, and
        // URLSession plus the Wechat token cache are safe from any queue.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            serviceType.buildRequestAsync(context, effectiveConfig) { request in
                guard let request else {
                    // The service could not build a request (Wechat's token
                    // fetch, say); log the failure and skip the send.
                    PusherLog.debug("[S:\(service),A:\(context.appName)] Failed to build request")
                    if !context.isTest {
                        PushLog.add(service: service, context: context, label: "Failed to build request")
                    }
                    return
                }

                // The service fully assembled the request; the framework sends
                // it as-is.
                RequestSender.shared.send(
                    request,
                    logString: "[S:\(service),A:\(context.appName)]",
                    service: service,
                    context: context
                )
                PusherLog.debug("[S:\(service),T:\(context.isTest),A:\(context.appName)] Pushed")
                if !context.isTest {
                    PushLog.add(service: service, context: context, label: "Pushed")
                }
                _ = self
            }
        }
    }
}
