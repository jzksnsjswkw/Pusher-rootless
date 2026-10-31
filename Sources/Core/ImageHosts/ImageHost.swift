import Foundation

/// A place an attachment can be uploaded to, so a service that only accepts a URL
/// can be sent one.
///
/// The first requirement for this was Bark, but it is not a Bark concern: any API
/// that takes a link instead of Base64 needs it. Which host receives the upload is
/// a property of the host, not of the service asking — the same file may be pushed
/// to several destinations at once, and they can want different hosts.
///
/// Everything a host needs beyond these members — an API key, a session token, a
/// multipart body written by hand — belongs inside its own file.
public protocol ImageHost {
    /// The name this host's cache lives under, and the value stored in the setting.
    static var identifier: String { get }

    /// The name a person reads in the picker.
    static var displayName: String { get }

    /// One line about what this host is good for, shown under the picker.
    static var summary: String { get }

    /// The largest file the host accepts, if it publishes a limit.
    ///
    /// Checked before uploading rather than after: a 30 MB picture sent to a 5 MB
    /// host is a wait followed by a rejection, and the notification it was attached
    /// to is held up the whole time.
    static var maximumBytes: Int? { get }

    /// How long a link from this host is trusted.
    static var cacheLifetime: TimeInterval { get }

    /// Whether the host requires something entered on the settings page.
    static var requiresKey: Bool { get }

    /// Uploads `data` and returns the public link, or `nil` on failure.
    static func upload(_ data: Data, key: String) -> String?
}

/// The hosts this app knows about, and which one is in use.
///
/// A registry rather than a static on the protocol: a protocol extension's static
/// members cannot be reached through the existential metatype, so `all` has to live
/// somewhere concrete. Adding a host means adding it here — one line, and it appears
/// in the picker.
public enum ImageHostRegistry {
    /// Every host the app can use, in the order the picker shows them.
    ///
    /// Ordered by how well each suits the job — a link that lives as long as the
    /// notification does, without recompressing the picture.
    public static let all: [any ImageHost.Type] = [
        ImgbbHost.self, BasePicHost.self, KappaLolHost.self, UguuHost.self,
    ]

    /// The host stored in the settings, falling back to the first usable one.
    ///
    /// A stored identifier that no longer exists — a host removed in an update —
    /// falls back rather than failing every push: the picture is an extra, and
    /// losing it should not lose the notification.
    public static func configured() -> (any ImageHost.Type)? {
        let stored = PrefsStore.global().string(PrefKey.imageHostKey) ?? ""
        if let chosen = all.first(where: { $0.identifier == stored }) {
            // A host that needs a key and has none is as unusable as a missing one.
            if chosen.requiresKey, key(for: chosen).isEmpty { return nil }
            return chosen
        }
        return all.first { !$0.requiresKey || !key(for: $0).isEmpty }
    }

    /// The host stored in the settings, whether or not it is usable.
    ///
    /// The settings page shows the stored choice even when it cannot upload — the
    /// user picked it, and a picker that silently moved to another host would look
    /// like the choice had not been saved.
    public static var selected: (any ImageHost.Type)? {
        let stored = PrefsStore.global().string(PrefKey.imageHostKey) ?? ""
        return all.first { $0.identifier == stored } ?? all.first
    }

    /// The key entered for `host`, or empty.
    public static func key(for host: any ImageHost.Type) -> String {
        PrefsStore.global().string(PrefKey.imageHostKeyKey(for: host.identifier)) ?? ""
    }
}

/// The upload cache, shared by every host.
///
/// One entry per (host, content), in the global preferences. The picture is a
/// property of the image and the host, not of the destination being sent to: two
/// instances using the same service were uploading the same file twice when this
/// lived in an instance's config, and one host's cache was invisible to another.
///
/// The key is the file's own bytes, so an image already uploaded is a hit and an
/// image edited and re-picked is a miss — which is what a cache of images wants.
public enum ImageHosts {
    /// The global preferences key every host's cache is nested under.
    static let storageKey = "imageHosts"

    /// A link for `data`, uploading through the configured host if this image has
    /// not been seen there before.
    ///
    /// `nil` when there is no usable host, the file is too large for the one
    /// chosen, or the upload fails. Every caller omits the image field in that
    /// case: a push without a picture is better than a push that does not arrive.
    public static func url(for data: Data) -> String? {
        guard let host = ImageHostRegistry.configured() else { return nil }
        if let limit = host.maximumBytes, data.count > limit { return nil }
        return url(for: data, host: host)
    }

