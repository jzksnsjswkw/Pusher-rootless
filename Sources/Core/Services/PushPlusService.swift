import Foundation

/// PushPlus (推送加), a WeChat-based push service.
///
/// One endpoint takes a user token and the message, and one request sends it. The
/// API answers `code: 200` for "the request was well formed" rather than "the
/// message was delivered" — delivery is asynchronous — so the send path has
/// nothing to wait on.
/// The keys this service's settings are stored under.
///
/// Bare names, so a stored instance carries `token` rather than
/// `pushplusToken` — a service's parameters are its own vocabulary and the
/// instance already says which service it belongs to.
enum PushPlusPrefKey {
    static let token = "token"
    static let topic = "topic"
    static let template = "template"
}

public enum PushPlusService: PushService {
    public static let serviceName = "PushPlus"
    static let pushURL = "https://www.pushplus.plus/send"

    public static func url(eventName: String, dbName: String, serverURL: String) -> String {
        pushURL
    }

    public static func defaultPrefs() -> [String: Any] {
        [
            PushPlusPrefKey.token: "",
            PushPlusPrefKey.topic: "",
            PushPlusPrefKey.template: "html",
        ]
    }

    public static func request(context: BulletinContext, config: ServiceConfig) -> PushRequest? {
        var infoDict: [String: Any] = [
            "token": config.raw.string(PushPlusPrefKey.token, default: ""),
            "title": context.displayTitle,
            // Required, like WxPusher's: an empty one is refused.
            "content": context.pushBody,
        ]
        // Both are optional and both have a sensible server-side default —
        // sending to the account itself, in the HTML template — so an empty field
        // leaves the key out rather than sending an empty value, which the API
        // would take as a choice.
        let topic = config.raw.string(PushPlusPrefKey.topic, default: "")
        if !topic.isEmpty { infoDict["topic"] = topic }
        let template = config.raw.string(PushPlusPrefKey.template, default: "")
        if !template.isEmpty { infoDict["template"] = template }

        return withLogBody(PushRequest(urlString: pushURL, infoDict: infoDict), infoDict)
    }
}
