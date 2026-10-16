import Foundation

/// ServerChan³, the newer ServerChan. Its own user system and its own SendKeys —
/// the two services are not interchangeable, which is why both are listed.
///
/// The SendKey carries the account: it begins `sctp{uid}t…`, and the host is built
/// from that `uid`. A key that does not match the shape is sent nowhere rather
/// than to a wrong host, because the alternative is a request to a domain that
/// does not exist for that user.
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
            ServerChan3PrefKey.sendKey: "",
            ServerChan3PrefKey.tags: "",
            ServerChan3PrefKey.short: "",
        ]
    }

    public static func request(context: BulletinContext, config: ServiceConfig) -> PushRequest? {
        guard let uid = uid(fromSendKey: config.raw.string(ServerChan3PrefKey.sendKey, default: ""))
        else { return nil }

        // A body is required when there is no title, and the title may be empty on
        // a test push, so the two swap roles rather than leaving one blank.
        let hasBody = !context.displayMessage.isEmpty

        var infoDict: [String: Any] = [
            "title": hasBody ? context.displayTitle : context.appName,
            "desp": hasBody ? context.displayMessage : (context.title ?? context.appName),
        ]
        let tags = config.raw.string(ServerChan3PrefKey.tags, default: "")
        if !tags.isEmpty { infoDict["tags"] = tags }
        let short = config.raw.string(ServerChan3PrefKey.short, default: "")
        if !short.isEmpty { infoDict["short"] = short }

        let key = config.raw.string(ServerChan3PrefKey.sendKey, default: "")
        let urlString = "https://\(uid)\(urlSuffix)\(key).send"
        return withLogBody(PushRequest(urlString: urlString, infoDict: infoDict), infoDict)
    }

    /// The account number inside a SendKey, which the API host is built from.
    ///
    /// Documented as `/^sctp(\d+)t/`: `sctp12345t…` belongs to account 12345.
    private static func uid(fromSendKey key: String) -> String? {
        guard key.hasPrefix("sctp") else { return nil }
        let digits = key.dropFirst(4).prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }
}

/// The keys this service's settings are stored under.
enum ServerChan3PrefKey {
    static let sendKey = "sendKey"
    static let tags = "tags"
    static let short = "short"
}
