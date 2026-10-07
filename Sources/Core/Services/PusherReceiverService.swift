import Foundation

/// Pusher Receiver: the companion Firefox/Chrome extension's REST endpoint on
/// restdb.io. Sends the shared data dict (including the attachment image when
/// enabled), authenticated with an `x-apikey` header.
///
/// The push URL is `https://{dbName}.restdb.io/rest/notifications`; the database
/// name comes from the service configuration.
public enum PusherReceiverService: PushService {
    public static let serviceName = "Pusher Receiver"
    static let urlBase = "https://"
    static let urlTail = ".restdb.io/rest/notifications"

    /// The URL template, with the database-name segment still missing.
    public static func url(eventName: String, dbName: String, serverURL: String) -> String {
        urlBase + dbName + urlTail
    }

    public static func request(context: BulletinContext, config: ServiceConfig) -> PushRequest? {
        let infoDict = baseInfoDict(context: context, config: config)
        return withLogBody(
            PushRequest(
                urlString: pushURL(config: config),
                headers: ["x-apikey": config.raw.string(PrefKey.key, default: "")],
                infoDict: infoDict
            ),
            infoDict
        )
    }

    private static func pushURL(config: ServiceConfig) -> String {
        let dbName = config.raw.string(PrefKey.dbName, default: "")
        return urlBase + dbName + urlTail
    }

    public static func extraPrefs(_ servicePrefs: Prefs) -> [String: Any]? {
        [
            PrefKey.includeIcon: servicePrefs[PrefKey.includeIcon] ?? true,
            PrefKey.includeImage: servicePrefs[PrefKey.includeImage] ?? true,
            PrefKey.imageMaxWidth: servicePrefs[PrefKey.imageMaxWidth] ?? Pusher.defaultMaxWidth,
            PrefKey.imageMaxHeight: servicePrefs[PrefKey.imageMaxHeight] ?? Pusher.defaultMaxHeight,
            PrefKey.imageShrinkFactor: servicePrefs[PrefKey.imageShrinkFactor]
                ?? Pusher.defaultShrinkFactor,
        ]
    }

    public static func extraCustomAppPrefs(_ appPrefs: Prefs) -> [String: Any]? {
        [
            PrefKey.includeIcon: appPrefs[PrefKey.includeIcon] ?? true,
            PrefKey.includeImage: appPrefs[PrefKey.includeImage] ?? true,
            PrefKey.imageMaxWidth: appPrefs[PrefKey.imageMaxWidth] ?? Pusher.defaultMaxWidth,
            PrefKey.imageMaxHeight: appPrefs[PrefKey.imageMaxHeight] ?? Pusher.defaultMaxHeight,
            PrefKey.imageShrinkFactor: appPrefs[PrefKey.imageShrinkFactor]
                ?? Pusher.defaultShrinkFactor,
        ]
    }

    public static func shouldIncludeIcon(config: ServiceConfig) -> Bool {
        config.raw.bool(PrefKey.includeIcon)
    }

    public static func shouldIncludeImage(config: ServiceConfig) -> Bool {
        config.raw.bool(PrefKey.includeImage)
    }
}
