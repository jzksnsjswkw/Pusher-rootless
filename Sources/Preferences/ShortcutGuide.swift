import UIKit

/// The guide presented from a Shortcut instance's page.
///
/// One question — "what do I put in the Shortcut?" — and the mistake that costs
/// the most time. Pusher hands the Shortcut a dictionary, and a Shortcut that has
/// not been told to accept input still runs and quietly receives nothing, with
/// nothing on either side saying why.
///
/// Kept short on purpose: it is read once, standing in another app with a half
/// finished Shortcut open. The screenshot carries the step that is hard to
/// describe — the first action's wording changes once the dictionary action is
/// added — so the text does not have to.
enum ShortcutGuide {

    static func present(from controller: UIViewController) {
        GuideSheet.present(
            from: controller,
            title: "Using a Shortcut".localized,
            blocks: [
                .heading("The example".localized),
                .text(("The Shortcut below already does everything this page "
                    + "describes. Add it, then point this instance at it.").localized),
                .action(
                    title: "Get the example Shortcut".localized,
                    detail: ("Opened for you to add. Only needs signing once the "
                        + "copy in Pusher has expired.").localized,
                    run: fetchExample
                ),

                .heading("How it runs".localized),
                .text(("Pusher passes the notification as a dictionary and runs "
                    + "the Shortcut in the background. Nothing else is needed "
                    + "here.").localized),

                .heading("Accept the input".localized),
                .text(("This is the step to get right. Without it the Shortcut "
                    + "runs and receives nothing, silently.\n\n"
                    + "Add **Get Dictionary from Input** and set its *Get* field "
                    + "to **Shortcut Input**. The *Receive … input* action above "
                    + "it appears by itself — do not add that one.").localized),

                .image("shortcut_guide"),

                .heading("Read the fields".localized),
                .text(("Add **Get Value for Key** for each field you want, typing "
                    + "the key by hand. The same keys reach a webhook or a "
                    + "script.").localized),
                .code(fields),

                .heading("If nothing happens".localized),
                .text(("A failed Shortcut leaves no trace on either side. Check "
                    + "that the name here matches exactly, and that the dictionary "
                    + "step above is present.").localized),
            ]
        )
    }

    /// Fetches the example Shortcut and offers it to the Shortcuts app.
    ///
    /// The file in the bundle is unsigned, because iOS cannot sign one and a
    /// signature expires in about a year. It is signed when asked for, which is
    /// also why this needs the network and why the row says so.
    private static func fetchExample(_ host: GuideSheet.ActionHost) {
        host.setActionBusy(true, detail: "Signing…".localized)
        ShortcutSigner.signedExample { result in
            switch result {
            case .success(let url):
                host.setActionBusy(false, detail: nil)
                host.presentActionAlert(
                    title: "Shortcut Ready".localized,
                    message: ("Open it to add it to your Shortcuts. The Shortcuts "
                        + "app will ask before importing, because it did not come "
                        + "from Apple's gallery.").localized,
                    share: url
                )
            case .failure(let error):
                host.setActionBusy(false, detail: nil)
                host.presentActionAlert(
                    title: "Could Not Sign".localized,
                    message: error.localizedDescription,
                    share: nil
                )
            }
        }
    }

    /// The field list, in the shape the script guide uses: the keys are
    /// identifiers and stay English, the trailing comments are read by a person
    /// and are localized in place.
    private static var fields: String {
        """
        title       // \("标题".localized)
        subtitle    // \("副标题，常为空".localized)
        message     // \("正文".localized)
        appName     // \("来源应用名".localized)
        appID       // \("来源应用标识".localized)
        date        // \("到达时间，格式随服务".localized)
        deviceName  // \("本机名称".localized)
        icon        // \("需开启「包含图标」".localized)
        image       // \("需开启图片且通知带附件".localized)
        """
    }
}
