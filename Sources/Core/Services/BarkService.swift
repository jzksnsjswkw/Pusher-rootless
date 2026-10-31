import Foundation

/// Bark (`https://api.day.app`), including self-hosted servers.
///
/// The push URL is `{server}/{key}`; the server defaults to `api.day.app` and
/// can be overridden per service or per app.
public enum BarkService: PushService {
    public static let serviceName = "Bark"

    // Bark's two picture fields are URLs, not Base64: `icon` is the small picture
    // beside the notification and `image` is the attachment it opens. Both have to
    // be uploaded first, which is what the two switches turn on — see the branches
    // in `request`.
    public static var supportsIcon: Bool { true }
    public static var supportsImage: Bool { true }

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
            isEnabled: config.raw.bool(BarkPrefKey.cipherEnabled, default: false),
            algorithm: BarkCipher.Algorithm(rawValue: raw.string(BarkPrefKey.cipherAlgorithm) ?? "")
                ?? .aes128,
            mode: BarkCipher.Mode(rawValue: raw.string(BarkPrefKey.cipherMode) ?? "") ?? .cbc,
            key: raw.string(BarkPrefKey.cipherKey) ?? ""
        )
    }

    public static func request(context: BulletinContext, config: ServiceConfig) throws -> PushRequest? {
        var infoDict: [String: Any] = [
            "title": context.displayTitle,
            "body": context.message ?? "",
        ]
        // Bark has a field for the subtitle, so the three arrive as three and the
        // notification keeps its own shape. `displayMessage` is not used here for
        // exactly that reason: it joins the subtitle to the body for services
        // that have only one place to put both, and Bark is not one of them —
        // its own subtitle line would be blank while the words sat at the top of
        // the body.
        //
        // Absent when there is none, which is what the API means by unset: an
        // empty `subtitle` would draw a blank line above the body.
        if let subtitle = context.subtitle, !subtitle.isEmpty {
            infoDict["subtitle"] = subtitle
        }
        for (prefKey, apiName) in parameters {
            let value = config.raw.string(prefKey) ?? ""
            if !value.isEmpty { infoDict[apiName] = value }
        }

        // The notification's own attachment, as a link.
        //
        // Bark takes `image` as a URL, so the attachment is uploaded before it can
        // ride along — and only when the instance's switch asks for it. A link the
        // user typed in the parameters wins over both: they asked for that picture
        // on every push, and replacing it with the notification's would undo a
        // setting they made deliberately.
        //
        // An upload that fails leaves the field alone rather than failing the push:
        // the notification is the message, the picture is the extra.
        if shouldIncludeImage(config: config),
           infoDict["image"] == nil,
           let url = context.attachmentURL,
           let data = try? Data(contentsOf: url),
           let hosted = ImageHosts.url(for: data) {
            infoDict["image"] = hosted
        }

        // The icon beside the notification, likewise as a link.
        //
        // The same picture the other services carry as Base64 — the app's own icon,
        // or the one the user gave this destination. Bark cannot take Base64, so it
        // is uploaded and sent as a URL. A `icon` the user typed takes precedence,
        // for the same reason as above.
        if shouldIncludeIcon(config: config), infoDict["icon"] == nil,
           let icon = ServiceIcon.image(from: config.raw) ?? context.iconImage,
           let data = icon.pngData(),
           let hosted = ImageHosts.url(for: data) {
            infoDict["icon"] = hosted
        }
        // `delete` is only meaningful together with an id.
        if infoDict["delete"] != nil, infoDict["id"] == nil {
            infoDict.removeValue(forKey: "delete")
        }

        // Encryption replaces the body rather than adding to it: the app puts the
        // decrypted dictionary in the body's place, so anything sent beside the
        // ciphertext would either be ignored or shown unencrypted — which defeats
        // the point of turning it on.
        var encryptionFailure: String?
        let settings = cipherSettings(from: config)
        if settings.isUsable {
            let json = (try? JSONSerialization.data(withJSONObject: infoDict))
                .flatMap { String(data: $0, encoding: .utf8) }
            if let json, let encrypted = try? BarkCipher.encrypt(json: json, settings: settings) {
                infoDict = encrypted
            }
            // A failure leaves the plaintext body so the push still arrives, but
            // silently is wrong: the user turned encryption on to keep the
            // notification from being readable in transit, and a fallback they were
            // never told about is the one outcome that defeats the setting. The
            // footer already warns about the key length in the UI, so this is the
            // second half of the same warning — for the case where it went
            // unnoticed.
            // The note goes in the *log copy*, not the body: the server should not
            // receive a stray key, and the user reads it in the log viewer.
            if infoDict["ciphertext"] == nil {
                encryptionFailure = settings.problem()?.localizedDescription
                    ?? "Bark encryption failed; the body was sent unencrypted"
            }
        }

        // The configured URL is `{server}/`; the key is the last path segment.
        // The key is the last path segment of the endpoint, so a missing one
        // produces a URL that looks valid — `https://api.day.app/` — and the
        // request goes out to the server root. Bark answers that with an error the
        // user never sees, and a test push reported "sent". There is nothing to
        // build here without it.
        let key = config.raw.string(PrefKey.key, default: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw RequestError.missingField("Key")
        }

        let urlString = config.raw.string(PrefKey.url, default: "") + key
        let request = withLogBody(PushRequest(urlString: urlString, infoDict: infoDict), infoDict)
        if let encryptionFailure {
            request.failureReason = encryptionFailure
        }
        return request
    }

    /// Whether this instance asked for the picture fields.
    ///
    /// The protocol's defaults are `false`, so a service that supports pictures
    /// has to say so here as well: declaring `supportsImage` only makes the switch
    /// appear, and without these the switch would be drawn, stored, and read by
    /// nobody.
    public static func shouldIncludeIcon(config: ServiceConfig) -> Bool {
        config.raw.bool(PrefKey.includeIcon)
    }

    public static func shouldIncludeImage(config: ServiceConfig) -> Bool {
        config.raw.bool(PrefKey.includeImage)
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
    // IV are what the encryption produces. The IV is not configured at all — the
    // app has no field for one and reads it from the request, so it is generated
    // per push; see `BarkCipher.encrypt`.
    static let cipherEnabled = "cipherEnabled"
    static let cipherAlgorithm = "cipherAlgorithm"
    static let cipherMode = "cipherMode"
    static let cipherKey = "cipherKey"
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
