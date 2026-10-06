import Foundation

/// Pusher Receiver: the companion Firefox/Chrome extension's REST endpoint on
/// restdb.io. Sends the shared data dict (including the attachment image when
/// enabled), authenticated with an `x-apikey` header.
public enum PusherReceiverService: PushService {
    public static let serviceName = "Pusher Receiver"
    static let urlTemplate = "https://REPLACE_DB_NAME.restdb.io/rest/notifications"

    public static func url(eventName: String, dbName: String, serverURL: String) -> String {
        urlTemplate.replacingOccurrences(of: "REPLACE_DB_NAME", with: dbName)
    }

    public static func request(context: BulletinContext, config: ServiceConfig) -> PushRequest? {
        let infoDict = baseInfoDict(context: context, config: config)
        return withLogBody(
            PushRequest(
                urlString: replacedKeyURL(config: config),
                headers: ["x-apikey": config.raw.string(PrefKey.key, default: "")],
                infoDict: infoDict
            ),
            infoDict
        )
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
