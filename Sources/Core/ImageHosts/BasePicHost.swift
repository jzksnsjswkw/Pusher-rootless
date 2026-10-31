import Foundation

/// BasePic — no account, no key, and a year of retention.
///
/// Kept alongside imgbb rather than replaced by it: it needs nothing at all, and a
/// host with no key is the one that keeps working when the others start asking for
/// registration.
///
///     POST https://basepic.com/api/v1/images
///     image=@photo.png  expires_in_days=365
///     → { "image_url": "https://basepic.com/<id>/photo.png", … }
public enum BasePicHost: ImageHost {
    public static let identifier = "basepic"
    public static let displayName = "BasePic"
    public static let summary = "Kept for a year, no account needed"
    /// Not published; the year of retention is the only figure it states, and the
    /// request is refused by the server rather than by a guess here.
    public static let maximumBytes: Int? = nil
    /// Kept well inside the host's own year, so a link is never handed out on the
    /// day it expires.
    public static let cacheLifetime: TimeInterval = 300 * 24 * 60 * 60
    public static let requiresKey = false

    private static let endpoint = "https://basepic.com/api/v1/images"
    private static let retentionDays = 365

    public static func upload(_ data: Data, key: String) -> String? {
        var multipart = MultipartBody()
        multipart.add("image", filename: "image.png", type: "image/png", data)
        multipart.add("expires_in_days", String(retentionDays))
        let answer = HostUpload.post(
            endpoint, contentType: multipart.contentType, body: multipart.body
        )
        guard let url = answer?["image_url"] as? String, url.hasPrefix("http") else {
            return nil
        }
        return url
    }
}
