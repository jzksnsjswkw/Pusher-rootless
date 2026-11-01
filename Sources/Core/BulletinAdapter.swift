import Foundation
import UIKit

/// SpringBoard objects are reached through ``Runtime`` message sends, not by
/// casting to an `@objc` protocol.
///
/// Casting a `Runtime`-resolved object to an ad-hoc `@objc` protocol does **not**
/// work, and the reason is easy to miss: `as?` on a class instance tests
/// `conforms(to:)`, which is the class's *declared* conformance list. The
/// SpringBoard classes were never compiled against a protocol declared here, so
/// they do not list it — every cast fails even though the object implements
/// every selector. Measured on-device with an equivalent protocol/class pair:
///
/// ```
/// cast(never declared conformance)     = FAILED
/// cast(after class_addProtocol)        = OK
/// runtime message send                 = OK
/// ```
///
/// Calling through the runtime needs no conformance and is what this file does.
/// Names are only used to resolve a class, never to declare one.

/// `SBIconImageInfo` comes from the bridging header; see the note there for why
/// it has to be a C struct.
typealias IconImageInfoFunction = @convention(c) (
    AnyObject, Selector, SBIconImageInfo
) -> AnyObject?

typealias IconImageFunction = @convention(c) (
    AnyObject, Selector, Int32
) -> AnyObject?

/// `BBSectionInfoAlertTypeBanner` as a raw value, kept out of Swift's enum-case
/// naming so the check cannot break if the case is renamed or shadowed.
private let sectionInfoAlertTypeBanner: UInt = 1

/// The single SpringBoard boundary of the push pipeline.
///
/// Everything that needs BulletinBoard / SpringBoard private classes lives
/// here: the current `BBServer`, the per-app `BBSectionInfo`, app display names
/// (`SBApplicationController`), app icons (`SBIconController`), and the
/// lock-screen and Wi-Fi device state. Each is converted into the plain value
/// types in `PushSupport.swift`, so no other file below the hook touches a
/// SpringBoard class.
///
/// `PusherEngine.handle(bulletin:)` — called from the `BBServer` hook — is the
/// only consumer on the hot path: it converts the bulletin once and the rest of
/// the pipeline sees only the resulting ``BulletinContext``.
///
/// Exposed to ObjC because the `BBServer` hook owns the server reference: the
/// hook hands `self` over once, and everything downstream reads the value type
/// the adapter produces.
@objc(NSPBulletinAdapter)
public final class BulletinAdapter: NSObject {
    @objc(sharedInstance)
    public static let shared = BulletinAdapter()

    /// The live `BBServer`, set from the hook. `nil` until the hook has run
    /// (e.g. shortly after a SpringBoard restart).
    ///
    /// `weak`, because the server outlives the tweak's interest in it and the
    /// hook is not the owner.
    @objc public weak var server: BBServer?

    /// Whether this process holds the live server.
    ///
    /// `false` in Preferences, which is a separate process with no `BBServer` at
    /// all: callers that would otherwise read `sectionInfo` have to reach it some
    /// other way rather than build a context the pipeline cannot use.
    public static var hasServer: Bool { shared.server != nil }

    private override init() {
        super.init()
    }

    // MARK: - Readiness

    /// Whether SpringBoard's application controller is up. The pipeline cannot
    /// resolve app names before that.
    public static var isSpringBoardReady: Bool {
        Runtime.sharedInstance("SBApplicationController") != nil
    }

    /// Whether the bulletin was actually presented by SpringBoard.
    ///
    /// `lastInterruptDate` is how the system marks a bulletin it has shown. A
    /// bulletin without one is a replay of something queued before a restart, and
    /// forwarding it would send a notification the user already lived through.
    ///
    /// Two exceptions, both observed rather than assumed:
    ///
    /// - A composed notification goes through the publish path from a thread
    ///   outside SpringBoard's own, and `BBServer` copies the request into a fresh
    ///   bulletin — so the date stamped on the request never reaches the object
    ///   the hook sees. Its presence on screen was asked for by the user.
    /// - A notification with a `publisherBulletinID` came from an app, not from
    ///   the replay queue: the queue is what has no publisher.
    public static func wasPresented(_ bulletin: BBBulletin) -> Bool {
        if bulletin.lastInterruptDate != nil { return true }
        if (bulletin.context?["PusherComposed"] as? NSNumber)?.boolValue == true {
            return true
        }
        return !(bulletin.publisherBulletinID ?? "").isEmpty
    }

    // MARK: - Bulletin conversion

    /// Converts one bulletin into the pipeline's value type.
    public static func context(for bulletin: BBBulletin) -> BulletinContext {
        makeContext(bulletin, test: nil, appName: nil, displayTitle: nil, displayMessage: nil)
    }

