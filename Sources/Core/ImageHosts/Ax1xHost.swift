import Foundation

/// ax1x.com — the only host in the report with near-total reach across all three
/// Chinese carriers, and the reason it is offered at all.
///
/// 92/93 电信 · 89/90 联通 · 97/98 移动 · 44/44 海外, measured over 323 nodes.
/// 5 MB per file, no recompression, and duplicate uploads are rejected by content —
/// which is also a cheap dedupe.
///
/// The awkward part is the upload, and it is why this host is not simply another
/// `HostUpload.post` call:
///
///  1. The CSRF token is scraped from the HTML of `imgchr.com`, which is a *web
///     page*, not an API. There is no endpoint that returns it.
///  2. That domain is not reachable from every network in China at all — the
///     report has it at 0/323 — while the CDN that serves the images is the best
///     covered one measured. So a device that cannot reach `imgchr.com` can read
///     these links and cannot create them.
///
/// Failing cleanly is the contract: a `nil` here means the caller omits the
/// picture, and the notification still goes out.
///
///     GET  https://imgchr.com/            → auth_token = "…" in the HTML
///     POST https://imgchr.com/json        → { image: { url: "https://s41.ax1x.com/…" } }
public enum Ax1xHost: ImageHost {
    public static let identifier = "ax1x"
    public static let displayName = "路过图床"
    public static let summary = "国内覆盖最好，5 MB，原图不压缩"
    /// The file's own limit, below which the upload is refused — so the check can
    /// happen before the round trip rather than after it.
    public static let maximumBytes: Int? = 5 * 1024 * 1024
    /// No expiry is advertised, and none has been observed. A year is long enough
    /// that the entry is refreshed rarely and short enough that a link which did
    /// vanish is eventually retried.
    public static let cacheLifetime: TimeInterval = 365 * 24 * 60 * 60
    public static let requiresKey = false

    private static let site = "https://imgchr.com"
    private static let endpoint = "https://imgchr.com/json"

    public static func upload(_ data: Data, key: String) -> String? {
        guard let token = authToken() else { return nil }

        var multipart = MultipartBody()
        multipart.add("source", filename: "image.png", type: "image/png", data)
        multipart.add("type", "file")
        multipart.add("action", "upload")
        multipart.add("format", "json")
        multipart.add("auth_token", token)

        guard let answer = HostUpload.post(
            endpoint,
            contentType: multipart.contentType,
            body: multipart.body,
            headers: ["Referer": site + "/"]
        ), let image = answer["image"] as? [String: Any],
           let url = image["url"] as? String, url.hasPrefix("http")
        else {
            // A duplicate is not a failure of this upload: the file is already
            // there, and the host refuses to store a second copy. The link is not
            // returned with the refusal, so there is nothing to hand back — the
            // caller tries again next time, and the cache is what makes that rare.
            return nil
        }
        return url
    }

    /// The CSRF token the site puts in its own upload script.
    ///
    /// Scraped from HTML because there is no endpoint for it. The pattern is the
    /// one thing here that a redesign of their page would break, and a break shows
    /// up as "no pictures" rather than as a wrong upload.
    private static func authToken() -> String? {
        guard let url = URL(string: site + "/") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: HostUpload.timeout)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X)",
            forHTTPHeaderField: "User-Agent"
        )

        let done = DispatchSemaphore(value: 0)
        var token: String?
        URLSession.shared.dataTask(with: request) { payload, _, _ in
            defer { done.signal() }
            guard let payload,
                  let html = String(data: payload, encoding: .utf8)
            else { return }
            // `auth_token = "…"` in the inline configuration of their upload form.
            guard let range = html.range(of: "auth_token") else { return }
            let rest = html[range.upperBound...]
            guard let open = rest.firstIndex(of: "\""),
                  let close = rest[rest.index(after: open)...].firstIndex(of: "\"")
            else { return }
            let value = rest[rest.index(after: open)..<close]
            if value.count >= 16 { token = String(value) }
        }.resume()
        guard done.wait(timeout: .now() + HostUpload.timeout) == .success else {
            return nil
        }
        return token
    }
}
