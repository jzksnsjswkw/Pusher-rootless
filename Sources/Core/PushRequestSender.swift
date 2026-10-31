import Foundation
import UIKit

/// Sends a fully-built ``PushRequest`` and owns the per-bulletin retry budget.
///
/// The service has already decided the URL, headers, body and method; this type
/// only transports the request, retries what is worth retrying, and writes the
/// attempt to the log. It needs the bulletin identity for the retry key and the
/// log — carried by the plain ``BulletinContext`` value type, so the transport
/// layer does not depend on `BBBulletin`.
public final class RequestSender {
    public static let shared = RequestSender()

    /// Remaining attempts per bulletin+service, keyed by ``RetryKey``.
    private var retriesLeft: [String: Int] = [:]
    /// Guards ``retriesLeft``, which is read and written from both the main
    /// thread and URLSession's background completion queues.
    private let lock = NSLock()

    private init() {}

    /// Sends a request, starting a fresh retry budget for the bulletin.
    public func send(
        _ request: PushRequest,
        logString: String,
        service: String,
        context: BulletinContext
    ) {
        setRetriesLeft(Pusher.tries - 1, for: retryKey(context, service))

        // Every send passes through here — a service's single request, a script's
        // fifth `push()`, the editor's test run — so this is where a forwarded
        // notification enters the loop window. Counting at the call site instead
        // meant anything that bypassed that call site went uncounted, which is
        // exactly what a script's `push()` used to do.
        //
        // The guard dedupes by bulletin id, so a notification fanned out to three
        // instances is still one entry, and it ignores test pushes itself.
        LoopGuard.shared.recordForwarded(context)

        // An exception out of this block would leave the send queue and reach
        // SpringBoard, which takes the whole process down — a service that
        // cannot encode its payload must fail like any other send failure, not
        // by crashing the shell. `NSJSONSerialization` is the realistic source:
        // it throws on a value it cannot write, and a payload is assembled from
        // whatever a service decided to put in it.
        PusherTrap.run {
            self.sendAttempt(request, logString: logString, service: service, context: context)
        }
    }

    // MARK: - Retry bookkeeping

    private func retryKey(_ context: BulletinContext, _ service: String) -> String {
        "\(context.bulletinID)_\(context.appID)_\(service)"
    }

    private func setRetriesLeft(_ count: Int?, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        if let count {
            retriesLeft[key] = count
        } else {
            retriesLeft.removeValue(forKey: key)
        }
    }

    /// Atomically claims one retry, returning the remaining count, or `-1` when
    /// there was none left to claim.
    private func claimRetry(for key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let current = retriesLeft[key], current > 0 else { return -1 }
        let remaining = current - 1
        retriesLeft[key] = remaining
        return remaining
    }

    private func hasRetriesLeft(for key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (retriesLeft[key] ?? 0) > 0
    }

    // MARK: - Email delivery

    /// Talks SMTP. Never retried, and that is deliberate: `MAIL FROM` and `RCPT TO`
    /// are idempotent, but the message body is not — a failure in the middle of
    /// `DATA` may or may not have been accepted, and resending risks a duplicate in
    /// the mailbox with no way to tell. Reporting the failure once is honest; the
    /// alternative is silently sending twice.
    private func sendEmail(
        _ message: SMTPClient.Message,
        request: PushRequest,
        logString: String,
        service: String,
        context: BulletinContext
    ) {
        // The whole message, in the same shape the HTTP services log their request
        // bodies: a user diagnosing a send needs to see what was actually written,
        // not just that a connection was made.
        PushLog.add(service: service, context: context, label: "Request Body Dictionary", object: [
            "host": message.host,
            "port": message.port,
            "from": message.from,
            "to": message.recipients,
            "subject": message.subject,
            "body": message.body,
        ], tag: request.sequenceTag)
        SMTPClient.send(message) { result in
            switch result {
            case .success:
                PushLog.add(service: service, context: context, label: "Sent", tag: request.sequenceTag)
                self.finish(request, status: 200)
            case .failure(let failure):
                PushLog.add(service: service, context: context, label: failure.label, tag: request.sequenceTag)
                self.finish(request, status: 0, error: failure.label)
            }
        }
    }

