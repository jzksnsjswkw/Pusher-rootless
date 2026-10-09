import UIKit
import UniformTypeIdentifiers

/// Import and export, as a page's actions rather than a page of their own.
///
/// There is nothing to *look at* here — the work is "produce a document" or
/// "consume one" — so a separate screen would be a screen with two buttons on it.
/// The actions live behind a menu on the Instances page, which is where the
/// services being moved are listed.
///
/// The document is plain JSON, deliberately: it is meant to survive being pasted
/// into a message, hand-edited, or read by a person deciding whether to send it
/// to someone. That is also why export offers the clipboard as well as a file —
/// the common case is sending a service to a friend over a chat app.
/// A page that can refresh itself after an import.
///
/// The transfer code can add services but cannot know what the page behind it is
/// showing, so it asks rather than guesses.
@objc protocol ServiceTransferHost {
    func reloadAfterTransfer()
}

enum ServiceTransfer {

    // MARK: - Export

    /// Offers to export every configured service.
    ///
    /// Everything, rather than a selection: the reason to export is to move a
    /// configuration somewhere, and choosing a subset is a rarer intention than
    /// the amount of UI it would need.
    static func offerExport(from controller: UIViewController) {
        let instances = ServiceInstanceStore.instances()
        guard !instances.isEmpty else {
            present(controller, title: "Nothing to Export".localized,
                    message: "There are no services to export yet.".localized)
            return
        }

        let document = ServiceExporter.documentForAllInstances()

        // The script definitions that travel with these services are counted, so
        // the sheet can say what will be in the file: a user sending it to
        // someone should know whether it contains code, since that is the part
        // that is hard to replace.
        let scriptCount = document.services.filter { $0.definition != nil }.count
        var body = String(
            format: "%d services will be exported.".localized, document.services.count
        )
        if scriptCount > 0 {
            body += " " + String(
                format: "%d of them are scripts, which are included in the file."
                    .localized,
                scriptCount
            )
        }

        let sheet = UIAlertController(
            title: "Export Services".localized, message: body, preferredStyle: .alert
        )
        sheet.addAction(UIAlertAction(title: "Copy to Clipboard".localized, style: .default) {
            _ in
            do {
                let text = try ServiceExporter.json(from: document)
                UIPasteboard.general.string = text
                // Said as a plain confirmation with the size, because the number
                // is the useful thing to know before pasting it somewhere.
                let size = ByteCountFormatter.string(
                    fromByteCount: Int64(text.utf8.count), countStyle: .file
                )
                present(controller, title: "Copied".localized,
                        message: String(
                            format: "The services are on the clipboard (%@). Paste them "
                                + "into a message, or into Pusher on another device.",
                            size
                        )
                        .localized)
            } catch {
                present(controller, title: "Export Failed".localized,
                        message: error.localizedDescription)
            }
        })

        sheet.addAction(UIAlertAction(title: "Share as a File".localized, style: .default) {
            _ in
            do {
                let text = try ServiceExporter.json(from: document)
                let url = try write(text: text)
                let share = UIActivityViewController(
                    activityItems: [url], applicationActivities: nil
                )
                // On a pad the share sheet is a popover and needs an anchor.
                share.popoverPresentationController?.sourceView = controller.view
                share.popoverPresentationController?.sourceRect = CGRect(
                    x: controller.view.bounds.midX, y: controller.view.bounds.midY,
                    width: 0, height: 0
                )
                controller.present(share, animated: true)
            } catch {
                present(controller, title: "Export Failed".localized,
                        message: error.localizedDescription)
            }
        })

        sheet.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel))
        present(controller, sheet)
    }

    /// Writes the document to a temporary file, returning its URL.
    ///
    /// A file rather than a string in the share sheet: a `.json` attachment
    /// arrives as a file the recipient can hand to a picker, while a wall of text
    /// arrives as a message.
    private static func write(text: String) throws -> URL {
        let name = "Pusher Services.json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Import

    /// Offers the two ways a document can arrive.
    static func offerImport(from controller: UIViewController) {
        let sheet = UIAlertController(
            title: "Import Services".localized,
            message: ("Paste a document, or choose a file. Services already on this "
                + "device are left alone; anything new is added.").localized,
            preferredStyle: .alert
        )
        sheet.addAction(UIAlertAction(title: "From Clipboard".localized, style: .default) {
            _ in
            let text = UIPasteboard.general.string ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                present(controller, title: "Nothing to Import".localized,
                        message: "The clipboard is empty.".localized)
                return
            }
            apply(text: text, from: controller)
        })
        sheet.addAction(UIAlertAction(title: "From a File".localized, style: .default) {
            _ in
            let picker = UIDocumentPickerViewController(
                forOpeningContentTypes: [.json, .plainText, .text], asCopy: true
            )
            picker.allowsMultipleSelection = false
            picker.delegate = FilePickerDelegate.shared
            FilePickerDelegate.shared.onPick = { url, failure in
                if let failure {
                    present(controller, title: "Import Failed".localized, message: failure)
                    return
                }
                guard let url else { return }
                do {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    apply(text: text, from: controller)
                } catch {
                    present(controller, title: "Import Failed".localized,
                            message: error.localizedDescription)
                }
            }
            present(controller, picker)
        })
        sheet.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel))
        present(controller, sheet)
    }

    /// Reads a document and adds what it contains, reporting the outcome.
    private static func apply(text: String, from controller: UIViewController) {
        do {
            let document = try ServiceExporter.document(fromJSON: text)
            let result = try ServiceImporter.apply(document)

            var message = String(
                format: "%d services were added.".localized, result.added.count
            )
            if !result.renamed.isEmpty {
                let pairs = result.renamed
                    .map { "\($0.from) → \($0.to)" }
                    .joined(separator: ", ")
                message += "\n" + String(
                    format: "Renamed to avoid a name already here: %@".localized, pairs
                )
            }
            if !result.skipped.isEmpty {
                message += "\n" + String(
                    format: "Already on this device, so left alone: %@".localized,
                    result.skipped.joined(separator: ", ")
                )
            }
            if result.added.isEmpty {
                message = "Nothing was added. " + message
            }
            present(controller, title: "Import Finished".localized, message: message)
            // The list behind the sheet has to show what just arrived. Asked of
            // the controller rather than reloaded from here, because only a page
            // knows what it is displaying.
            (controller as? ServiceTransferHost)?.reloadAfterTransfer()
        } catch {
            present(controller, title: "Import Failed".localized, message: describe(error))
        }
    }

    /// A readable reason, preferring the Core layer's own wording.
    ///
    /// The Core layer has no string table, so its English text is passed through
    /// the bundle's — which is a no-op when a translation exists for the exact
    /// sentence and the English original otherwise.
    private static func describe(_ error: Error) -> String {
        if let importError = error as? ServiceImportError {
            switch importError {
            case .malformed(let detail):
                return detail.localized
            case .notAnExport(let kind):
                return String(
                    format: "This is a \"%@\" file, not a Pusher services export."
                        .localized, kind
                )
            case .tooNew(let version, let supported):
                return String(
                    format: ("This export was made by a newer version of Pusher "
                        + "(format %d); this one reads up to %d.").localized,
                    version, supported
                )
            case .nothingToAdd(let names):
                return String(
                    format: "Nothing was added: this device already has %@."
                        .localized, names.joined(separator: ", ")
                )
            }
        }
        return error.localizedDescription
    }

    // MARK: - Presenting

    private static func present(
        _ controller: UIViewController, _ other: UIViewController
    ) {
        controller.present(other, animated: true)
    }

    private static func present(
        _ controller: UIViewController, title: String, message: String
    ) {
        let alert = UIAlertController(
            title: title, message: message, preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Ok".localized, style: .default))
        controller.present(alert, animated: true)
    }
}

/// Holds the file picker's delegate.
///
/// A `UIDocumentPickerViewController` keeps its delegate weakly, so a delegate
/// created at the call site would be released before the user finished choosing —
/// the same trap as a bar button item's target.
final class FilePickerDelegate: NSObject, UIDocumentPickerDelegate {
    static let shared = FilePickerDelegate()

    /// Called with the chosen file, or with a reason it could not be read.
    var onPick: ((URL?, String?) -> Void)?

    func documentPicker(
        _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
    ) {
        onPick?(urls.first, nil)
        onPick = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        onPick?(nil, nil)
        onPick = nil
    }
}
