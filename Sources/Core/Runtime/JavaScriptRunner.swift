import Foundation
import JavaScriptCore

/// Runs a user's JavaScript to decide what a notification should become.
///
/// A script *is* the service: it is handed the notification and a `push(req)`
/// function, and whatever it passes to `push` is what gets sent. A script that
/// never calls `push` therefore does not forward that notification, which is the
/// natural way to write "skip this one".
///
/// ## Threading
///
/// Scripts run on a background queue — never the main thread — because a script
/// that loops forever would otherwise hang SpringBoard until the system's
/// watchdog killed it. ``Options`` decides how much isolation each run gets.
///
/// A `JSContext` may only be used from one thread at a time, which is what makes
/// "shared context, fresh thread per run" impossible rather than merely unwise:
/// a shared context is pinned to the thread that created it, and every run is
/// dispatched there. ``Options`` resolves that combination for its caller so the
/// UI can offer the switches independently.
///
/// ## Async
///
/// `fetch` blocks on the network underneath and returns an already-resolved
/// promise, so a script can use ordinary `await` style. JavaScriptCore drains its
/// microtask queue at the end of each evaluation, so an `async` script body runs
/// to completion before the call returns.
public enum JavaScriptRunner {

    // MARK: - Options

    /// How a script is run.
    public struct Options {
        /// Whether each run gets a fresh `JSContext`. On, one run cannot see
        /// another's variables; off, a context is created once and reused, which
        /// is cheaper but carries state between notifications.
        public var usesOwnContext: Bool
        /// Whether each run gets a thread of its own. Ignored when
        /// ``usesOwnContext`` is true (a fresh context may be used anywhere) and
        /// forced on when it is false, since a shared context has to stay on the
        /// thread that made it.
        public var usesOwnThread: Bool
        /// Seconds a run may take before it is abandoned. Zero means no limit.
        public var timeout: TimeInterval
        /// Largest response body `fetch` will accept, in bytes. Zero means no
        /// limit; a larger body is truncated and noted on the console.
        public var maximumResponseBytes: Int

        public init(
            usesOwnContext: Bool = true,
            usesOwnThread: Bool = true,
            timeout: TimeInterval = Pusher.defaultScriptTimeout,
            maximumResponseBytes: Int = Pusher.defaultMaxResponseBytes
        ) {
            self.usesOwnContext = usesOwnContext
            self.usesOwnThread = usesOwnThread
            self.timeout = timeout
            self.maximumResponseBytes = maximumResponseBytes
        }

        /// The options as the settings page describes them.
        ///
        /// - Parameters:
        ///   - sharingContext: the inverse of ``usesOwnContext``, phrased for the
        ///     switch the user sees.
        ///   - sharingThread: ignored when the context is shared, because a
        ///     shared context fixes its own thread.
        public init(
            sharingContext: Bool,
            sharingThread: Bool,
            timeout: TimeInterval,
            maximumResponseBytes: Int
        ) {
            self.init(
                usesOwnContext: !sharingContext,
                usesOwnThread: sharingContext ? true : sharingThread,
                timeout: timeout,
                maximumResponseBytes: maximumResponseBytes
            )
        }

        public static var `default`: Options { Options() }
    }

    /// Why a run produced nothing.
    public enum Failure {
        /// The script threw, or could not be parsed.
        case script(String)
        /// The run exceeded its time budget.
        case timedOut(TimeInterval)

        public var message: String {
            switch self {
            case .script(let text): return text
            case .timedOut(let seconds):
                return String(format: "Script timed out after %.1fs", seconds)
            }
        }
    }

    /// What one run produced.
    public struct Outcome {
        /// The requests the script pushed, in the order it pushed them.
        ///
        /// Sent already — `push()` delivers as it is called, so this is a record
        /// rather than a to-do list. Counted, it answers "did the script send
        /// anything"; listed, it lets the editor's transcript show what went out.
        public let requests: [PushRequest]
        /// Everything the script printed through `console`.
        public let consoleOutput: [String]
        /// Values the script left in `localStorage`, for the caller to persist.
        public let storage: [String: String]
        /// The failure, when the run did not finish.
        public let failure: Failure?
        /// The script's own `fetch` calls, which the runner performs itself.
        /// A `push(req)` request is *not* among them: it is collected for the
        /// caller to send, so its outcome can only be appended by the caller.

        /// Everything the script did, in the order it did it: `console` lines and
        /// `push` calls interleaved as they happened. A debug view shows this;
        /// the send path only reads ``requests``.
        public let trace: [TraceEntry]

        /// Whether the script chose not to forward this notification.
        public var isSkipped: Bool { failure == nil && requests.isEmpty }
    }

    /// One thing a script did, in order.
    public enum TraceEntry {
        /// A `console.log` line.
        case console(String)
        /// A `push(req)` call, described as raw HTTP.
        case request(method: String, raw: String)
        /// The response to the fetch that preceded it, phrased for the log:
        /// `200` or the reason the request failed.
        case response(String)
    }

    // MARK: - Entry point

    /// Runs `script` for one notification.
    ///
    /// - Parameters:
    ///   - script: the user's source.
    ///   - bullet: the notification, as the fields a service receives.
    ///   - storage: values left by the previous run, exposed as `localStorage`.
    ///   - options: how to run it.
    ///   - fetch: performs one HTTP request **on the calling thread**, so it may
    ///     block. The runner has already put the run somewhere blocking is safe.
    public static func run(
        script: String,
        bullet: [String: Any],
        storage: [String: String] = [:],
        options: Options = .default,
        prefs: [String: Any] = [:],
        device: [String: Any] = [:],
        fetch: @escaping (URLRequest) -> FetchResult,
        deliver: Deliver? = nil
    ) -> Outcome {
        // A shared context lives on one thread; a private context may go
        // anywhere. Either way the work happens off the main thread, which is
        // what the caller's queue provides.
        guard options.usesOwnContext else {
            return host.run(
                script: script, bullet: bullet, storage: storage,
                options: options, prefs: prefs, device: device,
                fetch: fetch, deliver: deliver
            )
        }

        guard options.usesOwnThread, options.timeout > 0 else {
            return evaluate(
                script: script, bullet: bullet, storage: storage,
                options: options, prefs: prefs, device: device,
                fetch: fetch, deliver: deliver
            )
        }

        // The result travels through a box: an abandoned run may still be using
        // the thread, so nothing local may be written after the wait gives up.
        let box = ResultBox()
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value = evaluate(
                script: script, bullet: bullet, storage: storage,
                options: options, prefs: prefs, device: device,
                fetch: fetch, deliver: deliver
            )
            finished.signal()
        }
        thread.stackSize = 1 << 20
        thread.start()