    // MARK: - Shortcut delivery

    /// Runs a Shortcut instead of performing an HTTP request.
    ///
    /// Retries are deliberately not offered. A failed HTTP request can be
    /// repeated safely because the server saw nothing; a Shortcut that ran part
    /// way through and then failed would, on a retry, run its actions twice —
    /// and its actions can be anything, including sending a message. Reporting
    /// the failure once is the honest thing to do.
    private func sendShortcut(
        named name: String,
        input: String,
        request: PushRequest,
        logString: String,
        service: String,
        context: BulletinContext
    ) {
        PushLog.add(service: service, context: context, label: "Shortcut", object: name, tag: request.sequenceTag)
        PusherLog.debug("\(logString) Running shortcut \"\(name)\"")

        let error = ShortcutRunner.run(name: name, input: input)
        if let error {
            PusherLog.info("[S:\(service)] Shortcut \"\(name)\" failed: \(error)")
            PushLog.add(service: service, context: context,
                        label: "Shortcut failed", object: error, tag: request.sequenceTag)
            finish(request, status: 0, error: error)
        } else {
            PusherLog.debug("\(logString) Shortcut \"\(name)\" started")
            PushLog.add(service: service, context: context, label: "Shortcut started", tag: request.sequenceTag)
            finish(request, status: 200)
        }
    }

    // MARK: - One attempt (HTTP)

    private func sendAttempt(
        _ request: PushRequest,
        logString: String,
        service: String,
        context: BulletinContext
    ) {
        // A shortcut run is not a fetch: it has no URL, no body and no HTTP
        // status. Sending it down the URLSession path would report a bogus
        // "invalid URL" failure, so it is diverted before any of that begins.
        // An email is not a fetch either: it opens an SMTP connection, which is a
        // conversation rather than one request and response. Same diversion as a
        // shortcut, for the same reason — the URLSession path has nothing to do
        // with it and would report a bogus "invalid URL".
        if let message = request.state[EmailState.message] as? SMTPClient.Message {
            sendEmail(message, request: request, logString: logString,
                      service: service, context: context)
            return
        }

        if let shortcutName = request.state[ShortcutState.shortcutName] as? String {
            sendShortcut(
                named: shortcutName,
                input: request.state[ShortcutState.input] as? String ?? "",
                request: request,
                logString: logString,
                service: service,
                context: context
            )
            return
        }

        var body = request.infoDict
        body.removeValue(forKey: "imageShrinkFactor")

        // A UIImage in the body is encoded here rather than by the service, so
        // the retry paths can substitute a scaled image and re-encode.
        if let image = body["image"] as? UIImage {
            body["image"] = PushImage.base64(image) as Any
        }

        let httpMethod = request.method
        let isBodyless = httpMethod.caseInsensitiveCompare("GET") == .orderedSame
            || httpMethod.caseInsensitiveCompare("HEAD") == .orderedSame

        var urlString = request.urlString
        if isBodyless {
            // A GET has nowhere to put a body, so the payload becomes the query
            // string. No length is imposed here: what a server accepts is the
            // server's business, and a real URL limit is far above anything a
            // notification carries. When one does refuse, the response says so and
            // the ordinary 413 path shrinks the image and tries again — the same
            // answer every other oversized payload gets.
            //
            // NSURLComponents percent-encodes both names and values, preserves
            // any existing query string, and handles '?', '&' and '#' — all of
            // which manual concatenation gets wrong.
            if let components = URLComponents(string: urlString) {
                var items = components.queryItems ?? []
                for key in body.keys.sorted() {
                    items.append(URLQueryItem(name: key, value: Self.stringValue(body[key])))
                }
                var updated = components
                updated.queryItems = items
                urlString = updated.string ?? urlString
            }
            PusherLog.debug("URL String: \(urlString)")
        }

        urlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        // The log is written to a plist the user can read, copy and paste into a
        // bug report. A token in a URL query is the usual way a service
        // authenticates — Gotify, ServerChan, WeCom all put the credential there —
        // so the URL is logged with its values masked, while the request itself
        // keeps the real one.
        // Logged verbatim. Masking the credential here would also hide the one
        // thing that explains a 401 — which key was actually sent — and the log is
        // a local file the user already controls. The path/query masking helpers
        // are kept for a future opt-in, but the default is to write what was sent.
        PushLog.add(service: service, context: context, label: "URL",
                    object: urlString, tag: request.sequenceTag)

        guard let url = URL(string: urlString) else {
            PusherLog.debug("Invalid URL: \(urlString)")
            PushLog.add(service: service, context: context, label: "Invalid URL", tag: request.sequenceTag)
            // Clear the retry key so a bad URL doesn't leak an entry in the
            // long-running SpringBoard process.
            setRetriesLeft(nil, for: retryKey(context, service))
            finish(request, status: 0, error: "invalid URL")
            return
        }

        // Credentials written into the URL — `https://user:pass@host/path` — are
        // turned into a Basic authorization header, and stripped from the URL:
        // a URL carrying credentials is logged by every proxy it passes through,
        // and `URL` keeps them where a request would send them twice.
        //
        // Accepted rather than offered as a field because it is what people type.
        // The custom webhook service takes a key in a header or the body; a
        // server that wants Basic auth has nowhere to put it otherwise.
        var sanitized = url
        var basicAuth: String?
        if let user = url.user, let password = url.password {
            basicAuth = Data("\(user):\(password)".utf8).base64EncodedString()
            if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                components.user = nil
                components.password = nil
                sanitized = components.url ?? url
            }
        }

