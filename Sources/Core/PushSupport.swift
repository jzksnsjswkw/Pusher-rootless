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
    /// `sectionInfo.pushSettings & Badges`.
    public var showsBadges = false
    /// `sectionInfo.pushSettings & Sounds`.
    public var showsSounds = false

    public init() {}

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
/// These used to be read straight from `SBLockScreenManager` / `SBWiFiManager`
/// inside the filter; now the adapter snapshots them so the filter is a pure
/// function of its inputs.
public struct DeviceState {
    public var isLocked = false
    /// `nil` when the device is not associated with a Wi-Fi network.
    public var wifiName: String?

    public init() {}

    public var isOnWiFi: Bool { wifiName != nil }
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
    /// Never `nil`; defaults to the current date when the bulletin has none.
    public var date: Date = Date()
    public var isTest = false

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
