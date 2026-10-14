import UIKit

/// The guide presented from a Bark instance's page.
///
/// Three pictures of another app — where the key is read off, what the
/// credentials should look like once it is in, and the encryption switches that
/// have to be matched. The wording is the guide's author's, kept as written: it
/// is short by intent and every line carries something.
enum BarkGuide {

    /// The key in the screenshots. Generated for the guide, not anyone's.
    static let exampleKey = "H2XmTALZxNUegivurCAvv4"

    static func present(from controller: UIViewController) {
        GuideSheet.present(
            from: controller,
            title: "Using Bark".localized,
            blocks: [
                .callout(("If Bark is on this device, add it to the app blacklist. "
                    + "Otherwise it loops forever: Bark shows a notification, "
                    + "Pusher forwards it, Bark shows it again.").localized),

                .heading("Key".localized),
                .text(("Copy the middle of the test URL on Bark's first screen "
                    + "into Key.").localized),
                .image("bark_guide"),
                .text(String(format: "Example: %@ is the key.".localized, exampleKey)),
                .image("bark_creds_guide"),

                .heading("Server URL".localized),
                .text("Leave it empty, or leave the default.".localized),

                .heading("Optional".localized),
                .text("Push encryption".localized),
                .text(("Optional. Match it to Push Encryption in Bark. Copy the "
                    + "algorithm, mode and key; leave the IV alone.").localized),
                .image("bark_crypto_guide"),
                .text(("More parameters: https://bark.day.app/#/params").localized),

                .heading("Testing".localized),
                .text("Tap Send Test Notification at the bottom. If nothing arrives, check the key first.".localized),
            ]
        )
    }
}