        var urlRequest = URLRequest(
            url: sanitized, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 10
        )
        if let basicAuth {
            urlRequest.setValue("Basic \(basicAuth)", forHTTPHeaderField: "Authorization")
            // Logged as a name, never the value: the whole point of moving it off
            // the URL is that it stops being written down.
            PushLog.add(service: service, context: context, label: "Header",
                        object: "Authorization: Basic ***", tag: request.sequenceTag)
        }
        PushLog.add(service: service, context: context, label: "Method", object: httpMethod, tag: request.sequenceTag)
        urlRequest.httpMethod = httpMethod

        for name in request.headers.keys.sorted() {
            let value = request.headers[name] ?? ""
            urlRequest.setValue(value, forHTTPHeaderField: name)
            PushLog.add(service: service, context: context, label: "Header",
                        object: "\(name): \(value)", tag: request.sequenceTag)
        }

        if !isBodyless {
            // Services provide a sanitized body via logInfoDict; the sender
            // only logs what it was given and never rewrites the real body.
            PushLog.add(service: service, context: context, label: "Request Body Dictionary",
                        object: request.logInfoDict ?? body, tag: request.sequenceTag)
            urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

            let payload: Data?
            if request.bodyType.caseInsensitiveCompare("form") == .orderedSame {
                payload = Self.formEncoded(body).data(using: .utf8)
                urlRequest.setValue(formContentType, forHTTPHeaderField: "Content-Type")
            } else {
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                do {
                    // Compact, not pretty-printed: the whitespace is for a
                    // reader and the reader here is a server. It is also a few
                    // bytes per field on every push.
                    payload = try JSONSerialization.data(withJSONObject: body)
                } catch {
                    PusherLog.debug("\(logString) JSON serialization failed: \(error)")
                    PushLog.add(service: service, context: context,
                                label: "JSON Serialization Error",
                                object: error.localizedDescription, dontTruncate: true, tag: request.sequenceTag)
                    setRetriesLeft(nil, for: retryKey(context, service))
                    finish(request, status: 0, error: "could not encode the body")
                    return
                }
            }
            if let payload {
                urlRequest.setValue(String(payload.count), forHTTPHeaderField: "Content-Length")
                urlRequest.httpBody = payload
            }
        }

