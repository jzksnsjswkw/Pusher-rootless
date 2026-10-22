import Foundation

/// Feishu (Lark) group bot webhook.
///
/// The push URL is `https://open.feishu.cn/open-apis/bot/v2/hook/{key}`; the
/// key is the webhook token from the bot's configuration page.
public enum FeishuService: PushService {
    public static let serviceName = "Feishu"
    static let urlBase = "https://open.feishu.cn/open-apis/bot/v2/hook/"

    public static func url(eventName: String, dbName: String, serverURL: String) -> String {
        urlBase
    }

    public static func defaultPrefs() -> [String: Any] {
        [FeishuPrefKey.secret: ""]
    }

    public static func request(context: BulletinContext, config: ServiceConfig) -> PushRequest? {
        // The four parts in the order the original assembled them, and with its
        // punctuation: the app name takes a colon before the title — "微信: 西瓜猪"
        // — and the lines after it are separated by a bare carriage return.
        //
        // Built by appending rather than by joining a filtered list, because each
        // part is added only if there is something before it or not: the colon
        // belongs between the first two and nowhere else, so a message with no
        // app name starts at the title, and one with no title puts the subtitle on
        // the first line without a leading ":" or blank line.
        var text: String?
        if !context.appName.isEmpty {
            text = context.appName
        }
        if let title = context.title, !title.isEmpty {
            if let current = text {
                text = current + ": " + title
            } else {
                text = title
            }
        }
        if let subtitle = context.subtitle, !subtitle.isEmpty {
            if let current = text {
                text = current + "\r" + subtitle
            } else {
                text = subtitle
            }
        }
        if let message = context.message, !message.isEmpty {
            if let current = text {
                text = current + "\r" + message
            } else {
                text = message
            }
        }

        var infoDict: [String: Any] = [
            "msg_type": "text",
            "content": ["text": text ?? ""],
        ]

        // A bot can require a signature, and then every request must carry
        // `timestamp` and `sign` *in the body* — Feishu differs from DingTalk here,
        // which puts the same pair in the query string.
        //
        // The scheme is also the reverse of DingTalk's: there the secret is the key
        // and `"<seconds>\n<secret>"` the message; here that string is the key and
        // the message is empty. The timestamp is in seconds, not milliseconds.
        let secret = config.raw.string(FeishuPrefKey.secret, default: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty {
            let timestamp = Int(Date().timeIntervalSince1970)
            // The reverse of DingTalk: `"<seconds>\n<secret>"` is the key and the
            // message is empty.
            infoDict["timestamp"] = String(timestamp)
            infoDict["sign"] = HmacSHA256.sign(
                key: "\(timestamp)\n\(secret)", message: ""
            )
        }
        let urlString = urlBase + config.raw.string(PrefKey.key, default: "")
        return withLogBody(
            PushRequest(urlString: urlString, infoDict: infoDict),
            infoDict
        )
    }
}

enum FeishuPrefKey {
    /// The bot's signing secret, empty when the bot does not require one.
    static let secret = "secret"
}
