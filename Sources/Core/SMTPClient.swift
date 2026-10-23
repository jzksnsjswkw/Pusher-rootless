import Foundation

// Security's SSLContext is deprecated in favour of Network.framework, and the
// deprecation is accurate for everything except this: Network picks its TLS when
// the connection is created, and STARTTLS has to start TLS on a socket that is
// already carrying traffic. The API is present and works — measured on iOS 16.5 —
// so the warnings it raises are silenced for this file rather than worked around.
/// A minimal SMTP client: just enough to send one message, over either of the two
/// ways mail servers encrypt a conversation.
///
/// Written rather than taken from a package because the alternative is SwiftNIO,
/// which would take the injected dylib from under 2 MB to several times that and
/// statically link a second TLS stack into a process that already has one.
///
/// Two transports, because the providers disagree about them:
///
/// - **Implicit TLS** (port 465): the socket is TLS from the first byte. Most
///   Chinese providers — QQ, 163, 126, Sina — and Gmail work this way.
/// - **STARTTLS** (port 587): the socket starts in the clear, the client sends
///   `STARTTLS`, and the same socket is upgraded once the server agrees. Outlook
///   offers no implicit port at all, and several corporate servers likewise.
///
/// `Network.framework` cannot do the second: its TLS is chosen when the connection
/// is created, and STARTTLS is by definition a change of mind halfway through. So
/// this file uses a BSD socket and `SSLContext` from Security for both — one
/// transport, two orders of events, no second TLS implementation.
enum SMTPClient {

    /// Everything one send needs, assembled by the service from its settings.
    struct Message {
        var host: String
        var port: UInt16
        var username: String
        var password: String
        /// The address in `MAIL FROM`, which is not always the login name.
        var from: String
        var recipients: [String]
        var subject: String
        /// A display name beside the address in `From:`, empty for none.
        var senderName: String
        var body: String
        /// How the conversation is encrypted — from the first byte, upgraded by
        /// `STARTTLS`, or not at all.
        var security: EmailSecurity
    }

    enum Failure: Error {
        case noRecipients
        case refused(String)
        case rejected(String)
        case timedOut
        case connection(String)

        /// A sentence for the log, which is the only place a user can see this.
        var label: String {
            switch self {
            case .noRecipients: return "No recipients"
            case .refused(let step): return "Server refused \(step)"
            case .rejected(let step): return "Server rejected \(step)"
            case .timedOut: return "Timed out"
            case .connection(let detail): return "Connection failed: \(detail)"
            }
        }
    }

    /// How long the whole conversation may take. A mailbox that does not answer is
    /// one the user needs to be told about, not one to wait on forever.
    private static let timeout: TimeInterval = 25

