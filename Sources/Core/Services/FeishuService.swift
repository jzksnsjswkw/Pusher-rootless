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

    public static func request(context: BulletinContext, config: ServiceConfig) -> PushRequest? {
        // Join the parts that are present, skipping the ones that are not, so
        // the message has no blank leading lines.
        let parts = [context.appName, context.title, context.subtitle, context.message]
            .compactMap { $0 }
            .filter { !$0.isEmpty }

        let infoDict: [String: Any] = [
            "msg_type": "text",
            "content": ["text": parts.joined(separator: "\r\n")],
        ]
        let urlString = urlBase + config.raw.string(PrefKey.key, default: "")
        return withLogBody(
            PushRequest(urlString: urlString, infoDict: infoDict),
            infoDict
        )
    }
}
