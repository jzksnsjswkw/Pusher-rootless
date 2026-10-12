import Foundation

/// Gets the example Shortcut onto the device, signed.
///
/// A Shortcut cannot be imported unless Apple has signed it, and iOS has no way
/// to sign one — the `shortcuts` binary that does it is macOS only. So a signed
/// copy ships in the bundle, and a signing service is contacted only when that
/// copy has gone stale.
///
/// **Why a bundled copy at all.** The signing service is a community one
/// (HubSign, part of RoutineHub) that runs Apple's binary on a Mac. It sits
/// behind Cloudflare, which challenges some networks outright — measured from a
/// mainland connection, every endpoint answers 403 with a browser-check page,
/// with or without browser headers. A button that only works on some networks is
/// worse than one that works on none, so the common path is a file that is
/// already here.
///
/// **Why it can go stale.** An Apple signature lasts about a year; the copy in
/// this bundle expires in November 2027. When it does, the service is asked for a
/// fresh one — a self-healing path that needs no release, for the networks it
/// works on. Until then nothing is sent anywhere.
///
/// The expiry is read from the certificate rather than held as a constant, so the
/// two cannot disagree: replacing the bundled file is all it takes to move the
/// deadline.
enum ShortcutSigner {

    /// Where a fresh signature comes from, when one is needed.
    private static let service = URL(string: "https://hubsign.routinehub.services/sign")!

    /// The example Shortcut's name, as the service names the file it returns and
    /// as the Shortcuts app shows it on the import screen.
    private static let shortcutName = "Pusher"

    /// The unsigned definition — sent to the service, never handed to the user.
    private static let definitionName = "PusherExample"

    /// The signed copy that ships in the bundle.
    private static let signedName = "PusherExampleSigned"

    enum SigningError: LocalizedError {
        case missingResource
        case network(String)
        case rejected(Int)
        case notSigned

        var errorDescription: String? {
            switch self {
            case .missingResource:
                return "The example Shortcut is missing from this build."
            case .network(let detail):
                // The service is behind Cloudflare, which refuses some networks
                // before the request is ever seen. Saying so saves the user from
                // concluding their own connection is broken.
                return ("Could not reach the signing service: \(detail)\n\n"
                    + "That service is sometimes unreachable from some networks. "
                    + "It is only needed once the Shortcut included with Pusher "
                    + "has expired.")
            case .rejected(let status):
                return "The signing service refused the Shortcut (HTTP \(status))."
            case .notSigned:
                return "The signing service returned a file that is not signed."
            }
        }
    }

