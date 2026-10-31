import Foundation

/// The push request model: everything the sender needs to perform one send.
///
/// A service fully assembles the request (URL, headers, body, method, body
/// encoding) and hands it to ``RequestSender``, which only transports it. That
/// split is what lets a service be a pure function of its inputs.
public final class PushRequest {
    public var urlString: String
    public var headers: [String: String]
    /// The request body. May contain a `UIImage` under `"image"`, which the
    /// sender encodes to Base64 on the way out.
    public var infoDict: [String: Any]
    /// Optional sanitized copy of ``infoDict`` for logging (e.g. Base64 image
    /// fields replaced with placeholders). The sender logs this as-is and never
    /// rewrites the real body.
    public var logInfoDict: [String: Any]?
    /// HTTP method; defaults to `"POST"`.
    public var method: String
    /// Body encoding for methods that carry a body: `"json"` (default) or
    /// `"form"`. GET/HEAD ignore this and put the body in the query string.
    public var bodyType: String
    /// Optional service-controlled resend hook. See ``ResendHandler``.
    public var resendHandler: ResendHandler?
    /// How many times this request has already been resent through
    /// ``resendHandler``. The sender increments this on each service-triggered
    /// resend and uses the existing per-bulletin retry budget to prevent
    /// infinite resend loops.
    public var resendCount = 0
    /// Optional human-readable reason set by a service when it marks the
    /// request as failed through ``resendHandler``. The sender logs it.
    public var failureReason: String?
    /// Which request of a script's sequence this is, 1-based, or `nil` for a
    /// request that is not part of one.
    ///
    /// Every request a script pushes shares the notification's log section, so
    /// without this the URL, body and response lines of three `push()` calls
    /// interleave into one pile and the reader cannot tell which response answered
    /// which request — the last one looked like the only one that had answered.
    public var sequenceTag: String?

    /// Called once when the request is finally done with — delivered, failed, or
    /// out of retries.
    ///
    /// A push that a script awaits needs an answer, and the sender's retry logic is
    /// asynchronous: the first attempt may fail and be repeated. This is how the
    /// script learns the *final* outcome rather than the first one, without
    /// duplicating any of the retrying, logging or image shrinking that lives in
    /// the sender.
    ///
    /// Unset for an ordinary notification: nobody is waiting.
    public var completion: ((JavaScriptRunner.FetchResult) -> Void)?

    /// Service-private state carried alongside the request. Never serialized
    /// into the body or the log — used to hand information from a service's
    /// request builder to its own resend handler (Wechat's rejected token, for
    /// instance).
    public var state: [String: Any] = [:]

    public init(
        urlString: String,
        headers: [String: String]? = nil,
        infoDict: [String: Any]? = nil,
        method: String = "POST"
    ) {
        self.urlString = urlString
        self.headers = headers ?? [:]
        self.infoDict = infoDict ?? [:]
        self.method = method.isEmpty ? "POST" : method
        self.bodyType = "json"
    }

    /// A copy carrying a new body, but the same resend state. Used by the retry
    /// paths, which replace the payload (a smaller image) and send again.
    public func copy(infoDict newInfoDict: [String: Any]) -> PushRequest {
        let copy = PushRequest(
            urlString: urlString, headers: headers, infoDict: newInfoDict, method: method
        )
        copy.bodyType = bodyType
        copy.logInfoDict = logInfoDict
        copy.resendHandler = resendHandler
        copy.sequenceTag = sequenceTag
        copy.completion = completion
        copy.resendCount = resendCount
        copy.failureReason = failureReason
        copy.state = state
        return copy
    }
}

/// Called after a send attempt gets a response or an error.
///
/// The handler may inspect the result and either:
///  - call `completion(nil, false)` to let the sender continue its normal
///    handling,
///  - call `completion(newRequest, false)` to resend a (possibly refreshed)
///    request, or
///  - call `completion(nil, true)` to stop and treat the attempt as failed.
///
/// The callback may be asynchronous — Wechat's expired-token path refreshes the
/// token before answering.
/// What a service's resend handler decided to do.
///
/// This used to be a `(PushRequest?, Bool)` pair, where a request meant "send this
/// instead" and the *reason* was inferred from `failureReason` being nil and the
/// object being new. That inference is what made a script's last `push()` repeat:
/// a chained request was indistinguishable from a retry, so the transport attached
/// the previous step's handler to it and the previous step handed the request back
/// for ever. The intent has to be stated, not guessed.
public enum ResendDecision {
    /// Try again with this request (a refreshed token, a smaller image, or the
    /// same request again). Spends one retry.
    case retry(PushRequest)

    /// Nothing to change; let the transport judge the response as usual.
    case finish

    /// The body said the request failed even though the transport succeeded, or
    /// the handler could not continue. The reason goes in `failureReason`.
    case fail
}

public typealias ResendHandler = (
    _ request: PushRequest,
    _ response: URLResponse?,
    _ data: Data?,
    _ error: Error?,
    _ completion: @escaping (ResendDecision) -> Void
) -> Void
