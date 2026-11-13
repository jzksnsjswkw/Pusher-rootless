import Foundation

/// The on-device push log.
///
/// Sections are keyed by the bulletin identity carried on the context
/// (`bulletinID` + `appID` + timestamp), so the log layer never has to know
/// about `BBBulletin`. One section collects the log lines of a single bulletin
/// as it makes its way through the pipeline for one service.
public enum PushLog {

    /// Appends one entry to a bulletin's log section for `service`.
    ///
    /// - Parameters:
    ///   - service: the registry name, or `""` for the global (pre-fan-out) log.
    ///     An empty name is always logged; a named service can be muted through
    ///     its `<service>LogEnabled` preference.
    ///   - label: a line that explains the entry. When `object` is also given
    ///     the two are rendered as `"label: object"`; when only one is given it
    ///     is logged on its own.
    public static func add(
        service: String,
        context: BulletinContext,
        label: String? = nil,
        object: Any? = nil,
        dontTruncate: Bool = false,
        tag: String? = nil
    ) {
        // Reachable concurrently from the main thread and from URLSession's
        // background completion queues (e.g. Wechat's token request); the
        // read-modify-write of the log prefs must be serialized or entries can
        // be lost.
        lock.lock()
        defer { lock.unlock() }
        addLocked(service: service, context: context, label: label, object: object,
                  dontTruncate: dontTruncate, tag: tag)
    }

    private static let lock = NSLock()

    private static func addLocked(
        service: String,
        context: BulletinContext,
        label: String?,
        object: Any?,
        dontTruncate: Bool,
        tag: String?
    ) {
        guard isEnabled(forService: service) else { return }

        // From memory when there is an unwritten change, from disk otherwise.
        //
        // Read from disk on every line and the pending lines are lost: the write
        // is deferred, so the next call would load what was there before the last
        // one and overwrite the entry it had just added.
        let sections = pending(service) ?? LogStore.logSections(forService: service)
        var mutableSections = sections
        let index = mutableSections.firstIndex {
            $0["appID"] as? String == context.appID
                && $0["bulletinID"] as? String == context.bulletinID
                && ($0["timestamp"] as? Date) == context.date
        }

        var section: [String: Any]
        if let index {
            section = mutableSections[index]
        } else {
            section = [
                "appID": context.appID,
                "bulletinID": context.bulletinID,
                "timestamp": context.date,
            ]
        }

        var lines = (section["logs"] as? [String]) ?? []
        if lines.isEmpty {
            // The name travels with the id. The id alone is exact but unreadable
            // — `com.tencent.xin` says nothing to the person reading their own log,
            // and the name is the one thing that makes the section recognisable
            // without going and looking the id up.
            //
            // The name itself is not translated: it is what the app calls itself,
            // which is already in the device's language.
            let name = context.appName
            if !name.isEmpty, name != context.appID {
                lines.append("Processing \(context.appID) (\(name))")
            } else {
                lines.append("Processing \(context.appID)")
            }
        }
        lines.append(line(label: label, object: object,
                          dontTruncate: dontTruncate, tag: tag))
        section["logs"] = lines

        if let index {
            mutableSections[index] = section
        } else {
            mutableSections.append(section)
        }

        // Only keep the most recent sections.
        if mutableSections.count > maxSections {
            mutableSections.removeFirst(mutableSections.count - maxSections)
        }

        // Held in memory until the burst ends.
        //
        // Written to the log domain shortly after rather than on every line. A single
        // request writes a dozen: URL, headers, body, then the response. Each one
        // used to commit the whole log domain to disk and post the Darwin
        // notification the log viewer listens for, so a busy notification woke
        // SpringBoard a dozen times to redraw a screen nobody was looking at.
        objc_sync_enter(flushLock)
        dirty[service] = mutableSections
        objc_sync_exit(flushLock)
        scheduleFlush()
    }

    /// What has been written for `service` but not yet flushed.
    private static func pending(_ service: String) -> [[String: Any]]? {
        objc_sync_enter(flushLock)
        defer { objc_sync_exit(flushLock) }
        return dirty[service]
    }

    /// Writes what has accumulated, once, after a pause.
    ///
    /// The log is a debugging aid: a few hundred milliseconds of lag before the
    /// viewer sees a line is not something a user can notice, and the cost of not
    /// waiting is a disk write per line.
    private static func scheduleFlush() {
        objc_sync_enter(flushLock)
        defer { objc_sync_exit(flushLock) }
        flushWorkItem?.cancel()
        let item = DispatchWorkItem { flush() }
        flushWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + flushDelay, execute: item
        )
    }

    private static let flushLock = NSObject()
    private static var flushWorkItem: DispatchWorkItem?
    /// Service names with unwritten lines, and the sections to write for each.
    private static var dirty: [String: [[String: Any]]] = [:]

    /// How long to wait for more lines before writing.
    private static let flushDelay: TimeInterval = 0.4

    /// Writes every accumulated change, once.
    private static func flush() {
        objc_sync_enter(flushLock)
        let pending = dirty
        dirty.removeAll()
        objc_sync_exit(flushLock)
        for (service, sections) in pending {
            LogStore.setLogSections(sections, forService: service)
        }
    }

    /// Writes anything still pending, now.
    ///
    /// For a caller that is about to exit, or for a page that has just asked for
    /// the log and would otherwise read what was there a moment ago.
    public static func flushNow() { flush() }

    /// Combines the label and object the way the log viewer expects.
    private static func line(label: String?, object: Any?, dontTruncate: Bool,
                             tag: String?) -> String {
        // If only one of the two was supplied, log just that one.
        let body: String
        switch (label, object) {
        case let (label?, nil):
            body = label
        case let (nil, object?):
            body = LogString.describe(object, dontTruncate: dontTruncate)
        case let (label?, object?):
            body = "\(label): \(LogString.describe(object, dontTruncate: dontTruncate))"
        case (nil, nil):
            body = ""
        }
        // A script that calls `push()` several times produces several requests for
        // one notification, and they all share a log section. Without a marker the
        // lines interleave and a reader cannot tell which response belongs to
        // which request — the last one looked like the only one that had answered.
        guard let tag else { return body }
        return "[\(tag)] \(body)"
    }

    /// Whether logging is switched on for one service. The global log (empty
    /// service name) is always on.
    private static func isEnabled(forService service: String) -> Bool {
        guard !service.isEmpty else { return true }
        let prefs = PrefsStore.prefs()
        guard prefs[PrefKey.logEnabledKey(forService: service)] != nil else { return true }
        let enabled = prefs.bool(PrefKey.logEnabledKey(forService: service), default: true)
        if !enabled { PusherLog.debug("[S:\(service)] Log Disabled") }
        return enabled
    }

    /// How many bulletin sections are retained per service.
    private static let maxSections = 100
}
