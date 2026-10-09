import UIKit
import UniformTypeIdentifiers

/// One selectable row: something that can travel.
struct Item {
        public enum Kind {
            /// A configured destination.
            case instance
            /// A script, on its own.
            case definition
        }

        public let kind: Kind
        /// The id the item has here.
        public let id: String
        public let name: String
        /// A second line: the type, or what the script is used by.
        public let detail: String
        public let icon: UIImage?
        /// Whether this one starts out selected.
        ///
        /// Scripts are only pre-selected when they are not already travelling
        /// inside an instance — see ``ServiceExporter/document(instanceIDs:definitionIDs:)``
        /// — because a script carried by a selected instance needs no entry of
        /// its own and one here would be a duplicate on the far side.
        public let isPreSelected: Bool

        public init(
            kind: Kind, id: String, name: String, detail: String,
            icon: UIImage?, isPreSelected: Bool
        ) {
            self.kind = kind
            self.id = id
            self.name = name
            self.detail = detail
            self.icon = icon
            self.isPreSelected = isPreSelected
        }
}


/// Choosing what to move, and moving it.
///
/// A picker rather than "everything", because both lists carry things a user may
/// deliberately want to leave behind: an instance holding a credential they are
/// not sending anywhere, a script half-written, a test service. Exporting all of
/// it and asking the recipient to delete the extras is a worse trade than one
/// screen of checkboxes.
///
/// The document is plain JSON, deliberately: it is meant to survive being pasted
/// into a message, hand-edited, or read by a person deciding whether to send it
/// to someone. That is also why export offers the clipboard as well as a file —
/// the common case is sending a service to a friend over a chat app.
enum ServiceTransfer {

    /// Which page the sheet was opened from, and therefore what it offers.
    ///
    /// The two lists are separate pages precisely because they are different
    /// kinds of thing, so a transfer started from one should not ask about the
    /// other — importing a script from the Instances page would leave the user
    /// wondering where it went.
    enum Scope {
        /// Configured destinations, with the scripts they use.
        case instances
        /// Scripts, alone.
        case services
    }

    // MARK: - What is on offer

    /// Everything that can be exported, in the order the page shows it.
    ///
    /// - Parameter scope: what the page that opened this is about. See ``Scope``.
    static func items(scope: Scope = .instances) -> [Item] {
        let instances = ServiceInstanceStore.instances()
        let definitions = CustomServiceStore.definitions()

        if scope == .services {
            // Only scripts, and each as its own entry: this page is about the
            // scripts themselves, so a script used by five services is still one
            // thing to move.
            return definitions.map { definition in
                let count = instances.filter { $0.type == definition.id }.count
                return Item(
                    kind: .definition,
                    id: definition.id,
                    name: definition.name,
                    detail: count == 0
                        ? "Script · not used by any service".localized
                        : String(format: "Script · used by %d services".localized, count),
                    icon: ServiceIcon.logo(forDefinitionID: definition.id)
                        ?? ServiceArtwork.image(forType: definition.id),
                    isPreSelected: true
                )
            }
        }

        var items: [Item] = instances.map { instance in
            let usage = definitions.first { $0.id == instance.type }
            return Item(
                kind: .instance,
                id: instance.id,
                name: instance.name,
                detail: usage.map { "\(instance.descriptor.displayName) · script: \($0.name)" }
                    ?? instance.descriptor.displayName,
                icon: ServiceIcon.logo(forInstanceID: instance.id)
                    ?? ServiceArtwork.image(forType: instance.type),
                isPreSelected: true
            )
        }

        // A script referenced by an instance above travels with it, so it is not
        // offered as a separate choice; one nothing uses is, since moving a
        // half-written script to another device is a real intention.
        let referenced = Set(instances.map(\.type))
        let usedBy = { (id: String) -> Int in
            instances.filter { $0.type == id }.count
        }
        items += definitions.map { definition in
            let count = usedBy(definition.id)
            return Item(
                kind: .definition,
                id: definition.id,
                name: definition.name,
                detail: count == 0
                    ? "Script · not used by any service".localized
                    : String(format: "Script · used by %d services".localized, count),
                icon: ServiceIcon.logo(forDefinitionID: definition.id)
                    ?? ServiceArtwork.image(forType: definition.id),
                isPreSelected: !referenced.contains(definition.id)
            )
        }
        return items
    }

    // MARK: - Export

