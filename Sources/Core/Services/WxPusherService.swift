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
    /// The simple-push endpoint. Same host, different path, and no app token: an
    /// SPT names its own recipient.
    static let simplePushURL = "https://wxpusher.zjiecode.com/api/send/message/simple-push"

    public static func url(eventName: String, dbName: String, serverURL: String) -> String {
        pushURL
    }

    public static func defaultPrefs() -> [String: Any] {
        [
            WxPusherPrefKey.mode: WxPusherMode.spt.rawValue,
            WxPusherPrefKey.spt: "",
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
            "content": hasBody ? context.displayMessage : (context.title ?? context.appName),
            // 1 text, 2 HTML, 3 Markdown. Text is the default the API documents.
            "contentType": config.raw.int(WxPusherPrefKey.contentType, default: 1),
        ]

        // Two ways to send, chosen on the page rather than inferred from which
        // field was filled in: a user who pastes an App Token and leaves an SPT
        // from an earlier attempt behind would otherwise be sent the wrong way
        // with nothing on screen saying so.
        let mode = WxPusherMode(
            rawValue: config.raw.string(WxPusherPrefKey.mode, default: "")
        ) ?? .spt
        let spt = config.raw.string(WxPusherPrefKey.spt, default: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == .spt, !spt.isEmpty {
            infoDict["spt"] = spt
            let summary = hasBody ? context.displayTitle : context.appName
            if !summary.isEmpty { infoDict["summary"] = summary }
            let url = config.raw.string(WxPusherPrefKey.url, default: "")
            if !url.isEmpty { infoDict["url"] = url }
            return withLogBody(
                PushRequest(urlString: simplePushURL, infoDict: infoDict), infoDict
            )
        }

        infoDict["appToken"] = config.raw.string(WxPusherPrefKey.appToken, default: "")

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
/// Which of the two ways to send this instance uses.
public enum WxPusherMode: String {
    /// A personal token from the WxPusher site. No app, no user list.
    case spt
    /// An app's token, with recipients named by UID or topic.
    case app
}

enum WxPusherPrefKey {
    static let mode = "wxPusherMode"
    /// A simple push token, `SPT_…`.
    static let spt = "spt"
    static let appToken = "appToken"
    static let uids = "uids"
    static let topicIds = "topicIds"
    static let contentType = "contentType"
    static let url = "url"
}
