import Foundation

/// Bark (`https://api.day.app`), including self-hosted servers.
///
/// The push URL is `{server}/{key}`; the server defaults to `api.day.app` and
/// can be overridden per service or per app.
public enum BarkService: PushService {
    public static let serviceName = "Bark"

    // Bark builds its own body (`title` and `body`), and its API takes image
    // *URLs* rather than Base64 data, so the shared payload's icon/image fields
    // have nowhere to go. Bark's own `Image:` field is a separate, free-form URL.
    public static var supportsIcon: Bool { false }
    public static var supportsImage: Bool { false }

    static let defaultServer = "https://api.day.app"

    /// The URL up to and including the trailing slash; `request(context:config:)`
    /// appends the configured key as the last path segment.
    public static func url(eventName: String, dbName: String, serverURL: String) -> String {
        let base = serverURL.isEmpty ? defaultServer : serverURL
        // A user-entered server URL may or may not end in a slash; normalise so
        // the key segment is always appended cleanly.
        return (base.hasSuffix("/") ? String(base.dropLast()) : base) + "/"
    }

    /// Bark's `image` parameter is a user-entered image URL, not Base64 image
    /// data, so the default replacement would wrongly hide it in the log.
    /// Nothing in Bark's body carries Base64 image data.
    public static var logImageDataProperties: [String] { [] }

    /// The Bark push API parameter names, keyed by preference key.
    /// Everything the push API accepts, in the order the documentation lists it.
    ///
    /// `title`, `body` and `subtitle` are absent: the first two come from the
    /// notification, and `subtitle` is handled below rather than configured —
    /// a fixed string here would replace the notification's own subtitle.
    ///
    /// Keys that the two names disagree on are the ones the app renamed: the
    /// stored `autoCopy` is `autoCopy` on the wire and `copy` is `copy`, and
    /// `clickURL` is `url` because the storage key is shared with other services.
    private static let parameters: [(prefKey: String, apiName: String)] = [
        (BarkPrefKey.markdown, "markdown"),
        (BarkPrefKey.group, "group"),
        (BarkPrefKey.icon, "icon"),
        (BarkPrefKey.image, "image"),
        (BarkPrefKey.badge, "badge"),
        (BarkPrefKey.level, "level"),
        (BarkPrefKey.volume, "volume"),
        (BarkPrefKey.call, "call"),
        (BarkPrefKey.sound, "sound"),
        (BarkPrefKey.copy, "copy"),
        (BarkPrefKey.autoCopy, "autoCopy"),
        (BarkPrefKey.clickURL, "url"),
        (BarkPrefKey.action, "action"),
        (BarkPrefKey.isArchive, "isArchive"),
        (BarkPrefKey.ttl, "ttl"),
        (BarkPrefKey.id, "id"),
        (BarkPrefKey.delete, "delete"),
    ]

    /// The encryption settings an instance stored, whether or not they are on.
    private static func cipherSettings(from config: ServiceConfig) -> BarkCipher.Settings {
        let raw = config.raw
        return BarkCipher.Settings(
            algorithm: BarkCipher.Algorithm(rawValue: raw.string(BarkPrefKey.cipherAlgorithm) ?? "")
                ?? .aes128,
            mode: BarkCipher.Mode(rawValue: raw.string(BarkPrefKey.cipherMode) ?? "") ?? .cbc,
            key: raw.string(BarkPrefKey.cipherKey) ?? "",
            iv: raw.string(BarkPrefKey.cipherIV) ?? ""
        )
    }

    public static func request(context: BulletinContext, config: ServiceConfig) -> PushRequest? {
        var infoDict: [String: Any] = [
            "title": context.displayTitle,
            "body": context.displayMessage,
        ]
        // No `subtitle`, deliberately. The notification's subtitle is already in
        // `displayMessage` — a bulletin shows it above the body, and the composed
        // string joins the two — so sending it again would print it twice, once
        // on its own line and once at the top of the body.
        for (prefKey, apiName) in parameters {
            let value = config.raw.string(prefKey) ?? ""
            if !value.isEmpty { infoDict[apiName] = value }
        }
        // `delete` is only meaningful together with an id.
        if infoDict["delete"] != nil, infoDict["id"] == nil {
            infoDict.removeValue(forKey: "delete")
        }

        // Encryption replaces the body rather than adding to it: the app puts the
        // decrypted dictionary in the body's place, so anything sent beside the
        // ciphertext would either be ignored or shown unencrypted — which defeats
        // the point of turning it on.
        let settings = cipherSettings(from: config)
        if settings.isUsable {
            let json = (try? JSONSerialization.data(withJSONObject: infoDict))
                .flatMap { String(data: $0, encoding: .utf8) }
            if let json, let encrypted = try? BarkCipher.encrypt(json: json, settings: settings) {
                infoDict = encrypted
            }
            // A failure leaves the plaintext body: the push arrives readable
            // rather than not arriving at all, and the log shows the request.
        }

        // The configured URL is `{server}/`; the key is the last path segment.
        let urlString = config.raw.string(PrefKey.url, default: "")
            + config.raw.string(PrefKey.key, default: "")
        return withLogBody(
            PushRequest(urlString: urlString, infoDict: infoDict),
            infoDict
        )
    }

    public static func defaultPrefs() -> [String: Any] {
        var prefs: [String: Any] = [PrefKey.serverURL: defaultServer]
        for (prefKey, _) in parameters {
            prefs[prefKey] = ""
        }
        return prefs
    }

    public static func defaultCustomAppPrefs() -> [String: Any] {
        var prefs: [String: Any] = [:]
        for (prefKey, _) in parameters {
            prefs[prefKey] = ""
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
    static let markdown = "markdown"

    // Encryption is a group of its own, not a parameter: the ciphertext and the
    // IV are what the encryption produces, and what the user configures is the
    // algorithm, the mode and the two secrets.
    static let cipherEnabled = "cipherEnabled"
    static let cipherAlgorithm = "cipherAlgorithm"
    static let cipherMode = "cipherMode"
    static let cipherKey = "cipherKey"
    static let cipherIV = "cipherIV"
    static let icon = "icon"
    static let copy = "copy"
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
