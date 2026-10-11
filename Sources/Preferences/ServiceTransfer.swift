import UIKit
import UniformTypeIdentifiers

/// One selectable row: something that can travel.
struct Item {
    /// The name it has, which is also how it is identified here: a name is
    /// unique within each kind, and nothing is stored until the import runs,
    /// so there is no id to use.
    let name: String
    /// A second line: the kind, or the script an instance uses.
    let detail: String
    let icon: UIImage?
    /// Whether its row is ticked to begin with.
    let isPreSelected: Bool
}


/// Choosing what to move, and moving it.
///
/// A picker rather than "everything", because a list carries things a user may
/// deliberately want to leave behind: an instance holding a credential they are
/// not sending anywhere, a script half-written, a test service. Exporting all of
/// it and asking the recipient to delete the extras is a worse trade than one
/// screen of checkboxes.
///
/// The document is plain JSON, deliberately: it is meant to survive being pasted
/// into a message, hand-edited, or read by a person deciding whether to send it to
/// someone. That is also why export offers the clipboard as well as a file — the
/// common case is sending a service to a friend over a chat app.
enum ServiceTransfer {

    /// Which page the sheet was opened from, and therefore what it lists.
    ///
    /// The two pages are separate because they are different kinds of thing, so a
    /// transfer started from one lists that one — and the *other* kind is a
    /// switch at the bottom rather than a set of rows mixed in, because it is a
    /// different decision: "and the scripts too", not "which scripts".
    enum Scope {
        /// Configured destinations, with an option to carry their scripts.
        case instances
        /// Scripts, with an option to carry their destinations.
        case services
    }

    /// What a picker was asked, and what it produced.
    ///
    /// One type for both directions, because the two sheets differ only in their
    /// labels and what happens to the answer.
    private struct Request {
        var title: String
        var actionTitle: String
        var footer: String
        /// The label of the switch that also carries the other kind, or `nil`
        /// when there is nothing else to carry.
        var companionLabel: String?
        /// Whether that switch starts on.
        var companionIsOn: Bool
        /// What the switch's footer says; it depends on the state, since what
        /// happens when it is on and off is exactly what a user needs told.
        var companionFooter: (Bool) -> String
        var onConfirm: ([String], Bool) -> Void
    }

    // MARK: - Items

    /// The rows for one page, in the order the page shows them.
    static func items(scope: Scope) -> [Item] {
        switch scope {
        case .instances:
            let definitions = CustomServiceStore.definitions()
            return ServiceInstanceStore.instances().map { instance in
                let script = definitions.first { $0.id == instance.type }
                return Item(
                    name: instance.name,
                    detail: script.map {
                        String(format: "Uses the service \"%@\"".localized, $0.name)
                    } ?? instance.descriptor.displayName,
                    icon: ServiceArtwork.image(forType: instance.type),
                    isPreSelected: true
                )
            }

        case .services:
            let instances = ServiceInstanceStore.instances()
            return CustomServiceStore.definitions().map { definition in
                let count = instances.filter { $0.type == definition.id }.count
                return Item(
                    name: definition.name,
                    detail: count == 0
                        ? "Not used by any instance yet".localized
                        : String(format: "Used by %d instances".localized, count),
                    icon: ServiceIcon.logo(forDefinitionID: definition.id)
                        ?? ServiceArtwork.image(forType: definition.id),
                    isPreSelected: true
                )
            }
        }
    }

    // MARK: - Export

    /// Offers to export from one page.
    static func offerExport(from controller: UIViewController, scope: Scope = .instances) {
        let items = items(scope: scope)
        guard !items.isEmpty else {
            present(controller, title: "Nothing to Export".localized,
                    message: scope == .services
                        ? "There are no services to export yet.".localized
                        : "There are no services to export yet.".localized)
            return
        }

        // One thing and nothing else to consider: asking which ones would be a
        // screen with a single row on it.
        let companionAvailable = companionCount(scope: scope) > 0
        if items.count == 1, !companionAvailable {
            deliver(names: items.map(\.name), includeCompanion: false,
                    scope: scope, from: controller)
            return
        }

        let request = Request(
            title: scope == .services
                ? "Export Services".localized
                : "Export Instances".localized,
            actionTitle: "Export".localized,
            footer: scope == .services
                ? "The ones you choose are written to a file.".localized
                : ("The ones you choose are written to a file. An instance that uses "
                    + "a service is written with it, so it works on the other "
                    + "device.").localized,
            companionLabel: companionLabel(scope: scope, forExport: true),
            companionIsOn: true,
            companionFooter: { isOn in
                if scope == .services {
                    return isOn
                        ? ("Each service's instances are written too, so they work as "
                            + "soon as the file is imported.").localized
                        : "Only the services are written. Nothing uses them yet.".localized
                }
                return isOn
                    ? ("The services your instances use are written too, so they work "
                        + "on the other device.").localized
                    : ("Only the instances are written. An instance that uses a "
                        + "service needs that service on the other device already "
                        + "— it cannot be obtained from this file.").localized
            },
        ) { names, includeCompanion in
            deliver(names: names, includeCompanion: includeCompanion,
                    scope: scope, from: controller)
        }

        presentPicker(request, items: items, from: controller)
    }

