import UIKit

/// The scripting guide presented from a definition page.
///
/// A sheet, not a pushed page: it answers one question ("what does a script look
/// like?") and goes away. Half height, scrollable, with a copy button for the
/// prompt a user pastes to an AI assistant along with the result they want.
enum ScriptingGuide {

    /// The prompt a user copies and pastes to an AI assistant, together with the
    /// result they want.
    ///
    /// Written for the machine that will read it: the API surface, the runtime's
    /// exact guarantees (async works; fetch is real; one push per send), and the
    /// output shape. Anything the assistant has to guess is a support request
    /// later, so the prompt states it instead.
    static let aiPrompt = """
    Write a JavaScript script for Pusher, an iOS tweak that forwards
    notifications to a push service.

    Runtime: JavaScriptCore on iOS. The script runs once per notification, as an
    async function, so top-level await works. Modern syntax (const/let, arrow
    functions, destructuring, optional chaining, async/await, Promise) is
    available. There is no DOM, no Node APIs, no timers.

    Injected values:
    - bullet — the notification:
        bullet.deviceName  string  this iPhone's name
        bullet.appName     string  the sending app's display name
        bullet.appID       string  the sending app's bundle ID
        bullet.title       string  may be empty
        bullet.subtitle    string  may be empty
        bullet.message     string  the notification body
        bullet.date        string  formatted timestamp
        bullet.icon        string  base64 PNG of the app icon
        bullet.image       string  base64 of the notification's attachment image

    Injected functions:
    - push(req) — sends a request. Call once to send, several times to send
      several, or never to skip this notification. req is:
        { url: string (required),
          method: "GET" | "POST" | ... (default "POST"),
          headers: { name: value },
          body: object (sent as JSON) or string (sent as-is) }
    - fetch(url, init) — real HTTP, same semantics as the web platform:
      returns a Promise of a Response with ok, status, headers, url, and
      json()/text(). init accepts method, headers, body.
    - localStorage.getItem/setItem/removeItem/clear — persists per service.
    - console.log/info/warn/error — shown in the script editor's Run output.

    Rules:
    - Call push() to forward the notification; without it, nothing is sent.
    - The script must finish within 2 seconds.
    - Do not use while(true) loops or blocking patterns.

    Output ONLY the JavaScript source, no markdown fences, no explanation.
    """

    /// Presents the guide over `controller`.
    static func present(from controller: UIViewController) {
        let host = UIViewController()
        host.modalPresentationStyle = .pageSheet
        host.view.backgroundColor = .systemGroupedBackground
        host.navigationItem.title = "Scripting Guide".localized

        let copy = UIAction(title: "Copy AI Prompt".localized) { [weak host] _ in
            UIPasteboard.general.string = aiPrompt
            let alert = UIAlertController(
                title: nil,
                message: "AI prompt copied. Paste it into your AI assistant and "
                    + "describe the result you want.".localized,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Ok".localized, style: .default))
            host?.present(alert, animated: true)
        }
        host.navigationItem.rightBarButtonItems = [
            UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak host] _ in
                host?.dismiss(animated: true)
            }),
            UIBarButtonItem(image: UIImage(systemName: "doc.on.doc"),
                             menu: UIMenu(children: [copy])),
        ]

        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(scrollView)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        func section(_ title: String, _ body: String) {
            let label = UILabel()
            label.text = title
            label.font = .preferredFont(forTextStyle: .headline)
            label.numberOfLines = 0
            stack.addArrangedSubview(label)

            let text = UILabel()
            text.text = body
            text.font = .preferredFont(forTextStyle: .subheadline)
            text.textColor = .secondaryLabel
            text.numberOfLines = 0
            stack.addArrangedSubview(text)
        }

        section("How a script works".localized, (
            "The script runs once per notification. Call push(req) to send a "
                + "request — call it more than once to send several, or not at "
                + "all to skip this notification. Top-level await works, so you "
                + "can fetch a token before sending."
        ))

        section("bullet — the notification".localized, (
            "bullet.deviceName, bullet.appName, bullet.appID, bullet.title, "
                + "bullet.subtitle, bullet.message, bullet.date are strings. "
                + "bullet.icon and bullet.image are base64 PNG data (strings), "
                + "present when the notification has them."
        ))

        section("Other functions".localized, (
            "fetch(url, init) — real HTTP, like the browser's fetch. Returns a "
                + "Response with ok, status, and json()/text().\n"
                + "localStorage — persists values between notifications, per "
                + "service.\n"
                + "console.log(...) — shown in the editor's Run output."
        ))

        section("Limits".localized, (
            "The script must finish within 2 seconds, so no long loops. Fetch "
                + "runs for real: during a run, requests are actually sent."
        ))

        let promptNote = UILabel()
        promptNote.text = "Let an AI write it".localized
        promptNote.font = .preferredFont(forTextStyle: .headline)
        promptNote.numberOfLines = 0
        stack.addArrangedSubview(promptNote)

        let promptBody = UILabel()
        promptBody.text = "Tap the copy button (top right) to copy a prompt that "
            + "describes this API. Paste it into your AI assistant and add the "
            + "result you want — which service to send to, what to filter, and so "
            + "on — then paste the JavaScript it writes back here.".localized
        promptBody.font = .preferredFont(forTextStyle: .subheadline)
        promptBody.textColor = .secondaryLabel
        promptBody.numberOfLines = 0
        stack.addArrangedSubview(promptBody)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40),
        ])

        controller.present(host, animated: true)
    }
}
