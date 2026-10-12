import Foundation

/// Gets the example Shortcut onto the device.
///
/// A Shortcut cannot be imported unless Apple has signed it, and there is no
/// signing capability on iOS — the `shortcuts` binary that does it is macOS
/// only. So the file shipped in the bundle is the *unsigned* definition, and it
/// is signed on demand by a community service that runs that binary for us
/// (HubSign, part of RoutineHub). The signature it returns is an ordinary Apple
/// one, the same kind the Shortcuts app produces when a shortcut is shared, so
/// the file a user gets is one the system accepts.
///
/// The alternative was to ship a pre-signed file, which is what this does not
/// do. A signature lasts about a year — the ones taken from `shortcuts sign` on
/// this project's Mac expire in November 2027 — and a bundled copy would have to
/// be re-signed and re-released before then, by whoever has a Mac at the time.
/// Asking for a fresh signature when the user asks for the shortcut has no such
/// deadline, and the file the user ends up with is signed today rather than
/// whenever the release was cut.
///
/// The cost is a network request to a third party that this project does not
/// control. It is made once, only when the user presses the button, and it sends
/// the example Shortcut and nothing else — no notification, no configuration, no
/// identifier.
enum ShortcutSigner {

    /// Where the example Shortcut comes from.
    private static let service = URL(string: "https://hubsign.routinehub.services/sign")!

    /// The example Shortcut's name, as it arrives.
    ///
    /// The service names the signed file after this, and the Shortcuts app shows
    /// it on the import screen.
    private static let shortcutName = "Pusher"

    /// The bundled definition.
    private static let resourceName = "PusherExample"

    enum SigningError: LocalizedError {
        case missingResource
        case network(String)
        case rejected(Int, String)
        case notSigned

        var errorDescription: String? {
            switch self {
            case .missingResource:
                return "The example Shortcut is missing from this build."
            case .network(let detail):
                return "Could not reach the signing service: \(detail)"
            case .rejected(let status, let body):
                return "The signing service refused the Shortcut (\(status)): \(body)"
            case .notSigned:
                return "The signing service returned a file that is not signed."
            }
        }
    }

    /// Fetches a signed copy of the example Shortcut.
    ///
    /// Reports back on the main queue: the result is written to a file and handed
    /// to a share sheet, both of which are the caller's to do on the main thread.
    static func signedExample(completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try signedExampleSynchronously() }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func signedExampleSynchronously() throws -> URL {
        guard let definition = Bundle.pusher.url(
            forResource: resourceName, withExtension: "shortcut"
        ), let contents = try? Data(contentsOf: definition) else {
            throw SigningError.missingResource
        }

        // Hand-built rather than through `URLSession.uploadTask(with:from:)`: the
        // field order and the multipart boundary are the only things this need
        // get right, and a request assembled here can be read in one screen.
        let boundary = "PusherBoundary\(UUID().uuidString)"
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"shortcutName\"\r\n\r\n")
        append("\(shortcutName)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"shortcut\"; "
            + "filename=\"\(resourceName).shortcut\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(contents)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: service)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        // The service runs the macOS binary behind a web front end; a shortcut
        // that is a few hundred kilobytes of comments takes a moment.
        request.timeoutInterval = 30

        let (data, response) = try awaitSynchronously(request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SigningError.rejected(http.statusCode, String(body.prefix(200)))
        }

        // A signed shortcut is an Apple Encrypted Archive; an unsigned one is a
        // plist. Checking the magic rather than trusting the status code, because
        // the service answers 200 with an error page in some cases.
        guard data.count > 4, data.prefix(4) == Data("AEA1".utf8) else {
            throw SigningError.notSigned
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(shortcutName).shortcut")
        try data.write(to: destination)
        return destination
    }

    /// A `URLSession` request, waited for.
    ///
    /// The caller is already on a background queue, and this method's work is
    /// entirely about the reply, so an async interface would only move the
    /// continuation somewhere else.
    private static func awaitSynchronously(
        _ request: URLRequest
    ) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<(Data, URLResponse), Error>?

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                outcome = .failure(SigningError.network(error.localizedDescription))
                return
            }
            guard let data, let response else {
                outcome = .failure(SigningError.network("empty reply"))
                return
            }
            outcome = .success((data, response))
        }.resume()

        _ = semaphore.wait(timeout: .now() + 40)
        guard let outcome else {
            throw SigningError.network("timed out")
        }
        return try outcome.get()
    }
}
