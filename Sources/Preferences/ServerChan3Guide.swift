import UIKit

/// The guide presented from a ServerChan³ instance's page.
///
/// Its own guide rather than a shared one with Turbo: the two services look alike
/// and have separate accounts, and telling them apart is the first thing a reader
/// has to do here.
enum ServerChan3Guide {

    /// The example's values, which are also what the screenshot shows.
    static let exampleUID = "12345"
    static let exampleKey = "sctp12345abcdeabcdeabcdeabcde"

    static func present(from controller: UIViewController) {
        GuideSheet.present(
            from: controller,
            title: "Using ServerChan³".localized,
            blocks: [
                .callout(("ServerChan³ and ServerChan Turbo are two separate services "
                    + "with separate accounts and separate keys.").localized),

                .text("Get your credentials at: https://sc3.ft07.com/sendkey".localized),

                .heading("Example".localized),
                .image("serverchan3_example"),
                .text(String(format: ("UID is **%@**, SendKey is **%@** "
                    + "(use the copy button for the whole value).").localized,
                    exampleUID, exampleKey)),

                .heading("The settings below are optional".localized),

                .heading("Tags".localized),
                .text("Separated by vertical bars, like 工作|重要.".localized),
            ]
        )
    }
}
