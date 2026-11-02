import Foundation

/// uguu.se — for a picture that only has to survive the next few hours.
///
/// 128 MiB, no registration, no recompression, and it deletes the file after three
/// hours. That is not a defect here: a verification code's screenshot is worthless
/// once the code has been used, and a host that throws it away is doing the right
/// thing with it.
///
///     POST https://uguu.se/upload?output=text
///     files[]=@photo.png
///     → https://d.<host>/<id>.png          (plain text, not JSON)
///
/// The plain-text answer is why this one does not go through `HostUpload`'s JSON
/// path — the response is the URL itself.
public enum UguuHost: ImageHost {
    public static let identifier = "uguu"
    public static let displayName = "uguu"
    public static let summary = "128 MB，3 小时后自动删除"
    public static let maximumBytes: Int? = 128 * 1024 * 1024
    /// Shorter than the file's own life, so the entry is never the reason a dead
    /// link keeps being handed out.
    public static let cacheLifetime: TimeInterval = 2.5 * 60 * 60
    public static let requiresKey = false

    private static let endpoint = "https://uguu.se/upload"

    public static func upload(_ data: Data, key: String) -> String? {
        var multipart = MultipartBody()
        multipart.add("files[]", filename: "image.png", type: "image/png", data)
        guard let target = URL(string: endpoint) else { return nil }

        var request = URLRequest(url: target, timeoutInterval: HostUpload.timeout)
        request.httpMethod = "POST"
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = multipart.body

        let done = DispatchSemaphore(value: 0)
        var result: String?
        URLSession.shared.dataTask(with: request) { payload, response, _ in
            defer { done.signal() }
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let payload,
                  let text = String(data: payload, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  text.hasPrefix("http")
            else { return }
            result = text
        }.resume()
        guard done.wait(timeout: .now() + HostUpload.timeout) == .success else {
            return nil
        }
        return result
    }
}
