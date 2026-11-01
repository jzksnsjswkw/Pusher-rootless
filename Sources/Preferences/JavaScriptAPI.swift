import UIKit

/// The API a service script sees, written as TypeScript declarations.
///
/// Declarations rather than prose because this text is read twice: by a person
/// scanning for a field name, and by an AI assistant that is about to write code
/// against it. A type is the one form that serves both — it says what exists,
/// what type it is, and what it means, with no sentence in between to misread.
///
/// The comments are localized at the point the block is built, not stored here,
/// so the same declaration can be shown in either language.
enum JavaScriptAPI {

    /// The `bullet` a *script* gets: everything the notification carries.
    static var scriptBullet: String {
        """
        bullet: {
          deviceName: string   // \("this iPhone's name".localized)
          appName: string      // \("the sending app's display name".localized)
          appID: string        // \("the sending app's bundle ID".localized)
          title: string        // \("the notification title, may be empty".localized)
          subtitle: string     // \("the notification subtitle, may be empty".localized)
          message: string      // \("the notification body".localized)
          date: string         // \("a formatted timestamp".localized)
          icon?: string        // \("base64 PNG of the app icon, when there is one".localized)
          image?: string       // \("base64 PNG of the attachment, when there is one".localized)
          sim?: {              // \("only in SMS notifications".localized)
            slot: number        // \("the slot number, 1 or 2".localized)
            phoneNumber: string // \("the receiving card's number".localized)
            label: string       // \("the nickname set in Global Settings".localized)
          }
        }
        """
    }

    /// The `device` a *script* gets: the same object a hook sees.
    ///
    /// Which notification arrives does not depend on it, but what a script does
    /// with one can — only forward while charging, stay quiet on cellular.
    static var scriptDevice: String {
        """
        device: {                // \("read-only".localized)
          name: string            // \("this iPhone's name".localized)
          osVersion: string       // \("e.g. 16.5".localized)
          locked: boolean         // \("the screen is locked".localized)
          wifi: boolean           // \("on Wi-Fi".localized)
          cellular: boolean       // \("on cellular data".localized)
          online: boolean         // \("has any network at all".localized)
          network: "wifi" | "cellular" | "none"
          battery?: number        // \("0 to 1, absent when unreadable".localized)
          charging: boolean       // \("plugged in".localized)
          batteryState: "unplugged" | "charging" | "full"
        }
        """
    }

    /// The `pref` object a *script* gets: the settings its service declared.
    ///
    /// Rendered from the declarations rather than written out, because unlike
    /// `bullet` and `fetch` these are the service's own fields: an AI writing a
    /// script should see `pref.apiKey: string` and nothing else, so it cannot
    /// invent a setting the user never declared.
    ///
    /// - Returns: `nil` when the service declares nothing, since a script for
    ///   such a service has no `pref` to read.
    static func scriptPrefs(declared: [ConfigField]) -> String? {
        let fields = declared.filter { !$0.key.isEmpty }
        guard !fields.isEmpty else { return nil }
        var lines = ["pref: {"]
        for field in fields {
            let type = field.kind == .toggle ? "boolean" : "string"
            var comment = field.displayTitle
            if field.defaultBool, field.kind == .toggle {
                comment += " (" + "default on".localized + ")"
            } else if !field.defaultString.isEmpty, field.kind == .text {
                comment += " (" + String(format: "default %@".localized, field.defaultString) + ")"
            }
            lines.append("  \(field.key): \(type)   // \(comment)")
        }
        lines.append("}")
        lines.append("// " + ("Set on each service, not here: your script only reads it.".localized))
        return lines.joined(separator: "\n")
    }

    /// The functions a *script* can call.
    static var scriptFunctions: String {
        """
        push(req: {
          url: string                              // \("where to send it".localized)
          method?: "GET" | "POST" | "PUT" | ...    // \("default \"POST\"".localized)
          headers?: { [name: string]: string }
          body?: object | string                   // \("an object is sent as JSON".localized)
        }): Response
        // \("Sends now and returns the response, so you can check res.ok and decide whether to push again.".localized)

        push({ shortcut: string, payload: object }): Response
        // \("Runs one of your Shortcuts instead of sending a request. payload is required and is passed to it exactly as written.".localized)

        fetch(url: string, init?: object): Promise<Response>
        // \("Real HTTP: Response has ok, status, headers, url, json() and text().".localized)

        localStorage: {
          getItem(key: string): string | null
          setItem(key: string, value: string): void
          removeItem(key: string): void
          clear(): void
        }
        // \("Kept per service, and persists between notifications.".localized)

        console.log / console.warn / console.error
        // \("Shown in the editor's Run output.".localized)

        """
    }

