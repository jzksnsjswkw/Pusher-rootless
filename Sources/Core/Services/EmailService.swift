import Foundation

/// Email, sent straight to the mailbox's own SMTP server.
///
/// The other services all speak HTTP; this one opens a socket. Everything it needs
/// is in ``SMTPClient`` — credentials, TLS, the SMTP conversation, and the message
/// itself — and it delivers asynchronously, so the engine hands it a closure rather
/// than a request.
///
/// Servers are known by domain. The providers disagree about which port carries
/// which kind of encryption — the Chinese ones and Gmail take implicit TLS on 465,
/// while Outlook has no implicit port at all and offers STARTTLS on 587 — so each
/// entry carries its own port and mode. A mailbox on anything else needs both
/// typed in.
public enum EmailService: PushService {
    public static let serviceName = "Email"

    public static func url(eventName: String, dbName: String, serverURL: String) -> String {
        // Not an HTTP request, so there is no endpoint to report. `request()`
        // carries the message in `state` and the sender has a branch for it.
        ""
    }

    public static func defaultPrefs() -> [String: Any] {
        [
            EmailPrefKey.from: "",
            EmailPrefKey.password: "",
            EmailPrefKey.host: "",
            EmailPrefKey.port: "",
            // Empty means "take it from the address", which is the table below.
            EmailPrefKey.security: "",
            EmailPrefKey.senderName: "",
            EmailPrefKey.subject: "",
        ]
    }

    /// The request the pipeline carries.
    ///
    /// Not an HTTP request: like a shortcut, this one is delivered by its own
    /// branch in the sender. The message travels in `state`, which is the field
    /// meant for information a service hands to its delivery path.
    public static func request(context: BulletinContext, config: ServiceConfig) -> PushRequest? {
        guard let message = message(context: context, config: config) else { return nil }
        let request = PushRequest(urlString: "", infoDict: [:])
        request.state[EmailState.message] = message
        return request
    }

