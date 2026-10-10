import UIKit

/// The scripting guide presented from a definition page.
///
/// A sheet, not a pushed page: it answers one question ("what does a script look
/// like?") and goes away. Half height, scrollable, with a copy button for the
/// prompt a user pastes to an AI assistant along with the result they want.
enum ScriptingGuide {

    /// Presents the guide over `controller`.
    /// - Parameter declaredFields: the settings the service declares, so the
    ///   `pref` block shows this service's own fields and nothing else. Empty for
    ///   a service that declares none, whose script has no `pref` to read.
    static func present(
        from controller: UIViewController,
        declaredFields: [ConfigField] = []
    ) {
        var blocks: [GuideSheet.Block] = [
                .heading("How a script works".localized),
                .text(("The script runs once per notification. Call push(req) to "
                    + "send a request — call it more than once to send several, "
                    + "or not at all to skip this notification. Top-level await "
                    + "works, so you can fetch a token before sending.").localized),

                .heading("bullet — the notification".localized),
                .text(("Read the notification's fields and decide. bullet.icon and "
                    + "bullet.image are undefined unless the service asks for the "
                    + "icon or the image.").localized),
                .code(JavaScriptAPI.scriptBullet),

                .heading("Functions".localized),
                .code(JavaScriptAPI.scriptFunctions),

                .heading("Settings".localized),
                .text(("The service's own settings — a key, a URL, a flag — are "
                    + "declared on the service and filled in on each service that "
                    + "uses it. The script reads them from pref, so one script can "
                    + "serve several services with different values.").localized),

                .heading("Where variables live".localized),
                .text(("The script runs fresh for every notification. A top-level "
                    + "let or const belongs to that run alone and is gone by the "
                    + "next one — that is what keeps one notification's data out "
                    + "of another's.\n"
                    + "localStorage is how a value survives to the next "
                    + "notification: it is kept per service, so two services of "
                    + "the same type do not share it.").localized),

                .heading("Limits".localized),
                .text(("The script must finish within 2 seconds, so no long loops. "
                    + "Fetch runs for real: during a run, requests are actually "
                    + "sent.").localized),

                .heading("Let an AI write it".localized),
                .text(("Tap Copy AI Prompt (top right). It is a system prompt: it "
                    + "teaches the assistant this API. The dialog asks what you "
                    + "want the script to do — write it there, paste the whole "
                    + "thing to your assistant, then paste the JavaScript it "
                    + "writes back here.").localized),
        ]

        // The `pref` block only when the service declares fields, and its
        // types are the ones actually declared: a prompt that showed an invented
        // setting would have the AI write a script that reads a field the
        // service does not have.
        if let pref = JavaScriptAPI.scriptPrefs(declared: declaredFields) {
            if let settingsHeading = blocks.lastIndex(where: {
                if case .heading("Settings".localized) = $0 { return true }
                return false
            }) {
                blocks.insert(.code(pref), at: settingsHeading + 2)
            }
        }

        GuideSheet.present(
            from: controller,
            title: "Scripting Guide".localized,
            blocks: blocks,
            prompt: { JavaScriptAPI.scriptPrompt(requirement: $0, declared: declaredFields) }
        )
    }
}
