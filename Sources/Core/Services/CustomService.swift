import Foundation

/// A user-defined webhook.
///
/// Custom services are configured entirely from the UI: a URL template, an
/// optional key with a choice of how to send it (query, header or body), an
/// HTTP method and a body encoding. Any service name that is not a built-in one
/// resolves here.
public enum CustomService: PushService {
    /// Custom services are keyed by their user-chosen name in prefs, so there
    /// is no single registry name.
    public static let serviceName = ""

    public static func url(eventName: String, dbName: String, serverURL: String) -> String {
        ""
    }

    /// How the configured key is transmitted.
    private enum AuthenticationMethod: Int {
        /// Substituted into the URL template (`REPLACE_KEY`).
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
            urlString: replacedKeyURL(config: config),
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
}