    /// Hands back a signed copy of the example Shortcut.
    ///
    /// Reports on the main queue: the result is a file to be shown to a user.
    static func signedExample(completion: @escaping (Result<URL, Error>) -> Void) {
        if let bundled = bundledSignedCopy() {
            completion(.success(bundled))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try requestSignature() }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - The copy that ships with the app

    /// The bundled signed copy, if it is there and its signature is still good.
    ///
    /// The file is returned in place rather than copied: it is read-only, it is
    /// exactly what the Shortcuts app wants, and copying it would only make a
    /// second file that can fall out of step with the first.
    private static func bundledSignedCopy() -> URL? {
        guard let url = Bundle.pusher.url(forResource: signedName, withExtension: "shortcut"),
              let data = try? Data(contentsOf: url),
              isSigned(data)
        else { return nil }

        // A certificate that cannot be read is treated as usable. The check
        // exists to decide whether to ask for a fresh signature, and asking is
        // the unreliable path — nine times out of ten the file is fine and the
        // parse is what failed.
        if let expiry = signatureExpiry(in: data), expiry < Date() { return nil }
        return url
    }

    /// The archive's magic number. A signed Shortcut is an Apple Encrypted
    /// Archive; an unsigned one is a bare plist.
    private static func isSigned(_ data: Data) -> Bool {
        data.count > 4 && data.prefix(4) == Data("AEA1".utf8)
    }

    /// The instant the signature stops being valid, or `nil` if it cannot be read.
    ///
    /// Taken from the certificate in the archive rather than kept as a constant
    /// beside it, so the file and this code cannot disagree about when the
    /// signature runs out: replacing the bundled file is all it takes to move the
    /// deadline.
    ///
    /// `SecCertificateCopyValues` would be the obvious way to read it and is not
    /// callable — it is private, along with the OID constants it takes — so the
    /// certificate's DER is walked. A first attempt scanned the bytes for
    /// anything shaped like a timestamp, which found the right answer for the leaf
    /// certificate and the wrong one for the chain: this reads the structure
    /// instead, and its answers match `cryptography`'s for all three certificates
    /// in the file.
    private static func signatureExpiry(in data: Data) -> Date? {
        guard let header = archiveHeader(in: data),
              let chain = header["SigningCertificateChain"] as? [Data],
              let leaf = chain.first
        else { return nil }
        return certificateExpiry(leaf)
    }

    /// The `notAfter` of a DER-encoded X.509 certificate.
    ///
    /// Certificate is a SEQUENCE holding `tbsCertificate`, an algorithm, and the
    /// signature. The validity period is the fifth element of the first, and its
    /// second child is `notAfter`.
    private static func certificateExpiry(_ der: Data) -> Date? {
        let bytes = [UInt8](der)
        var outer = 0
        guard let certificate = readElement(bytes, &outer), certificate.tag == 0x30
        else { return nil }

        var cursor = certificate.start
        guard let tbs = readElement(bytes, &cursor), tbs.tag == 0x30 else { return nil }

        var field = tbs.start
        // version (context 0), serialNumber, signature algorithm, issuer.
        for expected: UInt8 in [0xA0, 0x02, 0x30, 0x30] {
            guard let element = readElement(bytes, &field), element.tag == expected
            else { return nil }
        }
        guard let validity = readElement(bytes, &field), validity.tag == 0x30
        else { return nil }

        var time = validity.start
        guard let notBefore = readElement(bytes, &time),
              notBefore.tag == 0x17 || notBefore.tag == 0x18
        else { return nil }
        guard let notAfter = readElement(bytes, &time),
              notAfter.tag == 0x17 || notAfter.tag == 0x18
        else { return nil }

        return parseTimestamp(
            bytes[notAfter.start..<notAfter.end], isUTCTime: notAfter.tag == 0x17
        )
    }

    /// One tag-length-value at `offset`, advancing the cursor past it.
    private static func readElement(
        _ bytes: [UInt8], _ offset: inout Int
    ) -> (tag: UInt8, start: Int, end: Int)? {
        guard offset < bytes.count else { return nil }
        let tag = bytes[offset]
        var index = offset + 1
        guard index < bytes.count else { return nil }

        let first = bytes[index]
        var length = 0
        if first & 0x80 == 0 {
            length = Int(first)
            index += 1
        } else {
            let count = Int(first & 0x7F)
            // Four bytes covers every length an X.509 certificate can carry.
            guard count >= 1, count <= 4, index + count < bytes.count else { return nil }
            index += 1
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[index])
                index += 1
            }
        }
        guard index + length <= bytes.count else { return nil }
        offset = index + length
        return (tag, index, index + length)
    }

    /// Parses `YYMMDDHHMMSSZ` (UTCTime) or `YYYYMMDDHHMMSSZ` (GeneralizedTime).
    private static func parseTimestamp(
        _ bytes: ArraySlice<UInt8>, isUTCTime: Bool
    ) -> Date? {
        guard bytes.last == UInt8(ascii: "Z") else { return nil }
        let digits = bytes.dropLast()
        let expected = isUTCTime ? 12 : 14
        guard digits.count == expected,
              digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 })
        else { return nil }

        var value = 0
        for digit in digits { value = value * 10 + Int(digit - 0x30) }

        var components = DateComponents()
        if isUTCTime {
            // RFC 5280: two-digit years below 50 are 20xx, the rest 19xx.
            let year = value / 10_000_000_000
            components.year = year < 50 ? 2000 + year : 1900 + year
            let rest = value % 10_000_000_000
            components.month = rest / 100_000_000
            components.day = (rest / 1_000_000) % 100
            components.hour = (rest / 10_000) % 100
            components.minute = (rest / 100) % 100
            components.second = rest % 100
        } else {
            components.year = value / 100_000_000_000
            let rest = value % 100_000_000_000
            components.month = rest / 1_000_000_000
            components.day = (rest / 10_000_000) % 100
            components.hour = (rest / 100_000) % 100
            components.minute = (rest / 100) % 100
            components.second = rest % 100
        }
        components.timeZone = TimeZone(secondsFromGMT: 0)

        return Calendar(identifier: .gregorian).date(from: components)
    }

    /// The plist at the front of an Apple Encrypted Archive.
    ///
    /// Layout: four magic bytes, four unused, four bytes of little-endian header
    /// length, then that many bytes of header.
    private static func archiveHeader(in data: Data) -> [String: Any]? {
        guard data.count > 12 else { return nil }
        let length = data.subdata(in: 8..<12).withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self)
        }
        let start = 12
        let end = start + Int(length)
        guard length > 0, end <= data.count else { return nil }
        return try? PropertyListSerialization.propertyList(
            from: data.subdata(in: start..<end), options: [], format: nil
        ) as? [String: Any]
    }

    // MARK: - Asking for a fresh signature

    private static func requestSignature() throws -> URL {
        guard let definition = Bundle.pusher.url(
            forResource: definitionName, withExtension: "shortcut"
        ), let contents = try? Data(contentsOf: definition) else {
            throw SigningError.missingResource
        }

        // Hand-built rather than through `URLSession.uploadTask(with:from:)`: the
        // field order and the multipart boundary are the only things this needs
        // to get right, and a request assembled here can be read in one screen.
        let boundary = "PusherBoundary\(UUID().uuidString)"
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"shortcutName\"\r\n\r\n")
        append("\(shortcutName)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"shortcut\"; "
            + "filename=\"\(definitionName).shortcut\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(contents)
        append("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: service)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        // A browser-shaped request: the service sits behind Cloudflare, which
        // treats a bare `URLSession` user agent as worth challenging.
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.httpBody = body
        request.timeoutInterval = 30

        let (data, response) = try awaitSynchronously(request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SigningError.rejected(http.statusCode)
        }
        // Checked rather than assumed from the status: the service answers 200
        // with an HTML error page in some cases.
        guard isSigned(data) else { throw SigningError.notSigned }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(shortcutName).shortcut")
        try data.write(to: destination)
        return destination
    }

    /// A `URLSession` request, waited for.
    ///
    /// The caller is already on a background queue and this method's work is
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
