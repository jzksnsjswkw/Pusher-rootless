import Foundation

/// Pushover, including the device and sound lists the UI manages.
public enum PushoverService: PushService {
    public static let serviceName = "Pushover"
    static let pushURL = "https://api.pushover.net/1/messages.json"

    public static func url(eventName: String, dbName: String, serverURL: String) -> String {
        pushURL
    }

    public static func request(context: BulletinContext, config: ServiceConfig) throws -> PushRequest? {
        // Both are credentials the API rejects the request for; without them the
        // push fails at the server with a message the user has to go and look up.
        let token = config.raw.string(PrefKey.token, default: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let user = config.raw.string(PrefKey.user, default: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw RequestError.missingField("Token") }
        guard !user.isEmpty else { throw RequestError.missingField("User Key") }
        let deviceIDs = config.raw.dictionaries(PrefKey.devices).compactMap { $0.string("id") }

        // A body is required, and a notification may be a title alone: the two
        // fields swap roles so neither is empty and nothing is printed twice.
        let hasBody = !context.displayMessage.isEmpty
        let title = hasBody ? context.displayTitle : context.appName
        let body = hasBody ? context.displayMessage : (context.title ?? title)

        var infoDict: [String: Any] = [
            "token": token,
            "user": user,
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
