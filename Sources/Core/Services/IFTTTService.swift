import Foundation

/// IFTTT Maker Webhooks.
///
/// The webhook accepts three values; what goes in them depends on "Curate Data":
/// a curated single notification (value3 carries the icon, or the date when
/// there is no icon), or the whole shared data dict JSON-serialized into
/// value1.
public enum IFTTTService: PushService {
    public static let serviceName = "IFTTT"
    static let urlTemplate = "https://maker.ifttt.com/trigger/REPLACE_EVENT_NAME/with/key/REPLACE_KEY"

    public static func url(eventName: String, dbName: String, serverURL: String) -> String {
        urlTemplate.replacingOccurrences(of: "REPLACE_EVENT_NAME", with: eventName)
    }

    public static func request(context: BulletinContext, config: ServiceConfig) -> PushRequest? {
        let data = baseInfoDict(context: context, config: config)
        let curated = config.raw.bool(PrefKey.curateData)

        let request = PushRequest(urlString: replacedKeyURL(config: config))
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