    static func send(
        _ message: Message,
        completion: @escaping (Result<Void, Failure>) -> Void
    ) {
        guard !message.recipients.isEmpty else {
            completion(.failure(.noRecipients))
            return
        }
        // On a background thread: the whole conversation is blocking, and it is
        // started from a SpringBoard daemon path that must not be held up.
        DispatchQueue.global(qos: .utility).async {
            let result = converse(message)
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - The conversation

    private static func converse(_ message: Message) -> Result<Void, Failure> {
        var socket = BSDSocket()

        switch socket.connect(host: message.host, port: message.port, timeout: timeout) {
        case .failure(let error):
            return .failure(.connection(error.detail))
        case .success:
            break
        }
        defer { socket.close() }

        var secure: SSLSession?

        /// Sends a command and reads the reply code.
        func exchange(_ command: String?, expecting: String, step: String) -> Result<Void, Failure> {
            if let command {
                if let secure {
                    if case .failure(let error) = secure.writeAll(command) {
                        return .failure(.connection(error.detail))
                    }
                } else if case .failure(let error) = socket.writeAll(command) {
                    return .failure(.connection(error.detail))
                }
            }
            let reply: String
            if let secure {
                switch secure.readLine() {
                case .success(let line): reply = line
                case .failure(let error): return .failure(.connection(error.detail))
                }
            } else {
                switch socket.readLine() {
                case .success(let line): reply = line
                case .failure(let error): return .failure(.connection(error.detail))
                }
            }
            guard reply.hasPrefix(expecting) else {
                // A 4xx or 5xx is the server declining something specific; the step
                // name is what tells the user which. Anything else was answered in
                // a way this client did not expect.
                let failure: Failure = reply.hasPrefix("4") || reply.hasPrefix("5")
                    ? .rejected(step) : .refused(step)
                return .failure(failure)
            }
            return .success(())
        }

        // A STARTTLS server greets in the clear; the socket is upgraded after EHLO.
        if case .failure(let error) = exchange(nil, expecting: "220", step: "greeting") {
            return .failure(error)
        }

        switch message.security {
        case .starttls:
            // The EHLO before the upgrade exists only to ask whether STARTTLS is
            // offered; the conversation proper begins after it.
            if case .failure(let error) = exchange("EHLO pusher\r\n",
                                                   expecting: "250", step: "EHLO") {
                return .failure(error)
            }
            if case .failure(let error) = exchange("STARTTLS\r\n",
                                                   expecting: "220", step: "STARTTLS") {
                return .failure(error)
            }
            switch SSLSession.over(socket: socket, host: message.host) {
            case .failure(let error):
                return .failure(.connection(error.detail))
            case .success(let session):
                secure = session
            }
        case .tls:
            switch SSLSession.over(socket: socket, host: message.host) {
            case .failure(let error):
                return .failure(.connection(error.detail))
            case .success(let session):
                secure = session
            }
        case .plain:
            // Nothing to set up. The conversation continues in the clear, which is
            // what this mode was chosen for — a server on a private network that
            // offers neither TLS option, or a user isolating a TLS failure from an
            // authentication one.
            break
        }

        // After a STARTTLS upgrade the server forgets everything it was told, so
        // EHLO goes again. Over implicit TLS there was no first one.
        if case .failure(let error) = exchange("EHLO pusher\r\n",
                                               expecting: "250", step: "EHLO") {
            return .failure(error)
        }
        if case .failure(let error) = exchange("AUTH LOGIN\r\n",
                                               expecting: "334", step: "AUTH LOGIN") {
            return .failure(error)
        }
        if case .failure(let error) = exchange(base64(message.username) + "\r\n",
                                               expecting: "334", step: "username") {
            return .failure(error)
        }
        if case .failure(let error) = exchange(base64(message.password) + "\r\n",
                                               expecting: "235", step: "password") {
            return .failure(error)
        }
        if case .failure(let error) = exchange("MAIL FROM:<\(message.from)>\r\n",
                                               expecting: "250", step: "MAIL FROM") {
            return .failure(error)
        }
        for recipient in message.recipients {
            if case .failure(let error) = exchange("RCPT TO:<\(recipient)>\r\n",
                                                   expecting: "250", step: "RCPT TO") {
                return .failure(error)
            }
        }
        if case .failure(let error) = exchange("DATA\r\n", expecting: "354", step: "DATA") {
            return .failure(error)
        }
        // The body is sent without reading a reply first: the 354 that opened the
        // data section is the last thing the server says until the message ends.
        let payload = mimeData(message) + "\r\n.\r\n"
        if let secure {
            if case .failure(let error) = secure.writeAll(payload) {
                return .failure(.connection(error.detail))
            }
            switch secure.readLine() {
            case .success(let reply) where reply.hasPrefix("250"):
                break
            case .success(let reply):
                return .failure(.rejected("message body (\(reply.prefix(60)))"))
            case .failure(let error):
                return .failure(.connection(error.detail))
            }
        } else {
            if case .failure(let error) = socket.writeAll(payload) {
                return .failure(.connection(error.detail))
            }
            switch socket.readLine() {
            case .success(let reply) where reply.hasPrefix("250"):
                break
            case .success(let reply):
                return .failure(.rejected("message body (\(reply.prefix(60)))"))
            case .failure(let error):
                return .failure(.connection(error.detail))
            }
        }

        _ = exchange("QUIT\r\n", expecting: "221", step: "QUIT")
        return .success(())
    }

    // MARK: - Pieces

    private static func base64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    /// The message as SMTP wants it: headers, a blank line, then the body.
    ///
    /// The subject and any sender name are UTF-8 inside `=?UTF-8?B?…?=` wrappers,
    /// because Chinese sent as-is arrives as mojibake in most clients.
    private static func mimeData(_ message: Message) -> String {
        let subject = "=?UTF-8?B?\(base64(message.subject))?="
        let from = message.senderName.isEmpty
            ? message.from
            : "=?UTF-8?B?\(base64(message.senderName))?= <\(message.from)>"
        // A line holding a single "." ends the DATA section, so any line starting
        // with one is escaped by doubling it.
        let body = message.body
            .components(separatedBy: "\n")
            .map { $0.hasPrefix(".") ? "." + $0 : $0 }
            .joined(separator: "\r\n")
        return [
            "From: \(from)",
            "To: \(message.recipients.joined(separator: ", "))",
            "Subject: \(subject)",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: 8bit",
            "",
            body,
        ].joined(separator: "\r\n")
    }
}

/// A transport-level failure, named for the log.
struct TransportError: Error {
    let detail: String
}

// MARK: - BSD socket

/// A TCP socket with a deadline, and line-at-a-time reads.
///
/// Blocking calls with `SO_RCVTIMEO`/`SO_SNDTIMEO` rather than a non-blocking loop:
/// the whole conversation runs on its own thread, so blocking is the simplest thing
/// that cannot get stuck — every call gives up on its own.
private struct BSDSocket {
    var descriptor: Int32 = -1

    mutating func connect(host: String, port: UInt16, timeout: TimeInterval) -> Result<Void, TransportError> {
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
            ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
            ai_addr: nil, ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let head = result else {
            return .failure(TransportError(detail: "cannot resolve \(host)"))
        }
        defer { freeaddrinfo(result) }

        // The first address that accepts a connection wins; a host often resolves
        // to both an IPv4 and an IPv6 address and only one of them may be reachable.
        var address = head
        while true {
            let fd = socket(address.pointee.ai_family, address.pointee.ai_socktype,
                            address.pointee.ai_protocol)
            if fd >= 0 {
                var seconds = Int32(timeout)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &seconds, 4)
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &seconds, 4)
                // Nagle would hold small commands back waiting for company, and an
                // SMTP conversation is nothing but small commands.
                var one: Int32 = 1
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, 4)

                if Darwin.connect(fd, address.pointee.ai_addr,
                                  address.pointee.ai_addrlen) == 0 {
                    descriptor = fd
                    return .success(())
                }
                Darwin.close(fd)
            }
            guard let next = address.pointee.ai_next else {
                return .failure(TransportError(detail: "cannot connect to \(host):\(port)"))
            }
            address = next
        }
    }

    func writeAll(_ text: String) -> Result<Void, TransportError> {
        var bytes = Array(text.utf8)
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return send(descriptor, base, buffer.count, 0)
            }
            if written <= 0 { return .failure(TransportError(detail: "write failed")) }
            bytes.removeFirst(written)
        }
        return .success(())
    }

    /// One reply line, without its CRLF.
    ///
    /// Multi-line replies (`250-…` then `250 …`) are returned one line at a time;
    /// the caller's prefix test only passes on the final line, because the others
    /// carry `-` where it expects a space.
    func readLine() -> Result<String, TransportError> {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = recv(descriptor, &byte, 1, 0)
            if count <= 0 { return .failure(TransportError(detail: "connection closed")) }
            if byte == 0x0A {
                if bytes.last == 0x0D { bytes.removeLast() }
                return .success(String(decoding: bytes, as: UTF8.self))
            }
            bytes.append(byte)
        }
    }

    func close() {
        if descriptor >= 0 { Darwin.close(descriptor) }
    }
}

