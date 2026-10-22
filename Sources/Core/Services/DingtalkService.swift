import Foundation

/// DingTalk's group robot, which posts into a chat rather than to people.
///
/// One URL carries the whole credential — `https://oapi.dingtalk.com/robot/send?access_token=…`
/// — and the message goes in a JSON body shaped by `msgtype`.
///
/// A robot can also be made to require a signature. It then checks every request
/// for `timestamp` and `sign`, where the sign is the HMAC-SHA256 of
/// `"<timestamp>\n<secret>"` under the robot's own secret, base64-encoded and
/// URL-encoded. This service computes it per request, as the protocol requires:
/// the signature covers the timestamp, so a fixed one would expire.
///
/// @mentions are separate from the text: the API takes the numbers and handles the
/// highlighting, but a mention of a person reads as a bare number in the message,
/// so the same numbers are appended to the body as `@13800138000`. That is what the
/// client shows, and what the person sees when the mention does not highlight.
public enum DingtalkService: PushService {
    public static let serviceName = "Dingtalk"

    static let endpoint = "https://oapi.dingtalk.com/robot/send"

    public static func url(eventName: String, dbName: String, serverURL: String) -> String {
        endpoint
    }

    public static func defaultPrefs() -> [String: Any] {
        [
            DingtalkPrefKey.token: "",
            DingtalkPrefKey.secret: "",
            DingtalkPrefKey.atMobiles: "",
            DingtalkPrefKey.atAll: false,
        ]
    }

    public static func request(context: BulletinContext, config: ServiceConfig) -> PushRequest? {
        let token = config.raw.string(DingtalkPrefKey.token, default: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The token is the whole credential; a request without one has no
        // recipient at all.
        guard !token.isEmpty else { return nil }

        var components = URLComponents(string: endpoint)
        var query = [URLQueryItem(name: "access_token", value: token)]

        // The signature covers the timestamp, so both are made together and sent
        // together. Absent a secret the robot does not check, and adding an empty
        // one would be rejected.
        let secret = config.raw.string(DingtalkPrefKey.secret, default: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty {
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            query.append(URLQueryItem(name: "timestamp", value: String(timestamp)))
            query.append(URLQueryItem(
                name: "sign", value: sign(timestamp: timestamp, secret: secret)
            ))
        }
        components?.queryItems = query
        guard let urlString = components?.string else { return nil }

        // Text only. The markdown type has no title of its own to speak of, does not
        // highlight @mentions, and needs the number repeated in the body — three
        // ways to be worse for the same message, for a formatting nobody asked for
        // in a notification.
        let body = messageText(context: context, config: config)
        var infoDict: [String: Any] = [
            "msgtype": "text",
            "text": ["content": body],
        ]

        let atAll = config.raw.bool(DingtalkPrefKey.atAll)
        let mobiles = splitMobiles(config.raw.string(DingtalkPrefKey.atMobiles, default: ""))
        if atAll || !mobiles.isEmpty {
            var at: [String: Any] = ["isAtAll": atAll]
            if !atAll, !mobiles.isEmpty {
                at["atMobiles"] = mobiles
            }
            infoDict["at"] = at
        }

        return withLogBody(PushRequest(urlString: urlString, infoDict: infoDict), infoDict)
    }

    /// The message body.
    ///
    /// No `@number` is appended, unlike the pattern other chat APIs need. A `text`
    /// message is rendered by DingTalk itself: given `at.atMobiles`, it replaces the
    /// number with the person's display name and appends it when the body has no
    /// place for it. Verified against a real group — a body with no mention came out
    /// with a blue `@end` added at the end, and one that already contained the number
    /// had it replaced in place. Appending our own copy would have produced two.
    private static func messageText(context: BulletinContext, config: ServiceConfig) -> String {
        // Assembled from the raw fields, the way the Feishu message is, and not
        // from `displayMessage`. That property folds the subtitle in only when the
        // bulletin says the system is showing it — a decision about the phone's
        // screen, not about what the user wants forwarded. A notification with a
        // subtitle therefore reached the group without it.
        var lines = [context.displayTitle]
        if let subtitle = context.subtitle, !subtitle.isEmpty {
            lines.append(subtitle)
        }
        if let message = context.message, !message.isEmpty {
            lines.append(message)
        }
        return lines.joined(separator: "\n")
    }

    /// Splits a list of phone numbers, accepting the separators a pasted list
    /// carries — full-width comma and semicolon included, since the field is
    /// usually filled from a Chinese keyboard.
    private static func splitMobiles(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",，;；")
        return text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The robot's signature: the secret is the key, `"<ms>\n<secret>"` the
    /// message. The query string wants the base64 percent-escaped.
    private static func sign(timestamp: Int, secret: String) -> String {
        HmacSHA256.sign(key: secret, message: "\(timestamp)\n\(secret)")
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
}

/// The keys this service's settings are stored under.
enum DingtalkPrefKey {
    static let token = "token"
    static let secret = "secret"
    static let atMobiles = "atMobiles"
    static let atAll = "atAll"
}
