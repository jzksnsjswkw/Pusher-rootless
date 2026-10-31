import Foundation

/// The kind of service a user's script defines.
///
/// A script is a *type*, not a destination: the user writes one (see
/// ``CustomServiceDefinition``) and it then behaves like any built-in service —
/// addable, enabled, orderable, with its own app list and log, and addable more
/// than once. Each instance keeps its own settings and its own `localStorage`,
/// while the script itself lives on the definition, so editing it takes effect
/// for every service using it.
///
/// The script receives the notification as `bullet` and decides what to send by
/// calling `push(req)`. Not calling `push` skips that notification, so a script
/// can filter as well as forward — and, because it can also `await fetch(...)`,
/// it can obtain a credential first (an access token, say) the way the built-in
/// Wechat service does.
///
/// ## Why there is no `request(context:config:)`
///
/// That method is synchronous and returns one request. A script may send none,
/// one, or several, and may need to do network work to decide, so this service
/// overrides the asynchronous entry point and runs the script on a background
/// queue.
public enum JavaScriptService: PushService {
    /// The registry name. Instances carry their own names; this identifies the
    /// kind.
    public static let serviceName = "JavaScript"

    public static var supportsIcon: Bool { true }
    public static var supportsImage: Bool { true }


    /// No endpoint can be derived, so overrides never differ by URL.
    public static func url(eventName: String, dbName: String, serverURL: String) -> String {
        ""
    }

    /// Reached only if the asynchronous path is bypassed; a script has to run to
    /// produce anything, so there is nothing to return here.
    public static func request(context: BulletinContext, config: ServiceConfig) throws -> PushRequest? {
        nil
    }

    public static func request(
        context: BulletinContext,
        config: ServiceConfig,
        completion: @escaping (Result<PushRequest, Error>) -> Void
    ) {
        // The script belongs to the definition, so it is read at send time: an
        // edit then applies to every service already using it.
        let script = CustomServiceStore.definition(id: config.type)?
            .script.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !script.isEmpty else {
            PushLog.add(service: config.name, context: context,
                        label: "Script is empty or its service was deleted")
            completion(.failure(RequestError.missingField("Script")))
            return
        }

        // `push()` sends for real as the script runs, so the script gets a
        // response back: the status is what tells it whether to carry on, and it
        // is the same object `fetch` resolves to. The send happens on this run's
        // own thread, which is a background one — never SpringBoard's main thread.
        let service = config.name
        let outcome = JavaScriptRunner.run(
            script: script,
            bullet: payload(context: context, config: config),
            storage: storedValues(config: config),
            options: options(config: config),
            // `pref`: the values this service declared and this instance filled
            // in. An empty object when the service declares nothing, so a script
            // can read `pref.anything` safely either way.
            prefs: ConfigFields.values(forInstance: config.name, type: config.type),
            // The same object a hook sees, captured on the main thread before this
            // background run starts: `push()` can block for seconds, and a battery
            // level read after that would describe the device at the wrong moment.
            device: BulletinAdapter.deviceStateForHooks().scriptValue,
            fetch: ScriptHTTP.perform,
            deliver: { request in
                // The request goes through the ordinary send, so it gets the
                // ordinary treatment: the same log lines, the same retry budget,
                // the same image shrinking on a 413. What changes is only that
                // someone asks for the answer.
                //
                // One attempt is one `push()`. The sender reports its *final*
                // outcome — after any retries — which is what the script needs to
                // decide whether to push again.
                let done = DispatchSemaphore(value: 0)
                let box = OutcomeBox()
                // `send` grants a fresh retry budget itself, which is what makes a
                // second `push()` independent of the first one's retries.
                request.completion = { result in
                    box.result = result
                    done.signal()
                }
                RequestSender.shared.send(
                    request,
                    logString: "[S:\(service),A:\(context.appName)]",
                    service: service,
                    context: context
                )
                // The wait is bounded by the retry budget: five attempts with the
                // sender's delay between them, plus each attempt's own timeout.
                let budget = Double(Pusher.tries) * (Self.attemptTimeout + Pusher.delayBetweenRetries)
                _ = done.wait(timeout: .now() + budget)
                return box.result ?? JavaScriptRunner.FetchResult(
                    status: 0, error: "push() timed out before the request finished"
                )
            }
        )

        // The pipeline keeps console output out of the log: a script may print
        // per notification, and a chatty one would fill the log unbounded. The
        // editor's Run shows it instead; failures are still logged here.
        persist(storage: outcome.storage, context: context, config: config)

        if let failure = outcome.failure {
            PushLog.add(service: config.name, context: context,
                        label: "Script failed", object: failure.message, dontTruncate: true)
            completion(.failure(RequestError.invalidField("Script", reason: failure.message)))
            return
        }

        // Every `push()` has already gone through the transport by the time the
        // script finishes — its logging, its retries and its loop-window entry
        // included. Nothing is left to deliver.
        //
        // This reports "handled" rather than "declined": the script did its job,
        // and the only thing the engine must not do is send the same requests
        // again. `.failure` would read as "this instance had nothing to send",
        // which is the opposite of what happened.
        if outcome.requests.isEmpty {
            PushLog.add(service: config.name, context: context, label: "Script sent nothing")
            completion(.failure(ScriptDeclined()))
            return
        }
        completion(.failure(RequestHandled()))
    }

    /// The script sent its own requests; the pipeline must not send them again.
    ///
    /// A failure by type because the return position is "no request for you", but
    /// it is not an error: the caller checks for this and stays quiet.
    struct RequestHandled: LocalizedError {
        var errorDescription: String? { "Sent by the script" }
    }