    /// The same conversion for synthetic test-push bulletins, where the caller
    /// supplies the display strings and app name instead of deriving them.
    public static func context(
        for bulletin: BBBulletin,
        test: TestOrigin?,
        appName: String?,
        displayTitle: String?,
        displayMessage: String?,
        skipsSectionLookup: Bool = false
    ) -> BulletinContext {
        makeContext(bulletin, test: test, appName: appName,
                    displayTitle: displayTitle, displayMessage: displayMessage,
                    skipsSectionLookup: skipsSectionLookup)
    }

    private static func makeContext(
        _ bulletin: BBBulletin,
        test: TestOrigin?,
        appName: String?,
        displayTitle: String?,
        displayMessage: String?,
        skipsSectionLookup: Bool = false
    ) -> BulletinContext {
        var context = BulletinContext()
        let appID = bulletin.sectionID ?? ""
        context.appID = appID
        context.publisherBulletinID = bulletin.publisherBulletinID ?? ""
        // The group key for the log. A bulletin reaches the hook more than once —
        // the data provider publishes it, SpringBoard assigns an identifier, and it
        // is published again — so `bulletinID` changes between those passes while
        // the publisher's identifier does not. Grouping on the stable one keeps a
        // notification's lines in one section.
        context.bulletinID = context.publisherBulletinID.isEmpty
            ? (bulletin.bulletinID ?? "")
            : context.publisherBulletinID
        // Default the date here (rather than mutating the bulletin) so the
        // context always carries the timestamp the log and date string use.
        context.date = bulletin.date ?? Date()
        context.test = test

        context.title = bulletin.title
        context.subtitle = bulletin.subtitle
        context.message = bulletin.message
        context.appName = appName ?? Self.appName(forBundleID: appID)

        if let displayTitle, let displayMessage {
            // Test pushes supply their own display strings.
            context.displayTitle = displayTitle
            context.displayMessage = displayMessage
        } else {
            context.displayTitle = Self.displayTitle(appName: context.appName, title: bulletin.title)
            context.displayMessage = Self.displayMessage(
                subtitle: bulletin.subtitle,
                message: bulletin.message,
                showsSubtitle: bulletin.showsSubtitle
            )
        }

        // A notification composed by the user, published to be looked at.
        //
        // It arrives through the normal publish path, so without this marker it
        // would be indistinguishable from a live one and the app rules would
        // filter it — a test that gets blocked by a rule answers a question nobody
        // asked. Marked as a test, so the rules skip it exactly as they skip the
        // instance page's test push.
        if (bulletin.context?["PusherComposed"] as? NSNumber)?.boolValue == true {
            // A composed notification is usually just shown, but a hook's Run also
            // carries the phase its editor executed — and that phase must not run
            // again here.
            if let ran = bulletin.context?["PusherRanHook"] as? String,
               let phase = BulletinHookRunner.Phase(rawValue: ran) {
                context.test = .hook(phase)
            } else {
                context.test = .composed
            }
        }

        // A card the user chose on the compose page. A real message's card is
        // resolved later by asking `imagent`; a composed one has no database row,
        // so the choice is carried here instead. Read before the `isTest` early
        // return, because the lookup below never runs for a composed notification.
        if let slot = bulletin.context?["PusherSIMSlot"] as? NSNumber, slot.intValue > 0 {
            context.simSubscription = SIMSubscription(
                slot: slot.intValue,
                phoneNumber: bulletin.context?["PusherSIMPhone"] as? String ?? "",
                label: bulletin.context?["PusherSIMLabel"] as? String ?? ""
            )
        }

        context.attachmentURL = bulletin.primaryAttachment?.url

        // Capture only the bundle ID string, never the bulletin: the provider
        // runs later, on the background queue that builds the payload.
        context.iconImageProvider = { Self.iconImage(forBundleID: appID) }

        // A test push skips this lookup, and must keep skipping it.
        //
        // `-[BBServer _sectionInfoForSectionID:effective:]` asserts that it is
        // called on the main queue, and a test push arrives on the
        // `CPDistributedMessagingCenter` reply thread instead — calling it there
        // trips the libdispatch assertion and SpringBoard is killed with
        // `SIGTRAP`. The look-up is also pointless for a test: the synthetic
        // bulletin has no real app behind it, and the SNS/device filters that
        // consume these settings are skipped for a test push anyway.
        guard !context.isTest, !skipsSectionLookup else { return context }

        guard let server = shared.server else {
            context.notificationSettingsUnavailableReason = "Server is nil, it shouldn't be"
            return context
        }
        guard let sectionInfo = server._sectionInfo(forSectionID: appID, effective: true) else {
            context.notificationSettingsUnavailableReason = "Section info is nil, it shouldn't be"
            return context
        }
        context.notificationSettings = Self.settings(from: sectionInfo)
        return context
    }