        URLSession.shared.dataTask(with: urlRequest) { [weak self] data, response, error in
            guard let self else { return }
            PusherLog.debug("\(logString) Got response back")
            let key = self.retryKey(context, service)

            // A service's own handler only runs when the transport said the request
            // succeeded. It is there to read a body — `errcode`, an "accepted"
            // flag — not to decide whether a 500 happened; leaving HTTP to the
            // sender keeps one place responsible for "is this a delivery", and
            // means a service's vocabulary cannot accidentally swallow a real
            // transport failure.
            let status = (response as? HTTPURLResponse)?.statusCode
            let transportOK = error == nil && (status.map { (200..<300).contains($0) } ?? true)
            guard let resendHandler = request.resendHandler, transportOK else {
                self.handleResponse(request, data: data, response: response, error: error,
                                    logString: logString, service: service, context: context)
                return
            }

            resendHandler(request, response, data, error) { decision in
                switch decision {
                case .retry(let newRequest):
                    let remaining = self.claimRetry(for: key)
                    guard remaining >= 0 else {
                        let reason = newRequest.failureReason ?? request.failureReason
                            ?? "Resend attempts exhausted"
                        PushLog.add(service: service, context: context,
                                    label: "Network Response: Failed after all resend attempts",
                                    object: reason, tag: request.sequenceTag)
                        PusherLog.debug("\(logString) Failed after all resend attempts: \(reason)")
                        self.setRetriesLeft(nil, for: key)
                        self.finish(request, status: 0, error: reason)
                        return
                    }
                    newRequest.resendHandler = newRequest.resendHandler ?? resendHandler
                    newRequest.resendCount = request.resendCount + 1
                    PusherLog.debug("\(logString) Resending via service callback (attempt \(newRequest.resendCount + 1))")
                    PushLog.add(service: service, context: context,
                                label: "----- Resending via service callback (attempt \(newRequest.resendCount + 1)) -----", tag: request.sequenceTag)
                    self.sendAttempt(newRequest, logString: logString, service: service, context: context)

                case .fail:
                    let reason = request.failureReason ?? "Resend handler marked request as failed"
                    PushLog.add(service: service, context: context,
                                label: "Network Response: Failed by resend handler",
                                object: reason, tag: request.sequenceTag)
                    PusherLog.debug("\(logString) Failed by resend handler: \(reason)")
                    self.setRetriesLeft(nil, for: key)
                    self.finish(request, status: 0, error: reason)

                case .finish:
                    self.handleResponse(request, data: data, response: response, error: error,
                                        logString: logString, service: service, context: context)
                }
            }
        }.resume()
    }

    // MARK: - Response handling

    /// Reports the final outcome to whoever asked for one.
    ///
    /// Called at every point where the sender stops working on a request, so a
    /// script awaiting `push()` is never left hanging — including the paths that
    /// give up on purpose.
    private func finish(
        _ request: PushRequest,
        status: Int,
        response: URLResponse? = nil,
        data: Data? = nil,
        error: String? = nil
    ) {
        guard let completion = request.completion else { return }
        var headers: [String: String] = [:]
        if let http = response as? HTTPURLResponse {
            for (field, value) in http.allHeaderFields {
                headers[String(describing: field).lowercased()] = String(describing: value)
            }
        }
        completion(JavaScriptRunner.FetchResult(
            status: status,
            headers: headers,
            body: data ?? Data(),
            finalURL: (response as? HTTPURLResponse)?.url?.absoluteString,
            error: error
        ))
        // Cleared so a retry that somehow reaches here twice cannot deliver two
        // answers for one push.
        request.completion = nil
    }

    private func handleResponse(
        _ request: PushRequest,
        data: Data?,
        response: URLResponse?,
        error: Error?,
        logString: String,
        service: String,
        context: BulletinContext
    ) {
        let key = retryKey(context, service)

        guard let error else {
            let dataString = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            // 200 is success. Everything else is a failure worth repeating — the
            // only reading of the response this layer makes.
            //
            // No other status is special-cased and the body is never parsed for an
            // error code: a service that reports "token expired" as HTTP 200 with
            // `{"errcode": 40014}` is ordinary, and its own `resendHandler` is
            // where that is understood. Guessing here would mean knowing every
            // service's vocabulary and getting it wrong for the next one.
            if status == 200 {
                PushLog.add(service: service, context: context,
                            label: "Network Response: Success", object: dataString, tag: request.sequenceTag)
                PusherLog.debug("\(logString) Success: \(dataString)")
                setRetriesLeft(nil, for: key)
                finish(request, status: status, response: response, data: data)
                return
            }

            PushLog.add(service: service, context: context,
                        label: "Network Response: HTTP \(status)",
                        object: dataString, dontTruncate: true, tag: request.sequenceTag)
            PusherLog.debug("\(logString) HTTP \(status): \(dataString)")
            retryAfterFailure(request, status: status, response: response, data: data,
                              logString: logString, service: service, context: context, key: key)
            return
        }
        PushLog.add(service: service, context: context,
                    label: "Network Response: Error",
                    object: error.localizedDescription, dontTruncate: true, tag: request.sequenceTag)
        PusherLog.debug("\(logString) Error: \(error)")

        retryAfterFailure(request, status: 0, response: response, data: data,
                          logString: logString, service: service, context: context, key: key,
                          failureText: error.localizedDescription)
    }

    /// One retry decision, for every kind of failure.
    ///
    /// Every failure is treated the same — transport error, 500, 401, 413 — because
    /// the sender cannot tell a permanent one from a passing one, and a service
    /// that can says so through its `resendHandler`. That distinction is the whole
    /// reason the handler exists, so it does not belong here as well.
    ///
    /// The image is shrunk on each attempt. It is a guess — the failure may have
    /// nothing to do with size — but it is the only lever available, and once the
    /// factor reaches 1.0 or the budget runs out the image is dropped rather than
    /// sent again unchanged.
    private func retryAfterFailure(
        _ request: PushRequest,
        status: Int,
        response: URLResponse?,
        data: Data?,
        logString: String,
        service: String,
        context: BulletinContext,
        key: String,
        failureText: String? = nil
    ) {
        if let image = request.infoDict["image"] as? UIImage,
           retryWithShrunkImage(request, image: image,
                                 dataString: failureText ?? "HTTP \(status)",
                                 logString: logString, service: service,
                                 context: context, key: key) {
            return
        }

        let remaining = claimRetry(for: key)
        guard remaining >= 0 else {
            // Out of attempts: report the failure rather than clearing the state
            // and going quiet.
            setRetriesLeft(nil, for: key)
            finish(request, status: status, response: response, data: data,
                   error: failureText)
            return
        }

        let attempt = Pusher.tries - remaining
        PusherLog.debug("\(logString) ----- Retrying. Try \(attempt) of \(Pusher.tries) -----")
        PushLog.add(service: service, context: context,
                    label: "----- Retrying. Try \(attempt) of \(Pusher.tries) -----",
                    tag: request.sequenceTag)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Pusher.delayBetweenRetries) { [weak self] in
            self?.sendAttempt(request, logString: logString, service: service, context: context)
        }
    }

    /// Builds the next attempt with a smaller image, or with none.
    ///
    /// The caller has already decided to retry; this decides what to send. The
    /// image is shrunk by the configured factor, and dropped once the factor can
    /// no longer help or no attempts remain.
    private func retryWithShrunkImage(
        _ request: PushRequest,
        image: UIImage,
        dataString: String,
        logString: String,
        service: String,
        context: BulletinContext,
        key: String
    ) -> Bool {
        // The retry decision was already taken by `retryAfterFailure`, which owns
        // the budget; this only builds the next request.
        let remaining = claimRetry(for: key)
        _ = remaining

        // `imageShrinkFactor` comes from user prefs, so a non-numeric value
        // falls back to the default rather than parsing as 0.
        let shrinkFactor = request.infoDict["imageShrinkFactor"] != nil
            ? CGFloat(request.infoDict.prefsDouble(PrefKey.imageShrinkFactor, default: Double(Pusher.defaultShrinkFactor)))
            : Pusher.defaultShrinkFactor

        var newBody = request.infoDict
        if shrinkFactor <= 1.0 || remaining <= 0 {
            // A factor at or below 1.0 cannot shrink anything, and no attempts are
            // left to shrink in. Drop the image instead of sending it again
            // unchanged — a notification without its picture still arrives.
            newBody["image"] = true
            PushLog.add(service: service, context: context,
                        label: "Image removed for the retry", object: dataString,
                        tag: request.sequenceTag)
        } else {
            let shrunk = PushImage.shrunk(image, by: shrinkFactor)
            newBody["image"] = shrunk
            PushLog.add(service: service, context: context,
                        label: "Image shrunk for the retry",
                        object: "\(Int(shrunk.size.width))×\(Int(shrunk.size.height))",
                        tag: request.sequenceTag)
        }

        let retry = request.copy(infoDict: newBody)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Pusher.delayBetweenRetries) { [weak self] in
            self?.sendAttempt(retry, logString: logString, service: service, context: context)
        }
        return true
    }

    // MARK: - Encoding

    /// The substring a server returns when the body is too large. Matched
    /// case-insensitively against the raw response.
    private let requestEntityTooLarge = "request entity too large"

    /// `application/x-www-form-urlencoded` encoding, RFC 3986 unreserved
    /// characters only and spaces as `+`.
    /// Percent-encoding for a URL query value, where `+` means "plus" and a
    /// space must be `%20`.
    static func queryEncoded(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func formEncoded(_ dictionary: [String: Any]) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

        func encode(_ value: String) -> String {
            (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)
                .replacingOccurrences(of: "%20", with: "+")
        }

        return dictionary.keys.sorted().map { key in
            "\(encode(key))=\(encode(stringValue(dictionary[key])))"
        }.joined(separator: "&")
    }

    /// A value rendered for a query string or form body. GET/HEAD requests
    /// cannot carry non-string values (an NSNumber, the `true` image marker),
    /// so they are stringified rather than dropped.
    static func stringValue(_ value: Any?) -> String {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        case let flag as Bool: return flag ? "true" : "false"
        case nil: return ""
        default: return String(describing: value!)
        }
    }
}

