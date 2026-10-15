import Foundation

/// Pushbullet, authenticated with an account access token.
public enum PushbulletService: PushService {
    public static let serviceName = "Pushbullet"
    static let pushURL = "https://api.pushbullet.com/v2/pushes"

    public static func url(eventName: String, dbName: String, serverURL: String) -> String {
        pushURL
    }

    public static func request(context: BulletinContext, config: ServiceConfig) -> PushRequest? {
        var infoDict: [String: Any] = [
            "type": "note",
            "title": context.displayTitle,
            "body": context.pushBody,
        ]
        if let device = firstDeviceID(config: config) {
            infoDict["device_iden"] = device
        }

        return withLogBody(
            PushRequest(
                urlString: pushURL,
                headers: ["Access-Token": config.raw.string(PrefKey.token, default: "")],
                infoDict: infoDict
            ),
            infoDict
        )
    }

    /// Pushbullet targets a single device, so only the first configured one is
    /// used — the UI allows selecting several, but the API takes one.
    static func firstDeviceID(config: ServiceConfig) -> String? {
        config.raw.dictionaries(PrefKey.devices)
            .compactMap { $0.string("id") }
            .first
    }
}
