import Foundation

/// Pushover, including the device and sound lists the UI manages.
public enum PushoverService: PushService {
    public static let serviceName = "Pushover"
    static let urlTemplate = "https://api.pushover.net/1/messages.json"

    public static func url(eventName: String, dbName: String, serverURL: String) -> String {
        urlTemplate
    }

    public static func request(context: BulletinContext, config: ServiceConfig) -> PushRequest? {
        let deviceIDs = config.raw.dictionaries(PrefKey.devices).compactMap { $0.string("id") }

        var infoDict: [String: Any] = [
            "token": config.raw.string(PrefKey.token, default: ""),
            "user": config.raw.string(PrefKey.user, default: ""),
            "title": context.displayTitle,
            "message": context.displayMessage,
            "device": deviceIDs.joined(separator: ","),
        ]
        // Pushover accepts one sound per message, so the first selected wins.
        if let sound = config.raw.stringArray(PrefKey.sounds).first {
            infoDict["sound"] = sound
        }

        // The credentials travel in the body, not a header; the sender still
        // posts this as JSON, matching the original implementation.
        return withLogBody(
            PushRequest(urlString: replacedKeyURL(config: config), infoDict: infoDict),
            infoDict
        )
    }
}
