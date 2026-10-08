import Foundation

/// Performs the HTTP requests a script's `fetch` asks for.
///
/// `fetch` is synchronous from the script's point of view — it hands back a
/// finished response — so this blocks the calling thread on `URLSession`. That is
/// safe because the run is already on a background queue, and it is what lets a
/// script use ordinary `await` style without an event loop.
///
/// The only restriction is the response size, which the caller applies; there is
/// deliberately no allow-list, since a script exists precisely to reach whatever
/// endpoint the user has in mind.
enum ScriptHTTP {
    /// Sends one request and waits for it.
    ///
    /// Never throws: a failure is returned as ``JavaScriptRunner/FetchResult``
    /// carrying `error`, which `fetch` turns into a rejected promise. That is
    /// what the specification does, and it means a script's `try/catch` sees a
    /// failed request the way it would in a browser.
    static func perform(_ request: URLRequest) -> JavaScriptRunner.FetchResult {
        var request = request
        if request.timeoutInterval <= 0 {
            request.timeoutInterval = Pusher.scriptFetchTimeout
        }
        // A script has no cache to consult and no notion of a stale response, so
        // a push always asks the server.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let semaphore = DispatchSemaphore(value: 0)
        let box = Box()

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                // `NSURLErrorCancelled` on a timeout reads as a cancellation, so
                // the message is phrased from the request rather than the code.
                let code = (error as NSError).code
                box.error = code == NSURLErrorTimedOut
                    ? "request timed out"
                    : error.localizedDescription
                return
            }
            guard let http = response as? HTTPURLResponse else {
                box.error = "no response"
                return
            }

            var headers: [String: String] = [:]
            // Lower-cased, as the specification requires: a script looking up
            // `headers.get("content-type")` must not depend on the server's
            // spelling.
            for (field, value) in http.allHeaderFields {
                headers[String(describing: field).lowercased()] = String(describing: value)
            }

            box.result = JavaScriptRunner.FetchResult(
                status: http.statusCode,
                headers: headers,
                body: data ?? Data(),
                finalURL: http.url?.absoluteString
            )
        }.resume()

        // A little past the request's own timeout, so URLSession reports the
        // timeout itself rather than the wait giving up first.
        guard semaphore.wait(timeout: .now() + request.timeoutInterval + 5) == .success else {
            return JavaScriptRunner.FetchResult(error: "request timed out")
        }
        if let error = box.error { return JavaScriptRunner.FetchResult(error: error) }
        return box.result ?? JavaScriptRunner.FetchResult(error: "no response")
    }

    /// Carries the callback's result back across the wait.
    private final class Box: @unchecked Sendable {
        var result: JavaScriptRunner.FetchResult?
        var error: String?
    }
}