private extension Dictionary where Key == String, Value == Any {
    func prefsDouble(_ key: String, default defaultValue: Double) -> Double {
        Prefs(self).double(key, default: defaultValue)
    }
}

// MARK: - Catching Objective-C exceptions

/// Runs a block inside an Objective-C `@try`.
///
/// Swift's `do`/`catch` sees only Swift errors, so an `NSException` raised by a
/// private framework call unwinds past every `catch` in this file and into the
/// process hosting the tweak — SpringBoard, for a push. `NSJSONSerialization` is
/// the realistic source: it throws on a value it cannot write.
///
/// The trap is ObjC (`Sources/Hooks/ShortcutHooks.xm`), looked up with `dlsym`
/// for the reason the shortcut runner is: the Preferences bundle recompiles
/// these sources and would otherwise need a symbol it never calls.
enum PusherTrap {

    /// Runs `body`, catching an Objective-C exception rather than letting it
    /// unwind into the host process.
    ///
    /// A missing hook runs the block plainly: a trap that is not loaded must not
    /// turn a working send into a silent no-op.
    static func run(_ body: @escaping @convention(block) () -> Void) {
        typealias TrapFn = @convention(c) (AnyObject) -> Void
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "PusherTrapExceptions")
        else {
            body()
            return
        }
        unsafeBitCast(symbol, to: TrapFn.self)(body as AnyObject)
    }
}
