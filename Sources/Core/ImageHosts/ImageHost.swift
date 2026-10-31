import Foundation

/// A place an attachment can be uploaded to, so a service that only accepts a URL
/// can be sent one.
///
/// The first requirement for this was Bark, but it is not a Bark concern: any API
/// that takes a link instead of Base64 needs it. Which host receives the upload is
/// a property of the host, not of the service asking — the same file may be pushed
/// to several destinations at once, and they can want different hosts.
public protocol ImageHost {
    /// The name this host's cache lives under.
    ///
    /// One entry per host so that switching hosts does not read another's links, and
    /// so a host added later brings its own storage without a migration.
    static var identifier: String { get }

    /// How long a link from this host is trusted.
    static var cacheLifetime: TimeInterval { get }

    /// Uploads `data` and returns the public link, or `nil` on failure.
    static func upload(_ data: Data) -> String?
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

    /// A link for `data`, uploading through `host` if this image has not been seen
    /// there before.
    ///
    /// `nil` when the upload fails, and the caller omits the image field: a push
    /// without a picture is better than a push that does not arrive.
    public static func url<Host: ImageHost>(for data: Data, host: Host.Type) -> String? {
        let key = contentKey(for: data)
        if let cached = entry(host: host.identifier, key: key),
           let link = cached["url"] as? String, !link.isEmpty,
           let at = cached["at"] as? Date,
           // Checked against the clock, not just presence: an entry that outlives
           // the host's own retention is an image that silently stops appearing.
           Date().timeIntervalSince(at) < host.cacheLifetime {
            return link
        }
        guard let uploaded = host.upload(data), !uploaded.isEmpty else { return nil }
        store(host: host.identifier, key: key, url: uploaded)
        return uploaded
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
