import Foundation

/// 企业微信's group robot — the "消息推送" robot a group admin adds, not the
/// application that sends to named users.
///
/// The credential is a key in the webhook URL
/// (`https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=…`), and unlike
/// DingTalk there is no signature and no keyword to satisfy: a valid key is the
/// whole of the authentication, and a wrong one comes back as `93000 invalid
/// webhook url`.
///
/// Text only. The message body is assembled exactly as the DingTalk one is —
/// composed title, subtitle, message, one per line — so a notification reads the
/// same in either chat.
public enum WeComRobotService: PushService {
    public static let serviceName = "WeComRobot"

    static let endpoint = "https://qyapi.weixin.qq.com/cgi-bin/webhook/send"

    public static func url(eventName: String, dbName: String, serverURL: String) -> String {
        endpoint
    }

    public static func defaultPrefs() -> [String: Any] {
        [WeComPrefKey.token: ""]
    }

    public static func request(context: BulletinContext, config: ServiceConfig) throws -> PushRequest? {
        let token = config.raw.string(WeComPrefKey.token, default: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw RequestError.missingField("Key")
        }
        // `URLComponents` encodes the *value*, not the whole URL. Percent-encoding
        // the assembled string would leave `&` and `=` in the key unescaped, which
        // is how an imported key with a `&` silently becomes a second parameter.
        var components = URLComponents(string: endpoint)
        components?.queryItems = [URLQueryItem(name: "key", value: token)]
        guard let urlString = components?.string else { return nil }

        // The same three lines as the DingTalk message, for the same reason: an
        // empty body is rejected, and a missing part should not leave a blank line.
        var lines = [context.displayTitle]
        if let subtitle = context.subtitle, !subtitle.isEmpty {
            lines.append(subtitle)
        }
        if let message = context.message, !message.isEmpty {
            lines.append(message)
        }

        let infoDict: [String: Any] = [
            "msgtype": "text",
            "text": ["content": lines.joined(separator: "\n")],
        ]

        return withLogBody(PushRequest(urlString: urlString, infoDict: infoDict), infoDict)
    }
}

/// The keys this service's settings are stored under.
enum WeComPrefKey {
    static let token = "token"
}
