import Foundation

/// ServerChan Turbo (Server酱), a WeChat push service.
///
/// The SendKey is part of the path rather than a field, so the URL is built from
/// it and the request carries only the message.
public enum ServerChanService: PushService {
    public static let serviceName = "ServerChan"
    static let urlBase = "https://sctapi.ftqq.com/"

    public static func url(eventName: String, dbName: String, serverURL: String) -> String {
        urlBase
    }

    public static func defaultPrefs() -> [String: Any] {
        [ServerChanPrefKey.sendKey: ""]
    }

    public static func request(context: BulletinContext, config: ServiceConfig) -> PushRequest? {
        let infoDict: [String: Any] = [
            "title": context.displayTitle,
            "desp": context.displayMessage,
        ]
        let urlString = urlBase
            + config.raw.string(ServerChanPrefKey.sendKey, default: "")
            + ".send"
        let request = PushRequest(urlString: urlString, infoDict: infoDict)
        // The API documents `curl -d`, which is form encoding; its JSON support is
        // an addition rather than the documented shape.
        request.bodyType = "form"
        return withLogBody(request, infoDict)
    }
}

/// The keys this service's settings are stored under.
enum ServerChanPrefKey {
    static let sendKey = "sendKey"
}
