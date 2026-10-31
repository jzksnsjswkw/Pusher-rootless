import Foundation

/// Detects a forwarding loop by watching for the same notification content
/// arriving over and over.
///
/// A forwarded push can produce a notification of its own, which is then
/// forwarded again. The signal is repetition: the same title, subtitle and
/// message, ten times inside the last twenty-five forwarded notifications.
///
/// The guard lives beside the transport rather than the filter chain, because the
/// question it answers — "has this content been *sent* too many times?" — can only
/// be answered by the thing that sends. Anything that sends counts, whether it was
/// a built-in service building one request or a script pushing five.
public final class LoopGuard {
    public static let shared = LoopGuard()

    private var recentContent: [String] = []

    /// Bulletin ids already counted.
    ///
    /// A notification fanned out to three instances is one notification, not three
    /// links in a chain; without this the threshold would be reached by a third as
    /// many real notifications.
    private var recordedBulletinIDs: [String] = []

    /// Serializes `isLooping` and `recordForwarded`, which run on the notification
    /// thread and on whichever queue a script's background run uses.
    private let lock = NSLock()

    private init() {}

    /// Whether this bulletin's content has already been forwarded often enough to
    /// count as a loop.
    ///
    /// Nothing is recorded here: a notification that is filtered, hidden or has
    /// nowhere to go never reaches a transport, so it cannot be part of a loop —
    /// and counting it would let a burst of blocked notifications fill the window
    /// and silence the next real one.
    public func isLooping(_ context: BulletinContext) -> Bool {
        let signature = context.contentSignature
        lock.lock()
        defer { lock.unlock() }
        return recentContent.filter { $0 == signature }.count
            >= Pusher.loopPreventionThreshold
    }

    /// Notes that this content was actually handed to a transport.
    ///
    /// One entry per notification, not per instance or per request: the loop this
    /// guards against is one notification producing another, and two destinations
    /// both sending the same bulletin — or a script pushing it five times — is not
    /// five links in a chain.
    ///
    /// A test push is not counted. It is a message the user asked for from a
    /// settings page, it cannot be the start of a loop, and a handful of them
    /// tapping through their destinations would otherwise fill the window and
    /// silence the next real notification. The rule lives here rather than at each
    /// call site so that whatever sends — a service, a script, the editor — is
    /// covered by construction.
    public func recordForwarded(_ context: BulletinContext) {
        guard !context.isTest else { return }
        let signature = context.contentSignature
        lock.lock()
        defer { lock.unlock() }

        guard !recordedBulletinIDs.contains(context.bulletinID) else { return }
        recordedBulletinIDs.append(context.bulletinID)
        if recordedBulletinIDs.count > Pusher.loopPreventionWindow {
            recordedBulletinIDs.removeFirst()
        }

        // Slide the window rather than clearing it: clearing would reset the
        // duplicate count mid-loop, so a genuine loop — the threshold within the
        // last window — could never be detected.
        while recentContent.count >= Pusher.loopPreventionWindow {
            recentContent.removeFirst()
        }
        recentContent.append(signature)
    }

    /// Forgets everything. Used by tests; a running tweak keeps its window.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        recentContent.removeAll()
        recordedBulletinIDs.removeAll()
    }
}