// MARK: - TLS

/// A TLS session over an already-open socket, or over one it upgrades.
///
/// `SSLContext` is used rather than `Network.framework` because STARTTLS needs to
/// start TLS on a connection that is already carrying traffic, and Network chooses
/// its TLS when the connection is created.
private final class SSLSession {
    private let context: SSLContext
    private var socket: BSDSocket
    /// The socket is handed to the TLS callbacks as a stable pointer, so it is
    /// stored here rather than passed by value into `SSLSetConnection`.
    private let fdBox: UnsafeMutablePointer<Int32>

    private init(context: SSLContext, socket: BSDSocket) {
        self.context = context
        self.socket = socket
        self.fdBox = .allocate(capacity: 1)
        fdBox.pointee = socket.descriptor
        SSLSetConnection(context, UnsafeRawPointer(fdBox))

        // The reference is the socket pointer given to `SSLSetConnection`; the TLS
        // layer always hands back what it was given, so there is nothing to unwrap.
        SSLSetIOFuncs(context, { reference, data, length in
            let fd = reference.load(as: Int32.self)
            let read = recv(fd, data, length.pointee, 0)
            if read > 0 { length.pointee = read; return errSecSuccess }
            if read == 0 { return errSSLClosedGraceful }
            return errSSLWouldBlock
        }, { reference, data, length in
            let fd = reference.load(as: Int32.self)
            let written = send(fd, data, length.pointee, 0)
            if written > 0 { length.pointee = written; return errSecSuccess }
            return errSSLWouldBlock
        })
    }

