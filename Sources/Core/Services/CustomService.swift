import Foundation

/// A user-defined webhook.
///
/// Custom services are configured entirely from the UI: a URL, an optional key
/// with a choice of how to send it (query, header or body), an HTTP method and a
/// body encoding. Any service name that is not a built-in one resolves here.
public enum CustomService: PushService {
    /// The registry name this descriptor is reached by. Instances carry their
    /// own user-chosen names; this identifies the *kind*.
    public static let serviceName = "Custom"

    public static func url(eventName: String, dbName: String, serverURL: String) -> String {
        ""
    }

    /// How the configured key is transmitted.
    private enum AuthenticationMethod: Int {
        /// The key is already part of the URL the user entered.
        case url = 0
        /// Sent as an HTTP header named by `paramName` (default `Access-Token`).
        case header = 1
        /// Embedded in the JSON body under `paramName` (default `key`).
        case body = 2
    }

    public static func request(context: BulletinContext, config: ServiceConfig) -> PushRequest? {
        var infoDict = baseInfoDict(context: context, config: config)

        let key = config.raw.string(PrefKey.key, default: "")
        let paramName = config.raw.string(PrefKey.paramName, default: "")
        let method = AuthenticationMethod(rawValue: config.raw.int(PrefKey.authenticationMethod))
            ?? .url

        var headers: [String: String] = [:]
        switch method {
        case .url:
            break
        case .header:
            headers[paramName.isEmpty ? "Access-Token" : paramName] = key
        case .body:
            infoDict[paramName.isEmpty ? "key" : paramName] = key
        }

        let request = PushRequest(
            urlString: config.raw.string(PrefKey.url, default: ""),
            headers: headers,
            infoDict: infoDict,
            method: config.raw.string(PrefKey.method, default: "POST")
        )
        request.bodyType = config.raw.string(PrefKey.bodyType, default: "json")
        return withLogBody(request, infoDict)
    }

    public static func shouldIncludeIcon(config: ServiceConfig) -> Bool {
        config.raw.bool(PrefKey.includeIcon)
    }

    public static func shouldIncludeImage(config: ServiceConfig) -> Bool {
        config.raw.bool(PrefKey.includeImage)
    }

    /// Everything a new webhook needs, so a freshly added instance can be
    /// configured rather than arriving blank.
    public static func defaultPrefs() -> [String: Any] {
        [
            PrefKey.url: "",
            PrefKey.key: "",
            PrefKey.paramName: "",
            PrefKey.method: "POST",
            PrefKey.bodyType: "json",
            PrefKey.authenticationMethod: 0,
            // The payload's `date` field is formatted with this, and
            // `Custom.plist` offers a field for it.
            PrefKey.dateFormat: "MMM d, h:mm a",
            PrefKey.includeIcon: false,
            PrefKey.includeImage: true,
            PrefKey.imageMaxWidth: Pusher.defaultMaxWidth,
            PrefKey.imageMaxHeight: Pusher.defaultMaxHeight,
            PrefKey.imageShrinkFactor: Pusher.defaultShrinkFactor,
        ]
    }

    public static func defaultCustomAppPrefs() -> [String: Any] {
        [
            PrefKey.includeIcon: false,
            PrefKey.includeImage: true,
            PrefKey.imageMaxWidth: Pusher.defaultMaxWidth,
            PrefKey.imageMaxHeight: Pusher.defaultMaxHeight,
            PrefKey.imageShrinkFactor: Pusher.defaultShrinkFactor,
        ]
    }
}
