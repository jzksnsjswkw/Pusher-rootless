import UIKit

/// The guide presented from a Bark instance's page.
///
/// Three things the page cannot show: where the key is read off, what the
/// credentials it is pasted into should end up looking like, and that forwarding
/// Bark's own notifications back to Bark loops. The last one is a trap rather
/// than an instruction — the loop is self-sustaining and both sides look healthy
/// while it runs — so it leads.
enum BarkGuide {

    /// The key in the screenshots. Generated for the guide, not anyone's.
    static let exampleKey = "H2XmTALZxNUegivurCAvv4"

    static func present(from controller: UIViewController) {
        GuideSheet.present(
            from: controller,
            title: "Using Bark".localized,
            blocks: [
                .heading("Before you test".localized),
                .text(("If Bark is on this device, add it to the app blacklist first. "
                    + "Otherwise the loop never ends: Pusher forwards to Bark, Bark "
                    + "shows a notification, Pusher forwards that too.").localized),

                .heading("Key".localized),
                .text(("Copy the middle of the test URL on Bark's first screen into "
                    + "**Key**.").localized),
                .image("bark_guide"),
                .text(String(format: "Example: %@ is the key.".localized, exampleKey)),
                .image("bark_creds_guide"),

                .heading("Server URL".localized),
                .text("Leave it empty.".localized),

                .heading("Optional".localized),
                .text(("**Push encryption** — match it to the Push Encryption screen "
                    + "in Bark. Copy the algorithm, mode and key; leave the IV "
                    + "alone.").localized),
                .image("bark_crypto_guide"),
                .text(("Other parameters: bark.day.app/#/params").localized),

                .heading("Testing".localized),
                .text("Tap **Send Test Notification** at the bottom. If nothing arrives, check the key first.".localized),
            ]
        )
    }
}