    /// How long one HTTP attempt may take before `push()` gives up waiting.
    ///
    /// Longer than the sender's own request timeout so its failure is the one
    /// reported, rather than a generic "timed out" from here.
    private static let attemptTimeout: TimeInterval = 15

    /// Carries the sender's answer back across the wait.
    private final class OutcomeBox: @unchecked Sendable {
        var result: JavaScriptRunner.FetchResult?
    }

    /// A script that chose not to push. Not a failure, and reported separately so
    /// the log does not call it one.
    struct ScriptDeclined: LocalizedError {
        var errorDescription: String? { "Script sent nothing" }
    }

    // MARK: - The `bullet` object

    /// The notification as the script sees it.
    ///
    /// The keys are the ones every service's payload carries (`baseInfoDict`),
    /// so a script and a built-in service describe the same notification with
    /// the same words.
    static func payload(context: BulletinContext, config: ServiceConfig) -> [String: Any] {
        let data = baseInfoDict(context: context, config: config)

        // `baseInfoDict` writes `icon` and `image` only when the instance asked
        // for them, which leaves them *absent*. A script reading an absent
        // property already gets `undefined`, so this changes nothing — except in
        // the one case it does: `baseInfoDict` sets `image` to `true` to say "there
        // was an attachment but it could not be decoded", and a script doing
        // `if (bullet.image)` would then take a boolean for the base64 string it
        // expects and send `true` to the endpoint.
        //
        // So both fields are stated explicitly: the value when there is one, and
        // `undefined` when the option is off. What the script reads is then what
        // the guide says, which is the property that matters — the declaration is
        // the contract.
        var fields = data
        fields["icon"] = shouldIncludeIcon(config: config) ? (data["icon"] ?? nil) : nil
        fields["image"] = shouldIncludeImage(config: config)
            ? (data["image"] as? String ?? nil)
            : nil

        // The remaining fields are set here rather than in `baseInfoDict` because
        // they are the *script's* view rather than a payload's: `deviceName` is
        // already there, and these are the same values under their own names.
        fields["appID"] = context.appID
        fields["appName"] = context.appName
        fields["title"] = context.title ?? ""
        fields["subtitle"] = context.subtitle ?? ""
        fields["message"] = context.message ?? ""
        fields["date"] = dateString(context.date, config: config)
        return fields
    }

    // MARK: - Settings

    /// How the instance's advanced settings ask for the script to be run.
    static func options(config: ServiceConfig) -> JavaScriptRunner.Options {
        let raw = config.raw
        let timeout = raw.double(PrefKey.scriptTimeout)
        // Stored in MB (the unit the page shows); zero means the default.
        let maximumMB = raw.double(PrefKey.scriptMaxResponseBytes)
        return JavaScriptRunner.Options(
            sharingContext: raw.bool(PrefKey.scriptShareContext),
            sharingThread: raw.bool(PrefKey.scriptShareThread),
            timeout: timeout > 0 ? timeout : Pusher.defaultScriptTimeout,
            maximumResponseBytes: maximumMB > 0
                ? Int(maximumMB * 1024 * 1024)
                : Pusher.defaultMaxResponseBytes
        )
    }

    /// The values the script left in `localStorage` last time.
    ///
    /// Stored on the instance, so two script services never share a store unless
    /// the user moves the value themselves.
    static func storedValues(config: ServiceConfig) -> [String: String] {
        guard let stored = config.raw.dict(PrefKey.scriptStorage) else { return [:] }
        return stored.raw.compactMapValues { $0 as? String }
    }

    /// Writes the script's `localStorage` back onto its instance.
    ///
    /// Only written when it changed, since this runs on every notification and
    /// the store is usually untouched.
    static func persist(storage: [String: String], context: BulletinContext, config: ServiceConfig) {
        guard storage != storedValues(config: config) else { return }
        PrefsStore.updateInstance(config.name) { object in
            object[PrefKey.scriptStorage] = storage
        }
    }

    // MARK: - What an instance stores

    public static func defaultPrefs() -> [String: Any] {
        [
            // No script here: it lives on the definition. What an *instance*
            // stores is its own storage and the options below.
            PrefKey.scriptStorage: [String: String](),
            // Advanced options, with the defaults the runner documents.
            PrefKey.scriptShareContext: false,
            PrefKey.scriptShareThread: false,
            PrefKey.scriptTimeout: Pusher.defaultScriptTimeout,
            PrefKey.scriptMaxResponseBytes: Pusher.defaultMaxResponseBytes,
            // The notification's own fields, as every service offers them.
            PrefKey.includeIcon: true,
            PrefKey.includeImage: true,
            PrefKey.imageMaxWidth: Pusher.defaultMaxWidth,
            PrefKey.imageMaxHeight: Pusher.defaultMaxHeight,
            PrefKey.imageShrinkFactor: Pusher.defaultShrinkFactor,
            PrefKey.dateFormat: "MMM d, h:mm a",
        ]
    }

    public static func defaultCustomAppPrefs() -> [String: Any] {
        [
            PrefKey.includeIcon: true,
            PrefKey.includeImage: true,
            PrefKey.imageMaxWidth: Pusher.defaultMaxWidth,
            PrefKey.imageMaxHeight: Pusher.defaultMaxHeight,
            PrefKey.imageShrinkFactor: Pusher.defaultShrinkFactor,
        ]
    }

    public static func shouldIncludeIcon(config: ServiceConfig) -> Bool {
        config.raw.bool(PrefKey.includeIcon, default: true)
    }

    public static func shouldIncludeImage(config: ServiceConfig) -> Bool {
        config.raw.bool(PrefKey.includeImage, default: true)
    }
}
