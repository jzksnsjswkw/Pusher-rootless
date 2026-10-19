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

    /// Whether the user's rules hide this bulletin from the phone entirely.
    ///
    /// Called from the `BBServer` hook *before* `%orig`, because that is what
    /// hiding means: the notification is never published, so nothing draws it.
    /// Only the rule lists are consulted — matching is string comparison on fields
    /// that were already resolved — and nothing here awaits, allocates a context of
    /// its own, or reads the network. A hook that fetched could not answer this
    /// question, and this must answer it before SpringBoard draws a single pixel.
    /// Bulletins this process deliberately kept off the screen.
    ///
    /// Suppressing the display means `%orig` is not called, so SpringBoard never
    /// publishes the bulletin and never stamps it with a `lastInterruptDate`. The
    /// engine uses that stamp to tell a live notification from a queued one being
    /// replayed after a restart, so a suppressed-but-forwarded notification would
    /// be discarded as a replay — the "Forward only" rule forwarded nothing. The
    /// suppressed ids are remembered here so those two cases can be told apart.
    private var suppressedBulletinIDs: [String] = []

    @objc(shouldSuppressBulletin:)
    public func shouldSuppress(bulletin: BBBulletin?) -> Bool {
        guard let bulletin else { return false }
        guard currentConfig().enabled else { return false }
        // Building a context reads the app's section info from BBServer and
        // resolves its name — real work, on every notification, and pointless for
        // the many users who write no rules. Asked before the context exists,
        // which is why the check is a cheap one on the stored lists rather than on
        // the resolved outcome.
        guard FilterRules.hasAnyRules else { return false }
        let context = BulletinAdapter.context(for: bulletin)
        guard FilterRules.suppressesNotification(context) else { return false }
        // Logged, because hiding is otherwise silent: the notification is never
        // published, so nothing else in the pipeline gets to mention it.
        PushLog.add(service: "", context: context, label: "Hidden by a rule")

        lock.lock()
        suppressedBulletinIDs.append(context.bulletinID)
        // Bounded, evicting the oldest: only bulletins from this same moment are
        // still in flight, so a small window is all that is ever needed. An array
        // rather than a set because `Set.removeFirst` takes an arbitrary element,
        // which would evict one that is still on its way.
        if suppressedBulletinIDs.count > 32 {
            suppressedBulletinIDs.removeFirst()
        }
        lock.unlock()
        return true
    }

    /// Called from the `BBServer` hook for every published bulletin.
    @objc(handleBulletin:)
    public func handle(bulletin: BBBulletin?) {
        guard let bulletin else {
            PusherLog.debug("Bulletin nil")
            return
        }

        let context = BulletinAdapter.context(for: bulletin)

        // A bulletin without a `lastInterruptDate` is normally a queued one being
        // replayed after a restart — but it is also what a bulletin looks like
        // when a rule suppressed the display, because suppressing means never
        // publishing it. Those were recorded when the decision was taken.
        lock.lock()
        let wasSuppressed = suppressedBulletinIDs.contains(context.bulletinID)
        if wasSuppressed {
            suppressedBulletinIDs.removeAll { $0 == context.bulletinID }
        }
        lock.unlock()
        guard wasSuppressed || BulletinAdapter.wasPresented(bulletin) else {
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

        // The global app list is not checked here. It is a *default* an instance
        // can override, so it has to be consulted per instance, beside the
        // instance's own — a check that runs once for the whole notification
        // cannot be overridden by anything, and an instance with its own empty
        // blacklist would still be blocked by the global list it had just
        // replaced. See `send(to:context:config:deviceState:)`.

        guard !isLooping(context) else {
            PusherLog.debug("Prevented loop")
            PushLog.add(service: "", context: context, label: "Prevented loop")
            return
        }


        guard !config.enabledInstances.isEmpty else {
            PusherLog.debug("No services enabled!")
            return
        }

        // The per-instance work goes to a background queue as a whole, hooks
        // included.
        //
        // A hook may `fetch` — that is what it is for — and `fetch` blocks the
        // thread it runs on. Running the fan-out here would therefore block
        // SpringBoard for as long as a hook's network call takes. The device
        // state is read first, on this thread, so the SpringBoard access stays
        // where it belongs.
        let deviceState = BulletinAdapter.currentDeviceState()
        let instances = config.enabledInstances
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for instance in instances {
                self.send(to: instance, context: context, config: config,
                          deviceState: deviceState)
            }
        }
    }

    /// Reports whether this bulletin looks like a forwarding loop.
    ///
    /// A forwarded push can itself produce a notification that would be forwarded
    /// again. The count of identical contents in the recent window is compared
    /// against the threshold, so a legitimate single duplicate is not mistaken for
    /// a loop.
    ///
    /// Nothing is recorded here. A notification that is filtered, hidden or has
    /// nowhere to go never reaches a service, so it cannot be part of a loop — and
    /// counting it would let a burst of blocked notifications fill the window and
    /// silence the next real one. Only ``recordForwarded(_:)`` fills the window,
    /// and it is called when a service was actually asked to send.
    private func isLooping(_ context: BulletinContext) -> Bool {
        let signature = context.contentSignature
        lock.lock()
        defer { lock.unlock() }
        return recentContent.filter { $0 == signature }.count
            >= Pusher.loopPreventionThreshold
    }

    /// Bulletin ids already counted toward the window.
    ///
    /// A notification fanned out to three instances is one notification, not three
    /// links in a chain; without this the threshold would be reached by a third as
    /// many real notifications.
    private var recordedBulletinIDs: [String] = []

    /// Notes that this content was actually forwarded.
    ///
    /// One entry per notification, not per instance: the loop this guards against
    /// is one notification producing another, and two instances of a service both
    /// sending the same bulletin is not two links in a chain.
    private func recordForwarded(_ context: BulletinContext) {
        let signature = context.contentSignature
        lock.lock()
        defer { lock.unlock() }

        guard !recordedBulletinIDs.contains(context.bulletinID) else { return }
        recordedBulletinIDs.append(context.bulletinID)
        if recordedBulletinIDs.count > Pusher.loopPreventionWindow {
            recordedBulletinIDs.removeFirst()
        }

        // Slide the window rather than clearing it: clearing would reset the
        // duplicate count mid-loop, so a genuine loop (the threshold within the
        // last window) could never be detected.
        while recentContent.count >= Pusher.loopPreventionWindow {
            recentContent.removeFirst()
        }
        recentContent.append(signature)
    }

    // MARK: - Instance hooks

    /// Runs one of an instance's hooks, logging what it decided.
    ///
    /// - Returns: the outcome, or `nil` when the hook is **switched off or
    ///   empty** — which is the case the switch exists for: a disabled or
    ///   cleared hook must cost nothing at all, so it is not even parsed.
    ///
    ///   `nil` means "no hook ran", *not* "drop the notification". The two are
    ///   easy to conflate because a hook that runs and calls nothing also drops
    ///   the notification, but they are opposite decisions: an instance with its
    ///   hooks switched off must forward exactly as it did before hooks
    ///   existed.
    private func runHook(
        _ hook: HookConfig,
        phase: BulletinHookRunner.Phase,
        service: String,
        context: BulletinContext,
        deviceState: DeviceState
    ) -> BulletinHookRunner.Outcome? {
        guard hook.shouldRun else { return nil }

        let outcome = BulletinHookRunner.run(
            script: hook.script,
            phase: phase,
            context: context,
            deviceState: deviceState,
            storage: HookStorage.values(forService: service, phase: phase)
        )

        if !outcome.storage.isEmpty {
            HookStorage.setValues(outcome.storage, forService: service, phase: phase)
        }
        for line in outcome.consoleOutput {
            PushLog.add(service: service, context: context,
                        label: "Hook (\(phase.rawValue))", object: line, dontTruncate: true)
        }
        if let failure = outcome.failure {
            // A hook that cannot run must not decide: it either kept the
            // notification (the runner's `failing` outcome) or, when the script
            // threw after calling keep, its edits stand. Either way the
            // notification keeps moving, and the reason is in the log.
            PushLog.add(service: service, context: context,
                        label: "Hook (\(phase.rawValue)) failed",
                        object: failure.message, dontTruncate: true)
        }

        if !outcome.isKept {
            PushLog.add(service: service, context: context,
                        label: "Hook (\(phase.rawValue)) dropped the notification")
        } else if outcome.isForced {
            PushLog.add(service: service, context: context,
                        label: "Hook (\(phase.rawValue)) forced the push past the filters")
        }
        return outcome
    }

    /// Applies a hook's edits and logs them, so the log shows what actually went
    /// out rather than what arrived.
    private func apply(
        _ outcome: BulletinHookRunner.Outcome,
        to context: inout BulletinContext,
        service: String
    ) {
        guard outcome.hasChanges else { return }
        let changed = outcome.changes.apply(to: &context)
        for field in changed {
            PushLog.add(service: service, context: context, label: "Hook changed \(field)")
        }
    }

    // MARK: - Per-service pipeline

    /// Applies the filters and then builds and sends the request for one
    /// instance.
    public func send(to id: String, context: BulletinContext, config: ConfigSnapshot? = nil) {
        let snapshot = config ?? currentConfig()
        guard let instance = snapshot.instance(id: id) else { return }

        // A test push arrives from the distributed-messaging callback, already
        // off the main thread, so the device state is fetched the way a hook
        // fetches it — hopped to the main thread for the SpringBoard part.
        if Thread.isMainThread {
            let state = BulletinAdapter.currentDeviceState()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.send(to: instance, context: context, config: snapshot, deviceState: state)
            }
        } else {
            let state = BulletinAdapter.deviceStateForHooks()
            send(to: instance, context: context, config: snapshot, deviceState: state)
        }
    }

    /// Applies this instance's hooks and filters, then builds and sends its
    /// request.
    ///
    /// The context is taken **by value**, and every hook edit stays in this
    /// copy: two instances of one script are independent destinations, so one
    /// instance's hook rewriting a title must not rewrite it for another. The
    /// caller's context is untouched.
    private func send(
        to instance: ServiceInstance,
        context: BulletinContext,
        config: ConfigSnapshot,
        deviceState: DeviceState
    ) {
        let id = instance.id
        guard let serviceConfig = config.config(forID: id) else { return }
        // An instance whose service was deleted has no descriptor of its own —
        // `service(named:)` hands back the generic webhook, which would build a
        // request from settings that are not a webhook's. Said out loud and
        // skipped, so the log explains the silence instead of the instance
        // appearing to work.
        if instance.hasMissingService {
            let label = "Service deleted, not sent"
            PusherLog.debug("[S:\(id),A:\(context.appID)] \(label)")
            PushLog.add(service: id, context: context, label: label)
            return
        }
        let serviceType = instance.descriptor
        // The log is keyed by instance id, so two instances of one service keep
        // separate logs.
        let service = id

        var context = context
        var effectiveConfig = serviceConfig

        // ── The user's rules ────────────────────────────────────────────────
        // Checked before the hooks: a rule is a statement about whether this
        // notification should be forwarded at all, and a hook that edits it should
        // not run for one the user has already ruled out. The rules win over the
        // filters below by construction — they answered first.
        //
        // Only the "do not forward" half happens here. The "do not show" half is
        // decided in the BBServer hook, before `%orig`, because hiding a
        // notification means not letting SpringBoard publish it.
        // The instance's own rules decide first, then the global ones. Unlike
        // hiding — which is an effect on the device and takes any list's answer —
        // forwarding is per destination, so each list is asked about its own
        // destination only and the answer is local to this call.
        let ownRules = FilterRules.instance(id).outcome(for: context)
        let globalRules = FilterRules.global().outcome(for: context)
        if let action = ownRules ?? globalRules, !action.forwards {
            let label = "Filtered by a rule (\(action.rawValue))"
            PusherLog.debug("[S:\(id),A:\(context.appID)] \(label)")
            PushLog.add(service: id, context: context, label: label)
            return
        }

        // ── The "received" hook ─────────────────────────────────────────────
        // First thing after the notification exists for this instance, so it
        // sees everything the pipeline would otherwise forward — before the app
        // list, the notification settings or the device conditions have had a
        // say.
        //
        // Runs for a test push as well: the test button is how a user checks
        // what this instance does with a notification, and a hook is part of
        // that. Only the *filters* below are skipped for a test, because they
        // exist to suppress unwanted pushes and this one was asked for.
        var isForced = false
        if let received = runHook(
            serviceConfig.receivedHook, phase: .received,
            service: service, context: context, deviceState: deviceState
        ) {
            if received.isKept {
                apply(received, to: &context, service: service)
                isForced = received.isForced
            } else {
                // The hook ran and chose silence: this notification is dropped
                // for this instance, which is the decision it exists to make.
                return
            }
        }

        if !context.isTest {
            // `keep({force: true})`: the hook has decided, so the filters that
            // exist to suppress unwanted pushes do not get to disagree.
            if !isForced {
            // The instance's own list, or the global one when it has none: the
            // segment's "Default" is what makes the second case reachable, and
            // an instance that set its own replaces the global list rather than
            // adding to it — otherwise a global blacklist could never be lifted
            // for one destination.
            if let reason = PushFilter.effectiveAppListReason(
                config: serviceConfig, global: config, appID: context.appID
            ) {
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
            if let reason = PushFilter.deviceReason(
                whenToPush: serviceConfig.whenToPush,
                whatNetwork: serviceConfig.whatNetwork,
                deviceState: deviceState
            ) {
                PusherLog.debug("[S:\(service),A:\(context.appID)] Device Conditions said no: \(reason)")
                PushLog.add(service: service, context: context, label: reason)
                return
            }
            PusherLog.debug("[S:\(service),A:\(context.appID)] Device Conditions ok")
            }   // end: not forced

            // Per-app overrides replace the instance-wide prefs for this app.
            effectiveConfig = serviceConfig.effective(forAppID: context.appID)
        }

        // ── The "filtered" hook ─────────────────────────────────────────────
        // Every gate above has said yes and nothing has been sent yet. This is
        // the last place a hook can change what goes out — and, for a hook that
        // reads the message first (asking a model to classify an SMS, say), the
        // place where that reading is worth the wait.
        if let filtered = runHook(
            serviceConfig.filteredHook, phase: .filtered,
            service: service, context: context, deviceState: deviceState
        ) {
            if filtered.isKept {
                apply(filtered, to: &context, service: service)
            } else {
                return
            }
        }

        // Build and send on a background queue: the filter decision above ran on
        // the main thread where the SpringBoard objects live, but building the
        // payload can do heavy work (decoding and shrinking the attachment,
        // generating the icon) that must not stall SpringBoard.
        //
        // Everything used below is thread-safe: the context and config are
        // read-only value types, the log and the retry map lock internally, and
        // URLSession plus the Wechat token cache are safe from any queue.
        serviceType.buildRequestAsync(context, effectiveConfig) { request in
            guard let request else {
                // The service could not build a request (Wechat's token fetch,
                // say); log the failure and skip the send.
                PusherLog.debug("[S:\(service),A:\(context.appName)] Failed to build request")
                if !context.isTest {
                    PushLog.add(service: service, context: context, label: "Failed to build request")
                }
                return
            }

            // The service fully assembled the request; the framework sends it
            // as-is.
            RequestSender.shared.send(
                request,
                logString: "[S:\(service),A:\(context.appName)]",
                service: service,
                context: context
            )
            PusherLog.debug("[S:\(service),T:\(context.isTest),A:\(context.appName)] Pushed")
            if !context.isTest {
                PushLog.add(service: service, context: context, label: "Pushed")
                // Now it is part of the loop-prevention window: a service was
                // asked to send it, so a notification caused by it can be the
                // second link in a chain.
                self.recordForwarded(context)
            }
        }
    }
}
