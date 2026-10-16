import Foundation

/// ServerChan³, the newer ServerChan. Its own user system and its own SendKeys —
/// the two services are not interchangeable, which is why both are listed.
///
/// The account number is part of the host — `https://{uid}.push.ft07.com/...` —
/// and the SendKey page shows it alongside the key. It could be parsed out of the
/// key, which begins `sctp{uid}t…`, and that is not what happens: the two are
/// typed in separately. A key pasted from a different account than the number
/// beside it would otherwise build a URL that looks right and belongs to someone
/// else.
public enum ServerChan3Service: PushService {
    public static let serviceName = "ServerChan3"
    static let urlSuffix = ".push.ft07.com/send/"

    public static func url(eventName: String, dbName: String, serverURL: String) -> String {
        // The real URL carries the account and the key, so the host is built per
        // instance in `request`. Nothing is left for this to return.
        ""
    }

    public static func defaultPrefs() -> [String: Any] {
        [
            ServerChan3PrefKey.uid: "",
            ServerChan3PrefKey.sendKey: "",
            ServerChan3PrefKey.tags: "",
        ]
    }

    public static func request(context: BulletinContext, config: ServiceConfig) -> PushRequest? {
        // A body is required when there is no title, and the title may be empty on
        // a test push, so the two swap roles rather than leaving one blank.
        let hasBody = !context.displayMessage.isEmpty

        var infoDict: [String: Any] = [
            "title": hasBody ? context.displayTitle : context.appName,
            "desp": hasBody ? context.displayMessage : (context.title ?? context.appName),
        ]
        let tags = config.raw.string(ServerChan3PrefKey.tags, default: "")
        if !tags.isEmpty { infoDict["tags"] = tags }

        let uid = config.raw.string(ServerChan3PrefKey.uid, default: "")
            .trimmingCharacters(in: .whitespaces)
        let key = config.raw.string(ServerChan3PrefKey.sendKey, default: "")
            .trimmingCharacters(in: .whitespaces)
        guard !uid.isEmpty, !key.isEmpty else { return nil }
        let urlString = "https://\(uid)\(urlSuffix)\(key).send"
        return withLogBody(PushRequest(urlString: urlString, infoDict: infoDict), infoDict)
    }
}

/// The keys this service's settings are stored under.
enum ServerChan3PrefKey {
    static let uid = "uid"
    static let sendKey = "sendKey"
    static let tags = "tags"
}
