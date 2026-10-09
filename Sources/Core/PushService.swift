import Foundation
import UIKit

/// One push destination (Bark, Pushover, a custom webhook, …).
///
/// A service is a `enum`-like namespace of static functions rather than an
/// instantiable object: it has no state of its own, and its only inputs are a
/// ``BulletinContext`` and a ``ServiceConfig``. Conforming types are registered
/// in ``ServiceRegistry`` and receive the whole send pipeline for free.
///
/// Only the two `request(...)` members are required. Everything else has a
/// default implementation that matches the majority of services, so a simple
/// service is a handful of lines.
public protocol PushService {
    /// Registry key. Must match the service name used in prefs
    /// (e.g. `"Pushover"`).
    static var serviceName: String { get }

    /// The service's request URL, as far as it can be built from the service's
    /// own options.
    ///
    /// This is used only to tell per-app overrides apart (an override whose URL
    /// differs from the service-wide one carries its own). The *final* push URL
    /// is assembled by the service's `request(context:config:)` from
    /// ``ServiceConfig/raw``, because credentials that belong in the URL (Bark's
    /// key, IFTTT's event name and key, Wechat's access token) are resolved
    /// there. Defaults to the empty string for custom / unknown services.
    static func url(eventName: String, dbName: String, serverURL: String) -> String

    /// Builds the request synchronously.
    ///
    /// The default synchronous path is enough for every service except those
    /// that must first obtain a credential (Wechat's access token); those
    /// override ``request(context:config:completion:)`` instead.
    static func request(context: BulletinContext, config: ServiceConfig) -> PushRequest?

    /// Builds the request, possibly asynchronously.
    ///
    /// The completion receives `nil` when the request cannot be built (for
    /// instance a credential fetch failed); the caller then logs the failure
    /// and skips the send rather than firing a request that is guaranteed to
    /// fail server-side.
    static func request(
        context: BulletinContext,
        config: ServiceConfig,
        completion: @escaping (PushRequest?) -> Void
    )

    // MARK: Options with defaults

    /// The service's own settings, with every field defaulted.
    ///
    /// This is the *only* description of what an instance of this service
    /// stores: it both seeds a newly added instance and normalizes a stored one,
    /// so a value that is missing or of the wrong type resolves to the same
    /// default in both cases. Keys the service does not list here are carried
    /// through untouched (the shared template adds them), which keeps
    /// user-defined extras — a custom webhook's headers, say — from being lost.
    static func defaultPrefs() -> [String: Any]

    /// The service's own keys that an app override may change, defaulted.
    ///
    /// An override starts as a copy of these, so an app that is not customized
    /// further behaves exactly like the service.
    static func defaultCustomAppPrefs() -> [String: Any]

    /// Whether this service's payload can carry the app icon at all.
    ///
    /// A *capability*, not a setting. A destination that has no field for an
    /// icon (Feishu, Wechat) can never use one, so its pages must not offer the
    /// switch: an option that changes nothing is worse than no option, because
    /// the user reads it as a promise. ``shouldIncludeIcon`` is the setting, and
    /// is only asked when this is true.
    static var supportsIcon: Bool { get }

    /// Whether this service's payload can carry the attachment image at all.
    ///
    /// See ``supportsIcon``.
    static var supportsImage: Bool { get }

    /// Whether the app icon belongs in the shared data dict.
    static func shouldIncludeIcon(config: ServiceConfig) -> Bool

    /// Whether the bulletin's attachment belongs in the shared data dict.
    static func shouldIncludeImage(config: ServiceConfig) -> Bool

    /// Keys in the payload holding large Base64 image data; these are replaced
    /// with a placeholder in the log copy. Override with `[]` for a service
    /// with no Base64 image fields.
    static var logImageDataProperties: [String] { get }
}

// MARK: - Defaults

public extension PushService {
    /// A service that stores nothing of its own.
    static func defaultPrefs() -> [String: Any] { [:] }

    /// A service whose overrides change nothing of their own.
    static func defaultCustomAppPrefs() -> [String: Any] { [:] }

    static var supportsIcon: Bool { false }
    static var supportsImage: Bool { false }
    static func shouldIncludeIcon(config: ServiceConfig) -> Bool { false }
    static func shouldIncludeImage(config: ServiceConfig) -> Bool { false }
    static var logImageDataProperties: [String] { Pusher.logImageDataProperties }

