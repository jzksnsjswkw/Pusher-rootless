import Foundation
import Network

/// A minimal SMTP client: just enough to send one message over an implicit-TLS
/// connection.
///
/// Written rather than taken from a package because the alternative is SwiftNIO,
/// which would take the injected dylib from under 2 MB to several times that and
/// statically link a second TLS stack into a process that already has one.
/// `Network.framework` has been in the system since iOS 12 and does the TLS
/// itself — measured working from SpringBoard, which is the only environment this
/// code runs in.
///
/// Scope is deliberate: implicit TLS on port 465, `AUTH LOGIN`, one plain-text
/// body, no attachments, no STARTTLS. That covers the mailboxes this is for; a
/// server that only offers 587 is not handled.
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

    /// One exchange: a command to send, and the reply code expected back.
    private struct Step {
        let command: String?
        let expected: String
        let name: String
    }

    /// How long the whole conversation may take. A mailbox that does not answer is
    /// one the user needs to be told about, not one to wait on forever.
    private static let timeout: TimeInterval = 20

    static func send(
        _ message: Message,
        completion: @escaping (Result<Void, Failure>) -> Void
    ) {
        guard !message.recipients.isEmpty else {
            completion(.failure(.noRecipients))
            return
        }

        let tls = NWProtocolTLS.Options()
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        guard let port = NWEndpoint.Port(rawValue: message.port) else {
            completion(.failure(.connection("bad port \(message.port)")))
            return
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(message.host), port: port, using: parameters
        )

        // The conversation is a sequence where every step waits for the last
        // reply, so it is a list walked one entry at a time rather than eight
        // nested completion handlers. Nested ones cannot be read, and cannot be
        // timed out as a whole.
        var steps: [Step] = [
            Step(command: nil, expected: "220", name: "greeting"),
            Step(command: "EHLO pusher\r\n", expected: "250", name: "EHLO"),
            Step(command: "AUTH LOGIN\r\n", expected: "334", name: "AUTH LOGIN"),
            Step(command: base64(message.username) + "\r\n", expected: "334", name: "username"),
            Step(command: base64(message.password) + "\r\n", expected: "235", name: "password"),
            Step(command: "MAIL FROM:<\(message.from)>\r\n", expected: "250", name: "MAIL FROM"),
        ]
        for recipient in message.recipients {
            steps.append(Step(command: "RCPT TO:<\(recipient)>\r\n",
                              expected: "250", name: "RCPT TO"))
        }
        steps.append(Step(command: "DATA\r\n", expected: "354", name: "DATA"))
        steps.append(Step(command: mimeData(message) + "\r\n.\r\n",
                          expected: "250", name: "message body"))
        steps.append(Step(command: "QUIT\r\n", expected: "221", name: "QUIT"))

        let queue = DispatchQueue(label: "smtp")
        var index = 0
        var finished = false
        var buffer = Data()

        func finish(_ result: Result<Void, Failure>) {
            guard !finished else { return }
            finished = true
            connection.cancel()
            completion(result)
        }

        /// Runs the step at `index`: sends its command if it has one, then waits
        /// for the reply.
        func runStep() {
            guard index < steps.count else {
                finish(.success(()))
                return
            }
            let step = steps[index]
            guard let command = step.command else {
                awaitReply(for: step)
                return
            }
            connection.send(content: Data(command.utf8), completion: .contentProcessed { error in
                if let error {
                    finish(.failure(.connection(error.localizedDescription)))
                    return
                }
                awaitReply(for: step)
            })
        }

        /// Consumes one complete reply from the buffer, reading more when the reply
        /// has not arrived in full.
        func awaitReply(for step: Step) {
            if let (code, consumed) = takeReply(from: buffer) {
                buffer.removeFirst(consumed)
                guard code == step.expected else {
                    // A 4xx or 5xx is the server declining something specific; the
                    // step name is what tells the user which. Anything else is
                    // answered in a way this client did not expect.
                    let failure: Failure = code.hasPrefix("4") || code.hasPrefix("5")
                        ? .rejected(step.name)
                        : .refused(step.name)
                    finish(.failure(failure))
                    return
                }
                index += 1
                runStep()
                return
            }

            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
                data, _, isComplete, error in
                if let data, !data.isEmpty { buffer.append(data) }
                if let error {
                    finish(.failure(.connection(error.localizedDescription)))
                    return
                }
                if buffer.isEmpty, isComplete {
                    finish(.failure(.connection("connection closed")))
                    return
                }
                awaitReply(for: step)
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                runStep()
            case .failed(let error), .waiting(let error):
                finish(.failure(.connection(error.localizedDescription)))
            default:
                break
            }
        }

        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) {
            finish(.failure(.timedOut))
        }
    }

    // MARK: - Pieces

    /// The first complete reply in the buffer, and how many bytes it occupied.
    ///
    /// A reply ends on a line whose code is followed by a space; `250-` lines are
    /// continuations, so a prefix test on the whole buffer answers too early
    /// whenever the server sends several.
    private static func takeReply(from buffer: Data) -> (String, Int)? {
        guard let text = String(data: buffer, encoding: .utf8) else { return nil }
        var consumed = 0
        for line in text.components(separatedBy: "\r\n") {
            consumed += line.utf8.count + 2 // the line plus its CRLF
            guard line.count >= 4 else { continue }
            let code = String(line.prefix(3))
            guard code.allSatisfy(\.isNumber) else { continue }
            let separator = line[line.index(line.startIndex, offsetBy: 3)]
            if separator == " " {
                return (code, min(consumed, buffer.count))
            }
        }
        return nil
    }

    private static func base64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    /// The message as SMTP wants it: headers, a blank line, then the body.
    ///
    /// The subject is UTF-8 inside a `=?UTF-8?B?…?=` wrapper, because a Chinese
    /// subject sent as-is arrives as mojibake in most clients.
    private static func mimeData(_ message: Message) -> String {
        let subject = "=?UTF-8?B?\(base64(message.subject))?="
        // A line holding a single "." ends the DATA section, so any line starting
        // with one is escaped by doubling it.
        let body = message.body
            .components(separatedBy: "\n")
            .map { $0.hasPrefix(".") ? "." + $0 : $0 }
            .joined(separator: "\r\n")
        // A name beside the address is what most clients show in place of the
        // mailbox, so it is encoded the same way the subject is — a Chinese name
        // sent as-is arrives as mojibake.
        let from = message.senderName.isEmpty
            ? message.from
            : "=?UTF-8?B?\(base64(message.senderName))?= <\(message.from)>"
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