    /// Offers to export a selection from one page.
    static func offerExport(from controller: UIViewController, scope: Scope = .instances) {
        let items = items(scope: scope)
        guard !items.isEmpty else {
            present(controller, title: "Nothing to Export".localized,
                    message: scope == .services
                        ? "There are no scripts to export yet.".localized
                        : "There are no services to export yet.".localized)
            return
        }

        // One thing configured and nothing else to consider: asking which ones
        // would be a screen with a single row on it.
        if items.count == 1 {
            deliver(items: items, from: controller)
            return
        }

        let picker = TransferPickerController(
            title: scope == .services
                ? "Export Services".localized
                : "Export Services".localized,
            items: items,
            actionTitle: "Export".localized,
            footer: scope == .services
                ? "The ones you choose are written to a file.".localized
                : ("The ones you choose are written to a file. A script used by "
                    + "a chosen service is included with it.").localized
        ) { chosen in
            deliver(items: chosen, from: controller)
        }
        present(controller, UINavigationController(rootViewController: picker))
    }

    /// Builds the document for the chosen items and asks where to put it.
    private static func deliver(items: [Item], from controller: UIViewController) {
        let document = ServiceExporter.document(
            instanceIDs: items.filter { $0.kind == .instance }.map(\.id),
            definitionIDs: items.filter { $0.kind == .definition }.map(\.id)
        )
        guard document.count > 0 else {
            present(controller, title: "Nothing to Export".localized,
                    message: "Nothing was selected.".localized)
            return
        }

        var body = String(
            format: "%d services will be exported.".localized, document.services.count
        )
        if !document.definitions.isEmpty {
            body += " " + String(
                format: "%d scripts will be exported on their own.".localized,
                document.definitions.count
            )
        }
        let scripts = document.services.filter { $0.definition != nil }.count
        if scripts > 0 {
            body += " " + String(
                format: "%d of the services are scripts, which are included."
                    .localized, scripts
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
                // With the size, because that is the useful thing to know before
                // pasting it somewhere.
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

    /// Offers the two ways a document can arrive, from one page.
    static func offerImport(from controller: UIViewController, scope: Scope = .instances) {
        let sheet = UIAlertController(
            title: "Import Services".localized,
            message: ("Paste a document, or choose a file. You will be shown what is "
                + "in it before anything is added.").localized,
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
            preview(text: text, from: controller, scope: scope)
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
                    preview(text: text, from: controller, scope: scope)
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

    /// Shows what a document holds before anything is written.
    ///
    /// Reading first, applying second: a pasted document is opaque, and the only
    /// way a user can tell a friend's services from their own backup is if they
    /// are shown the names. It also lets them leave some behind, which is the
    /// same choice export offers.
    private static func preview(
        text: String, from controller: UIViewController, scope: Scope
    ) {
        let document: ServiceExport
        do {
            document = try ServiceExporter.document(fromJSON: text)
        } catch {
            present(controller, title: "Import Failed".localized, message: describe(error))
            return
        }

        // One line per entry, as the picker's items. Named with what the entry is,
        // since a name alone does not say whether it is a destination or a script.
        //
        // A page of scripts shows only the scripts a document carries: its
        // instances are for the Instances page to import, and offering them here
        // would put a destination on the page that does not list destinations.
        var items: [Item] = scope == .services ? [] : document.services.map { service in
            let isScript = service.definition != nil
            return Item(
                kind: .instance,
                // The document's own index is the id here: nothing is stored
                // until the import runs, so there is no id to use.
                id: service.name,
                name: service.name,
                detail: isScript
                    ? "Service · uses a script".localized
                    : (service.type ?? "Service".localized),
                icon: ServiceImporter.storedIcon(for: service)
                    ?? service.type.flatMap { ServiceArtwork.image(forType: $0) },
                isPreSelected: true
            )
        }
        items += document.definitions.map { definition in
            Item(
                kind: .definition,
                id: definition.name,
                name: definition.name,
                detail: "Script".localized,
                icon: ServiceIcon.image(fromBase64: (definition.defaults?[PrefKey.customIcon]
                    as? String) ?? ""),
                isPreSelected: true
            )
        }

        guard !items.isEmpty else {
            present(controller, title: "Nothing to Import".localized,
                    message: "The document has no services in it.".localized)
            return
        }

        let picker = TransferPickerController(
            title: "Import Services".localized,
            items: items,
            actionTitle: "Import".localized,
            footer: ("Services already on this device are left alone; anything new "
                + "is added under the name shown here.").localized
        ) { chosen in
            apply(
                document: document,
                selecting: Set(chosen.map(\.id)),
                scope: scope,
                from: controller
            )
        }
        present(controller, UINavigationController(rootViewController: picker))
    }

    /// Adds the chosen entries from a document.
    private static func apply(
        document: ServiceExport, selecting ids: Set<String>, scope: Scope,
        from controller: UIViewController
    ) {
        // Filtered into a document of its own, so the importer has one job and
        // there is no second place that knows how a selection is spelled.
        //
        // From the Services page, the *instances* of a document are dropped
        // rather than offered: the page is about scripts, and a destination added
        // behind it would appear on a list the user is not looking at. A script
        // those instances use still arrives through the definitions they carry.
        var selection = ServiceExport(
            services: scope == .services
                ? []
                : document.services.filter { ids.contains($0.name) }
        )
        selection.definitions = document.definitions.filter { ids.contains($0.name) }
            + (scope == .services
                ? document.services.compactMap { ids.contains($0.name) ? $0.definition : nil }
                : [])

        guard selection.count > 0 else {
            present(controller, title: "Nothing to Import".localized,
                    message: "Nothing was selected.".localized)
            return
        }

        do {
            let result = try ServiceImporter.apply(selection)

            var message = String(
                format: "%d services were added.".localized, result.added.count
            )
            if !result.definitions.isEmpty {
                message += "\n" + String(
                    format: "%d scripts were added: %@".localized,
                    result.definitions.count, result.definitions.joined(separator: ", ")
                )
            }
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
            if result.added.isEmpty, result.definitions.isEmpty {
                message = "Nothing was added. ".localized + message
            }
            present(controller, title: "Import Finished".localized, message: message)
            // The page behind the sheet has to show what just arrived. Asked of
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
    /// the bundle's — a no-op when a translation exists for the exact sentence,
    /// and the English original otherwise.
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

    private static func present(_ controller: UIViewController, _ other: UIViewController) {
        controller.present(other, animated: true)
    }

    private static func present(
        _ controller: UIViewController, title: String, message: String
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Ok".localized, style: .default))
        controller.present(alert, animated: true)
    }
}

/// A page that can refresh itself after an import.
@objc protocol ServiceTransferHost {
    func reloadAfterTransfer()
}

// MARK: - The picker

/// A checklist of what to move, with the two lists' own appearance.
///
/// Built like the pages it serves — an inset-grouped table, the same icons in the
/// same place — because the items are the same objects the user is looking at two
/// screens away, and they should not look like different things here.
final class TransferPickerController: UIViewController {
    private let items: [Item]
    private let actionTitle: String
    private let footer: String
    private let onConfirm: ([Item]) -> Void

    /// Which rows are ticked, by id.
    private var selected: Set<String>
    private var tableView: UITableView!

    init(
        title: String,
        items: [Item],
        actionTitle: String,
        footer: String,
        onConfirm: @escaping ([Item]) -> Void
    ) {
        self.items = items
        self.actionTitle = actionTitle
        self.footer = footer
        self.onConfirm = onConfirm
        self.selected = Set(items.filter(\.isPreSelected).map(\.id))
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        tableView = UITableView(frame: view.bounds, style: .insetGrouped)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Cancel on the left, the action on the right: the sheet's own
        // convention, and the action is disabled while nothing is ticked so it
        // cannot do nothing.
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Cancel".localized, style: .plain, target: self, action: #selector(cancel)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: actionTitle, style: .done, target: self, action: #selector(confirm)
        )
        refreshActionButton()
    }

    @objc private func cancel() {
        dismiss(animated: true)
    }

    @objc private func confirm() {
        let chosen = items.filter { selected.contains($0.id) }
        // Dismissed first: the caller presents its own sheet, and presenting over
        // a sheet that is still going away leaves it behind the new one.
        dismiss(animated: true) { [onConfirm] in
            onConfirm(chosen)
        }
    }

    private func refreshActionButton() {
        navigationItem.rightBarButtonItem?.isEnabled = !selected.isEmpty
    }
}

extension TransferPickerController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        footer
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let item = items[indexPath.row]

        var configuration = UIListContentConfiguration.subtitleCell()
        configuration.text = item.name
        configuration.secondaryText = item.detail
        configuration.secondaryTextProperties.color = .secondaryLabel
        configuration.image = item.icon
        configuration.imageProperties.maximumSize = CGSize(width: 29, height: 29)
        cell.contentConfiguration = configuration

        cell.accessoryType = selected.contains(item.id) ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = items[indexPath.row]
        if selected.contains(item.id) {
            selected.remove(item.id)
        } else {
            selected.insert(item.id)
        }
        tableView.reloadRows(at: [indexPath], with: .none)
        refreshActionButton()
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
