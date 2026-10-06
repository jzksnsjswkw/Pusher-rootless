import Foundation

/// Bark (`https://api.day.app`), including self-hosted servers.
public enum BarkService: PushService {
    public static let serviceName = "Bark"
    static let defaultURL = "https://api.day.app/REPLACE_KEY"

    public static func url(eventName: String, dbName: String, serverURL: String) -> String {
        guard !serverURL.isEmpty else { return defaultURL }
        // A user-entered server URL may or may not end in a slash; normalise so
        // the key segment is always appended cleanly.
        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        return base + "/REPLACE_KEY"
    }

    /// Bark's `image` parameter is a user-entered image URL, not Base64 image
    /// data, so the default replacement would wrongly hide it in the log.
    /// Nothing in Bark's body carries Base64 image data.
    public static var logImageDataProperties: [String] { [] }

    /// The Bark push API parameter names, keyed by preference key.
    private static let parameters: [(prefKey: String, apiName: String)] = [
        (BarkPrefKey.level, "level"),
        (BarkPrefKey.volume, "volume"),
        (BarkPrefKey.badge, "badge"),
        (BarkPrefKey.call, "call"),
        (BarkPrefKey.autoCopy, "autoCopy"),
        (BarkPrefKey.sound, "sound"),
        (BarkPrefKey.image, "image"),
        (BarkPrefKey.group, "group"),
        (BarkPrefKey.isArchive, "isArchive"),
        (BarkPrefKey.ttl, "ttl"),
        (BarkPrefKey.clickURL, "url"),
        (BarkPrefKey.action, "action"),
        (BarkPrefKey.id, "id"),
        (BarkPrefKey.delete, "delete"),
    ]

    public static func request(context: BulletinContext, config: ServiceConfig) -> PushRequest? {
        var infoDict: [String: Any] = [
            "title": context.displayTitle,
            "body": context.displayMessage,
        ]
        for (prefKey, apiName) in parameters {
            let value = config.raw.string(prefKey) ?? ""
            if !value.isEmpty { infoDict[apiName] = value }
        }
        // `delete` is only meaningful together with an id.
        if infoDict["delete"] != nil, infoDict["id"] == nil {
            infoDict.removeValue(forKey: "delete")
        }

        return withLogBody(
            PushRequest(urlString: replacedKeyURL(config: config), infoDict: infoDict),
            infoDict
        )
    }

    public static func extraPrefs(_ servicePrefs: Prefs) -> [String: Any]? {
        var prefs: [String: Any] = [
            PrefKey.serverURL: servicePrefs.string(PrefKey.serverURL, default: "https://api.day.app"),
        ]
        for (prefKey, _) in parameters {
            prefs[prefKey] = servicePrefs.string(prefKey) ?? ""
        }
        return prefs
    }

    public static func extraCustomAppPrefs(_ appPrefs: Prefs) -> [String: Any]? {
        var prefs: [String: Any] = [:]
        for (prefKey, _) in parameters {
            prefs[prefKey] = appPrefs.string(prefKey) ?? ""
        }
        return prefs
    }
}

/// Bark's own preference keys.
///
/// These are plain strings in the plist; naming them keeps the parameter table
/// above readable and makes a typo a compile error rather than a silently
/// ignored push parameter.
enum BarkPrefKey {
    static let level = "level"
    static let volume = "volume"
    static let badge = "badge"
    static let call = "call"
    static let autoCopy = "autoCopy"
    static let sound = "sound"
    static let image = "image"
    static let group = "group"
    static let isArchive = "isArchive"
    static let ttl = "ttl"
    static let clickURL = "clickURL"
    static let action = "action"
    static let id = "id"
    static let delete = "delete"
}
