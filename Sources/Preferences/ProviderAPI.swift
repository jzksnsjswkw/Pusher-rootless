import Foundation

/// A failure reported by a provider's API, already phrased for the user.
enum ProviderError: LocalizedError {
    case server(String)

    var errorDescription: String? {
        switch self {
        case .server(let message): return message
        }
    }
}

/// Thin clients for the provider endpoints the device and sound pickers read.
///
/// They are separate from the push services on purpose: the services build a
/// payload for a *notification*, while these list the account's devices and
/// sounds for the settings UI. Both are async and throw, so the callers can
/// await them and report failures in one place.
enum PushoverAPI {
    private static let base = "https://api.pushover.net/1"

    /// Validates the credentials and reads the account's devices.
    static func post(path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "\(base)/\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(request)
    }

    /// The sounds this account may use.
    static func getSounds(token: String) async throws -> [String: Any] {
        var components = URLComponents(string: "\(base)/sounds.json")!
        components.queryItems = [URLQueryItem(name: "token", value: token)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        return try await perform(request)
    }

    private static func perform(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard !data.isEmpty else {
            throw ProviderError.server(
                "Server did not respond. Please check your internet connection or try again later.".localized
            )
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.server("Network Error".localized)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            // A 4xx still carries a JSON body with the provider's own message.
            throw ProviderError.server(json["error"] as? String ?? "\(json)")
        }
        return json
    }
}

/// Pushbullet's REST API, authenticated with the account token.
enum PushbulletAPI {
    private static let base = "https://api.pushbullet.com/v2"

    static func get(_ path: String) async throws -> [String: Any] {
        guard let token = currentToken() else { throw ProviderError.server("Missing access token") }
        var request = URLRequest(url: URL(string: "\(base)/\(path)")!)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "Access-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard !data.isEmpty else {
            throw ProviderError.server(
                "Server did not respond. Please check your internet connection or try again later.".localized
            )
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.server("Network Error".localized)
        }
        if let error = json["error"] as? [String: Any] {
            throw ProviderError.server(error["message"] as? String ?? "Unknown Error".localized)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProviderError.server("\(json)")
        }
        return json
    }

    private static func currentToken() -> String? {
        let token = PrefsStore.service(named: PushbulletService.serviceName, isCustom: false)
            .string(PrefKey.token, default: "")
        return token.isEmpty ? nil : token
    }
}
