import Foundation

/// Uploads an attachment once and remembers the URL.
///
/// Bark's API takes image *URLs*, so a Base64 attachment has to become a link
/// before it can ride along. Uploading on every push would be wrong twice over:
/// the same picture would be stored again each time, and the push would wait on a
/// third party it did not have to consult. The key is the file's own bytes, so an
/// image that has been sent before is a cache hit — and an image edited and
/// re-picked is a miss, because its bytes changed.
public enum ImageHost {
    /// How long a cached link is trusted.
    ///
    /// BasePic keeps an image for a year; the entry stops being used well before
    /// that, so a link is never handed out on the day it expires.
    public static let cacheLifetime: TimeInterval = 300 * 24 * 60 * 60

    /// The storage key a cached upload lives under.
    ///
    /// Derived from the content, not the path: the compose page writes each pick
    /// to a fresh file, so a path would never repeat.
    static func cacheKey(for data: Data) -> String {
        "host.\(fnv1a(data))"
    }

    /// A link for `data`, uploading it first if this image has not been seen.
    ///
    /// Returns `nil` when the upload fails, and the caller omits the image field:
    /// a push without a picture is better than a push that does not arrive.
    public static func url(for data: Data, storage: String) -> String? {
        let key = cacheKey(for: data)
        let stored = PrefsStore.instance(storage)
        if let cached = stored[key] as? [String: Any],
           let link = cached["url"] as? String, !link.isEmpty,
           let at = cached["at"] as? Date,
           // Checked against the clock, not just presence: the entry outlives the
           // year BasePic keeps the file only if this is not consulted, and a
           // stale link is an image that silently stops appearing.
           Date().timeIntervalSince(at) < cacheLifetime {
            return link
        }
        guard let uploaded = upload(data), !uploaded.isEmpty else { return nil }
        // Written through the instance's own storage so the cache follows the
        // instance: one destination's link is not another's.
        PrefsStore.updateInstance(storage) {
            $0[key] = ["url": uploaded, "at": Date()]
        }
        return uploaded
    }

    /// BasePic: no account, no key, and a year of retention.
    ///
    /// The `multipart/form-data` body is built by hand because this runs inside
    /// SpringBoard, where a background `URLSession` would be cancelled as soon as
    /// the caller returned — the request is a blocking `NSURLSession` call on the
    /// queue the push is already running on.
    static func upload(_ data: Data) -> String? {
        guard let url = URL(string: "https://basepic.com/api/v1/images") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        let boundary = "PusherBoundary-\(UUID().uuidString)"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type"
        )
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"image\"; filename=\"image.png\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: image/png\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"expires_in_days\"\r\n\r\n365".data(using: .utf8)!
        )
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let done = DispatchSemaphore(value: 0)
        var result: String?
        URLSession.shared.dataTask(with: request) { body, response, _ in
            defer { done.signal() }
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let body
            else { return }
            result = ImageHost.imageURL(fromJSON: body)
        }.resume()
        guard done.wait(timeout: .now() + 25) == .success else { return nil }
        return result
    }

    /// The `image_url` field of the upload's JSON answer.
    ///
    /// A separate seam so the parsing can be checked without a network.
    static func imageURL(fromJSON body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body),
              let fields = object as? [String: Any],
              let url = fields["image_url"] as? String,
              url.hasPrefix("http")
        else { return nil }
        return url
    }

    /// 64-bit FNV-1a over the file's bytes.
    ///
    /// A cryptographic digest would be the obvious choice, but CommonCrypto is not
    /// linked into the Preferences bundle and this cache only has to tell one
    /// picture from another — a collision would show the wrong photo, which a
    /// 64-bit digest over a handful of picker outputs does not reach.
    static func fnv1a(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
