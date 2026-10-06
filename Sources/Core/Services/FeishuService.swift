import Foundation

/// Feishu (Lark) group bot webhook.
///
/// Feishu's payload is a single text message, so the bulletin's parts are
/// joined into one block rather than using the shared data dict.
public enum FeishuService: PushService {
    public static let serviceName = "Feishu"
    static let urlTemplate = "https://open.feishu.cn/open-apis/bot/v2/hook/REPLACE_KEY"

    public static func url(eventName: String, dbName: String, serverURL: String) -> String {
        urlTemplate
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
        return withLogBody(
            PushRequest(urlString: replacedKeyURL(config: config), infoDict: infoDict),
            infoDict
        )
    }
}
