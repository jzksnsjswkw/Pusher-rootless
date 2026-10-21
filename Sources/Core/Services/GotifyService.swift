import Foundation

/// Gotify, a push service you host yourself.
///
/// One endpoint takes everything in the query string — `?token=…` — and the message
/// in a JSON body:
///
///     POST https://your-server/message?token=APP_TOKEN
///     { "title": "…", "message": "…", "priority": 5 }
///
/// Its reason to exist in this app is that nothing leaves the user's own server.
/// Every other built-in service is somebody's hosted product, and someone who runs
/// their own is usually not looking for another hosted one.
///
/// Basic authentication is written into the server URL — `https://user:pass@host` —
/// which the sender turns into a header. That is a field fewer to configure, and it
/// is how people write such a URL anyway.
public enum GotifyService: PushService {
    public static let serviceName = "Gotify"

    /// The token goes in the query string and the message in the body, so the URL
    /// is a function of the instance's own server and token.
    public static func url(eventName: String, dbName: String, serverURL: String) -> String {
        ""
    }

    public static func defaultPrefs() -> [String: Any] {
        [
            GotifyPrefKey.serverURL: "",
            GotifyPrefKey.token: "",
            GotifyPrefKey.priority: 5,
        ]
    }

    public static func request(context: BulletinContext, config: ServiceConfig) -> PushRequest? {
        let server = config.raw.string(GotifyPrefKey.serverURL, default: "")
            .trimmingCharacters(in: .whitespaces)
        let token = config.raw.string(GotifyPrefKey.token, default: "")
            .trimmingCharacters(in: .whitespaces)
        // Both are needed, and a URL built without either would be a request to
        // nowhere. A trailing slash is common and would produce `//message`.
        guard !server.isEmpty, !token.isEmpty else { return nil }

        var base = server.hasSuffix("/") ? String(server.dropLast()) : server
        if !base.lowercased().hasSuffix("/message") { base += "/message" }

        var components = URLComponents(string: base)
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let urlString = components?.string else { return nil }

        // `message` is required — the server answers 400 "Field 'message' is
        // required" for an empty one — and a notification may be a title alone, so
        // the body falls back to the title. The title keeps the app's name either
        // way, so the two fields are not the same sentence.
        let hasBody = !context.displayMessage.isEmpty
        var infoDict: [String: Any] = [
            "title": hasBody ? context.displayTitle : context.appName,
            "message": hasBody
                ? context.displayMessage
                : (context.title ?? context.appName),
        ]
        // A priority is one of Gotify's own notions — higher values make the client
        // shout — and its default of 0 is silent, so the app's own default is sent.
        let priority = config.raw.int(GotifyPrefKey.priority, default: 5)
        infoDict["priority"] = priority

        let request = PushRequest(urlString: urlString, infoDict: infoDict)
        return withLogBody(request, infoDict)
    }
}

/// The keys this service's settings are stored under.
enum GotifyPrefKey {
    static let serverURL = "serverURL"
    static let token = "token"
    static let priority = "priority"
}
