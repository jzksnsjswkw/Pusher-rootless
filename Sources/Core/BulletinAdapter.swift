import Foundation
import UIKit

/// Interfaces onto SpringBoard objects resolved at runtime.
///
/// These are `@objc` protocols rather than imported classes: naming a
/// SpringBoard class from Swift would create a link-time dependency on
/// `SpringBoard.framework`, which is absent from Preferences.app. Casting a
/// `Runtime`-resolved object to one of these protocols is safe — the cast only
/// succeeds when the object really implements the selectors.
@objc private protocol SBApplicationController {
    func application(withBundleIdentifier id: String) -> SBApplication?
}

@objc private protocol SBApplication {
    var displayName: String? { get }
}

@objc private protocol SBLockScreenManager {
    var isUILocked: Bool { get }
}

@objc private protocol SBWiFiManager {
    var currentNetworkName: String? { get }
}

@objc private protocol SBIconModel {
    func expectedIconForDisplayIdentifier(_ identifier: String) -> AnyObject?
}

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
    /// Bulletins that were never shown (`lastInterruptDate` is `nil`) are
    /// queued bulletins being replayed, e.g. right after a SpringBoard restart,
    /// and must not be forwarded.
    public static func wasPresented(_ bulletin: BBBulletin) -> Bool {
        bulletin.lastInterruptDate != nil
    }

    // MARK: - Bulletin conversion

    /// Converts one bulletin into the pipeline's value type.
    public static func context(for bulletin: BBBulletin) -> BulletinContext {
        makeContext(bulletin, isTest: false, appName: nil, displayTitle: nil, displayMessage: nil)
    }

    /// The same conversion for synthetic test-push bulletins, where the caller
    /// supplies the display strings and app name instead of deriving them.
    public static func context(
        for bulletin: BBBulletin,
        isTest: Bool,
        appName: String?,
        displayTitle: String?,
        displayMessage: String?
    ) -> BulletinContext {
        makeContext(bulletin, isTest: isTest, appName: appName,
                    displayTitle: displayTitle, displayMessage: displayMessage)
    }

    private static func makeContext(
        _ bulletin: BBBulletin,
        isTest: Bool,
        appName: String?,
        displayTitle: String?,
        displayMessage: String?
    ) -> BulletinContext {
        var context = BulletinContext()
        let appID = bulletin.sectionID ?? ""
        context.appID = appID
        context.bulletinID = bulletin.bulletinID ?? ""
        // Default the date here (rather than mutating the bulletin) so the
        // context always carries the timestamp the log and date string use.
        context.date = bulletin.date ?? Date()
        context.isTest = isTest

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

        context.attachmentURL = bulletin.primaryAttachment?.url

        // Capture only the bundle ID string, never the bulletin: the provider
        // runs later, on the background queue that builds the payload.
        context.iconImageProvider = { Self.iconImage(forBundleID: appID) }

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
    public static func currentDeviceState() -> DeviceState {
        var state = DeviceState()
        if let manager = Runtime.sharedInstance("SBLockScreenManager") as? SBLockScreenManager {
            state.isLocked = manager.isUILocked
        }
        if let manager = Runtime.sharedInstance("SBWiFiManager") as? SBWiFiManager {
            state.wifiName = manager.currentNetworkName
        }
        return state
    }

    // MARK: - App metadata

    /// The app's display name, or `"Unknown App: <id>"` when SpringBoard does
    /// not know it.
    public static func appName(forBundleID appID: String) -> String {
        if let controller = Runtime.sharedInstance("SBApplicationController") as? SBApplicationController,
           let app = controller.application(withBundleIdentifier: appID),
           let name = app.displayName, !name.isEmpty {
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
        guard !head.isEmpty, let message, !message.isEmpty else { return head }
        return "\(head)\n\(message)"
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

        guard let iconController = Runtime.sharedInstance("SBIconController"),
              let model = Runtime.send(iconController, "model") as? SBIconModel,
              let icon = model.expectedIconForDisplayIdentifier(bundleID)
        else { return nil }

        // iOS 13+ takes a struct; the earlier signature takes a variant int.
        if let image = generateIconImage(icon, variant: 2) { return image }
        return generateIconImage(icon)
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
