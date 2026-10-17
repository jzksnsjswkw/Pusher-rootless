import UIKit

/// The guide presented from a Bark instance's page.
///
/// Two versions of the same instructions, because Bark changed where the key is
/// shown. The new one comes first: a reader on the current app finds what they see
/// on screen immediately, and a reader on an older one scrolls past it to the
/// version that matches theirs.
enum BarkGuide {

    /// The key in the screenshots. Generated for the guide, not anyone's.
    static let exampleKey = "H2XmTALZxNUegivurCAvv4"

    static func present(from controller: UIViewController) {
        GuideSheet.present(
            from: controller,
            title: "Using Bark".localized,
            blocks: [
                .callout(("If you test on this device, you must add Bark to the app "
                    + "blacklist. Otherwise it loops forever: Bark posts a "
                    + "notification, Pusher forwards it to Bark, Bark posts it "
                    + "again, and Pusher forwards that.").localized),

                // MARK: Current Bark

                .heading("Current version".localized),
                .text(("Under Usage Example, open the arrow to the right of Copy "
                    + "and choose Copy Key.").localized),
                .image("bark_key_menu"),
                .text(String(format: ("The key is **%@** in the example above.").localized,
                             exampleKey)),

                // MARK: Older Bark

                .heading("Older versions of Bark".localized),
                .text("Copy the middle of the test URL on Bark's first screen.".localized),
                .image("bark_guide"),
                .image("bark_creds_guide"),

                // MARK: Shared

                .heading("Server URL".localized),
                .text("Leave the default, or leave it empty.".localized),

                .heading("The advanced settings below are optional".localized),

                .heading("Push encryption".localized),
                .text("Match it to Push Encryption in Bark.".localized),
                .image("bark_crypto_guide"),
                .text("Copy the algorithm, mode and key. Leave the IV alone.".localized),

                .text("More parameters: bark.day.app/#/params".localized),
            ]
        )
    }
}
