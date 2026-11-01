import Foundation
import UIKit

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

/// What is being uploaded, which decides how long its link is kept.
///
/// An icon is the same picture every time it is needed, and one that outlives its
/// entry here is an upload repeated on the next notification. An attachment is a
/// photograph of one moment — kept long enough for the notification to still make
/// sense days later, and no longer, because every one of them is a copy of
/// something private sitting on someone else's server.
public enum ImageHostKind: String {
    case icon
    case attachment

    /// How long a link of this kind is reused before uploading again.
    var cacheLifetime: TimeInterval {
        switch self {
        case .icon: return 90 * 24 * 60 * 60
        case .attachment: return 3 * 24 * 60 * 60
        }
    }
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
    public static func url(for data: Data, kind: ImageHostKind) -> String? {
        guard let host = ImageHostRegistry.configured() else { return nil }
        if let limit = host.maximumBytes, data.count > limit { return nil }
        return url(for: data, host: host, kind: kind)
    }

    /// A link for `data` through one specific host.
    public static func url(
        for data: Data, host: any ImageHost.Type, kind: ImageHostKind
    ) -> String? {
        let key = contentKey(for: data)
        if let cached = entry(host: host.identifier, key: key),
           let link = cached["url"] as? String, !link.isEmpty,
           let at = cached["at"] as? Date,
           // The shorter of the two: a link is only as good as the host's own
           // retention, and how long this app would like to keep it.
           Date().timeIntervalSince(at) < min(host.cacheLifetime, kind.cacheLifetime) {
            return link
        }
        guard let uploaded = host.upload(data, key: ImageHostRegistry.key(for: host)),
              !uploaded.isEmpty
        else { return nil }
        store(host: host.identifier, key: key, url: uploaded, kind: kind)
        return uploaded
    }

    /// How many links are stored, over every host.
    ///
    /// Shown before the cache is cleared: "清空缓存" with no number is a button whose
    /// effect the user cannot judge.
    public static func cachedEntryCount() -> Int {
        let hosts = PrefsStore.global()[storageKey] as? [String: Any] ?? [:]
        return hosts.values.reduce(0) { total, value in
            total + ((value as? [String: Any])?.count ?? 0)
        }
    }

    /// Forgets every link.
    ///
    /// Only the cache: the pictures themselves stay on the host, where a link that
    /// has already been sent still resolves. Clearing here means the next push
    /// uploads again, which is the point — a stale entry is what the button is for.
    public static func clearCache() {
        PrefsStore.updateGlobal { $0.removeValue(forKey: storageKey) }
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
    static func store(host: String, key: String, url: String, kind: ImageHostKind) {
        PrefsStore.updateGlobal { global in
            var hosts = (global[storageKey] as? [String: Any]) ?? [:]
            var cache = (hosts[host] as? [String: Any]) ?? [:]
            // Pruned on every write: the cache only ever grows otherwise, and what
            // it holds are links to pictures on someone else's server — the ones
            // nobody will fetch again have no reason to stay.
            cache = pruned(cache)
            cache[key] = ["url": url, "at": Date(), "kind": kind.rawValue]
            hosts[host] = cache
            global[storageKey] = hosts
        }
    }

    /// Drops entries past their retention.
    ///
    /// An entry is worth keeping as long as the link in it still works *and* could
    /// still be asked for. Past that it is a dead link holding a place in the
    /// preferences file, and nothing reads it again — the next upload writes a new
    /// entry under the same key.
    static func pruned(_ cache: [String: Any]) -> [String: Any] {
        let now = Date()
        return cache.filter { _, value in
            guard let entry = value as? [String: Any],
                  let at = entry["at"] as? Date
            else { return false }
            let kind = (entry["kind"] as? String).flatMap(ImageHostKind.init(rawValue:))
                ?? .attachment
            // Twice the lifetime: an entry that just expired is still the link the
            // last notification used, and dropping it keeps nothing.
            return now.timeIntervalSince(at) < kind.cacheLifetime * 2
        }
    }

    /// The cache key for `data`.
    ///
    /// Not the file's bytes. The same picture encoded twice is rarely the same
    /// file: PNG carries the encoder's name, a timestamp, and the exact chunk
    /// splitting any UIKit render happened to choose, so a byte hash of an icon
    /// rendered on two different notifications produced two keys — and an upload
    /// for each. That is what the fifteen identical entries in the settings file
    /// were: one icon, uploaded fifteen times.
    ///
    /// The pixels are what makes two pictures the same, so the pixels are what is
    /// hashed. Decoded through `UIImage` and reduced to the first bytes of its
    /// bitmap, which is stable across encoders for the same drawing.
    ///
    /// 64-bit FNV-1a over those bytes: a cryptographic digest would be the obvious
    /// choice, but CommonCrypto is not linked into the Preferences bundle, and a
    /// collision here only shows the wrong photo — which a 64-bit digest over a
    /// handful of pictures does not reach.
    static func contentKey(for data: Data) -> String {
        if let key = pixelKey(for: data) { return key }
        // Not a picture, or not one UIImage can draw. Hashing the bytes still gives
        // a correct cache for a file that is only ever uploaded verbatim.
        return fnv1a(data)
    }

    /// The hash of a decoded picture's pixels, or `nil` when it does not decode.
    private static func pixelKey(for data: Data) -> String? {
        guard let image = UIImage(data: data),
              let pixels = bitmapBytes(of: image)
        else { return nil }
        return fnv1a(pixels)
    }

    /// A picture's pixels, at a fixed size.
    ///
    /// Drawn into a 64×64 RGBA buffer rather than read from `CGImage`: the source
    /// bitmap's layout depends on how the image was made (premultiplied or not,
    /// wide colour or not), and two encodings of one drawing need not produce the
    /// same buffer. Redrawing normalises both into the same layout, and 64×64 is
    /// enough that two different pictures do not collide while being far cheaper
    /// than hashing a full-size photograph.
    private static func bitmapBytes(of image: UIImage) -> Data? {
        let side = 64
        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &buffer,
            width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        UIGraphicsPopContext()
        return Data(buffer)
    }

    /// 64-bit FNV-1a.
    private static func fnv1a(_ data: Data) -> String {
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