    /// Builds the document for a selection and asks where to put it.
    private static func deliver(
        names: [String], includeCompanion: Bool, scope: Scope, from controller: UIViewController
    ) {
        let document = document(names: names, includeCompanion: includeCompanion, scope: scope)
        guard document.count > 0 else {
            present(controller, title: "Nothing to Export".localized,
                    message: "Nothing was selected.".localized)
            return
        }

        var body = String(format: "%d services will be exported.".localized,
                          document.instances.count)
        if document.services.count > 0 {
            body += " " + String(format: "%d services are included.".localized,
                                 document.services.count)
        }
        if document.instances.isEmpty {
            body = String(format: "%d services will be exported.".localized,
                          document.services.count)
        }

        let sheet = UIAlertController(
            title: scope == .services
                ? "Export Services".localized
                : "Export Instances".localized,
            message: body, preferredStyle: .alert
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
                            format: ("The services are on the clipboard (%@). Paste them "
                                + "into a message, or into Pusher on another device.")
                                .localized,
                            size
                        ))
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

    /// Resolves chosen names into the exporter's selection.
    private static func document(
        names: [String], includeCompanion: Bool, scope: Scope
    ) -> ServiceExport {
        let chosen = Set(names)
        switch scope {
        case .instances:
            let chosenInstances = ServiceInstanceStore.instances()
                .filter { chosen.contains($0.name) }
            let instanceIDs = chosenInstances.map(\.id)
            // Only the services these instances actually use — not every service
            // on the device. An instance's `type` names the service it was created
            // from, so the set is what the chosen instances refer to, and a
            // selection of one Bark instance no longer carries an unrelated
            // script along with it.
            //
            // The switch still decides whether they come at all: an instance
            // written without its service imports against a service the
            // receiving device already has.
            let usedTypes = Set(chosenInstances.map(\.type))
            let serviceIDs = includeCompanion
                ? CustomServiceStore.definitions()
                    .filter { usedTypes.contains($0.id) }
                    .map(\.id)
                : []
            return ServiceExporter.document(
                selection: ServiceExporter.Selection(
                    instanceIDs: instanceIDs, serviceIDs: serviceIDs
                )
            )

        case .services:
            let serviceIDs = CustomServiceStore.definitions()
                .filter { chosen.contains($0.name) }
                .map(\.id)
            let instanceIDs = includeCompanion
                ? ServiceInstanceStore.instances()
                    .filter { serviceIDs.contains($0.type) }
                    .map(\.id)
                : []
            return ServiceExporter.document(
                selection: ServiceExporter.Selection(
                    instanceIDs: instanceIDs, serviceIDs: serviceIDs
                )
            )
        }
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
            title: scope == .services
                ? "Import Services".localized
                : "Import Instances".localized,
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
            read(text: text, scope: scope, from: controller)
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
                    read(text: text, scope: scope, from: controller)
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

    /// Reads a document and shows what is in it before writing anything.
    ///
    /// Reading first, applying second: a pasted document is opaque, and the only
    /// way a user can tell a friend's services from their own backup is if they
    /// are shown the names. It also lets them leave some behind, which is the same
    /// choice export offers.
    private static func read(text: String, scope: Scope, from controller: UIViewController) {
        let document: ServiceExport
        do {
            document = try ServiceExporter.document(fromJSON: text)
        } catch {
            present(controller, title: "Import Failed".localized, message: describe(error))
            return
        }

        let listing = listing(for: document, scope: scope)
        guard !listing.items.isEmpty else {
            present(controller, title: "Nothing to Import".localized,
                    message: scope == .services
                        ? "The document has no services in it.".localized
                        : "The document has no services in it.".localized)
            return
        }

        // A single row with nothing to accompany it needs no screen. On the
        // Instances page nothing can accompany an instance — its services always
        // travel with it — so a lone instance goes straight in.
        if listing.items.count == 1, listing.companion.isEmpty {
            apply(document: document, names: [listing.items[0].name],
                  includeCompanion: scope == .instances, scope: scope, from: controller)
            return
        }

        let request = Request(
            title: scope == .services
                ? "Import Services".localized
                : "Import Instances".localized,
            actionTitle: "Import".localized,
            footer: ("Services already on this device are left alone; anything new is "
                + "added under the name shown here.").localized,
            companionLabel: companionLabel(scope: scope, forExport: false),
            // On for the Services page, where an instance that uses a script has
            // to be offered. On the Instances page there is no switch, and the
            // services travel because they must.
            companionIsOn: true,
            companionFooter: { isOn in
                // Only reached on the Services page; the Instances page has no
                // switch, so it has no state to describe.
                isOn
                    ? "The instances that use them are added too.".localized
                    : ("Only the services are added. Nothing uses them until you add "
                        + "an instance yourself.").localized
            },
        ) { names, includeCompanion in
            apply(document: document, names: names,
                  includeCompanion: includeCompanion, scope: scope, from: controller)
        }

        presentPicker(request, items: listing.items, from: controller)
    }

    /// What a document offers the page that opened it.
    private struct Listing {
        /// The rows to show, being the kind this page is about.
        var items: [Item]
        /// How many of the *other* kind the document also carries.
        var companion: [String]
    }

    private static func listing(for document: ServiceExport, scope: Scope) -> Listing {
        switch scope {
        case .instances:
            return Listing(
                items: document.instances.map { instance in
                    Item(
                        name: instance.name,
                        detail: instance.service.map {
                            String(format: "Uses the service \"%@\"".localized, $0)
                        } ?? (instance.type ?? ""),
                        icon: ServiceImporter.storedIcon(for: instance)
                            ?? instance.type.flatMap { ServiceArtwork.image(forType: $0) },
                        isPreSelected: true
                    )
                },
                // Empty: on this page the services are not a choice. An instance
                // whose service is missing cannot be created without it, and one
                // whose service is here already gains nothing from a second copy —
                // so there is nothing for a switch to decide.
                companion: []
            )

        case .services:
            return Listing(
                items: document.services.map { service in
                    let fields = service.configFields?.count ?? 0
                    return Item(
                        name: service.name,
                        detail: fields == 0
                            ? "Service".localized
                            : String(format: "Service · %d settings".localized, fields),
                        icon: ServiceImporter.storedIcon(for: service)
                            ?? ServiceArtwork.image(forType: service.name),
                        isPreSelected: true
                    )
                },
                // The instances that use the chosen services, by name — the
                // switch's subject on this page, in both directions.
                companion: document.instances.map(\.name)
            )
        }
    }

    /// Adds the chosen entries.
    private static func apply(
        document: ServiceExport, names: [String], includeCompanion: Bool, scope: Scope,
        from controller: UIViewController
    ) {
        // Filtered into a document of its own, so the importer has one job and
        // there is no second place that knows how a selection is spelled.
        let chosen = Set(names)
        var selection: ServiceExport
        switch scope {
        case .instances:
            // Every service the document carries travels, always. There is nothing
            // for a choice to decide: a service already on this device is skipped
            // by the importer, and one that is missing is exactly what an instance
            // needs in order to exist. An instance whose service is in neither
            // place is reported, not silently stripped.
            selection = ServiceExport(
                services: document.services,
                instances: document.instances.filter { chosen.contains($0.name) }
            )
        case .services:
            selection = ServiceExport(
                services: document.services.filter { chosen.contains($0.name) },
                instances: includeCompanion
                    ? document.instances.filter { instance in
                        instance.service.map { serviceName in
                            document.services.contains {
                                $0.name == serviceName && chosen.contains($0.name)
                            }
                        } ?? false
                    }
                    : []
            )
        }

        guard selection.count > 0 else {
            present(controller, title: "Nothing to Import".localized,
                    message: "Nothing was selected.".localized)
            return
        }

        do {
            let result = try ServiceImporter.apply(selection)
            present(controller, title: "Import Finished".localized,
                    message: summary(of: result, scope: scope))
            // The page behind the sheet has to show what just arrived. Asked of
            // the controller rather than reloaded from here, because only a page
            // knows what it is displaying.
            (controller as? ServiceTransferHost)?.reloadAfterTransfer()
        } catch {
            present(controller, title: "Import Failed".localized, message: describe(error))
        }
    }

    /// What an import did, as a paragraph.
    ///
    /// Worded per page, because the two pages count different things: a page of
    /// instances has no interest in a script being added except as the reason its
    /// instance works.
    private static func summary(
        of result: ServiceImporter.Result, scope: Scope
    ) -> String {
        // The page's own kind is reported first: on a page of instances, what the
        // user came for is the instances, and a service appearing above them reads
        // as the wrong answer to the question they asked.
        var lines: [String] = []
        let instanceLine = result.instances.isEmpty ? nil : String(
            format: "%d instances were added: %@".localized,
            result.instances.count, result.instances.joined(separator: ", ")
        )
        let serviceLine = result.services.isEmpty ? nil : String(
            format: "%d services were added: %@".localized,
            result.services.count, result.services.joined(separator: ", ")
        )
        lines += (scope == .services ? [serviceLine, instanceLine] : [instanceLine, serviceLine])
            .compactMap { $0 }
        if result.isEmpty {
            lines.append("Nothing was added.".localized)
        }
        if !result.renamed.isEmpty {
            let pairs = result.renamed.map { "\($0.from) → \($0.to)" }.joined(separator: ", ")
            lines.append(String(format: "Renamed to avoid a name already here: %@"
                .localized, pairs))
        }
        let skipped = result.skipped.map { entry -> String in
            switch entry.reason {
            case .alreadyPresent:
                return String(format: "%@ (already here)".localized, entry.name)
            case .emptyScript:
                return String(format: "%@ (the service is empty)".localized, entry.name)
            case .serviceMissing(let service):
                return String(
                    format: "%@ (its service \"%@\" is not included)".localized,
                    entry.name, service
                )
            }
        }
        if !skipped.isEmpty {
            lines.append(String(format: "Left alone: %@".localized,
                                skipped.joined(separator: ", ")))
        }
        return lines.joined(separator: "\n")
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
            case .missingService(let instance, let service):
                return String(
                    format: ("\"%@\" uses a service called \"%@\", which the document "
                        + "does not include.").localized, instance, service
                )
            }
        }
        return error.localizedDescription
    }

    // MARK: - The switch

    /// How many of the other kind exist, for deciding whether to offer the switch
    /// at all.
    /// Whether the *other* kind exists at all, so a switch would have a subject.
    ///
    /// Only used on the export side: import asks the document instead, since a
    /// switch is pointless when the file carries nothing of the other kind.
    /// Whether the "also write the other kind" switch has anything to offer.
    ///
    /// Only a count of what *could* be included, asked before anything has been
    /// chosen — it decides whether the picker is worth showing at all. What is
    /// actually written is decided per selection in ``document(names:includeCompanion:scope:)``,
    /// which for instances means the services those instances use and nothing
    /// else.
    private static func companionCount(scope: Scope) -> Int {
        switch scope {
        case .instances: return CustomServiceStore.definitions().count
        case .services: return ServiceInstanceStore.instances().count
        }
    }

    private static func companionLabel(scope: Scope, forExport: Bool) -> String? {
        switch scope {
        case .instances:
            // Export only. Importing an instance needs its service, so there is
            // nothing to ask — see ``listing(for:scope:)``.
            return forExport ? "Include the services they use".localized : nil
        case .services:
            // The same words either way: on both pages the switch decides whether
            // the instances using the chosen services come along, and the user does
            // not care that one is an export and the other an import.
            return "Include the instances that use them".localized
        }
    }

    // MARK: - Presenting

    /// Shows a picker and runs its request.
    private static func presentPicker(
        _ request: Request, items: [Item], from controller: UIViewController
    ) {
        let picker = TransferPickerController(
            title: request.title,
            items: items,
            actionTitle: request.actionTitle,
            footer: request.footer,
            companionLabel: request.companionLabel,
            companionIsOn: request.companionIsOn,
            companionFooter: request.companionFooter,
            onConfirm: request.onConfirm
        )
        present(controller, UINavigationController(rootViewController: picker))
    }

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

