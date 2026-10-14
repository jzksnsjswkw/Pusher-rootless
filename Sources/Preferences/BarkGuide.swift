import UIKit

/// The guide presented from a Bark instance's page.
///
/// Two questions, in the order they come up: where the key comes from, and what
/// the encryption group below is for. Both are answered by a screenshot of the
/// Bark app, because both are about a page in another app — the key is read off
/// that page, and the encryption switches have to match settings that are made
/// there.
///
/// The key shown is a real one, generated for this guide. Using a made-up string
/// would leave the reader comparing shapes rather than positions, and the picture
/// is what they will hold their own key up against.
enum BarkGuide {

    /// The key in the screenshots. Generated for the guide, not anyone's.
    static let exampleKey = "H2XmTALZxNUegivurCAvv4"

    static func present(from controller: UIViewController) {
        GuideSheet.present(
            from: controller,
            title: "Using Bark".localized,
            blocks: [
                .heading("The key".localized),
                .text(("Pusher sends through Bark's own API, so it needs your "
                    + "device's key — Bark pushes to a device, and the key names "
                    + "the device. Open Bark, and the key is the string in the "
                    + "test URL on its first screen.").localized),
                .image("bark_guide"),
                .text(("Paste everything between the server and the trailing text "
                    + "into **Key** above. It is letters and digits, no slashes.").localized),

                .heading("Server URL".localized),
                .text(("Leave it empty to use Bark's own server, which is what "
                    + "the key above belongs to. Set it only if you run your own "
                    + "Bark server — then the key is that server's.").localized),

                .heading("Push encryption".localized),
                .text(("Optional, and it has to be set up on both sides. Bark can "
                    + "carry the whole push encrypted, so Bark's server and Apple "
                    + "see only ciphertext and the phone decrypts it. The settings "
                    + "on this page have to match the ones in Bark's "
                    + "**Push Encryption** screen exactly, or the phone shows "
                    + "\"Decryption Failed\".").localized),
                .image("bark_crypto_guide"),
                .text(("Copy the algorithm, the mode and the key from there into "
                    + "the group below. Do not set an IV: Bark generates one for "
                    + "each push, and Pusher does the same.").localized),

                .heading("Testing it".localized),
                .text(("**Send Test Notification** at the bottom of this page "
                    + "sends a real push through this instance. If nothing "
                    + "arrives, the key is the first thing to check — Bark "
                    + "accepts a wrong one and reports the failure only on the "
                    + "phone.").localized),
            ]
        )
    }
}
