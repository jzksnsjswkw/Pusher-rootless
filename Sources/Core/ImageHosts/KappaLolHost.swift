import Foundation

/// kappa.lol — for pictures the others refuse.
///
/// 100 MiB per file, and the only anonymous host in the report that hands back a
/// key you can delete with afterwards (`/api/delete?key=`). Its retention is not
/// promised — the terms allow removing content at any time — so it is offered for
/// size and deletion, not for permanence.
///
///     POST https://kappa.lol/api/upload
///     file=@photo.jpg
///     → { "link": "https://kappa.lol/<id>", "ext": ".png", "key": "…" }
///
/// The link is only half a URL: without the extension it serves a page rather than
/// the file, and the extension comes back in its own field.
public enum KappaLolHost: ImageHost {
    public static let identifier = "kappa"
    public static let displayName = "kappa.lol"
    public static let summary = "100 MB，可删除，但不承诺长期保存"
    public static let maximumBytes: Int? = 100 * 1024 * 1024
    /// Nothing is promised, so a link is not trusted for long. Thirty days is far
    /// beyond when a notification is read and well inside when the file may vanish.
    public static let cacheLifetime: TimeInterval = 30 * 24 * 60 * 60
    public static let requiresKey = false

    private static let endpoint = "https://kappa.lol/api/upload"

    public static func upload(_ data: Data, key: String) -> String? {
        var multipart = MultipartBody()
        multipart.add("file", filename: "image.png", type: "image/png", data)
        let answer = HostUpload.post(
            endpoint, contentType: multipart.contentType, body: multipart.body
        )
        guard let link = answer?["link"] as? String, link.hasPrefix("http") else {
            return nil
        }
        // The extension is a separate field and without it the URL is a page.
        guard let ext = answer?["ext"] as? String, !ext.isEmpty else { return link }
        return link + ext
    }
}