    /// Reduces a `BBSectionInfo` to the filter's value type.
    /// The notification settings for an app, as the pipeline sees them.
    ///
    /// Available only in a process that holds the server — the lookup asserts it
    /// runs on `BBServer`'s queue. Preferences has no server, which is why the
    /// pipeline asks for these over IPC instead.
    static func sectionSettings(for appID: String) -> NotificationSettings? {
        guard let server = shared.server,
              let sectionInfo = server._sectionInfo(forSectionID: appID, effective: true)
        else { return nil }
        return settings(from: sectionInfo)
    }

    private static func settings(from sectionInfo: BBSectionInfo) -> NotificationSettings {
        var settings = NotificationSettings()
        settings.allowsNotifications = sectionInfo.allowsNotifications
        settings.showsInLockScreen = sectionInfo.showsInLockScreen
        settings.showsInNotificationCenter = sectionInfo.showsInNotificationCenter
        settings.showsMessagePreview = sectionInfo.showsMessagePreview
        // Compared by raw value: the alert-type enum's Swift case names are
        // not stable across SDKs, and only the banner case is needed.
        settings.isBanner = sectionInfo.alertType.rawValue == sectionInfoAlertTypeBanner

        // The public `BBSectionInfoPushSettings` bits for badges and sounds are
        // shifted on this iOS line, so the actual masks are read directly; see
        // `BBActualSectionInfoPushSettings` in the bridging header.
        let pushSettings = sectionInfo.pushSettings.rawValue
        settings.showsBadges = pushSettings & NotificationSettings.badgesMask != 0
        settings.showsSounds = pushSettings & NotificationSettings.soundsMask != 0
        return settings
    }

    // MARK: - Device state

    /// Current device conditions, snapshotted so the filter stays pure.
    ///
    /// Wi-Fi is determined through SystemConfiguration rather than through
    /// SpringBoard. The original implementation read
    /// `SBWiFiManager.currentNetworkName`, but that class no longer exists on
    /// iOS 16 — `NSClassFromString(@"SBWiFiManager")` returns nil, so the old
    /// check could never report Wi-Fi and "Wi-Fi Only" silently never matched.
    /// The registrar's own reachability answer is what the system itself uses:
    /// reachable over a non-cellular interface *is* being on Wi-Fi.
    /// The device state for a hook, which may be running off the main thread.
    ///
    /// Reading the lock state goes through SpringBoard, so it happens on the
    /// main thread either way. A hook that contains `fetch` must not run on the
    /// main thread — that is the whole reason the pipeline hands runs to a
    /// background queue — so the read is hopped back here rather than the hook
    /// being pinned to the main thread.
    public static func deviceStateForHooks() -> DeviceState {
        if Thread.isMainThread { return currentDeviceState() }
        var state = DeviceState()
        DispatchQueue.main.sync { state = currentDeviceState() }
        return state
    }

    public static func currentDeviceState() -> DeviceState {
        var state = DeviceState()
        if let manager = Runtime.sharedInstance("SBLockScreenManager") {
            state.isLocked = Runtime.sendBool(manager, "isUILocked")
        }
        state.network = NetworkReachability.current()
        state.isOnWiFi = state.network == .wifi

        // Battery monitoring has to be switched on before `batteryLevel` reports
        // anything but -1, and this runs on a background queue for a hook — so it
        // is enabled here, on the same thread that reads it.
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled {
            device.isBatteryMonitoringEnabled = true
        }
        let level = device.batteryLevel
        state.batteryLevel = level >= 0 ? Double(level) : nil
        switch device.batteryState {
        case .charging: state.batteryState = "charging"
        case .full: state.batteryState = "full"
        default: state.batteryState = "unplugged"
        }
        state.isCharging = device.batteryState == .charging || device.batteryState == .full

        state.osVersion = device.systemVersion
        return state
    }

    // MARK: - App metadata

    /// The app's display name, or `"Unknown App: <id>"` when SpringBoard does
    /// not know it.
    public static func appName(forBundleID appID: String) -> String {
        if let controller = Runtime.sharedInstance("SBApplicationController"),
           let app = Runtime.send(controller, "applicationWithBundleIdentifier:", appID as NSString),
           let name = Runtime.send(app, "displayName") as? String,
           !name.isEmpty {
            return name
        }
        return "Unknown App: \(appID)"
    }

    /// `"AppName: title"`.
    static func displayTitle(appName: String, title: String?) -> String {
        guard let title, !title.isEmpty else { return appName }
        return "\(appName): \(title)"
    }

