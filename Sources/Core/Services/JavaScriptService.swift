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
    public static func request(context: BulletinContext, config: ServiceConfig) -> PushRequest? {
        nil
    }

    public static func request(
        context: BulletinContext,
        config: ServiceConfig,
        completion: @escaping (PushRequest?) -> Void
    ) {
        // The script belongs to the definition, so it is read at send time: an
        // edit then applies to every service already using it.
        let script = CustomServiceStore.definition(id: config.type)?
            .script.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !script.isEmpty else {
            PushLog.add(service: config.name, context: context,
                        label: "Script is empty or its service was deleted")
            completion(nil)
            return
        }

        let outcome = JavaScriptRunner.run(
            script: script,
            bullet: payload(context: context, config: config),
            storage: storedValues(config: config),
            options: options(config: config),
            // `pref`: the values this service declared and this instance filled
            // in. An empty object when the service declares nothing, so a script
            // can read `pref.anything` safely either way.
            prefs: ConfigFields.values(forInstance: config.name, type: config.type),
            fetch: ScriptHTTP.perform
        )

        // The pipeline keeps console output out of the log: a script may print
        // per notification, and a chatty one would fill the log unbounded. The
        // editor's Run shows it instead; failures are still logged here.
        persist(storage: outcome.storage, context: context, config: config)

        if let failure = outcome.failure {
            PushLog.add(service: config.name, context: context,
                        label: "Script failed", object: failure.message, dontTruncate: true)
            completion(nil)
            return
        }

        guard !outcome.requests.isEmpty else {
            // Not an error: a script that sends nothing is how it declines.
            PushLog.add(service: config.name, context: context, label: "Script sent nothing")
            completion(nil)
            return
        }

        // A script may ask for more than one request; the sender sends one, so
        // the extras are handed to it in order through the resend chain, which
        // already carries a retry budget and per-attempt logging.
        completion(chaining(outcome.requests, startingAt: 0, service: config.name, context: context))
    }

    // MARK: - Chaining several requests

    /// Wraps `requests[start]` so that a successful send continues with the next.
    ///
    /// The sender is built to send a single request with retries, so the second
    /// and later requests ride the existing resend mechanism: the handler is
    /// called after a response arrives and returns the next request instead of a
    /// retry. Nothing new is needed in the transport, and each step is logged by
    /// the sender as it goes.
    static func chaining(
        _ requests: [PushRequest],
        startingAt index: Int,
        service: String,
        context: BulletinContext
    ) -> PushRequest {
        let request = requests[index]
        guard index + 1 < requests.count else { return request }

        request.resendHandler = { _, _, _, _, completion in
            let next = chaining(requests, startingAt: index + 1, service: service, context: context)
            // `shouldFail: false` with a request means "send this instead",
            // which is how the next request in the script's sequence goes out.
            completion(next, false)
        }
        return request
    }

    // MARK: - The `bullet` object

    /// The notification as the script sees it.
    ///
    /// The keys are the ones every service's payload carries (`baseInfoDict`),
    /// so a script and a built-in service describe the same notification with
    /// the same words.
    static func payload(context: BulletinContext, config: ServiceConfig) -> [String: Any] {
        var data = baseInfoDict(context: context, config: config)

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