        guard finished.wait(timeout: .now() + options.timeout) == .success else {
            return Outcome(requests: [], consoleOutput: [], storage: storage,
                           failure: .timedOut(options.timeout), trace: [])
        }
        return box.value ?? Outcome(requests: [], consoleOutput: [], storage: storage,
                                    failure: .script("Script produced no result"), trace: [])
    }

    /// The one host used for shared-context runs.
    private static let host = ScriptHost()

    // MARK: - Hooks

    /// Runs a hook: a script whose contract is `keep()`, not `push()`.
    ///
    /// Shares everything with the service-script path — the same `fetch`, the
    /// same `localStorage`, the same threading and timeout rules — so a hook and
    /// a service script behave identically apart from what they are allowed to
    /// do. It is a separate entry point because the *decision* travels a
    /// different way: a hook reports whether to keep the notification and what
    /// it changed, and never produces a request.
    ///
    /// Deliberately no `push` is installed: a hook that could send would be a
    /// service, and the distinction (services send, hooks decide) is the whole
    /// reason the two exist side by side.
    /// Runs a hook with the same watchdog the service scripts get.
    ///
    /// A hook runs on the engine's fan-out queue, one instance after another, so a
    /// `while (true) {}` in one instance's pre-filter does not just hang that
    /// instance — it stops every later instance and the whole notification, on a
    /// queue that is never drained. The timeout cannot interrupt JavaScriptCore
    /// (there is no public way to), but running on a throwaway thread and
    /// abandoning the wait bounds the damage: the queue moves on, and the log says
    /// what happened.
    static func runHook(
        script: String,
        phase: String,
        bullet: [String: Any],
        device: [String: Any],
        storage: [String: String],
        timeout: TimeInterval,
        deliver: Deliver? = nil
    ) -> BulletinHookRunner.Outcome {
        guard timeout > 0 else {
            return runHook(
                script: script, phase: phase, bullet: bullet, device: device,
                storage: storage, timeout: timeout, deliver: deliver, directly: ()
            )
        }

        // Nothing local may be written after the wait gives up — the abandoned
        // thread still owns its copy of everything below this point.
        let box = HookResultBox()
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value = runHook(
                script: script, phase: phase, bullet: bullet, device: device,
                storage: storage, timeout: timeout, deliver: deliver, directly: ()
            )
            finished.signal()
        }
        thread.stackSize = 1 << 20
        thread.start()

        guard finished.wait(timeout: .now() + timeout) == .success else {
            return BulletinHookRunner.Outcome.failing(
                "Hook timed out after \(timeout)s", storage: storage
            )
        }
        return box.value
            ?? BulletinHookRunner.Outcome.failing("Hook produced no result", storage: storage)
    }

    private final class HookResultBox: @unchecked Sendable {
        var value: BulletinHookRunner.Outcome?
    }

    private static func runHook(
        script: String,
        phase: String,
        bullet: [String: Any],
        device: [String: Any],
        storage: [String: String],
        timeout: TimeInterval,
        deliver: Deliver?,
        directly: Void
    ) -> BulletinHookRunner.Outcome {
        // Hooks always get their own context: sharing one would let one hook's
        // `let` collide with another's, and a hook runs at most twice per
        // notification, so there is nothing to save by sharing.
        guard let context = JSContext() else {
            return BulletinHookRunner.Outcome.failing(
                "Could not create a JavaScript context", storage: storage
            )
        }

        var kept = false
        var forced = false
        var decided = false
        var changes = BulletinHookRunner.BulletChanges()
        var consoleLines: [String] = []
        var store = storage
        var failure: JavaScriptRunner.Failure?
        // Requests the hook sent through `push()`, in script order, for the editor
        // to display. Empty in the pipeline, which supplies no `deliver`.
        var hookTrace: [TraceEntry] = []

        context.exceptionHandler = { _, exception in
            failure = failure ?? .script(describe(exception))
        }

        installConsole(into: context) { consoleLines.append($0) }

        // `keep(options)`: how a hook says "carry on". Options travel as an
        // object so a second one can be added without changing the call.
        let keep: @convention(block) (JSValue?) -> Void = { value in
            kept = true
            decided = true
            guard let object = value?.toObject() as? [String: Any] else { return }
            if let force = object["force"] as? Bool, force { forced = true }
        }
        context.setObject(keep, forKeyedSubscript: "keep" as NSString)

        JavaScriptRunner.installGlobals(into: context)
        installStorage(
            into: context,
            read: { store[$0] },
            write: { store[$0] = $1 },
            remove: { store.removeValue(forKey: $0) },
            clear: { store.removeAll() },
            count: { Int32(store.count) }
        )
        installFetch(into: context, options: .init(
            timeout: timeout, maximumResponseBytes: Pusher.defaultMaxResponseBytes
        ), perform: { ScriptHTTP.perform($0) })
        installFetchObserver(into: context)

        // `push()` only exists when the caller supplied a way to send one. The
        // pipeline never does: a hook runs for every notification, and letting a
        // hook forward would send the same alert twice — once by the service that
        // matched it and once by the hook. The editor's Run supplies it so a
        // script can be exercised against a real request.
        if let deliver {
            let sendPush: @convention(block) (JSValue?) -> String = { request in
                guard let request, !request.isUndefined, !request.isNull else {
                    return "{\"status\":0,\"error\":\"push() expects an object\"}"
                }
                guard let object = request.toObject() as? [String: Any],
                      let built = makeRequest(from: object)
                else {
                    return "{\"status\":0,\"error\":\"push() needs a url, or a shortcut with a payload\"}"
                }
                let result = deliver(built)
                // Recorded so the editor shows the same purple request and green
                // or red response a service's Run does. The hook's own outcome
                // has no trace of its own, so this is the list it is read from.
                hookTrace.append(.request(method: built.method, raw: rawHTTP(built)))
                hookTrace.append(.response({
                    if let error = result.error { return "← failed: \(error)" }
                    return "← \(result.status)  \(Self.byteCount(result.body.count))"
                }()))
                return envelope(result)
            }
            context.setObject(sendPush, forKeyedSubscript: "__pushNative" as NSString)
            _ = context.evaluateScript("""
            var push = function (request) {
                var raw = __pushNative(request);
                return __makeResponse(JSON.parse(raw));
            };
            // `__makeResponse` is installed by `installFetch`; the hook path gets
            // the same one so a `response` reads the same in both places.
            if (typeof __makeResponse !== "function") {
                var __makeResponse = function (envelope) { return envelope; };
            }
            """)
            _ = context.evaluateScript("delete globalThis.__pushNative;")
        }

        // `bullet` is writable here — editing it is one of the two things a hook
        // is for — but the *property* is not, so a hook cannot replace the object
        // and lose the fields it did not set. `device` is frozen outright: a hook
        // must not be able to tell the filters a state the device is not in.
        context.setObject(bullet, forKeyedSubscript: "__bullet" as NSString)
        context.setObject(device, forKeyedSubscript: "__device" as NSString)
        // `device` is made read-only field by field. `Object.freeze` on an object
        // a host handed in does not take in JavaScriptCore — the assignment
        // succeeds and the hook reads back what it wrote — so each property is
        // defined explicitly instead. A hook must not be able to tell the
        // filters that the device is in a state it is not.
        _ = context.evaluateScript("""
        var __makeReadOnly = function (target) {
            var frozen = {};
            Object.keys(target).forEach(function (key) {
                frozen[key] = target[key];
                Object.defineProperty(frozen, key, { writable: false, configurable: false });
            });
            return frozen;
        };
        Object.defineProperty(globalThis, 'bullet', { value: __bullet, writable: false, configurable: true });
        Object.defineProperty(globalThis, 'device', { value: __makeReadOnly(__device), writable: false, configurable: true });
        delete globalThis.__bullet;
        delete globalThis.__device;
        delete globalThis.__makeReadOnly;
        """)

        let onFulfilled: @convention(block) (JSValue?) -> Void = { _ in }
        let onRejected: @convention(block) (JSValue?) -> Void = { value in
            failure = failure ?? .script(describe(value))
        }
        context.setObject(onFulfilled, forKeyedSubscript: "__hookFulfilled" as NSString)
        context.setObject(onRejected, forKeyedSubscript: "__hookRejected" as NSString)

        // The body is a block, so a hook's top-level `let`/`const` belong to the
        // run and cannot collide with a previous one.
        _ = context.evaluateScript("""
        (async function () {
        {
        \(script)
        }
        })().then(globalThis.__hookFulfilled, globalThis.__hookRejected);
        """)
        _ = context.evaluateScript("1")

        // Read the bullet back: the hook's whole point is that it may have
        // changed it, and `keep()` is what decides whether it did so usefully.
        if kept, let edited = context.objectForKeyedSubscript("bullet")?.toObject()
            as? [String: Any] {
            changes.title = stringField(edited, "title", original: bullet)
            changes.subtitle = stringField(edited, "subtitle", original: bullet)
            changes.message = stringField(edited, "message", original: bullet)
        }

        // A hook that broke before reaching a decision must not decide.
        //
        // "Did not call keep()" means "drop this notification", which is right
        // for a hook that ran and chose silence — but a hook that threw on line
        // one never chose anything, and treating that as a drop would let one
        // typo silently stop every push from that instance. Failing open is the
        // only safe reading: the notification keeps moving and the log says why.
        if failure != nil, !decided {
            kept = true
            changes = BulletinHookRunner.BulletChanges()
        }

        return BulletinHookRunner.Outcome(
            isKept: kept, isForced: forced, changes: changes,
            consoleOutput: consoleLines, storage: store, failure: failure,
            trace: hookTrace
        )
    }

    /// A bullet field the hook left in place, or `nil` when it changed nothing.
    private static func stringField(
        _ edited: [String: Any], _ name: String, original: [String: Any]
    ) -> String? {
        guard let value = edited[name] as? String,
              let before = original[name] as? String
        else { return nil }
        return value == before ? nil : value
    }

    /// Collects a run's result across the thread hop.
    private final class ResultBox: @unchecked Sendable {
        var value: Outcome?
    }

    // MARK: - A response

    /// What the host's `fetch` returns for one request.
    public struct FetchResult {
        /// HTTP status, or `0` when the request never completed.
        public let status: Int
        /// Response headers, stored lower-cased as the specification requires.
        public let headers: [String: String]
        public let body: Data
        /// The URL after any redirects, when it differs from the requested one.
        public let finalURL: String?
        /// Set when the request could not be performed at all — no network, an
        /// unresolvable host — which `fetch` reports as a rejected promise
        /// rather than as a response.
        public let error: String?

        public init(
            status: Int = 0,
            headers: [String: String] = [:],
            body: Data = Data(),
            finalURL: String? = nil,
            error: String? = nil
        ) {
            self.status = status
            self.headers = headers
            self.body = body
            self.finalURL = finalURL
            self.error = error
        }
    }

    // MARK: - Evaluating

    /// Evaluates one script against a fresh context.
    private static func evaluate(
        script: String,
        bullet: [String: Any],
        storage: [String: String],
        options: Options,
        prefs: [String: Any],
        device: [String: Any],
        fetch: @escaping (URLRequest) -> FetchResult,
        deliver: Deliver? = nil
    ) -> Outcome {
        guard let context = JSContext() else {
            return Outcome(requests: [], consoleOutput: [], storage: storage,
                           failure: .script("Could not create a JavaScript context"), trace: [])
        }
        return evaluate(
            script: script, in: context, bullet: bullet, storage: storage,
            options: options, prefs: prefs, device: device,
            fetch: fetch, deliver: deliver
        )
    }

    /// Sends one request on behalf of `push()` and returns what came back.
    ///
    /// The delivery is supplied by the caller rather than performed here: the
    /// runner knows how to build a request but not how a service sends one, and
    /// the two things it must not do are duplicate the transport and bypass it.
    /// Left unset — a hook, or the editor's dry run — `push()` answers with a
    /// response that says it was not sent, which is honest rather than silent.
    public typealias Deliver = (PushRequest) -> FetchResult

    /// Evaluates one script in a given context.
    ///
    /// - Returns: the requests it asked for and everything it printed, or the
    ///   reason it failed.
    static func evaluate(
        script: String,
        in context: JSContext,
        bullet: [String: Any],
        storage: [String: String],
        options: Options,
        prefs: [String: Any],
        device: [String: Any],
        fetch: @escaping (URLRequest) -> FetchResult,
        deliver: Deliver? = nil
    ) -> Outcome {
        var requests: [PushRequest] = []
        var consoleOutput: [String] = []
        var trace: [TraceEntry] = []
        var store = storage
        var failure: Failure?

        // A syntax error arrives here as well as a thrown exception, so this is
        // the single place a failure is observed.
        context.exceptionHandler = { _, exception in
            failure = .script(describe(exception))
        }

        installConsole(into: context) {
            consoleOutput.append($0)
            trace.append(.console($0))
        }

        // `push(req)`: the only way a script sends anything, and it sends *now*.
        //
        // It used to collect requests for the pipeline to send afterwards, which
        // made the script unable to see what happened — so it could not decide
        // whether the next push was worth making. Sending here and returning the
        // response gives a script the same footing `fetch` has: await the result,
        // read the status, carry on or stop.
        //
        // Blocking is safe for the same reason `fetch` is: the whole run happens on
        // a background queue or a dedicated thread, never on the main one.
        // Exposed as `__pushNative`, and `push()` itself is a thin JS wrapper that
        // turns the envelope into the same Response object `fetch` resolves to.
        let push: @convention(block) (JSValue?) -> String = { value in
            guard let object = value?.toObject() as? [String: Any] else {
                consoleOutput.append("push() expects an object")
                return envelope(FetchResult(error: "push() expects an object"))
            }
            guard let request = makeRequest(from: object) else {
                let message = "push() needs a url, or a shortcut with a payload"
                consoleOutput.append(message)
                return envelope(FetchResult(error: message))
            }
            trace.append(.request(method: request.method, raw: rawHTTP(request)))
            requests.append(request)

            let result = deliver?(request) ?? FetchResult(
                status: 0, error: "push() is not available here"
            )
            // Described in the same words a `fetch` response uses, so the editor's
            // output reads as one transcript rather than two.
            if let error = result.error {
                trace.append(.response("← failed: \(error)"))
            } else {
                trace.append(.response("← \(result.status)  \(Self.byteCount(result.body.count))"))
            }
            return envelope(result)
        }
        context.setObject(push, forKeyedSubscript: "__pushNative" as NSString)

        // The store is captured by the four accessors below, all of which see
        // the same dictionary, and `store` is what the outcome carries back out.
        JavaScriptRunner.installGlobals(into: context)
        installStorage(
            into: context,
            read: { store[$0] },
            write: { store[$0] = $1 },
            remove: { store.removeValue(forKey: $0) },
            clear: { store.removeAll() },
            count: { Int32(store.count) }
        )
        installFetch(into: context, options: options, perform: fetch)
        installFetchRecorder(into: context) { trace.append($0) }
        installFetchObserver(into: context)

        // `push()` is installed after `fetch`, because it is defined in terms of
        // the response object `fetch` creates: one shape for both, so a script
        // checks `res.ok` the same way whether it sent or fetched.
        _ = context.evaluateScript("""
        var push = function (request) {
            var raw = __pushNative(request);
            return __makeResponse(JSON.parse(raw));
        };
        """)

        // `pref`: the values the service's author declared, as filled in on the
        // instance running now. Frozen field by field for the same reason
        // `device` is — writing to it would change something that is not saved,
        // so the next run would read a different value than the script wrote.
        context.setObject(prefs, forKeyedSubscript: "__pref" as NSString)
        _ = context.evaluateScript(
            "var __frozenPref = {};"
                + "Object.keys(__pref).forEach(function (k) {"
                + "  __frozenPref[k] = __pref[k];"
                + "  Object.defineProperty(__frozenPref, k,"
                + "    { writable: false, configurable: false });"
                + "});"
                + "Object.defineProperty(globalThis, 'pref',"
                + "  { value: __frozenPref, writable: false, configurable: true });"
                + "delete globalThis.__pref;"
                + "delete globalThis.__frozenPref;"
        )

        // `device`: the same read-only object a hook sees, so a script can branch
        // on the battery or the network the same way its hook does. Not writable
        // for the same reason `pref` is not — nothing would save the change.
        if !device.isEmpty {
            context.setObject(device, forKeyedSubscript: "__device" as NSString)
            _ = context.evaluateScript(
                "Object.defineProperty(globalThis, 'device',"
                    + "  { value: __device, writable: false, configurable: true });"
                    + "delete globalThis.__device;"
            )
        }

        // The notification, marked non-writable so a script cannot replace it and
        // read stale fields back out of its own copy.
        context.setObject(bullet, forKeyedSubscript: "__bullet" as NSString)
        // Configurable, because the property is redefined on every run — with a
        // shared context, a non-configurable definition succeeds once and then
        // throws for the rest of the context's life. Not writable, which is what
        // the script needs: it can read `bullet` and cannot replace it with a
        // copy of its own, so it cannot read stale fields back out.
        _ = context.evaluateScript(
            "Object.defineProperty(globalThis, 'bullet', "
                + "{ value: __bullet, writable: false, configurable: true });"
                + "delete globalThis.__bullet;"
        )

        // The script runs as the body of an `async` function, and the promise
        // that produces is observed. Two things fall out of that: a top-level
        // `await` works without the script having to wrap itself in an IIFE, and
        // a throw anywhere on the awaited path rejects a promise this side holds
        // — which is the only way such a failure becomes reportable, since it
        // never reaches `exceptionHandler`.
        //
        // A script that writes its own `(async () => …)()` still rejects an
        // unheld promise, so ``installFetch`` records failed fetches as well and
        // the run falls back to that when nothing was sent.
        let onFulfilled: @convention(block) (JSValue?) -> Void = { _ in }
        let onRejected: @convention(block) (JSValue?) -> Void = { value in
            failure = failure ?? .script(describe(value))
        }
        context.setObject(onFulfilled, forKeyedSubscript: "__scriptFulfilled" as NSString)
        context.setObject(onRejected, forKeyedSubscript: "__scriptRejected" as NSString)

        // The script's own scope is a block, not the global one: with a shared
        // context, top-level `let`/`const` written straight into the global
        // scope would be re-declared by the next run and throw from the
        // temporal dead zone. A block gives each run its own bindings, which is
        // also the semantics "a run's variables do not leak" promises.
        let wrapped = """
        (async function () {
        {
        \(script)
        }
        })().then(globalThis.__scriptFulfilled, globalThis.__scriptRejected);
        """
        _ = context.evaluateScript(wrapped)

        // Settling a promise is a microtask, so the queue has to be drained by
        // one more evaluation before the failure is read.
        _ = context.evaluateScript("1")

        // A failed `fetch` that the script ignored explains an empty run when
        // nothing else does. It is not reported when the script sent something,
        // because a script that handled the failure and pushed has succeeded.
        if failure == nil, requests.isEmpty, let firstFailure = firstFetchFailure(in: context) {
            failure = .script(firstFailure)
        }

        return Outcome(
            requests: requests, consoleOutput: consoleOutput, storage: store,
            failure: failure, trace: trace
        )
    }

    /// One pushed request, as the raw HTTP a client would have sent.
    private static func rawHTTP(_ request: PushRequest) -> String {
        let target = URL(string: request.urlString)
        let path = target.flatMap { $0.path.isEmpty ? "/" : $0.path } ?? "/"
        let query = target?.query.map { "?\($0)" } ?? ""
        var lines = ["\(request.method) \(path)\(query) HTTP/1.1",
                     "Host: \(target?.host ?? "?")"]
        for field in request.headers.keys.sorted() {
            lines.append("\(field): \(request.headers[field] ?? "")")
        }
        if let body = try? JSONSerialization.data(withJSONObject: request.infoDict),
           let text = String(data: body, encoding: .utf8), !request.infoDict.isEmpty {
            lines.append("")
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }


    /// A readable description of a thrown value: its message, then its stack.
    ///
    /// The stack's line numbers come out empty on this platform, so the function
    /// names are what say where the script failed.
    private static func describe(_ exception: JSValue?) -> String {
        guard let exception else { return "Script error" }
        let message = exception.toString() ?? "Script error"
        guard let stack = exception.objectForKeyedSubscript("stack")?.toString() else {
            return message
        }
        let frames = stack
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return frames.isEmpty ? message : "\(message) at \(frames.joined(separator: " → "))"
    }

    // MARK: - The script's API

    /// `console.log` and friends, collected for the instance's log.
    private static func installConsole(into context: JSContext, append: @escaping (String) -> Void) {
        /// Renders one argument: strings bare, everything else as JSON where it
        /// can be, so `console.log(bullet)` shows the object.
        func render(_ value: JSValue?) -> String {
            guard let value else { return "undefined" }
            if value.isUndefined { return "undefined" }
            if value.isNull { return "null" }
            if value.isString { return value.toString() ?? "" }
            // An object stringifies to "[object Object]", which tells the reader
            // nothing, so it is serialized instead — `console.log(bullet)` is the
            // most useful line a script can contain.
            if value.isObject, let object = value.toObject(),
               JSONSerialization.isValidJSONObject(object),
               let data = try? JSONSerialization.data(withJSONObject: object),
               let json = String(data: data, encoding: .utf8) {
                return json
            }
            return value.toString() ?? String(describing: value)
        }

        // A variadic call hands the arguments over through the context's
        // `currentArguments`, not as a single value: a block declared with one
        // parameter receives only the first one.
        let sink: @convention(block) () -> Void = {
            let arguments = JSContext.currentArguments() as? [JSValue] ?? []
            let line = arguments.map { render($0) }.joined(separator: " ")
            append(line)
        }

        let console = JSValue(newObjectIn: context)
        for name in ["log", "info", "warn", "error", "debug", "trace"] {
            console?.setObject(sink, forKeyedSubscript: name as NSString)
        }
        context.setObject(console, forKeyedSubscript: "console" as NSString)
    }

    /// The globals JavaScriptCore does not ship.
    ///
    /// `Math`, `Date`, `JSON`, `Intl`, `Map`, `Set`, `Promise`, `RegExp`, `Proxy`
    /// and the ES2022 array and string methods are all native to this engine —
    /// there is nothing to add and nothing to gain from wrapping them. What is
    /// missing is the browser-adjacent half: the text encoders, the URL parser,
    /// base64, and a structured clone. Those are the ones a script reaches for
    /// without thinking, and without them the failure is a bare `X is not a
    /// function` at run time.
    ///
    /// `setTimeout` is deliberately absent. The script runs on a thread that blocks
    /// inside `fetch`, so a timer callback could only fire after the run it belongs
    /// to has already ended — `await new Promise(r => setTimeout(r, 500))` would
    /// hang until the timeout kills the run instead of pausing it. A missing
    /// function is an error a script author can read; a timer that never fires is
    /// not.
    private static func installGlobals(into context: JSContext) {
        // The four host-backed pieces, as blocks. Everything else is written in
        // JavaScript below, where it can stay close to the shape it imitates.
        let encode: @convention(block) (JSValue?) -> [NSNumber] = { text in
            [UInt8]((text?.toString() ?? "").utf8).map { NSNumber(value: $0) }
        }
        let btoa: @convention(block) (JSValue?) -> String = { text in
            Data((text?.toString() ?? "").utf8).base64EncodedString()
        }
        // No `.ignoreUnknownCharacters` and a strict round trip: `atob` has to
        // reject what is not base64. The platform's lenient decoder would turn
        // `"!!!"` into an empty string and lose the mistake.
        let atob: @convention(block) (JSValue?) -> String? = { text in
            let input = text?.toString() ?? ""
            guard let data = Data(base64Encoded: input),
                  data.base64EncodedString() == input
            else { return nil }
            return String(data: data, encoding: .utf8)
                ?? String(decoding: data, as: UTF8.self)
        }
        let decode: @convention(block) (JSValue?) -> String = { text in
            let latin1 = text?.toString() ?? ""
            var bytes: [UInt8] = []
            bytes.reserveCapacity(latin1.unicodeScalars.count)
            for scalar in latin1.unicodeScalars where scalar.value <= 0xFF {
                bytes.append(UInt8(scalar.value))
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        context.setObject(decode, forKeyedSubscript: "__pusherDecode" as NSString)
        context.setObject(encode, forKeyedSubscript: "__pusherEncode" as NSString)
        context.setObject(btoa, forKeyedSubscript: "__pusherBtoa" as NSString)
        context.setObject(atob, forKeyedSubscript: "__pusherAtob" as NSString)

        _ = context.evaluateScript("""
        var TextEncoder = function () {};
        TextEncoder.prototype.encoding = "utf-8";
        TextEncoder.prototype.encode = function (text) {
            var bytes = __pusherEncode(String(text === undefined ? "" : text));
            var out = new Uint8Array(bytes.length);
            for (var i = 0; i < bytes.length; i++) { out[i] = bytes[i]; }
            return out;
        };
        TextEncoder.prototype.encodeInto = function (text, target) {
            var bytes = this.encode(text);
            var n = Math.min(bytes.length, target.length);
            for (var i = 0; i < n; i++) { target[i] = bytes[i]; }
            return { read: String(text).length, written: n };
        };

        var TextDecoder = function (label) {
            this.encoding = (label || "utf-8").toLowerCase();
        };
        TextDecoder.prototype.decode = function (bytes) {
            var out = "";
            for (var i = 0; i < bytes.length; i++) {
                out += String.fromCharCode(bytes[i]);
            }
            // A Latin-1 string of the bytes, handed back to the host to decode as
            // UTF-8. `decodeURIComponent(escape(...))` was the shortcut here and is
            // both deprecated and wrong: it decodes `%` sequences as well, so a
            // byte like 0x25 could not survive.
            return __pusherDecode(out);
        };

        var btoa = function (text) {
            var input = String(text);
            for (var i = 0; i < input.length; i++) {
                if (input.charCodeAt(i) > 255) {
                    throw new Error("btoa: the string has characters outside Latin-1");
                }
            }
            return __pusherBtoa(input);
        };
        var atob = function (text) {
            var output = __pusherAtob(String(text));
            // The host answers `undefined` for a string it cannot decode; `null`
            // is what a Swift `String?` bridges to, so both are checked.
            if (output === null || output === undefined) {
                throw new Error("atob: the string is not valid base64");
            }
            return output;
        };

        var URLSearchParams = function (init) {
            var pairs = [];
            var add = function (key, value) {
                pairs.push([String(key), String(value)]);
            };
            if (init === undefined || init === null) {
                // empty
            } else if (typeof init === "string") {
                var query = init.charAt(0) === "?" ? init.slice(1) : init;
                if (query.length > 0) {
                    query.split("&").forEach(function (pair) {
                        if (pair.length === 0) { return; }
                        var index = pair.indexOf("=");
                        var key = index < 0 ? pair : pair.slice(0, index);
                        var value = index < 0 ? "" : pair.slice(index + 1);
                        add(decodeURIComponent(key.replace(/[+]/g, " ")),
                            decodeURIComponent(value.replace(/[+]/g, " ")));
                    });
                }
            } else if (typeof init === "object") {
                Object.keys(init).forEach(function (key) {
                    var value = init[key];
                    if (Array.isArray(value)) {
                        value.forEach(function (item) { add(key, item); });
                    } else {
                        add(key, value);
                    }
                });
            }
            var api = {
                append: function (k, v) { add(k, v); },
                set: function (k, v) {
                    pairs = pairs.filter(function (pair) { return pair[0] !== String(k); });
                    add(k, v);
                },
                get: function (k) {
                    var found = pairs.filter(function (p) { return p[0] === String(k); });
                    return found.length ? found[0][1] : null;
                },
                getAll: function (k) {
                    return pairs.filter(function (p) { return p[0] === String(k); })
                                .map(function (p) { return p[1]; });
                },
                has: function (k) {
                    return pairs.some(function (p) { return p[0] === String(k); });
                },
                delete: function (k) {
                    pairs = pairs.filter(function (p) { return p[0] !== String(k); });
                },
                forEach: function (fn) {
                    pairs.forEach(function (p) { fn(p[1], p[0], api); });
                },
                entries: function () { return pairs.map(function (p) { return [p[0], p[1]]; })[Symbol.iterator](); },
                keys: function () { return pairs.map(function (p) { return p[0]; })[Symbol.iterator](); },
                values: function () { return pairs.map(function (p) { return p[1]; })[Symbol.iterator](); },
                toString: function () {
                    return pairs.map(function (p) {
                        return encodeURIComponent(p[0]) + "=" + encodeURIComponent(p[1]);
                    }).join("&");
                }
            };
            Object.defineProperty(api, "size", { get: function () { return pairs.length; } });
            return api;
        };

        var URL = function (input, base) {
            var raw = String(input);
            var absolute;
            if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(raw)) {
                absolute = raw;
            } else if (base === undefined) {
                throw new TypeError("URL: '" + raw + "' is not an absolute URL");
            } else {
                var resolvedBase = new URL(String(base));
                absolute = raw.charAt(0) === "/"
                    ? resolvedBase.origin + raw
                    : resolvedBase.origin + resolvedBase.pathname.replace(/[^/]*$/, "") + raw;
            }
            var match = /^([a-zA-Z][a-zA-Z0-9+.-]*):(?:[/][/]([^/?#]*))?([^?#]*)(?:[?]([^#]*))?(?:#(.*))?$/
                .exec(absolute);
            if (!match) { throw new TypeError("URL: could not parse '" + raw + "'"); }

            var scheme = match[1].toLowerCase();
            var authority = match[2] || "";
            var path = match[3] || "";
            var search = match[4] === undefined ? "" : match[4];
            var hash = match[5] === undefined ? "" : match[5];

            var userInfo = "";
            var host = authority;
            var at = authority.lastIndexOf("@");
            if (at >= 0) {
                userInfo = authority.slice(0, at);
                host = authority.slice(at + 1);
            }
            var port = "";
            var colon = host.lastIndexOf(":");
            if (colon >= 0 && host.indexOf("]") < colon) {
                port = host.slice(colon + 1);
                host = host.slice(0, colon);
            }

            var api = {
                protocol: scheme + ":",
                username: userInfo.split(":")[0] || "",
                password: userInfo.indexOf(":") >= 0 ? userInfo.split(":")[1] : "",
                host: host + (port ? ":" + port : ""),
                hostname: host,
                port: port,
                pathname: path || (authority ? "/" : ""),
                search: search ? "?" + search : "",
                hash: hash ? "#" + hash : "",
                toString: function () {
                    var query = this.search;
                    return this.protocol + "//" + this.host + this.pathname + query + this.hash;
                }
            };
            Object.defineProperty(api, "origin", {
                get: function () { return this.protocol + "//" + this.host; }
            });
            Object.defineProperty(api, "searchParams", {
                get: function () { return new URLSearchParams(this.search); }
            });
            Object.defineProperty(api, "href", {
                get: function () { return this.toString(); }
            });
            return api;
        };

        var structuredClone = function (value) {
            // JSON is enough here: the values a script clones are the ones it also
            // sends, and those have to survive serialization anyway.
            if (value === undefined) { return undefined; }
            return JSON.parse(JSON.stringify(value));
        };

        var queueMicrotask = function (fn) {
            Promise.resolve().then(fn);
        };

        delete globalThis.__pusherDecode;
        delete globalThis.__pusherEncode;
        delete globalThis.__pusherBtoa;
        delete globalThis.__pusherAtob;
        """)
    }

    /// `localStorage`, backed by a dictionary for the duration of the run.
    ///
    /// The store is copied in and handed back with the outcome, so the caller
    /// decides where it lives between runs — which is what keeps two instances of
    /// one service from sharing their storage.
    private static func installStorage(
        into context: JSContext,
        read: @escaping (String) -> String?,
        write: @escaping (String, String) -> Void,
        remove removeItem: @escaping (String) -> Void,
        clear clearItems: @escaping () -> Void,
        count: @escaping () -> Int32
    ) {
        let get: @convention(block) (JSValue?) -> String? = { key in
            guard let key = key?.toString() else { return nil }
            return read(key)
        }
        let set: @convention(block) (JSValue?, JSValue?) -> Void = { key, value in
            guard let key = key?.toString() else { return }
            write(key, value?.toString() ?? "")
        }
        let remove: @convention(block) (JSValue?) -> Void = { key in
            guard let key = key?.toString() else { return }
            removeItem(key)
        }
        let clear: @convention(block) () -> Void = { clearItems() }
        let length: @convention(block) () -> Int32 = { count() }

        let storage = JSValue(newObjectIn: context)
        storage?.setObject(get, forKeyedSubscript: "getItem" as NSString)
        storage?.setObject(set, forKeyedSubscript: "setItem" as NSString)
        storage?.setObject(remove, forKeyedSubscript: "removeItem" as NSString)
        storage?.setObject(clear, forKeyedSubscript: "clear" as NSString)
        storage?.setObject(length, forKeyedSubscript: "__length" as NSString)

        // `localStorage.length` is a read-only property in the specification, not a
        // method, so it is a getter rather than a function under that name. A
        // function would still be truthy and would break the
        // `for (i = 0; i < localStorage.length; i++)` loop that is the only reason
        // anyone reads it.
        context.evaluateScript("""
        (function (s) {
            Object.defineProperty(s, 'length', {
                get: function () { return s.__length(); },
                configurable: false
            });
        })
        """).call(withArguments: [storage as Any])
        // Several names the platform's storage goes by, so a script written
        // against either the browser or the mini-program convention works.
        for name in ["localStorage", "sessionStorage"] {
            context.setObject(storage, forKeyedSubscript: name as NSString)
        }
    }

    /// `fetch(url, init)` — the specification's shape, over a blocking host call.
    private static func installFetch(
        into context: JSContext,
        options: Options,
        perform: @escaping (URLRequest) -> FetchResult
    ) {
        /// The native half: builds the request, blocks on `perform`, and returns
        /// a JSON envelope the shim below turns into a `Response`.
        let native: @convention(block) (JSValue?, JSValue?) -> String = { input, initObject in
            guard let urlString = input?.toString(), !urlString.isEmpty else {
                return envelope(error: "fetch: a URL is required")
            }
            guard let url = URL(string: urlString), url.scheme != nil else {
                return envelope(error: "fetch: invalid URL '\(urlString)'")
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = Pusher.scriptFetchTimeout
            if let optionsObject = initObject?.toObject() as? [String: Any] {
                if let method = optionsObject["method"] as? String {
                    request.httpMethod = method.uppercased()
                }
                for (field, value) in (optionsObject["headers"] as? [String: Any]) ?? [:] {
                    request.setValue(
                        value as? String ?? String(describing: value), forHTTPHeaderField: field
                    )
                }
                switch optionsObject["body"] {
                case let text as String:
                    request.httpBody = text.data(using: .utf8)
                case let object? where !(object is NSNull):
                    // A plain object is sent as JSON, which is what a script
                    // author means ninety-nine times out of a hundred.
                    if let data = try? JSONSerialization.data(withJSONObject: object) {
                        request.httpBody = data
                        if request.value(forHTTPHeaderField: "Content-Type") == nil {
                            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        }
                    }
                default:
                    break
                }
            }

            let result = perform(request)
            if let error = result.error {
                return envelope(error: "fetch: \(error)")
            }

            // An over-limit body is truncated rather than refused, so the script
            // still gets a response; the console note is how the user finds out.
            var body = result.body
            var note = ""
            if options.maximumResponseBytes > 0, body.count > options.maximumResponseBytes {
                body = body.prefix(options.maximumResponseBytes)
                note = "fetch: response truncated to \(options.maximumResponseBytes) bytes"
            }

            return envelope(result, body: body, url: result.finalURL ?? urlString, note: note)
        }
        context.setObject(native, forKeyedSubscript: "__fetchNative" as NSString)

        // The specification's face: a promise resolving to a Response with
        // `ok` / `status` / `headers` / `url`, and `text()` / `json()` that
        // themselves return promises.
        _ = context.evaluateScript("""
        // The response object both `fetch` and `push` hand back. One shape, because
        // a script that checks `res.ok` after a fetch should be able to check it
        // after a push without learning a second set of fields.
        var __makeResponse = function (data) {
            var lower = {};
            Object.keys(data.headers || {}).forEach(function (key) {
                lower[String(key).toLowerCase()] = String(data.headers[key]);
            });
            return {
                ok: data.status >= 200 && data.status < 300,
                status: data.status,
                statusText: '',
                url: data.url || '',
                error: data.error || null,
                headers: {
                    get: function (name) {
                        var value = lower[String(name).toLowerCase()];
                        return value === undefined ? null : value;
                    },
                    has: function (name) {
                        return lower[String(name).toLowerCase()] !== undefined;
                    },
                    forEach: function (callback) {
                        Object.keys(lower).forEach(function (key) {
                            callback(lower[key], key);
                        });
                    },
                    keys: function () { return Object.keys(lower); }
                },
                text: function () { return Promise.resolve(data.body || ''); },
                json: function () { return Promise.resolve(JSON.parse(data.body || 'null')); }
            };
        };
        globalThis.__makeResponse = __makeResponse;

        var fetch = function (input, init) {
            return new Promise(function (resolve, reject) {
                var raw;
                try {
                    raw = __fetchNative(String(input), init || {});
                } catch (e) {
                    reject(e);
                    return;
                }
                var data = JSON.parse(raw);
                if (data.error) {
                    if (globalThis.__fetchRecord) {
                        __fetchRecord(JSON.stringify({ error: data.error }));
                    }
                    reject(new TypeError(data.error));
                    return;
                }
                if (globalThis.__fetchRecord) {
                    __fetchRecord(JSON.stringify({
                        status: data.status,
                        bytes: (data.body || '').length
                    }));
                }
                if (data.note) { console.warn(data.note); }

                var lower = {};
                Object.keys(data.headers || {}).forEach(function (key) {
                    lower[String(key).toLowerCase()] = String(data.headers[key]);
                });

                resolve(__makeResponse(data));
            });
        };
        """)
    }

    /// Records every fetch outcome into the trace, so a run's report shows what
    /// each request answered — the half of the exchange a script author needs
    /// when a service rejects the call.
    ///
    /// Unconditional: the trace is the editor's channel, and the pipeline simply
    /// never reads it.
    private static func installFetchRecorder(
        into context: JSContext,
        append: @escaping (TraceEntry) -> Void
    ) {
        let sink: @convention(block) (JSValue?) -> Void = { value in
            guard let text = value?.toString() else { return }
            // The script side sends a JSON object so status and size stay
            // separate; a plain string is still accepted.
            if let data = text.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let error = object["error"] as? String {
                    append(.response("← failed: \(error)"))
                    return
                }
                let status = object["status"] as? Int ?? 0
                let bytes = object["bytes"] as? Int ?? 0
                append(.response("← \(status)  \(Self.byteCount(bytes))"))
                return
            }
            append(.response(text))
        }
        context.setObject(sink, forKeyedSubscript: "__fetchRecord" as NSString)
    }

    /// A byte count as a person reads it.
    private static func byteCount(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    /// Records a failed `fetch` so an ignored rejection can still be reported.
    ///
    /// The script is wrapped in an `async` function whose promise is observed,
    /// which catches a failure on the awaited path *at the top level*. A script
    /// that writes its own async IIFE rejects a promise nobody holds, so without
    /// this its failure would be invisible and the notification would simply not
    /// be forwarded for no stated reason.
    ///
    /// The observer attaches a second handler rather than replacing the first,
    /// so a script's own `catch` still runs.
    private static func installFetchObserver(into context: JSContext) {
        _ = context.evaluateScript("""
        var __fetchFailures = [];
        (function () {
            var original = fetch;
            fetch = function (input, init) {
                var promise = original(input, init);
                promise.catch(function (error) {
                    __fetchFailures.push(String(error && error.message ? error.message
                                                                       : error));
                });
                return promise;
            };
        })();
        """)
    }

    /// The first failed `fetch` this run saw, if any.
    private static func firstFetchFailure(in context: JSContext) -> String? {
        guard let failures = context.objectForKeyedSubscript("__fetchFailures")?
            .toArray() as? [String], let first = failures.first else { return nil }
        return "fetch failed: \(first)"
    }

    /// The JSON envelope both native halves return; the JS side turns it into the
    /// Response object a script sees.
    private static func envelope(
        _ result: FetchResult,
        body: Data? = nil,
        url: String? = nil,
        note: String = ""
    ) -> String {
        if let error = result.error { return envelope(error: error) }
        let effective = body ?? result.body
        var payload: [String: Any] = [
            "status": result.status,
            "headers": result.headers,
            "body": String(data: effective, encoding: .utf8) ?? "",
            "url": url ?? result.finalURL ?? "",
        ]
        if !note.isEmpty { payload["note"] = note }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return envelope(error: "could not encode the response")
        }
        return text
    }

    /// The JSON envelope the native `fetch` half returns.
    private static func envelope(error: String) -> String {
        let escaped = error
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "{\"error\":\"\(escaped)\",\"status\":0,\"headers\":{},\"body\":\"\"}"
    }

    /// Turns one `push({...})` argument into a request.
    ///
    /// The shape is the one every built-in service produces, so a script
    /// describes exactly what a service would have built.
    /// The request a script's `push()` describes.
    ///
    /// Two shapes, because there are two kinds of delivery: a URL to send to, and a
    /// Shortcut to run. `shortcut` is checked first, and requires a `payload` — the
    /// Shortcut's input is exactly that object, serialized as it stands. Nothing
    /// else in the call is passed along, so what the Shortcut receives is what the
    /// script wrote and nothing it did not.
    private static func makeRequest(from object: [String: Any]) -> PushRequest? {
        if let name = object["shortcut"] as? String,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let input = object["payload"] as? [String: Any] else { return nil }

            guard let data = try? JSONSerialization.data(withJSONObject: input),
                  let json = String(data: data, encoding: .utf8)
            else { return nil }

            let request = PushRequest(urlString: "", infoDict: [:])
            request.state[ShortcutState.shortcutName] =
                name.trimmingCharacters(in: .whitespacesAndNewlines)
            request.state[ShortcutState.input] = json
            request.logInfoDict = input
            return request
        }

        guard let url = object["url"] as? String, !url.isEmpty else { return nil }

        var headers: [String: String] = [:]
        for (field, value) in (object["headers"] as? [String: Any]) ?? [:] {
            headers[field] = value as? String ?? String(describing: value)
        }

        let method = (object["method"] as? String) ?? "POST"
        let body = (object["body"] as? [String: Any]) ?? [:]
        let request = PushRequest(
            urlString: url, headers: headers, infoDict: body, method: method
        )
        // The request body is the script's own object, so it is a different
        // object than the caller's `PushRequest`, not a stringified copy.
        request.bodyType = "json"
        request.logInfoDict = body
        return request
    }
}

// MARK: - Shared context

/// Owns the context used when runs share one.
///
/// The context is created on a dedicated thread and every run is dispatched
/// there, which is the only way a shared context can be used at all: it may only
/// be touched by the thread that made it. The thread runs a run loop so it can
/// wait idly between notifications.
private final class ScriptHost {
    private let lock = NSLock()
    private var thread: Thread?
    private var context: JSContext?
    private var ready = DispatchSemaphore(value: 0)

    /// Runs one script, waiting for the host thread.
    func run(
        script: String,
        bullet: [String: Any],
        storage: [String: String],
        options: JavaScriptRunner.Options,
        prefs: [String: Any],
        device: [String: Any],
        fetch: @escaping (URLRequest) -> JavaScriptRunner.FetchResult,
        deliver: JavaScriptRunner.Deliver? = nil
    ) -> JavaScriptRunner.Outcome {
        startThreadIfNeeded()

        let box = Box()
        lock.lock()
        box.work = { [context] in
            guard let context else { return }
            box.outcome = JavaScriptRunner.evaluate(
                script: script, in: context, bullet: bullet, storage: storage,
                options: options, prefs: prefs, device: device,
                fetch: fetch, deliver: deliver
            )
        }
        lock.unlock()

        // The host thread picks the work up from here; waiting is what makes the
        // caller's view synchronous, and the timeout is what stops a runaway
        // script from holding the caller forever.
        //
        // A *queue*, not a slot. Two notifications arriving at once — which is
        // ordinary when a page of them lands together — would otherwise have the
        // second overwrite the first, and the first caller would wait out its
        // whole timeout on work nobody was going to run.
        box.finished = DispatchSemaphore(value: 0)
        lock.lock()
        pending.append(box)
        lock.unlock()
        // Told, not waited for: the host is asleep until this arrives.
        wake.signal()

        let deadline = options.timeout > 0 ? options.timeout : 30
        guard box.finished.wait(timeout: .now() + deadline) == .success else {
            return JavaScriptRunner.Outcome(
                requests: [], consoleOutput: [], storage: storage,
                failure: .timedOut(options.timeout), trace: []
            )
        }
        return box.outcome ?? JavaScriptRunner.Outcome(
            requests: [], consoleOutput: [], storage: storage,
            failure: .script("Script produced no result"), trace: []
        )
    }

    /// One unit of work and the place its result goes.
    private final class Box: @unchecked Sendable {
        var work: (() -> Void)?
        var outcome: JavaScriptRunner.Outcome?
        var finished = DispatchSemaphore(value: 0)
    }

    private var pending: [Box] = []

    /// Wakes the host thread when work arrives.
    ///
    /// The thread used to run its run loop with a 20 ms deadline in a loop, which
    /// woke it fifty times a second for as long as SpringBoard ran — a device that
    /// never reaches deep sleep, and nothing in a profile that says why. It waits
    /// on this instead, with no deadline at all, and is signalled when there is
    /// something to do.
    private let wake = DispatchSemaphore(value: 0)

    private func startThreadIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard thread == nil else { return }

        let host = Thread { [weak self] in
            guard let self else { return }
            // Created here, on the thread that will own it. A run loop is still
            // needed — the JS engine schedules work on the current thread's — but
            // nothing polls it.
            self.context = JSContext()
            self.ready.signal()

            while true {
                // No deadline: asleep until there is work, and the thread does
                // not wake up at all while the device is idle.
                self.wake.wait()
                self.drainPending()
            }
        }
        host.stackSize = 1 << 20
        host.name = "PusherJavaScript"
        thread = host
        host.start()
        ready.wait()
    }

    private func drainPending() {
        lock.lock()
        let work = pending
        pending.removeAll()
        lock.unlock()

        // In arrival order: a shared context is sequential by nature, so the
        // order the runs were requested is the order they should see state.
        for box in work {
            box.work?()
            box.finished.signal()
        }
    }
}