    /// The composed message. The subtitle is only included when the bulletin
    /// says it is being shown.
    static func displayMessage(subtitle: String?, message: String?, showsSubtitle: Bool) -> String {
        let head = showsSubtitle ? (subtitle ?? "") : ""
        let body = message ?? ""
        // Either may be absent, and the one that is present is the whole message.
        // The earlier version returned `head` whenever `head` was empty, which
        // meant a notification with a body and no subtitle — WeChat's, among
        // others — produced an empty string and forwarded nothing.
        if head.isEmpty { return body }
        if body.isEmpty { return head }
        return "\(head)\n\(body)"
    }

    /// Resolves an app icon through SpringBoard's icon model.
    ///
    /// `SBIconController` / `SBIconModel` are SpringBoard UI objects that must
    /// only be touched on the main thread; the push pipeline builds payloads on
    /// a background queue, so this hops to the main thread when needed.
    public static func iconImage(forBundleID bundleID: String) -> UIImage? {
        guard !bundleID.isEmpty else { return nil }

        // `dispatch_sync` to the main queue would deadlock if this is already
        // running on the main thread, so the hop is conditional.
        if !Thread.isMainThread {
            var result: UIImage?
            DispatchQueue.main.sync { result = iconImage(forBundleID: bundleID) }
            return result
        }

        // Two ways, because the process differs.
        //
        // `SBIconController` exists only in SpringBoard. Preferences has none, so
        // the same call returned nil there — and every editor's Run, which runs in
        // Preferences, showed a notification with no `icon` while the identical
        // hook running for real carried one. That is the whole difference between
        // the two results.
        //
        // UIKit's own `_applicationIconImageForBundleIdentifier:format:scale:` is
        // available in both processes, so it is the fallback.
        if let iconController = Runtime.sharedInstance("SBIconController"),
           let model = Runtime.send(iconController, "model"),
           let icon = Runtime.send(
               model, "expectedIconForDisplayIdentifier:", bundleID as NSString
           ) {
            // iOS 13+ takes a struct; the earlier signature takes a variant int.
            if let image = generateIconImage(icon, variant: 2) { return image }
            if let image = generateIconImage(icon) { return image }
        }
        return applicationIcon(forBundleID: bundleID)
    }

    /// The installed app's icon through UIKit, which works in every process.
    ///
    /// `_applicationIconImageForBundleIdentifier:format:scale:` is private but
    /// present in UIKit on every supported system, and — unlike the SpringBoard
    /// route above — it does not need a process that has SpringBoard in it.
    public static func applicationIcon(forBundleID bundleID: String) -> UIImage? {
        typealias IconFunction = @convention(c) (
            AnyObject, Selector, NSString, Int32, CGFloat
        ) -> AnyObject?
        let selector = NSSelectorFromString(
            "_applicationIconImageForBundleIdentifier:format:scale:"
        )
        guard let cls = Runtime.cls("UIImage"),
              let method = class_getClassMethod(cls, selector)
        else { return nil }
        let call = unsafeBitCast(method_getImplementation(method), to: IconFunction.self)
        return call(cls, selector, bundleID as NSString, 0, UIScreen.main.scale) as? UIImage
    }

    /// `-[SBIcon generateIconImageWithInfo:]` (iOS 13+).
    private static func generateIconImage(_ icon: AnyObject) -> UIImage? {
        let info = SBIconImageInfo(
            size: CGSize(width: 60, height: 60),
            scale: UIScreen.main.scale,
            continuousCornerRadius: 12
        )
        guard let cls = object_getClass(icon),
              let method = class_getInstanceMethod(cls, NSSelectorFromString("generateIconImageWithInfo:"))
        else { return nil }
        let call = unsafeBitCast(
            method_getImplementation(method), to: IconImageInfoFunction.self
        )
        return call(icon, NSSelectorFromString("generateIconImageWithInfo:"), info) as? UIImage
    }

    /// `-[SBIcon generateIconImage:]` (iOS 12 and below).
    private static func generateIconImage(_ icon: AnyObject, variant: Int32) -> UIImage? {
        guard let cls = object_getClass(icon),
              let method = class_getInstanceMethod(cls, NSSelectorFromString("generateIconImage:"))
        else { return nil }
        let call = unsafeBitCast(
            method_getImplementation(method), to: IconImageFunction.self
        )
        return call(icon, NSSelectorFromString("generateIconImage:"), variant) as? UIImage
    }
}

// MARK: - Alert / URL conveniences

extension UIViewController {
    /// Presents a simple alert with an "Ok" button.
    func presentAlert(_ message: String, title: String = Pusher.name) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Ok", style: .default))
        present(alert, animated: true)
    }
}

/// Opens a URL through the shared application.
@discardableResult
public func openURL(_ string: String) -> Bool {
    guard let url = URL(string: string) else { return false }
    UIApplication.shared.open(url, options: [:], completionHandler: nil)
    return true
}
