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
        PushLog.add(service: service, context: context, label: "Shortcut", object: name)
        PusherLog.debug("\(logString) Running shortcut \"\(name)\"")

        let error = ShortcutRunner.run(name: name, input: input)
        if let error {
            PusherLog.info("[S:\(service)] Shortcut \"\(name)\" failed: \(error)")
            PushLog.add(service: service, context: context,
                        label: "Shortcut failed", object: error)
        } else {
            PusherLog.debug("\(logString) Shortcut \"\(name)\" started")
            PushLog.add(service: service, context: context, label: "Shortcut started")
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
        PushLog.add(service: service, context: context, label: "URL", object: urlString)

        guard let url = URL(string: urlString) else {
            PusherLog.debug("Invalid URL: \(urlString)")
            PushLog.add(service: service, context: context, label: "Invalid URL")
            // Clear the retry key so a bad URL doesn't leak an entry in the
            // long-running SpringBoard process.
            setRetriesLeft(nil, for: retryKey(context, service))
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
                        object: "Authorization: Basic ***")
        }
        PushLog.add(service: service, context: context, label: "Method", object: httpMethod)
        urlRequest.httpMethod = httpMethod

        for name in request.headers.keys.sorted() {
            let value = request.headers[name] ?? ""
            urlRequest.setValue(value, forHTTPHeaderField: name)
            PushLog.add(service: service, context: context, label: "Header",
                        object: "\(name): \(value)")
        }

        if !isBodyless {
            // Services provide a sanitized body via logInfoDict; the sender
            // only logs what it was given and never rewrites the real body.
            PushLog.add(service: service, context: context, label: "Request Body Dictionary",
                        object: request.logInfoDict ?? body)
            urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

            let payload: Data?
            if request.bodyType.caseInsensitiveCompare("form") == .orderedSame {
                payload = Self.formEncoded(body).data(using: .utf8)
                urlRequest.setValue(formContentType, forHTTPHeaderField: "Content-Type")
            } else {
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                do {
                    payload = try JSONSerialization.data(
                        withJSONObject: body, options: [.prettyPrinted]
                    )
                } catch {
                    PusherLog.debug("\(logString) JSON serialization failed: \(error)")
                    PushLog.add(service: service, context: context,
                                label: "JSON Serialization Error",
                                object: error.localizedDescription, dontTruncate: true)
                    setRetriesLeft(nil, for: retryKey(context, service))
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

            guard let resendHandler = request.resendHandler else {
                self.handleResponse(request, data: data, response: response, error: error,
                                    logString: logString, service: service, context: context)
                return
            }

            resendHandler(request, response, data, error) { newRequest, shouldFail in
                if let newRequest, !shouldFail {
                    let remaining = self.claimRetry(for: key)
                    guard remaining >= 0 else {
                        let reason = newRequest.failureReason ?? request.failureReason
                            ?? "Resend attempts exhausted"
                        PushLog.add(service: service, context: context,
                                    label: "Network Response: Failed after all resend attempts",
                                    object: reason)
                        PusherLog.debug("\(logString) Failed after all resend attempts: \(reason)")
                        self.setRetriesLeft(nil, for: key)
                        return
                    }
                    newRequest.resendHandler = newRequest.resendHandler ?? resendHandler
                    newRequest.resendCount = request.resendCount + 1
                    PusherLog.debug("\(logString) Resending via service callback (attempt \(newRequest.resendCount + 1))")
                    PushLog.add(service: service, context: context,
                                label: "----- Resending via service callback (attempt \(newRequest.resendCount + 1)) -----")
                    self.sendAttempt(newRequest, logString: logString, service: service, context: context)
                    return
                }

                if shouldFail {
                    let reason = (newRequest?.failureReason ?? request.failureReason)
                        ?? "Resend handler marked request as failed"
                    PushLog.add(service: service, context: context,
                                label: "Network Response: Failed by resend handler",
                                object: reason)
                    PusherLog.debug("\(logString) Failed by resend handler: \(reason)")
                    self.setRetriesLeft(nil, for: key)
                    return
                }

                self.handleResponse(request, data: data, response: response, error: error,
                                    logString: logString, service: service, context: context)
            }
        }.resume()
    }

    // MARK: - Response handling

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
            // A body-less success (204, or an empty 200) is still a success, so
            // it is not treated as a failure here.
            let dataString = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let image = request.infoDict["image"] as? UIImage

            if let image, dataString.lowercased().contains(requestEntityTooLarge) {
                if retryWithSmallerImage(request, image: image, dataString: dataString,
                                         logString: logString, service: service,
                                         context: context, key: key) {
                    return
                }
                // Retries exhausted and the payload is still too large even
                // after dropping the image: log the honest failure.
                PushLog.add(service: service, context: context,
                            label: "Network Response: Image too large on final attempt",
                            object: dataString)
                PusherLog.debug("\(logString) Failed: image too large after final attempt: \(dataString)")
                setRetriesLeft(nil, for: key)
                return
            }

            PushLog.add(service: service, context: context,
                        label: "Network Response: Success", object: dataString)
            PusherLog.debug("\(logString) Success: \(dataString)")
            setRetriesLeft(nil, for: key)
            return
        }

        PushLog.add(service: service, context: context,
                    label: "Network Response: Error",
                    object: error.localizedDescription, dontTruncate: true)
        PusherLog.debug("\(logString) Error: \(error)")

        guard hasRetriesLeft(for: key) else { return }
        let remaining = claimRetry(for: key)
        guard remaining >= 0 else {
            // Retries exhausted with no successful response: log an honest
            // final failure instead of silently clearing the retry state.
            PushLog.add(service: service, context: context,
                        label: "Network Response: Failed after all retries",
                        object: error.localizedDescription, dontTruncate: true)
            PusherLog.debug("\(logString) Failed after all retries: \(error)")
            setRetriesLeft(nil, for: key)
            return
        }

        // A transport-level error says nothing about the payload size, so the
        // image is kept intact here (unlike the "too large" path above).
        let attempt = Pusher.tries - remaining
        PusherLog.debug("\(logString) ----- Retrying. Try \(attempt) of \(Pusher.tries) -----")
        PushLog.add(service: service, context: context,
                    label: "----- Retrying. Try \(attempt) of \(Pusher.tries) -----")

        // Delay so the server doesn't get mad at us.
        let retry = request.copy(infoDict: request.infoDict)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.sendAttempt(retry, logString: logString, service: service, context: context)
        }
    }

    /// Handles a response that says the payload was too large.
    ///
    /// Returns `true` when a retry was scheduled. The image is shrunk by the
    /// configured factor, or dropped once the factor can no longer help (it is
    /// at or below 1.0) or the budget is exhausted.
    private func retryWithSmallerImage(
        _ request: PushRequest,
        image: UIImage,
        dataString: String,
        logString: String,
        service: String,
        context: BulletinContext,
        key: String
    ) -> Bool {
        let remaining = claimRetry(for: key)
        guard remaining >= 0 else { return false }

        // `imageShrinkFactor` comes from user prefs, so a non-numeric value
        // falls back to the default rather than parsing as 0.
        let shrinkFactor = request.infoDict["imageShrinkFactor"] != nil
            ? CGFloat(request.infoDict.prefsDouble(PrefKey.imageShrinkFactor, default: Double(Pusher.defaultShrinkFactor)))
            : Pusher.defaultShrinkFactor

        var newBody = request.infoDict
        let status: String
        if remaining == 0 || shrinkFactor <= 1.0 {
            // A factor that cannot shrink is as good as no shrink: drop the
            // image rather than re-sending the same oversized payload until the
            // budget runs out.
            status = "removed"
            newBody["image"] = true
        } else {
            status = "shrunk"
            newBody["image"] = PushImage.shrunk(image, by: shrinkFactor)
        }

        let sizeString = (newBody["image"] as? UIImage).map { " (size: \($0.size))" } ?? ""
        let attempt = Pusher.tries - remaining
        PusherLog.debug("\(logString) Retrying. Try \(attempt) of \(Pusher.tries) with image \(status)\(sizeString). Success but response was \(dataString).")
        PushLog.add(service: service, context: context,
                    label: "----- Retrying. Try \(attempt) of \(Pusher.tries) with image \(status)\(sizeString). Network Response: Success, but response was \(dataString). -----")

        // Delay so the server doesn't get mad at us.
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
