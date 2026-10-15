import Foundation

/// Pushover, including the device and sound lists the UI manages.
public enum PushoverService: PushService {
    public static let serviceName = "Pushover"
    static let pushURL = "https://api.pushover.net/1/messages.json"

    public static func url(eventName: String, dbName: String, serverURL: String) -> String {
        pushURL
    }

    public static func request(context: BulletinContext, config: ServiceConfig) -> PushRequest? {
        let deviceIDs = config.raw.dictionaries(PrefKey.devices).compactMap { $0.string("id") }

        // A body is required, and a notification may be a title alone: the two
        // fields swap roles so neither is empty and nothing is printed twice.
        let hasBody = !context.displayMessage.isEmpty
        let title = hasBody ? context.displayTitle : context.appName
        let body = hasBody ? context.displayMessage : (context.title ?? title)

        var infoDict: [String: Any] = [
            "token": config.raw.string(PrefKey.token, default: ""),
            "user": config.raw.string(PrefKey.user, default: ""),
            "title": title,
            "message": body,
            "device": deviceIDs.joined(separator: ","),
        ]
        // Pushover accepts one sound per message, so the first selected wins.
        if let sound = config.raw.stringArray(PrefKey.sounds).first {
            infoDict["sound"] = sound
        }

        // The credentials travel in the body, not a header; the sender still
        // posts this as JSON, matching the original implementation.
        return withLogBody(
            PushRequest(urlString: pushURL, infoDict: infoDict),
            infoDict
        )
    }
}
