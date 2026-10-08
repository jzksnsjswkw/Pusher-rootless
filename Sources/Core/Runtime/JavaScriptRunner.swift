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
        /// The requests the script asked for, in the order it asked for them.
        public let requests: [PushRequest]
        /// Everything the script printed through `console`.
        public let consoleOutput: [String]
        /// Values the script left in `localStorage`, for the caller to persist.
        public let storage: [String: String]
        /// The failure, when the run did not finish.
        public let failure: Failure?

        /// Whether the script chose not to forward this notification.
        public var isSkipped: Bool { failure == nil && requests.isEmpty }
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
        fetch: @escaping (URLRequest) -> FetchResult
    ) -> Outcome {
        // A shared context lives on one thread; a private context may go
        // anywhere. Either way the work happens off the main thread, which is
        // what the caller's queue provides.
        guard options.usesOwnContext else {
            return host.run(
                script: script, bullet: bullet, storage: storage,
                options: options, fetch: fetch
            )
        }

        guard options.usesOwnThread, options.timeout > 0 else {
            return evaluate(
                script: script, bullet: bullet, storage: storage,
                options: options, fetch: fetch
            )
        }

        // The result travels through a box: an abandoned run may still be using
        // the thread, so nothing local may be written after the wait gives up.
        let box = ResultBox()
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value = evaluate(
                script: script, bullet: bullet, storage: storage,
                options: options, fetch: fetch
            )
            finished.signal()
        }
        thread.stackSize = 1 << 20
        thread.start()

        guard finished.wait(timeout: .now() + options.timeout) == .success else {
            return Outcome(requests: [], consoleOutput: [], storage: storage,
                           failure: .timedOut(options.timeout))
        }
        return box.value ?? Outcome(requests: [], consoleOutput: [], storage: storage,
                                    failure: .script("Script produced no result"))
    }

    /// The one host used for shared-context runs.
    private static let host = ScriptHost()

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
        fetch: @escaping (URLRequest) -> FetchResult
    ) -> Outcome {
        guard let context = JSContext() else {
            return Outcome(requests: [], consoleOutput: [], storage: storage,
                           failure: .script("Could not create a JavaScript context"))
        }
        return evaluate(
            script: script, in: context, bullet: bullet, storage: storage,
            options: options, fetch: fetch
        )
    }

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
        fetch: @escaping (URLRequest) -> FetchResult
    ) -> Outcome {
        var requests: [PushRequest] = []
        var consoleOutput: [String] = []
        var store = storage
        var failure: Failure?

        // A syntax error arrives here as well as a thrown exception, so this is
        // the single place a failure is observed.
        context.exceptionHandler = { _, exception in
            failure = .script(describe(exception))
        }

        installConsole(into: context) { consoleOutput.append($0) }

        // `push(req)`: the only way a script sends anything.
        let push: @convention(block) (JSValue?) -> Bool = { value in
            guard let object = value?.toObject() as? [String: Any] else {
                consoleOutput.append("push() expects an object")
                return false
            }
            guard let request = makeRequest(from: object) else {
                consoleOutput.append("push() needs a url")
                return false
            }
            requests.append(request)
            return true
        }
        context.setObject(push, forKeyedSubscript: "push" as NSString)

        // The store is captured by the four accessors below, all of which see
        // the same dictionary, and `store` is what the outcome carries back out.
        installStorage(
            into: context,
            read: { store[$0] },
            write: { store[$0] = $1 },
            remove: { store.removeValue(forKey: $0) },
            clear: { store.removeAll() },
            count: { Int32(store.count) }
        )
        installFetch(into: context, options: options, perform: fetch)
        installFetchObserver(into: context)

        // The notification, marked non-writable so a script cannot replace it and
        // read stale fields back out of its own copy.
        context.setObject(bullet, forKeyedSubscript: "__bullet" as NSString)
        _ = context.evaluateScript(
            "Object.defineProperty(globalThis, 'bullet', "
                + "{ value: __bullet, writable: false, configurable: false });"
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

        let wrapped = """
        (async function () {
        \(script)
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
            requests: requests, consoleOutput: consoleOutput, storage: store, failure: failure
        )
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
            append(arguments.map { render($0) }.joined(separator: " "))
        }

        let console = JSValue(newObjectIn: context)
        for name in ["log", "info", "warn", "error", "debug", "trace"] {
            console?.setObject(sink, forKeyedSubscript: name as NSString)
        }
        context.setObject(console, forKeyedSubscript: "console" as NSString)
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

            var payload: [String: Any] = [
                "status": result.status,
                "headers": result.headers,
                "body": String(data: body, encoding: .utf8) ?? "",
                "url": result.finalURL ?? urlString,
            ]
            if !note.isEmpty { payload["note"] = note }
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let text = String(data: data, encoding: .utf8) else {
                return envelope(error: "fetch: could not encode the response")
            }
            return text
        }
        context.setObject(native, forKeyedSubscript: "__fetchNative" as NSString)

        // The specification's face: a promise resolving to a Response with
        // `ok` / `status` / `headers` / `url`, and `text()` / `json()` that
        // themselves return promises.
        _ = context.evaluateScript("""
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
                if (data.error) { reject(new TypeError(data.error)); return; }
                if (data.note) { console.warn(data.note); }

                var lower = {};
                Object.keys(data.headers || {}).forEach(function (key) {
                    lower[String(key).toLowerCase()] = String(data.headers[key]);
                });

                resolve({
                    ok: data.status >= 200 && data.status < 300,
                    status: data.status,
                    statusText: '',
                    url: data.url,
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
                    text: function () { return Promise.resolve(data.body); },
                    json: function () { return Promise.resolve(JSON.parse(data.body)); }
                });
            });
        };
        """)
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
    private static func makeRequest(from object: [String: Any]) -> PushRequest? {
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
        fetch: @escaping (URLRequest) -> JavaScriptRunner.FetchResult
    ) -> JavaScriptRunner.Outcome {
        startThreadIfNeeded()

        let box = Box()
        lock.lock()
        box.work = { [context] in
            guard let context else { return }
            box.outcome = JavaScriptRunner.evaluate(
                script: script, in: context, bullet: bullet, storage: storage,
                options: options, fetch: fetch
            )
        }
        lock.unlock()

        // The host thread picks the work up from here; waiting is what makes the
        // caller's view synchronous, and the timeout is what stops a runaway
        // script from holding the caller forever.
        box.finished = DispatchSemaphore(value: 0)
        lock.lock()
        pending = box
        lock.unlock()

        let deadline = options.timeout > 0 ? options.timeout : 30
        guard box.finished.wait(timeout: .now() + deadline) == .success else {
            return JavaScriptRunner.Outcome(
                requests: [], consoleOutput: [], storage: storage,
                failure: .timedOut(options.timeout)
            )
        }
        return box.outcome ?? JavaScriptRunner.Outcome(
            requests: [], consoleOutput: [], storage: storage,
            failure: .script("Script produced no result")
        )
    }

    /// One unit of work and the place its result goes.
    private final class Box: @unchecked Sendable {
        var work: (() -> Void)?
        var outcome: JavaScriptRunner.Outcome?
        var finished = DispatchSemaphore(value: 0)
    }

    private var pending: Box?

    private func startThreadIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard thread == nil else { return }

        let host = Thread { [weak self] in
            guard let self else { return }
            // Created here, on the thread that will own it.
            self.context = JSContext()
            self.ready.signal()

            let runLoop = RunLoop.current
            while !Thread.current.isCancelled {
                // A short sleep keeps the thread responsive without spinning.
                runLoop.run(mode: .default, before: Date().addingTimeInterval(0.02))
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
        let box = pending
        pending = nil
        lock.unlock()

        guard let box else { return }
        box.work?()
        box.finished.signal()
    }
}
