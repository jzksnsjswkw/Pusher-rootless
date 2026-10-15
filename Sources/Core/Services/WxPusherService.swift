import Foundation

/// WxPusher, which delivers to its own apps and to WeChat.
///
/// One endpoint takes an app token and the message. The recipient is reached
/// either by user id or by topic, and the API wants whichever is used as an
/// array — so the field is a comma-separated string here and split on the way
/// out, which is what the page can offer as one field.
public enum WxPusherService: PushService {
    public static let serviceName = "WxPusher"
    static let pushURL = "https://wxpusher.zjiecode.com/api/send/message"

    public static func url(eventName: String, dbName: String, serverURL: String) -> String {
        pushURL
    }

    public static func defaultPrefs() -> [String: Any] {
        [
            WxPusherPrefKey.appToken: "",
            WxPusherPrefKey.uids: "",
            WxPusherPrefKey.topicIds: "",
            WxPusherPrefKey.contentType: 1,
            WxPusherPrefKey.url: "",
        ]
    }

    public static func request(context: BulletinContext, config: ServiceConfig) -> PushRequest? {
        // A body is required, and a notification may be a title alone: the two
        // fields swap roles so neither is empty and nothing is printed twice.
        let hasBody = !context.displayMessage.isEmpty

        var infoDict: [String: Any] = [
            "appToken": config.raw.string(WxPusherPrefKey.appToken, default: ""),
            "content": hasBody ? context.displayMessage : (context.title ?? context.appName),
            // 1 text, 2 HTML, 3 Markdown. Text is the default the API documents.
            "contentType": config.raw.int(WxPusherPrefKey.contentType, default: 1),
        ]

        // Left out when empty rather than sent as "": the platform then shows the
        // content, which reads better than a blank line.
        let summary = hasBody ? context.displayTitle : context.appName
        if !summary.isEmpty { infoDict["summary"] = summary }

        // Both lists are sent as arrays; empty ones are left out rather than sent
        // as `[]`, which the API reads as "this app has no recipients" and rejects.
        let uids = Self.split(
            config.raw.string(WxPusherPrefKey.uids, default: "")
        )
        if !uids.isEmpty { infoDict["uids"] = uids }

        let topicIds = Self.split(
            config.raw.string(WxPusherPrefKey.topicIds, default: "")
        )
        if !topicIds.isEmpty { infoDict["topicIds"] = topicIds.map(Int.init).compactMap { $0 } }

        let url = config.raw.string(WxPusherPrefKey.url, default: "")
        if !url.isEmpty { infoDict["url"] = url }

        return withLogBody(PushRequest(urlString: pushURL, infoDict: infoDict), infoDict)
    }

    /// Splits a comma-separated field into its entries, dropping blanks.
    ///
    /// Whitespace and empty segments are what a pasted list has; the API would
    /// treat an empty entry as a recipient that matches nothing.
    private static func split(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// The keys this service's settings are stored under.
enum WxPusherPrefKey {
    static let appToken = "appToken"
    static let uids = "uids"
    static let topicIds = "topicIds"
    static let contentType = "contentType"
    static let url = "url"
}