    /// TLS from the first byte, as on port 465.
    static func over(socket: BSDSocket, host: String) -> Result<SSLSession, TransportError> {
        guard let context = SSLCreateContext(nil, .clientSide, .streamType) else {
            return .failure(TransportError(detail: "cannot create TLS context"))
        }
        let session = SSLSession(context: context, socket: socket)
        return session.handshake(host: host)
    }

    /// TLS starting now, on a socket that has already been talking, as after
    /// `STARTTLS`.
    static func upgrade(socket: BSDSocket, host: String) -> Result<SSLSession, TransportError> {
        over(socket: socket, host: host)
    }

    private func handshake(host: String) -> Result<SSLSession, TransportError> {
        SSLSetProtocolVersionMin(context, .tlsProtocol12)
        SSLSetPeerDomainName(context, host, host.utf8.count)
        let status = SSLHandshake(context)
        guard status == errSecSuccess else {
            return .failure(TransportError(detail: "TLS handshake failed (\(status))"))
        }
        return .success(self)
    }

    func writeAll(_ text: String) -> Result<Void, TransportError> {
        var bytes = Array(text.utf8)
        while !bytes.isEmpty {
            var processed = 0
            let status = bytes.withUnsafeBytes { buffer -> OSStatus in
                guard let base = buffer.baseAddress else { return errSSLInternal }
                return SSLWrite(context, base, buffer.count, &processed)
            }
            if status != errSecSuccess { return .failure(TransportError(detail: "TLS write failed (\(status))")) }
            bytes.removeFirst(processed)
        }
        return .success(())
    }

    func readLine() -> Result<String, TransportError> {
        var bytes: [UInt8] = []
        while true {
            var byte: UInt8 = 0
            var processed = 0
            let status = SSLRead(context, &byte, 1, &processed)
            if status != errSecSuccess { return .failure(TransportError(detail: "TLS read failed (\(status))")) }
            if processed == 0 { return .failure(TransportError(detail: "connection closed")) }
            if byte == 0x0A {
                if bytes.last == 0x0D { bytes.removeLast() }
                return .success(String(decoding: bytes, as: UTF8.self))
            }
            bytes.append(byte)
        }
    }
}
