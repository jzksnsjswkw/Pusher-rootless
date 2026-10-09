import UIKit

/// The scripting guide presented from a definition page.
///
/// A sheet, not a pushed page: it answers one question ("what does a script look
/// like?") and goes away. Half height, scrollable, with a copy button for the
/// prompt a user pastes to an AI assistant along with the result they want.
enum ScriptingGuide {

    /// The prompt a user copies.
    ///
    /// It is a *system* prompt: it fixes the API contract and the output format.
    /// The user's own requirement is not part of it — the trailing instruction
    /// tells them to append what they want, and the placeholder below is what
    /// they replace. Splitting this way is what keeps the API description and
    /// the user's wish from tangling.
    ///
    /// Localized, because the user pastes it to an assistant they are chatting
    /// with in their own language.
    static func aiPrompt(requirement: String) -> String {
        let placeholder = "★ Write here what you want the script to do."
        let requirementLine = requirement
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filled = requirementLine.isEmpty ? placeholder : requirementLine

        return ("This is a SYSTEM PROMPT. Everything before the marker below is "
            + "fixed context you must follow; after the marker is what the user "
            + "wants. Do not answer the system part — generate code only.").localized
            + "\n\n"
            + ("Write a JavaScript script for Pusher, an iOS tweak that forwards "
                + "notifications to a push service.").localized + "\n\n"
            + ("Runtime: JavaScriptCore on iOS. The script runs once per "
                + "notification, as an async function, so top-level await works. "
                + "Modern syntax (const/let, arrow functions, destructuring, "
                + "optional chaining, async/await, Promise) is available. There "
                + "is no DOM, no Node APIs, no timers.").localized + "\n\n"
            + "Injected values:".localized + "\n"
            + ("- bullet — the notification:\n"
                + "    bullet.deviceName  string  this iPhone's name\n"
                + "    bullet.appName     string  the sending app's display name\n"
                + "    bullet.appID       string  the sending app's bundle ID\n"
                + "    bullet.title       string  may be empty\n"
                + "    bullet.subtitle    string  may be empty\n"
                + "    bullet.message     string  the notification body\n"
                + "    bullet.date        string  formatted timestamp\n"
                + "    bullet.icon        string  base64 PNG of the app icon\n"
                + "    bullet.image       string  base64 of the attachment image").localized + "\n\n"
            + "Injected functions:".localized + "\n"
            + ("- push(req) — sends a request. Call once to send, several times "
                + "to send several, or never to skip this notification. req:\n"
                + "      { url: string (required),\n"
                + "        method: \"GET\" | \"POST\" | ... (default \"POST\"),\n"
                + "        headers: { name: value },\n"
                + "        body: object (sent as JSON) or string (sent as-is) }\n"
                + "- fetch(url, init) — real HTTP, web-platform semantics: a "
                + "Promise of a Response with ok, status, headers, url, and "
                + "json()/text().\n"
                + "- localStorage.getItem/setItem/removeItem/clear — persists "
                + "per service.\n"
                + "- console.log/info/warn/error — shown in the editor's Run "
                + "output.\n"
                + "- Each notification is a separate run: variables declared at "
                + "the top level of the script do not survive to the next one. "
                + "To keep a value across notifications, put it in "
                + "localStorage.").localized + "\n\n"
            + "Rules:".localized + "\n"
            + ("- Call push() to forward the notification; without it, nothing "
                + "is sent.\n"
                + "- The script must finish within 2 seconds.\n"
                + "- Do not use while(true) loops or blocking patterns.").localized + "\n\n"
            + ("Output ONLY the JavaScript source — no markdown fences, no "
                + "explanation, no commentary.").localized + "\n\n"
            + "────────────────\n"
            + ("USER REQUIREMENT — replace the line below with what you want, "
                + "or write your requirement after this prompt:").localized + "\n"
            + filled
    }

    /// The copy action's target, which a bar button item needs to stay alive.
    /// The sheet's actions. A bar button item holds its target weakly, so the
    /// target lives as an associated object on the presented controller rather
    /// than in this method's scope.
    private final class Target: NSObject {
        weak var host: UIViewController?

        @objc func close() {
            host?.dismiss(animated: true)
        }