/// A checklist of what to move, with the two pages' own appearance.
///
/// Built like the pages it serves — an inset-grouped table, the same icons in the
/// same place — because the items are the same objects the user is looking at two
/// screens away, and they should not look like different things here.
///
/// The other kind is a switch in a section of its own at the bottom, not more
/// rows: whether to carry the scripts alongside the services is a different
/// question from which services, and mixing them into one list of tick boxes is
/// what made the first version of this confusing.
final class TransferPickerController: UIViewController {
    private let items: [Item]
    private let actionTitle: String
    private let footer: String
    private let companionLabel: String?
    private let companionFooter: ((Bool) -> String)?
    private let onConfirm: ([String], Bool) -> Void

    /// The names whose rows are ticked.
    private var selected: Set<String>
    /// Whether the other kind travels too.
    private var companionIsOn: Bool

    private var tableView: UITableView!

    init(
        title: String,
        items: [Item],
        actionTitle: String,
        footer: String,
        companionLabel: String?,
        companionIsOn: Bool,
        companionFooter: ((Bool) -> String)?,
        onConfirm: @escaping ([String], Bool) -> Void
    ) {
        self.items = items
        self.actionTitle = actionTitle
        self.footer = footer
        self.companionLabel = companionLabel
        self.companionIsOn = companionIsOn
        self.companionFooter = companionFooter
        self.onConfirm = onConfirm
        self.selected = Set(items.filter(\.isPreSelected).map(\.name))
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Two sections when the switch is offered: the rows, then the switch.
    private var hasCompanionSection: Bool { companionLabel != nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        tableView = UITableView(frame: view.bounds, style: .insetGrouped)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "switch")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Cancel on the left, the action on the right: the sheet's own convention,
        // and the action is disabled while nothing is ticked so it cannot do
        // nothing.
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
        let names = items.filter { selected.contains($0.name) }.map(\.name)
        let companion = companionIsOn
        // Dismissed first: the caller presents its own sheet, and presenting over
        // a sheet that is still going away leaves it behind the new one.
        dismiss(animated: true) { [onConfirm] in
            onConfirm(names, companion)
        }
    }