    /// The `bullet` a *hook* gets.
    ///
    /// The same fields as a script's, minus the two images: a hook decides
    /// whether and how a notification is forwarded, and the icon and attachment
    /// are the payload's business — resolving them for a hook would cost an icon
    /// render and an image decode on every notification, for a value it could
    /// only pass on unchanged.
    static var hookBullet: String {
        """
        bullet: {
          appID: string       // 发送方应用的包名
          appName: string     // 发送方应用的显示名称
          title: string       // 可改写——keep() 会把改动传下去
          subtitle: string    // 可改写
          message: string     // 可改写
          date: string        // 格式化时间
          sim?: {             // \("only in SMS notifications".localized)
            slot: number        // \("the slot number, 1 or 2".localized)
            phoneNumber: string // \("the receiving card's number".localized)
            label: string       // \("the nickname set in Global Settings".localized)
          }
        }
        """
    }

    /// The `device` a hook gets. Read-only.
    static var hookDevice: String {
        """
        device: {                // \("read-only".localized)
          name: string            // \("this iPhone's name".localized)
          osVersion: string       // \("e.g. 16.5".localized)
          locked: boolean         // \("the screen is locked".localized)
          wifi: boolean           // \("on Wi-Fi".localized)
          cellular: boolean       // \("on cellular data".localized)
          online: boolean         // \("has any network at all".localized)
          network: "wifi" | "cellular" | "none"
          battery?: number        // \("0 to 1, absent when unreadable".localized)
          charging: boolean       // \("plugged in".localized)
          batteryState: "unplugged" | "charging" | "full"
        }
        """
    }

    /// The decision a hook returns.
    static var hookKeep: String {
        """
        keep(options?: { force?: boolean }): void

        // \("keep()                 continue with the notification".localized)
        // \("keep({ force: true })  continue even if a filter would block it".localized)
        // \("return without calling keep()   drop this notification".localized)
        """
    }

    /// The functions a *hook* can call. No `push`: a hook cannot send.
    static var hookFunctions: String {
        """
        fetch(url: string, init?: object): Promise<Response>
        // \("Real HTTP — the same fetch a script gets.".localized)

        localStorage: { … }
        // \("Kept per service and per hook, so the two hooks do not share it.".localized)

        console.log / console.warn / console.error
        // \("Shown in the editor's Run output.".localized)

        """
    }

    // MARK: - The AI prompts

    /// The prompt for writing a service script.
    ///
    /// - Parameter declared: the settings the service declares, so the prompt
    ///   teaches exactly the `pref` fields that exist. The AI writes against the
    ///   real ones; it is not left to guess a name the user never declared.
    static func scriptPrompt(requirement: String, declared: [ConfigField] = []) -> String {
        let prefs = scriptPrefs(declared: declared).map { $0 + "\n" } ?? ""
        let rule = declared.isEmpty ? "" :
            "- " + ("Read the user's settings from pref, never hard-code a key or "
                + "URL that a pref field already carries.").localized + "\n"
        return AIRequirement.preamble + "\n\n"
            + ("Write a JavaScript script for Pusher, an iOS tweak that forwards "
                + "notifications to a push service.").localized + "\n\n"
            + ("Runtime: JavaScriptCore on iOS. The script runs once per "
                + "notification as an async function, so top-level await works. "
                + "Modern syntax (const/let, arrow functions, destructuring, "
                + "optional chaining, async/await, Promise) is available. There "
                + "is no DOM, no Node APIs and no timers.").localized + "\n\n"
            + "API:".localized + "\n" + scriptBullet + "\n" + scriptDevice + "\n"
            + prefs + scriptFunctions + "\n"
            + ("Rules:".localized + "\n"
                + rule
                + "- " + "Call push() to forward the notification; without it nothing is sent.".localized + "\n"
                + "- " + "The script must finish within 2 seconds.".localized + "\n"
                + "- " + "Do not use while(true) loops or blocking patterns.".localized) + "\n\n"
            + ("Each notification is a separate run: a variable declared at the top "
                + "level does not survive to the next one. Use localStorage for that.").localized
            + "\n\n"
            + ("Output ONLY the JavaScript source — no markdown fences, no "
                + "explanation, no commentary.").localized + "\n\n"
            + AIRequirement.tail(requirement: requirement)
    }

