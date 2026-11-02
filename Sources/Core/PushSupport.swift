import Foundation
import UIKit

/// Value objects for the push pipeline.
///
/// Dependency rule: everything below the SpringBoard hook works on the plain
/// value types declared here and must not import BulletinBoard / SpringBoard.
/// SpringBoard types (`BBBulletin`, `BBSectionInfo`, `SBIconController`, …) are
/// converted exactly once, at the hook boundary, by ``BulletinAdapter``. That
/// keeps the filters, the request sender and the service payload builders
/// independent of SpringBoard's private classes.

/// The per-app notification settings the SNS filter is evaluated against.
///
/// Mirrors the subset of `BBSectionInfo` the filter reads, so the filter never
/// has to touch BulletinBoard. Populated by ``BulletinAdapter``.
public struct NotificationSettings: Equatable {
    /// The bits `BBSectionInfo.pushSettings` actually uses for badges and
    /// sounds on this iOS line. The public enum in the SDK declares them one
    /// position lower, so the masks are stated here rather than read from it.
    static let badgesMask: UInt = 1 << 3
    static let soundsMask: UInt = 1 << 4

    public var allowsNotifications = false
    public var showsInLockScreen = false
    public var showsInNotificationCenter = false
    public var showsMessagePreview = false
    /// `sectionInfo.alertType == BBSectionInfoAlertTypeBanner`.
    public var isBanner = false

    public init() {}

    /// `sectionInfo.pushSettings & Badges`.
    public var showsBadges = false
    /// `sectionInfo.pushSettings & Sounds`.
    public var showsSounds = false

    /// Whether one SNS condition is currently satisfied for this app.
    public func isSatisfied(_ condition: SNSCondition) -> Bool {
        switch condition {
        case .allowNotifications: return allowsNotifications
        case .lockScreen: return showsInLockScreen
        case .notificationCenter: return showsInNotificationCenter
        case .banners: return isBanner
        case .badges: return showsBadges
        case .sounds: return showsSounds
        case .showsPreviews: return showsMessagePreview
        }
    }
}

/// The device conditions the "when to push" / "what network" filter checks.
///
/// These used to be read straight from `SBLockScreenManager`
/// inside the filter; now the adapter snapshots them so the filter is a pure
/// function of its inputs.
public struct DeviceState {
    public var isLocked = false
    /// Whether the device currently has a non-cellular connection.
    ///
    /// Determined by ``NetworkReachability`` rather than by reading a
    /// SpringBoard Wi-Fi property, which no longer exists on iOS 16.
    public var isOnWiFi = false

    /// The network the device is actually using, when there is one.
    ///
    /// ``isOnWiFi`` answers the *filter's* question ("is this Wi-Fi rather than
    /// cellular"); this answers the script's ("is there a network at all, and
    /// which kind"). Both come from the same reachability query, so they cannot
    /// disagree.
    public var network: Network = .none

    /// Whether the device has any usable route at all — Wi-Fi or cellular.
    public var isOnline: Bool { network != .none }

    /// Battery charge, `0`–`1`, or `nil` when the level is unknown.
    ///
    /// `UIDevice.batteryLevel` is `-1` until battery monitoring has been switched
    /// on, and reports `-1` again on a device that does not have one — so the
    /// unreadable case is dropped rather than reported as a flat battery.
    public var batteryLevel: Double?

    /// Whether the device is plugged in and charging.
    public var isCharging = false

    /// The charger state in words: `unplugged`, `charging` or `full`.
    public var batteryState: String = "unplugged"

    /// The system version, e.g. `16.5`.
    public var osVersion: String = ""

    /// What the device's network is, as a script sees it.
    public enum Network: String {
        case none = "none"
        case wifi = "wifi"
        case cellular = "cellular"
    }

    public init() {}

    /// The state as a script's `device` object: a plain dictionary, so it
    /// crosses into JavaScript by value and a script cannot change what the
    /// filters see.
    public var scriptValue: [String: Any] {
        var value: [String: Any] = [
            "locked": isLocked,
            "wifi": network == .wifi,
            "cellular": network == .cellular,
            "online": isOnline,
            "network": network.rawValue,
            "charging": isCharging,
            "batteryState": batteryState,
            "osVersion": osVersion,
            // The name is read here rather than stored: it is the same call that
            // fills `bullet.deviceName`, and holding a copy would let the two
            // disagree after the user renames the phone.
            "name": UIDevice.current.name,
        ]
        // Absent rather than zero when unreadable, so `device.battery` is the
        // honest test.
        if let batteryLevel { value["battery"] = batteryLevel }
        return value
    }
}

/// One bulletin reduced to plain values: the pipeline's data model.
///
/// Populated by ``BulletinAdapter`` — the only thing that knows about
/// `BBBulletin` — and treated as read-only by everything downstream (the
/// filters, the request sender, the service payload builders and the log).
public struct BulletinContext {
    // MARK: Identity