    private func refreshActionButton() {
        navigationItem.rightBarButtonItem?.isEnabled = !selected.isEmpty
    }

}

extension TransferPickerController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int {
        hasCompanionSection ? 2 : 1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? items.count : 1
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        // The rows need no heading: the title says what they are.
        nil
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 { return footer }
        // The switch's own explanation, which changes with it: what
        // happens when it is on and off is exactly what a user needs told.
        return companionFooter?(companionIsOn)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 1 {
            let cell = tableView.dequeueReusableCell(withIdentifier: "switch", for: indexPath)
            var configuration = UIListContentConfiguration.cell()
            configuration.text = companionLabel
            cell.contentConfiguration = configuration
            cell.accessoryType = .none
            cell.selectionStyle = .none

            // A plain switch, kept in the cell: its state is read when the action
            // is taken, so there is nothing to write through a target.
            let toggle = UISwitch()
            toggle.isOn = companionIsOn
            toggle.addTarget(self, action: #selector(companionChanged(_:)), for: .valueChanged)
            cell.accessoryView = toggle
            return cell
        }

        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let item = items[indexPath.row]

        var configuration = UIListContentConfiguration.subtitleCell()
        configuration.text = item.name
        configuration.secondaryText = item.detail
        configuration.secondaryTextProperties.color = .secondaryLabel
        configuration.image = item.icon
        configuration.imageProperties.maximumSize = CGSize(width: 29, height: 29)
        cell.contentConfiguration = configuration
        cell.accessoryView = nil
        cell.accessoryType = selected.contains(item.name) ? .checkmark : .none
        return cell
    }

    @objc private func companionChanged(_ sender: UISwitch) {
        companionIsOn = sender.isOn
        // The footer describes what the switch does, so it changes with it.
        UIView.performWithoutAnimation {
            tableView.reloadSections(IndexSet(integer: 1), with: .none)
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 0 else { return }
        let name = items[indexPath.row].name
        if selected.contains(name) {
            selected.remove(name)
        } else {
            selected.insert(name)
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
