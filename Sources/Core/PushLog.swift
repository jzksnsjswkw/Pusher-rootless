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
        dontTruncate: Bool = false
    ) {
        // Reachable concurrently from the main thread and from URLSession's
        // background completion queues (e.g. Wechat's token request); the
        // read-modify-write of the log prefs must be serialized or entries can
        // be lost.
        lock.lock()
        defer { lock.unlock() }
        addLocked(service: service, context: context, label: label, object: object, dontTruncate: dontTruncate)
    }

    private static let lock = NSLock()

    private static func addLocked(
        service: String,
        context: BulletinContext,
        label: String?,
        object: Any?,
        dontTruncate: Bool
    ) {
        guard isEnabled(forService: service) else { return }

        let sections = LogStore.logSections(forService: service)
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
            lines.append("Processing \(context.appID)")
        }
        lines.append(line(label: label, object: object, dontTruncate: dontTruncate))
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

        LogStore.setLogSections(mutableSections, forService: service)
    }

    /// Combines the label and object the way the log viewer expects.
    private static func line(label: String?, object: Any?, dontTruncate: Bool) -> String {
        // If only one of the two was supplied, log just that one.
        switch (label, object) {
        case let (label?, nil):
            return label
        case let (nil, object?):
            return LogString.describe(object, dontTruncate: dontTruncate)
        case let (label?, object?):
            return "\(label): \(LogString.describe(object, dontTruncate: dontTruncate))"
        case (nil, nil):
            return ""
        }
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
