import Foundation

/// Why a service could not assemble a request.
///
/// A service's `request(context:config:)` returns `PushRequest?`, and `nil` on its
/// own says nothing: a missing credential, a server address that will not parse and
/// a token the network refused all look alike. The caller then has two jobs that
/// need different answers — tell the user what to fix, and decide whether trying
/// again could ever help — and neither can be done from a bare `nil`.
///
/// So a service `throw`s instead. The signature stays as it was; only the reason
/// becomes visible. A service that has nothing to report still returns `nil`.
public enum RequestError: LocalizedError {
    /// A field the service cannot work without was left empty.
    case missingField(String)

    /// A field holds something the service cannot use.
    case invalidField(_ name: String, reason: String)

    /// A credential could not be obtained (an access token fetch, say), so the
    /// request the service wanted to build does not exist. Distinct from
    /// ``missingField`` because retrying may succeed without the user changing
    /// anything.
    case credentialUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .missingField(let name):
            return "\(name) is empty"
        case .invalidField(let name, let reason):
            return "\(name) is invalid: \(reason)"
        case .credentialUnavailable(let detail):
            return detail
        }
    }
}