        /// Asks for the user's requirement, then puts the prompt on the
        /// pasteboard. The field is optional: a user who already appended their
        /// requirement can copy the bare prompt.
        @objc func copyPrompt() {
            let alert = UIAlertController(
                title: "Copy AI Prompt".localized,
                message: ("The prompt tells the AI the API. Add what you want "
                    + "the script to do below — the AI only writes code, it does "
                    + "not invent your requirement.").localized,
                preferredStyle: .alert
            )
            alert.addTextField { field in
                field.placeholder = "What should the script do?".localized
                field.autocorrectionType = .yes
            }
            alert.addAction(UIAlertAction(title: "Copy".localized, style: .default) { _ in
                UIPasteboard.general.string = ScriptingGuide.aiPrompt(
                    requirement: alert.textFields?.first?.text ?? ""
                )
                let done = UIAlertController(
                    title: nil,
                    message: "Copied. Paste it into your AI assistant.".localized,
                    preferredStyle: .alert
                )
                done.addAction(UIAlertAction(title: "Ok".localized, style: .default))
                self.host?.present(done, animated: true)
            })
            alert.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel))
            host?.present(alert, animated: true)
        }
    }

    private enum AssociatedKeys {
        static var target = 0
    }

    /// Presents the guide over `controller`.
    static func present(from controller: UIViewController) {
        let host = UIViewController()
        let target = Target()
        target.host = host
        host.modalPresentationStyle = .pageSheet
        host.view.backgroundColor = .systemGroupedBackground
        host.navigationItem.title = "Scripting Guide".localized

        // Plain bar button items with a real target: systemItem plus
        // primaryAction did not render on this iOS line, and an earlier draft
        // pointed the copy item at the host, which has no such selector.
        host.navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Copy AI Prompt".localized, style: .plain,
                            target: target, action: #selector(Target.copyPrompt)),
            UIBarButtonItem(title: "Close".localized, style: .plain,
                            target: target, action: #selector(Target.close)),
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
        ).localized)

        section("bullet — the notification".localized, (
            "bullet.deviceName, bullet.appName, bullet.appID, bullet.title, "
            + "bullet.subtitle, bullet.message, bullet.date are strings. "
            + "bullet.icon and bullet.image are base64 PNG data (strings), "
            + "present when the notification has them."
        ).localized)

        section("Where variables live".localized,
                ("The script runs fresh for every notification. A top-level "
                    + "let or const belongs to that run alone and is gone by the "
                    + "next one — that is what keeps one notification's data out "
                    + "of another's.\n"
                    + "localStorage is the way to carry a value across "
                    + "notifications: it is kept per service, so two services of "
                    + "the same type do not share it.").localized)

        section("Other functions".localized, (
            "fetch(url, init) — real HTTP, like the browser's fetch. Returns "
            + "a Response with ok, status, and json()/text().\n"
            + "localStorage — persists values between notifications, per "
            + "service.\n"
            + "console.log(...) — shown in the editor's Run output."
        ).localized)

        section("Limits".localized, (
            "The script must finish within 2 seconds, so no long loops. Fetch "
            + "runs for real: during a run, requests are actually sent."
        ).localized)

        let promptNote = UILabel()
        promptNote.text = "Let an AI write it".localized
        promptNote.font = .preferredFont(forTextStyle: .headline)
        promptNote.numberOfLines = 0
        stack.addArrangedSubview(promptNote)

        let promptBody = UILabel()
        promptBody.text = ("Tap Copy AI Prompt (top right). The prompt is a "
            + "system prompt — it teaches the AI this API. The copy dialog asks "
            + "what you want the script to do; write it there, then paste the "
            + "whole thing to your AI assistant and paste the JavaScript it "
            + "writes back here.").localized
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

        // The target outlives the presentation: a bar button holds its target
        // weakly, so the copy action would die with this method's scope.
        objc_setAssociatedObject(host, &AssociatedKeys.target, target,
                                 .OBJC_ASSOCIATION_RETAIN)

        // A bare view controller shows no navigation bar, and its
        // navigationItem — title and both buttons — is never displayed.
        let navigation = UINavigationController(rootViewController: host)
        navigation.modalPresentationStyle = .pageSheet
        controller.present(navigation, animated: true)
    }
}

private enum AssociatedKeys {
    static var target = 0
}