    /// The prompt for writing an instance hook.
    /// The prompt for a hook.
    ///
    /// Written for someone who has never seen a hook and does not know what one
    /// could be used for, which is most people the sheet is shown to. So it opens
    /// with what the thing does in plain language and three worked examples, and
    /// only then says what the code has access to.
    ///
    /// The AI is told to ask before writing. A user who reached this sheet without
    /// a clear idea would otherwise get a plausible script for a problem they do
    /// not have, and have no way to tell.
    static func hookPrompt(requirement: String) -> String {
        AIRequirement.hookPreamble + "\n\n"
            + ("What a hook is".localized + "\n"
                + ("Pusher forwards your phone's notifications to another device. "
                    + "A hook is a small piece of JavaScript that sits in the middle "
                    + "of that: it can decide whether a notification gets forwarded, "
                    + "and it can rewrite the text before it goes out.").localized
                + "\n\n"
                + ("You do not need to be a programmer to use one — describe what "
                    + "you want in plain words and the AI writes it for you. Some "
                    + "things people use hooks for:").localized + "\n"
                + "- " + ("Only forward verification codes. Everything else from "
                    + "that app stays on the phone.").localized + "\n"
                + "- " + ("Leave out the app name some notifications put in front "
                    + "of the title, so the forwarded message reads cleanly.").localized + "\n"
                + "- " + ("Skip forwarding at night, or while the screen is "
                    + "unlocked and you can already see it.").localized + "\n"
                + "- " + ("Collapse a burst: the same sender can only reach you "
                    + "once every few minutes.").localized) + "\n\n"
            + ("A hook cannot send anything by itself — there is no push(). It only "
                + "lets the notification through, optionally changed. Sending is "
                + "what the service already does.").localized + "\n\n"
            + "API:".localized + "\n" + hookBullet + "\n" + hookDevice + "\n"
            + hookKeep + "\n" + hookFunctions + "\n"
            + ("Rules:".localized + "\n"
                + "- " + "Call keep() to let the notification through; returning without it drops it.".localized + "\n"
                + "- " + "Rewriting bullet.title/subtitle/message changes what is sent.".localized + "\n"
                + "- " + "device is read-only: it reports the device, it does not set it.".localized + "\n"
                + "- " + "The hook must finish within 2 seconds.".localized + "\n"
                + "- " + "Do not use while(true) loops or blocking patterns.".localized) + "\n\n"
            + ("Each notification is a separate run: a variable declared at the top "
                + "level does not survive to the next one. Use localStorage for that.").localized
            + "\n\n"
            + ("Output ONLY the JavaScript source — no markdown fences, no "
                + "explanation, no commentary.").localized
            + "\n\n"
            + AIRequirement.tail(requirement: requirement)
    }
}

/// The hook guide presented from an instance page.
///
/// The same sheet as the script guide, with the hook's contract: keep() instead
/// of push(), a read-only `device`, and no ability to send.
enum HookGuide {
    static func present(from controller: UIViewController, phase: BulletinHookRunner.Phase) {
        GuideSheet.present(
            from: controller,
            title: (phase == .received ? "On Receiving" : "After Filtering").localized,
            blocks: [
                .heading("What a hook does".localized),
                .text((phase == .received
                    ? "Runs as soon as the notification arrives for this service — before the app list, the notification settings and the device conditions are consulted."
                    : "Runs after every filter has already passed, immediately before the request is built — the last place to change what goes out.").localized
                    + "\n"
                    + ("A hook cannot send anything: there is no push(). It decides "
                        + "whether to continue and may rewrite the notification's "
                        + "text.").localized),

                .heading("Deciding".localized),
                .code(JavaScriptAPI.hookKeep),

                .heading("bullet — the notification".localized),
                .text(("These three fields are yours to rewrite: what you leave in "
                    + "bullet when you call keep() is what the rest of the "
                    + "pipeline sees, including the log and the payload.").localized),
                .code(JavaScriptAPI.hookBullet),

                .heading("device — the device".localized),
                .text(("Reports the device; it does not set it. Assigning to it "
                    + "changes nothing, which is deliberate: a hook must not be "
                    + "able to tell the filters that the device is in a state it "
                    + "is not.").localized),
                .code(JavaScriptAPI.hookDevice),

                .heading("Functions".localized),
                .code(JavaScriptAPI.hookFunctions),

                .heading("Where variables live".localized),
                .text(("The hook runs fresh for every notification, so a top-level "
                    + "let or const is gone by the next one. localStorage is how a "
                    + "value survives — kept per service and per hook, so this "
                    + "hook and the other one on the same service do not share "
                    + "it.").localized),

                .heading("Limits".localized),
                .text(("The hook must finish within 2 seconds. Fetch runs for real, "
                    + "so a hook that asks a model to read a message does make "
                    + "that request — on every notification it runs for.").localized),

                .heading("If a hook fails".localized),
                .text(("A hook that throws before deciding does not drop the "
                    + "notification: it continues, and the reason appears in the "
                    + "log. A hook that fails while switched off costs nothing at "
                    + "all.").localized),

                .heading("Let an AI write it".localized),
                .text(("Tap Copy AI Prompt (top right) and send the whole thing to "
                    + "your assistant. It knows this hook's API, and it will ask "
                    + "what you want before writing anything — answer in plain "
                    + "words. Then paste the JavaScript it writes back here.").localized),
            ],
            prompt: { JavaScriptAPI.hookPrompt(requirement: $0) },
            // The AI asks its own questions, so there is nothing to type before
            // copying: asking here would be the same question twice, and the quick
            // answer typed into an alert would be worse than the conversation.
            asksForRequirement: false
        )
    }
}