    /// `bulletin.sectionID`.
    public var appID: String = ""
    /// The app's display name.
    public var appName: String = ""
    public var bulletinID: String = ""
    /// `bulletin.publisherBulletinID` — the identifier the publishing app chose.
    ///
    /// For Messages this is the `message.guid` row key, which is what links a
    /// notification back to the SMS database record it came from.
    public var publisherBulletinID: String = ""
    /// Never `nil`; defaults to the current date when the bulletin has none.
    public var date: Date = Date()
    /// Where this notification came from, when it was not a live one.
    ///
    /// One value rather than a `Bool` plus a side field: "is this a test" and
    /// "which hook is being tested" are the same question asked at different
    /// resolutions, and splitting them is how the two ends drifted — the publisher
    /// wrote a flag, the adapter read a different one, and a composed notification
    /// reached the filters as if it were live.
    public var test: TestOrigin?

    /// Whether this is a test rather than a live notification.
    public var isTest: Bool { test != nil }

    /// A notification the user composed on the test page.
    ///
    /// It is published so it can be looked at, and forwarded by the test path —
    /// never by the fan-out, which would send it to every instance instead of the
    /// one it was aimed at.
    public var isComposed: Bool { test == .composed }

    // MARK: Raw content

    /// Bulletin content exactly as `BBBulletin` carried it. Used by the shared
    /// data dict (IFTTT / Pusher Receiver / custom services), by Feishu, and by
    /// the loop-prevention and test-result-banner checks.
    public var title: String?
    public var subtitle: String?
    public var message: String?

    // MARK: Composed display strings

    /// `"AppName: title"`.
    public var displayTitle: String = ""
    /// Subtitle + message, joined as the bulletin would show them.
    public var displayMessage: String = ""

    /// The SIM the message arrived on, when the notification is an SMS.
    ///
    /// Resolved once, before the fan-out: the lookup crosses into `imagent` and
    /// waits for an answer, so doing it per instance would multiply that wait by
    /// the number of services and put the same line in every service's log.
    public var simSubscription: SIMSubscription?

    /// The bulletin's primary attachment file, `nil` when it has none.
    public var attachmentURL: URL?

    /// Lazily resolves the app icon, `nil` when none is available.
    ///
    /// Kept as a provider rather than a value because only some services want
    /// the icon and resolving it is expensive (SpringBoard icon generation plus
    /// PNG encoding); it hops to the main thread, so it is safe to call from a
    /// background queue.
    public var iconImageProvider: (() -> UIImage?)?

    /// Settings for this app, `nil` when SpringBoard has no section info for
    /// it; ``notificationSettingsUnavailableReason`` then explains why.
    public var notificationSettings: NotificationSettings?
    public var notificationSettingsUnavailableReason: String?

    public init() {}

    /// The resolved app icon, honouring the optional provider.
    public var iconImage: UIImage? { iconImageProvider?() }

    /// The identity used as the log section and retry key.
    public var identityKey: String { "\(bulletinID)_\(appID)" }

    /// The composed content string used by loop prevention.
    public var contentSignature: String {
        "\(displayTitle)\n\(subtitle ?? "")\n\(message ?? "")"
    }
}

/// Image helpers shared by the payload builders.
public enum PushImage {
    /// PNG/Base64 representation of an image, or `nil` when there is none.
    public static func base64(_ image: UIImage?) -> String? {
        guard let image else { return nil }
        return image.pngData()?.base64EncodedString(options: .endLineWithLineFeed)
    }

    /// Scales an image down by `factor` (e.g. `2.5` makes it 2.5× smaller).
    public static func shrunk(_ image: UIImage, by factor: CGFloat) -> UIImage {
        let size = CGSize(width: image.size.width / factor, height: image.size.height / factor)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// Where a synthetic notification came from.
///
/// Every test in this project starts one, and they differ only in which hook, if
/// any, is being exercised. One value for all of them: the question the pipeline
/// asks — "should the rules apply to this" — has the same answer for every case,
/// and a test that forgot to say so is exactly the bug this replaces.
public enum TestOrigin: Equatable {
    /// A notification composed to be looked at, or the fixed test push. The rules
    /// are skipped; no hook is force-run.
    case composed

    /// A run started from one hook's editor.
    ///
    /// That phase's hook runs whether or not its switch is on — "does my hook
    /// work" should not require remembering to enable it. The other phase keeps
    /// its own switch: a received hook the user turned off must not act on a
    /// notification it was never meant to see.
    case hook(BulletinHookRunner.Phase)

    /// The phase this test force-runs, if any.
    public var hookPhase: BulletinHookRunner.Phase? {
        if case .hook(let phase) = self { return phase }
        return nil
    }

    /// Whether `phase` has already run for this context.
    ///
    /// A Run executes the hook in the editor, to show what it decided, and then
    /// hands the result to the pipeline. The pipeline would run the same hook
    /// again on the same notification — twice the `fetch`, twice the `push()`,
    /// twice the log lines — so the phase the editor already ran is skipped here.
    public func hasRun(_ phase: BulletinHookRunner.Phase) -> Bool {
        hookPhase == phase
    }
}
