import Foundation

/// Email, sent straight to the mailbox's own SMTP server.
///
/// The other services all speak HTTP; this one opens a socket. Everything it needs
/// is in ``SMTPClient`` — credentials, TLS, the SMTP conversation, and the message
/// itself — and it delivers asynchronously, so the engine hands it a closure rather
/// than a request.
///
/// Servers are known by domain. Nine providers cover almost every mailbox someone
/// would forward to, and each entry is the host and port its own documentation
/// gives; a mailbox on anything else needs the server typed in, which is why the
/// field is there.
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
            EmailPrefKey.to: "",
            EmailPrefKey.host: "",
            EmailPrefKey.port: "",
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
        // One key per address row is where the page stores what was typed, so the
        // list is assembled from those. An instance from before the rows existed
        // left either a joined string or an array under `toEmail`; both are read
        // as a fallback, and the page rewrites them as rows on its next visit.
        var to: [String] = []
        var row = 0
        while let text = config.raw["\(EmailPrefKey.recipientPrefix)\(row)"] as? String {
            let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !address.isEmpty { to.append(address) }
            row += 1
        }
        if to.isEmpty {
            if let array = config.raw[EmailPrefKey.to] as? [String] {
                to = array.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            } else if let text = config.raw[EmailPrefKey.to] as? String {
                to = splitAddresses(text)
            }
        }
        let (host, port) = server(
            for: from,
            overrideHost: config.raw.string(EmailPrefKey.host, default: ""),
            overridePort: config.raw.string(EmailPrefKey.port, default: "")
        )
        // A message with no address has nowhere to go; the pipeline reports it as
        // nothing to send, the same as a webhook with no URL.
        guard !host.isEmpty, !to.isEmpty else { return nil }

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
            host: host,
            port: port,
            username: from,
            password: password,
            from: from,
            recipients: to,
            subject: typedSubject.isEmpty ? context.displayTitle : typedSubject,
            senderName: senderName,
            body: lines.joined(separator: "\n")
        )
    }

    /// The SMTP server for a sender address, or the one the user typed.
    ///
    /// The override wins in both fields, so a provider that moves its port can be
    /// worked around without a release — and a mailbox on an unlisted domain is
    /// only usable through it.
    private static func server(
        for address: String, overrideHost: String, overridePort: String
    ) -> (String, UInt16) {
        let typedHost = overrideHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedPort = UInt16(overridePort.trimmingCharacters(in: .whitespaces))

        if !typedHost.isEmpty {
            return (typedHost, typedPort ?? 465)
        }

        guard let at = address.lastIndex(of: "@") else { return ("", 465) }
        let domain = String(address[address.index(after: at)...]).lowercased()

        // Port 465 for all of them: every one of these speaks implicit TLS there,
        // and offering 587 as well would mean a second code path with STARTTLS for
        // no mailbox that needs it.
        let known: [String: String] = [
            "qq.com": "smtp.qq.com",
            "foxmail.com": "smtp.qq.com",
            "vip.qq.com": "smtp.qq.com",
            "exmail.qq.com": "smtp.exmail.qq.com",
            "gmail.com": "smtp.gmail.com",
            "163.com": "smtp.163.com",
            "126.com": "smtp.126.com",
            "yeah.net": "smtp.yeah.net",
            "sina.com": "smtp.sina.com",
            "sina.cn": "smtp.sina.cn",
            "139.com": "smtp.139.com",
            "189.cn": "smtp.189.cn",
            "icloud.com": "smtp.mail.me.com",
            "outlook.com": "smtp-mail.outlook.com",
            "hotmail.com": "smtp-mail.outlook.com",
            "live.com": "smtp-mail.outlook.com",
        ]
        return (known[domain] ?? "", typedPort ?? 465)
    }

    /// Splits a recipient list, accepting the separators a pasted list carries.
    private static func splitAddresses(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",，;； ")
        return text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// The keys this service's settings are stored under.
/// The key the message is carried under, between the service and the sender.
enum EmailState {
    static let message = "emailMessage"
}

enum EmailPrefKey {
    static let from = "fromEmail"
    /// Each address row is stored under this prefix plus its index; the page and
    /// the service both assemble the list from those keys.
    static let recipientPrefix = "emailRecipient"
    static let senderName = "senderName"
    static let subject = "subject"
    static let password = "password"
    static let to = "toEmail"
    static let host = "host"
    static let port = "port"
}
