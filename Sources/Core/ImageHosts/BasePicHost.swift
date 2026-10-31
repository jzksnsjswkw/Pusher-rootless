import Foundation

/// BasePic: no account, no key, and a year of retention.
///
/// Its reason to be first is that it asks for nothing — no registration, no API
/// key, no per-file management — and keeps the file long enough that a notification
/// sent today still shows its picture next year. The year is also why the cache
/// lifetime is set just inside it.
///
///     POST https://basepic.com/api/v1/images
///     image=@photo.png  expires_in_days=365
///     → { "image_url": "https://basepic.com/<id>/photo.png", … }
public enum BasePicHost: ImageHost {
    public static let identifier = "basepic"

    /// Kept well inside the host's own year, so a link is never handed out on the
    /// day it expires.
    public static let cacheLifetime: TimeInterval = 300 * 24 * 60 * 60

    private static let endpoint = "https://basepic.com/api/v1/images"
    private static let retentionDays = 365

    /// Uploads the file.
    ///
    /// The `multipart/form-data` body is built by hand because this runs inside
    /// SpringBoard, where a background `URLSession` would be cancelled as soon as
    /// the caller returned — so the request blocks on the queue the push is already
    /// running on.
    public static func upload(_ data: Data) -> String? {
        guard let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"

        let boundary = "PusherBoundary-\(UUID().uuidString)"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type"
        )

        var body = Data()
        func line(_ text: String) {
            body.append(contentsOf: Array(text.utf8))
        }
        func field(_ name: String, filename: String? = nil, type: String? = nil, _ value: Data) {
            line("--\(boundary)\r\n")
            if let filename, let type {
                line("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
                line("Content-Type: \(type)\r\n\r\n")
            } else {
                line("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            }
            body.append(value)
            line("\r\n")
        }

        field("image", filename: "image.png", type: "image/png", data)
        field("expires_in_days", String(retentionDays).data(using: .utf8) ?? Data())
        line("--\(boundary)--\r\n")
        request.httpBody = body

        let done = DispatchSemaphore(value: 0)
        var result: String?
        URLSession.shared.dataTask(with: request) { payload, response, _ in
            defer { done.signal() }
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let payload
            else { return }
            result = imageURL(fromJSON: payload)
        }.resume()
        guard done.wait(timeout: .now() + 25) == .success else { return nil }
        return result
    }

    /// The `image_url` field of the upload's answer.
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
}
