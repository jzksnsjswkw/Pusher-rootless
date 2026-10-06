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
public typealias ResendHandler = (
    _ request: PushRequest,
    _ response: URLResponse?,
    _ data: Data?,
    _ error: Error?,
    _ completion: @escaping (PushRequest?, Bool) -> Void
) -> Void
