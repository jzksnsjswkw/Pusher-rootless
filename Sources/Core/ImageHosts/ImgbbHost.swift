import Foundation

/// imgbb — the default, and the one that behaves best in the report's tests.
///
/// Anonymously usable, 32 MB per file, no recompression (a 772 KB JPEG came back
/// with the same md5, and a 27 MB PNG downloaded at 5 MB/s where the others timed
/// out), and images do not expire unless asked to.
///
///     POST https://imgbb.com/json
///     source=@photo.jpg  type=file  action=upload  format=json
///     → { "image": { "url": "https://i.ibb.co/<id>/photo.jpg" } }
///
/// The web endpoint rather than the documented API: `api.imgbb.com/1/upload` needs
/// a key the user would have to register for, and this one does not. Its answer
/// nests the link under `image.url` where the API puts it under `data.url`, so the
/// two are not interchangeable.
///
/// A key is still accepted: with one, the official API is used, which is what its
/// author documents and may outlive an undocumented endpoint.
public enum ImgbbHost: ImageHost {
    public static let identifier = "imgbb"
    public static let displayName = "imgbb"
    public static let summary = "永久保存、原图不压缩，但移动网络打不开"
    public static let maximumBytes: Int? = 32 * 1024 * 1024
    /// No expiry on the file, so the entry only has to outlive a notification's
    /// usefulness — a year is well past that and still short of forever.
    public static let cacheLifetime: TimeInterval = 365 * 24 * 60 * 60
    /// Optional: without a key the web endpoint is used, with one the API is.
    public static let requiresKey = false

    static let anonymousEndpoint = "https://imgbb.com/json"
    static let keyedEndpoint = "https://api.imgbb.com/1/upload"

    public static func upload(_ data: Data, key: String) -> String? {
        key.isEmpty ? uploadAnonymously(data) : uploadWithKey(data, key: key)
    }

    /// The documented API, used when the user has entered a key.
    static func uploadWithKey(_ data: Data, key: String) -> String? {
        var multipart = MultipartBody()
        multipart.add("image", filename: "image.png", type: "image/png", data)
        let answer = HostUpload.post(
            keyedEndpoint + "?key=" + (key.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed
            ) ?? key),
            contentType: multipart.contentType,
            body: multipart.body
        )
        // `{ "data": { "url": … }, "success": true }`
        let payload = answer?["data"] as? [String: Any]
        return link(from: payload?["url"])
    }

    /// The web endpoint, which asks for nothing.
    static func uploadAnonymously(_ data: Data) -> String? {
        var multipart = MultipartBody()
        multipart.add("source", filename: "image.png", type: "image/png", data)
        multipart.add("type", "file")
        multipart.add("action", "upload")
        multipart.add("format", "json")
        let answer = HostUpload.post(
            anonymousEndpoint,
            contentType: multipart.contentType,
            body: multipart.body,
            headers: [
                // The endpoint answers JSON to an XHR and a redirect to a form post.
                "X-Requested-With": "XMLHttpRequest",
                "Referer": "https://imgbb.com/",
            ]
        )
        // `{ "image": { "url": … }, "status_code": 200 }`
        let payload = answer?["image"] as? [String: Any]
        return link(from: payload?["url"])
    }

    private static func link(from value: Any?) -> String? {
        guard let url = value as? String, url.hasPrefix("http") else { return nil }
        return url
    }
}
