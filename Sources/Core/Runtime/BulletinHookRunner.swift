import Foundation
import JavaScriptCore

/// Runs one of an instance's two JavaScript hooks.
///
/// A hook is not a service script. A service script decides *what to send* by
/// calling `push(req)`; a hook is a **filter and an editor** at two fixed points
/// in the pipeline:
///
/// - `received` runs as soon as a notification arrives and the global gates have
///   passed — before the app list, the notification settings and the device
///   conditions are consulted.
/// - `filtered` runs after all of those have already said yes, immediately
///   before the request is built.
///
/// Both receive the same `bullet` and both answer the same way: call `keep()` to
/// continue with (possibly modified) bullet fields, or return without calling it
/// to drop the notification for this instance. `keep({ force: true })` continues
/// *regardless of the filters* — the second hook runs after they have passed
/// anyway, so forcing is how the first hook overrides them.
///
/// A hook cannot send anything: there is no `push` here, so a hook cannot be
/// used to reach a different endpoint. That is the deliberate line between a
/// service (which sends) and an instance hook (which decides).
///
/// ## What a hook gets
///
/// - `bullet` — the notification's fields, writable: assign to any field and
///   `keep()` carries the new value into the rest of the pipeline, including the
///   log and the payload.
/// - `device` — the device state, read-only (frozen in the script), so a hook
///   cannot make the filters see a state the device is not in.
/// - `fetch(url, init)` — real HTTP, the same shim a service script gets, so a
///   hook can ask a model to read an SMS before deciding.
/// - `localStorage`, `console.log` — the same as in a service script, with
///   storage kept per instance *and per hook*, so the two hooks of one instance
///   do not share state.
///
/// ## Cost
///
/// An empty hook is never run: the caller checks ``HookConfig/isEnabled`` first,
/// which is only true when its switch is on and the source is non-empty. That is
/// what keeps a hook that a user experimented with from costing anything on
/// every notification.
public enum BulletinHookRunner {

    /// Which of the two hooks is running. Determines the storage namespace and
    /// the name used in the log.
    public enum Phase: String {
        /// Runs right after the notification is received.
        case received
        /// Runs after every filter has passed.
        case filtered
    }

    /// What a hook decided.
    public struct Outcome {
        /// Whether the hook called `keep()`. `false` means "drop this
        /// notification for this instance", which is a decision, not a failure.
        public let isKept: Bool
        /// `keep({ force: true })`: continue even though a filter said no.
        public let isForced: Bool
        /// Field overrides the hook asked for, applied to the bullet's content.
        public let changes: BulletChanges
        /// Everything the hook printed, for the log.
        public let consoleOutput: [String]
        /// Values the hook left in its storage, for the caller to persist.
        public let storage: [String: String]
        /// Why the hook could not finish. A failure keeps the notification
        /// moving: a broken hook must not silently drop pushes.
        public let failure: JavaScriptRunner.Failure?

        /// Whether the hook changed anything a reader would notice.
        public var hasChanges: Bool { changes.isEmpty == false }
    }

    /// The bullet fields a hook is allowed to rewrite.
    ///
    /// Only the content: the notification's identity (app, bulletin id, date)
    /// identifies it in the log and in the retry bookkeeping, and rewriting
    /// those would corrupt both.
    public struct BulletChanges {
        public var title: String?
        public var subtitle: String?
        public var message: String?

        public var isEmpty: Bool { title == nil && subtitle == nil && message == nil }

        /// Applies the changes to a context, returning the field names changed.
        @discardableResult
        public func apply(to context: inout BulletinContext) -> [String] {
            var changed: [String] = []
            if let title, title != context.title {
                context.title = title
                changed.append("title")
            }
            if let subtitle, subtitle != context.subtitle {
                context.subtitle = subtitle
                changed.append("subtitle")
            }
            if let message, message != context.message {
                context.message = message
                changed.append("message")
            }
            // The composed strings the payload and the log read are derived, so
            // they are rebuilt here rather than left describing the old content.
            if !changed.isEmpty {
                context.displayTitle = BulletinAdapter.displayTitle(
                    appName: context.appName, title: context.title
                )
                context.displayMessage = [context.subtitle, context.message]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            }
            return changed
        }
    }

    // MARK: - Running

    /// Runs one hook.
    ///
    /// - Parameters:
    ///   - script: the hook's source. The caller has already checked it is worth
    ///     running (see ``HookConfig/isEnabled``).
    ///   - phase: which hook this is.
    ///   - context: the notification as the pipeline sees it.
    ///   - deviceState: the device state, injected read-only.
    ///   - storage: what this hook left behind last time.
    ///   - instanceID: identifies the instance, for the storage namespace the
    ///     caller uses.
    public static func run(
        script: String,
        phase: Phase,
        context: BulletinContext,
        deviceState: DeviceState,
        storage: [String: String] = [:]
    ) -> Outcome {
        // A hook runs on the calling queue. The caller (the pipeline) is already
        // off the main thread where the network is concerned; a hook's `fetch`
        // blocks, and that is acceptable here for the same reason it is in a
        // service script.
        JavaScriptRunner.runHook(
            script: script,
            phase: phase.rawValue,
            bullet: bulletFields(from: context),
            device: deviceState.scriptValue,
            storage: storage,
            timeout: Pusher.defaultScriptTimeout
        )
    }

    /// The bullet as a hook sees it: the fields a hook may write back.
    static func bulletFields(from context: BulletinContext) -> [String: Any] {
        [
            "appID": context.appID,
            "appName": context.appName,
            "title": context.title ?? "",
            "subtitle": context.subtitle ?? "",
            "message": context.message ?? "",
            "date": ISO8601DateFormatter().string(from: context.date),
        ]
    }
}

extension BulletinHookRunner.Outcome {
    /// An outcome for a hook that never got to run.
    ///
    /// `isKept` is true: a hook that cannot execute must not be able to drop a
    /// notification, or a typo in it would silently stop every push.
    static func failing(_ message: String, storage: [String: String]) -> Self {
        BulletinHookRunner.Outcome(
            isKept: true, isForced: false, changes: BulletinHookRunner.BulletChanges(),
            consoleOutput: [], storage: storage,
            failure: .script(message)
        )
    }
}
