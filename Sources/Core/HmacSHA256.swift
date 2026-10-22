import CryptoKit
import Foundation

/// HMAC-SHA256, base64-encoded.
///
/// DingTalk and Feishu sign their requests with the same primitive arranged in
/// opposite ways — one puts the secret in the key and the timestamp pair in the
/// message, the other the reverse — so the primitive lives here and each service
/// decides which is which. CryptoKit ships with the system since iOS 13, and the
/// digest is not something to reimplement.
enum HmacSHA256 {

    /// Signs `message` with `key` and returns the signature as base64.
    static func sign(key: String, message: String) -> String {
        let digest = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: Data(key.utf8))
        )
        return Data(digest).base64EncodedString()
    }
}
