import UIKit

/// The guide presented from a Bark instance's page.
///
/// Three pictures of another app — the key to read off, what the credentials look
/// like once it is in, and the encryption switches that have to be matched. The
/// wording is the guide's author's, kept as written: it is short by intent and
/// every line carries something.
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

                .heading("Key".localized),
                .text("Copy the middle of the test URL on Bark's first screen into Key.".localized),

                .heading("Server URL".localized),
                .text("Leave the default, or leave it empty.".localized),

                .heading("Example".localized),
                .image("bark_guide"),
                .image("bark_creds_guide"),
                .text(String(format: ("Bold, and without the brackets, is the key: "
                    + "%@").localized, exampleKey)),

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