    /// A link for `data` through one specific host.
    public static func url(for data: Data, host: any ImageHost.Type) -> String? {
        let key = contentKey(for: data)
        if let cached = entry(host: host.identifier, key: key),
           let link = cached["url"] as? String, !link.isEmpty,
           let at = cached["at"] as? Date,
           // Checked against the clock, not just presence: an entry that outlives
           // the host's own retention is an image that silently stops appearing.
           Date().timeIntervalSince(at) < host.cacheLifetime {
            return link
        }
        guard let uploaded = host.upload(data, key: ImageHostRegistry.key(for: host)),
              !uploaded.isEmpty
        else { return nil }
        store(host: host.identifier, key: key, url: uploaded)
        return uploaded
    }

    /// Every link stored for `data`, by host, so a caller can report what it has.
    static func cachedLinks(for data: Data) -> [String: String] {
        let key = contentKey(for: data)
        var links: [String: String] = [:]
        for host in ImageHostRegistry.all {
            if let link = entry(host: host.identifier, key: key)?["url"] as? String {
                links[host.identifier] = link
            }
        }
        return links
    }

    /// The entry for one (host, content) pair.
    static func entry(host: String, key: String) -> [String: Any]? {
        let hosts = PrefsStore.global()[storageKey] as? [String: Any]
        let cache = hosts?[host] as? [String: Any]
        return cache?[key] as? [String: Any]
    }

    /// Records a link.
    ///
    /// Read-modify-write of the whole nested object: preferences have no partial
    /// update, and writing only this host's sub-object would drop the others.
    static func store(host: String, key: String, url: String) {
        PrefsStore.updateGlobal { global in
            var hosts = (global[storageKey] as? [String: Any]) ?? [:]
            var cache = (hosts[host] as? [String: Any]) ?? [:]
            cache[key] = ["url": url, "at": Date()]
            hosts[host] = cache
            global[storageKey] = hosts
        }
    }

    /// The cache key for `data`, derived from its content rather than its path.
    ///
    /// The compose page writes each pick to a fresh file, so a path would never
    /// repeat. 64-bit FNV-1a: a cryptographic digest would be the obvious choice,
    /// but CommonCrypto is not linked into the Preferences bundle, and a collision
    /// only shows the wrong photo — which a 64-bit digest over a handful of picker
    /// outputs does not reach.
    static func contentKey(for data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

/// Building a `multipart/form-data` body, which every host here needs and none of
/// them should each write a fourth time.
///
/// Hand-built rather than through a library: this runs inside SpringBoard, where a
/// background `URLSession` is cancelled when the caller returns, so the request is
/// a blocking call on the queue the push is already on — and a dependency for
/// string appending would not pay for itself.
struct MultipartBody {
    let boundary = "PusherBoundary-\(UUID().uuidString)"

    private var data = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }
    var body: Data { data + Data("--\(boundary)--\r\n".utf8) }

    /// A text field.
    mutating func add(_ name: String, _ value: String) {
        add(name, value.data(using: .utf8) ?? Data())
    }

    /// A file field.
    mutating func add(_ name: String, filename: String, type: String, _ value: Data) {
        text("--\(boundary)\r\n")
        text("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        text("Content-Type: \(type)\r\n\r\n")
        data.append(value)
        text("\r\n")
    }

    private mutating func add(_ name: String, _ value: Data) {
        text("--\(boundary)\r\n")
        text("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        data.append(value)
        text("\r\n")
    }

    private mutating func text(_ value: String) {
        data.append(contentsOf: Array(value.utf8))
    }
}

/// A blocking POST, and the JSON answer.
///
/// `URLSession` rather than `NSURLConnection`: the former is the one still supported
/// and still works from a daemon. The semaphore is not a nicety — the session's
/// completion handler runs on another queue, and returning before it has is how an
/// upload would be reported as succeeding without a link.
enum HostUpload {
    /// How long an upload may take before it is abandoned.
    ///
    /// Generous, because a large picture over a slow connection is still worth
    /// sending; bounded, because the notification waiting on it is not.
    static let timeout: TimeInterval = 60

    static func post(
        _ url: String,
        contentType: String,
        body: Data,
        headers: [String: String] = [:]
    ) -> [String: Any]? {
        guard let target = URL(string: url) else { return nil }
        var request = URLRequest(url: target, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = body
        return send(request)
    }

    /// A blocking GET, and the JSON answer.
    static func get(_ url: String, headers: [String: String] = [:]) -> [String: Any]? {
        guard let target = URL(string: url) else { return nil }
        var request = URLRequest(url: target, timeoutInterval: timeout)
        request.httpMethod = "GET"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return send(request)
    }

    private static func send(_ request: URLRequest) -> [String: Any]? {
        let done = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        URLSession.shared.dataTask(with: request) { payload, response, _ in
            defer { done.signal() }
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let payload,
                  let object = try? JSONSerialization.jsonObject(with: payload)
            else { return }
            result = object as? [String: Any]
        }.resume()
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return result
    }
}
