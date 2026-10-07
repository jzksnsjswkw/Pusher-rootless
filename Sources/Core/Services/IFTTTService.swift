import Foundation

/// IFTTT Maker Webhooks.
///
/// The push URL is `https://maker.ifttt.com/trigger/{eventName}/with/key/{key}`;
/// both segments come from the service configuration. What goes into the
/// request's three values depends on "Curate Data": a curated single
/// notification (value3 carries the icon, or the date when there is no icon), or
/// the whole shared data dict JSON-serialized into value1.
public enum IFTTTService: PushService {
    public static let serviceName = "IFTTT"
    static let urlBase = "https://maker.ifttt.com/trigger/"

    /// The URL template, with both variable segments still in place. Used for
    /// per-app override comparison; the key is substituted at send time.
    public static func url(eventName: String, dbName: String, serverURL: String) -> String {
        urlBase + eventName + "/with/key/"
    }

    public static func request(context: BulletinContext, config: ServiceConfig) -> PushRequest? {
        let data = baseInfoDict(context: context, config: config)
        let curated = config.raw.bool(PrefKey.curateData)

        let request = PushRequest(urlString: Self.pushURL(config: config))
        if curated {
            let dateString = dateString(context.date, config: config)
            let icon = data["icon"] as? String
            request.infoDict = [
                "value1": context.displayTitle,
                "value2": context.displayMessage,
                "value3": icon ?? dateString,
            ]
            request.logInfoDict = [
                "value1": context.displayTitle,
                "value2": context.displayMessage,
                "value3": icon != nil ? Pusher.logImageDataReplacement : dateString,
            ]
        } else {
            // The whole data dict travels as a JSON *string* in value1, since
            // value1 is sent form-encoded and cannot carry a nested object.
            request.infoDict = ["value1": jsonString(data) ?? ""]
            request.logInfoDict = ["value1": jsonString(logInfoDict(data)) ?? ""]
        }
        return request
    }

    /// `.../trigger/{eventName}/with/key/{key}`.
    private static func pushURL(config: ServiceConfig) -> String {
        let eventName = config.raw.string(PrefKey.eventName, default: "")
        return urlBase + eventName + "/with/key/" + config.raw.string(PrefKey.key, default: "")
    }

    private static func jsonString(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func extraPrefs(_ servicePrefs: Prefs) -> [String: Any]? {
        [
            PrefKey.includeIcon: servicePrefs[PrefKey.includeIcon] ?? false,
            PrefKey.curateData: servicePrefs[PrefKey.curateData] ?? true,
        ]
    }

    public static func extraCustomAppPrefs(_ appPrefs: Prefs) -> [String: Any]? {
        [
            PrefKey.includeIcon: appPrefs[PrefKey.includeIcon] ?? false,
            PrefKey.curateData: appPrefs[PrefKey.curateData] ?? true,
        ]
    }

    public static func shouldIncludeIcon(config: ServiceConfig) -> Bool {
        config.raw.bool(PrefKey.includeIcon)
    }
}