    /// What the sender should actually deliver.
    ///
    /// Nil when a required field is missing, so the pipeline reports "nothing to
    /// send" the same way it does for a webhook with no URL.
    static func message(context: BulletinContext, config: ServiceConfig) -> SMTPClient.Message? {
        let from = config.raw.string(EmailPrefKey.from, default: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let password = config.raw.string(EmailPrefKey.password, default: "")
        guard !from.isEmpty, !password.isEmpty else { return nil }

        // One key per address row is where the page stores what was typed, so the
        // list is assembled from those. An instance from before the rows existed
        // left a joined string under `toEmail`, which is read as a fallback.
        var to: [String] = []
        var row = 0
        while let text = config.raw["\(EmailPrefKey.recipientPrefix)\(row)"] as? String {
            let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !address.isEmpty { to.append(address) }
            row += 1
        }
        if to.isEmpty, let text = config.raw[EmailPrefKey.to] as? String {
            to = text.components(separatedBy: CharacterSet(charactersIn: ",，;； "))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        let typedHost = config.raw.string(EmailPrefKey.host, default: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let typedPort = UInt16(config.raw.string(EmailPrefKey.port, default: "")
            .trimmingCharacters(in: .whitespaces))
        let typedSecurity = EmailSecurity(
            rawValue: config.raw.string(EmailPrefKey.security, default: "")
        )

        let endpoint = server(
            for: from, host: typedHost, port: typedPort, security: typedSecurity
        )
        guard !endpoint.host.isEmpty, !to.isEmpty else { return nil }

        let senderName = config.raw.string(EmailPrefKey.senderName, default: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // The subject defaults to the composed title — "微信: 西瓜猪" — so the
        // mailbox list shows the same line the phone's notification did.
        //
        // A subject the user typed replaces it, and the composed title then moves
        // into the body: the app and the title are what the notification was
        // about, and a custom subject that pushed them out would lose it.
        let typedSubject = config.raw.string(EmailPrefKey.subject, default: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []
        if !typedSubject.isEmpty {
            lines.append(context.displayTitle)
        }
        if let subtitle = context.subtitle, !subtitle.isEmpty {
            lines.append(subtitle)
        }
        if let message = context.message, !message.isEmpty {
            lines.append(message)
        }

        return SMTPClient.Message(
            host: endpoint.host,
            port: endpoint.port,
            username: from,
            password: password,
            from: from,
            recipients: to,
            subject: typedSubject.isEmpty ? context.displayTitle : typedSubject,
            senderName: senderName,
            body: lines.joined(separator: "\n"),
            security: endpoint.security
        )
    }

    /// The server for a sender address, or the one the user typed.
    ///
    /// A typed host wins outright, and carries its own port and mode with it: a
    /// mailbox on an unlisted domain is only usable by typing these, so nothing is
    /// second-guessed once they are there.
    private static func server(
        for address: String,
        host: String,
        port: UInt16?,
        security: EmailSecurity?
    ) -> (host: String, port: UInt16, security: EmailSecurity) {
        if !host.isEmpty {
            // A typed host takes its mode as typed, and "Default" there means the
            // conventional port for encrypted submission — there is no address in
            // the table to consult for a server the user named themselves.
            let mode = security ?? .starttls
            return (host, port ?? mode.defaultPort, mode)
        }

        guard let at = address.lastIndex(of: "@") else {
            return ("", 465, .tls)
        }
        let domain = String(address[address.index(after: at)...]).lowercased()

        let known: [String: (host: String, port: UInt16, security: EmailSecurity)] = [
            "qq.com": ("smtp.qq.com", 465, .tls),
            "foxmail.com": ("smtp.qq.com", 465, .tls),
            "vip.qq.com": ("smtp.qq.com", 465, .tls),
            "exmail.qq.com": ("smtp.exmail.qq.com", 465, .tls),
            "gmail.com": ("smtp.gmail.com", 465, .tls),
            "163.com": ("smtp.163.com", 465, .tls),
            "126.com": ("smtp.126.com", 465, .tls),
            "yeah.net": ("smtp.yeah.net", 465, .tls),
            "sina.com": ("smtp.sina.com", 465, .tls),
            "sina.cn": ("smtp.sina.cn", 465, .tls),
            "139.com": ("smtp.139.com", 465, .tls),
            "189.cn": ("smtp.189.cn", 465, .tls),
            "icloud.com": ("smtp.mail.me.com", 465, .tls),
            // The only provider here with no implicit-TLS port: 587 is all it has.
            "outlook.com": ("smtp-mail.outlook.com", 587, .starttls),
            "hotmail.com": ("smtp-mail.outlook.com", 587, .starttls),
            "live.com": ("smtp-mail.outlook.com", 587, .starttls),
        ]
        guard let entry = known[domain] else {
            return ("", 465, .tls)
        }
        return (entry.host, port ?? entry.port, security ?? entry.security)
    }
}

/// How the conversation is encrypted.
///
/// `plain` exists because some servers sit behind a VPN or on a private network and
/// offer neither — and because a user diagnosing a connection needs a way to tell
/// a TLS problem from an authentication one. It is the last option on the list and
/// says what it means.
enum EmailSecurity: String {
    /// TLS from the first byte. Port 465.
    case tls
    /// Begin in the clear, then `STARTTLS`. Port 587.
    case starttls
    /// No encryption at all. Port 25.
    case plain

    /// The port each mode is conventionally served on, used when the user has not
    /// said otherwise.
    var defaultPort: UInt16 {
        switch self {
        case .tls: return 465
        case .starttls: return 587
        case .plain: return 25
        }
    }
}

/// The key the message is carried under, between the service and the sender.
enum EmailState {
    static let message = "emailMessage"
}

enum EmailPrefKey {
    static let from = "fromEmail"
    /// Each address row is stored under this prefix plus its index.
    static let recipientPrefix = "emailRecipient"
    /// The joined form the single-field era wrote, still read as a fallback.
    static let to = "toEmail"
    static let password = "password"
    static let host = "host"
    static let port = "port"
    static let security = "security"
    static let senderName = "senderName"
    static let subject = "subject"
}