    static func request(
        context: BulletinContext,
        config: ServiceConfig,
        completion: @escaping (PushRequest?) -> Void
    ) {
        completion(request(context: context, config: config))
    }

    /// The shared data dict used by IFTTT / Pusher Receiver / custom services:
    /// `deviceName` / `appName` / `appID` / `title` / `subtitle` / `message` /
    /// `date`, plus an optional icon and attachment image.
    static func baseInfoDict(context: BulletinContext, config: ServiceConfig) -> [String: Any] {
        var data: [String: Any] = [
            "deviceName": UIDevice.current.name,
            "appName": context.appName,
            "appID": context.appID,
            "title": context.title ?? "",
            "subtitle": context.subtitle ?? "",
            "message": context.message ?? "",
            "date": dateString(context.date, config: config),
        ]

        if shouldIncludeIcon(config: config) {
            // The service's own icon wins over the sending app's.
            //
            // A service often reaches an account rather than an app — a bot, a
            // channel, a webhook — so the app icon is the wrong picture twice
            // over. When the user has picked one, it is already stored at its
            // final size, so it travels verbatim; only the app icon has to be
            // rendered, which is why the provider is consulted second.
            if let own = ServiceIcon.image(from: config.raw) {
                data["icon"] = ServiceIcon.storedValue(own)
            } else if let base64 = PushImage.base64(context.iconImage) {
                // The provider resolves the app icon through SpringBoard on
                // demand and may hop to the main thread; it returns nil when no
                // icon is available, in which case the field is omitted.
                data["icon"] = base64
            }
        }

        if shouldIncludeImage(config: config), let url = context.attachmentURL,
           let image = loadImage(at: url) {
            data["imageShrinkFactor"] = config.raw[PrefKey.imageShrinkFactor]
            data["image"] = shrinkIfNeeded(image, config: config)
        } else if shouldIncludeImage(config: config), context.attachmentURL != nil {
            // Tell the receiver there *is* an image even when it could not be
            // decoded, so a missing attachment is distinguishable from none.
            data["image"] = true
        }

        return data
    }

    /// The bulletin's attachment as an image.
    ///
    /// Rather than trusting a hard-coded attachment type, the URL is loaded as
    /// an image; it is a file URL on disk, with a raw-data fallback.
    static func loadImage(at url: URL) -> UIImage? {
        if let image = UIImage(contentsOfFile: url.path) { return image }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// Shrinks an attachment to the configured maximum dimensions.
    static func shrinkIfNeeded(_ image: UIImage, config: ServiceConfig) -> UIImage {
        let maxWidth = config.raw.double(PrefKey.imageMaxWidth)
        let maxHeight = config.raw.double(PrefKey.imageMaxHeight)

        var widthFactor: CGFloat = 0
        var heightFactor: CGFloat = 0
        if maxWidth > 0, image.size.width > maxWidth {
            widthFactor = image.size.width / maxWidth
        }
        if maxHeight > 0, image.size.height > maxHeight {
            heightFactor = image.size.height / maxHeight
        }
        // Shrink by the larger of the two factors when either applies.
        let factor = max(widthFactor, heightFactor)
        return factor > 0 ? PushImage.shrunk(image, by: factor) : image
    }

    /// The `date` field, formatted with the service's configured format.
    static func dateString(_ date: Date, config: ServiceConfig) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = config.raw.string(PrefKey.dateFormat, default: "MMM d, h:mm a")
        return formatter.string(from: date)
    }

    /// A copy of the payload that is safe to log: large Base64 image fields are
    /// replaced with a placeholder.
    ///
    /// The `imageShrinkFactor` retry hint is dropped too — it is an internal
    /// field, never part of the real body.
    static func logInfoDict(_ infoDict: [String: Any]) -> [String: Any] {
        var sanitized = infoDict
        for property in logImageDataProperties where sanitized[property] != nil {
            sanitized[property] = Pusher.logImageDataReplacement
        }
        sanitized.removeValue(forKey: "imageShrinkFactor")
        return sanitized
    }

    /// Attaches the sanitized payload to a request.
    static func withLogBody(_ request: PushRequest, _ infoDict: [String: Any]) -> PushRequest {
        request.logInfoDict = logInfoDict(infoDict)
        return request
    }
}
