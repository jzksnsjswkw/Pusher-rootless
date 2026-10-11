import UIKit

/// The guide presented from a Shortcut instance's page.
///
/// One question — "what do I put in the Shortcut?" — and two mistakes it is
/// written to prevent. Both come from the same place: Pusher hands the Shortcut a
/// *dictionary*, and a new Shortcut receives nothing at all until it is told to
/// accept input.
///
/// The first mistake is expecting the notification's text to arrive by itself.
/// A Shortcut that has not declared an input receives an empty run, and nothing
/// in the Shortcuts app says why.
///
/// The second is reading the fields one at a time out of an imagined `title`
/// variable, when the input is a dictionary that has to be looked up by key.
///
/// The screenshot shows the three actions that make it work, because the wording
/// of the first one ("Receive … input from Nowhere") is what changes when the
/// third is added, and that is hard to describe and easy to show.
enum ShortcutGuide {

    static func present(from controller: UIViewController) {
        GuideSheet.present(
            from: controller,
            title: "Using a Shortcut".localized,
            blocks: [
                .heading("What arrives".localized),
                .text(("Pusher passes the notification to your Shortcut as a "
                    + "dictionary. Nothing else is needed on this side — pick the "
                    + "Shortcut by name and it runs, silently, in the background, "
                    + "each time a notification is forwarded.").localized),

                .heading("Accept the input first".localized),
                .text(("This is the step that is easy to miss. A Shortcut that has "
                    + "not been told to accept input still runs, and quietly "
                    + "receives nothing.\n\n"
                    + "Add **Get Dictionary from Input**, then set its *Get* field "
                    + "to **Shortcut Input**. The Shortcuts app then adds a "
                    + "*Receive … input from Nowhere* action of its own accord, "
                    + "before it — you do not add that one yourself. It appearing "
                    + "is the sign that the dictionary will arrive.").localized),

                .image("shortcut_guide"),

                .heading("Read the fields".localized),
                .text(("Use **Get Value for Key** on that dictionary, once per "
                    + "field you want, with the key name typed in. The keys are "
                    + "the same ones every other service sends, so what is below "
                    + "also describes what a webhook or a script receives.").localized),
                .code(fields),

                .heading("Pictures".localized),
                .text(("icon and image are Base64 text, present only when this "
                    + "service's *Include Icon* and *Include Image* switches are "
                    + "on — and image only when the notification actually carried "
                    + "an attachment. Empty means the field was not asked for, not "
                    + "that the notification had none.").localized),

                .heading("Nothing happens".localized),
                .text(("A Shortcut that fails leaves no trace in Pusher, and the "
                    + "Shortcuts app does not report a background run. Two things "
                    + "to check first: the name here matches the Shortcut exactly — "
                    + "including any number the Shortcuts app appended to a "
                    + "duplicate — and the dictionary step above is present.").localized),
            ],
            prompt: { requirement in
                prompt(for: requirement)
            }
        )
    }

    /// The field list, written as declarations so it reads like the script guide.
    private static var fields: String {
        """
        title      // the notification's title
        subtitle   // its subtitle, often empty
        message    // its body
        appName    // the app it came from
        appID      // that app's bundle identifier
        date       // when it arrived, formatted as this service was configured
        deviceName // this device's name
        icon       // Base64 PNG, when Include Icon is on
        image      // Base64, when Include Image is on and the notification had one
        """
    }

    /// What the copy button puts on the pasteboard.
    private static func prompt(for requirement: String) -> String {
        """
        You are writing an iOS Shortcut for the Pusher tweak, which forwards \
        notifications to other destinations. Your answer is a list of Shortcuts \
        actions I perform by hand — you cannot run anything, and there is no API \
        to call.

        Pusher runs this Shortcut silently when a notification arrives, passing \
        the notification as a dictionary. The first step is always:

          1. Get Dictionary from Input — with its "Get" field set to "Shortcut \
        Input". Shortcuts then adds "Receive ... input from Nowhere" above it on \
        its own.

        The dictionary's keys, all strings:

        \(fields)

        Read one with Get Value for Key, typing the key name. Write steps in \
        plain language, name each action exactly as it appears in the Shortcuts \
        app, and keep the action count low — this Shortcut runs in the \
        background, where anything needing confirmation will hang.

        What I want it to do:
        \(requirement)
        """
    }
}
