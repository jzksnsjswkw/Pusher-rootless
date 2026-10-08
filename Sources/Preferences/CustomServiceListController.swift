import UIKit
import Preferences

/// The "Custom" page: the service *types* the user has written.
///
/// This page defines types; the "Services" page uses them. Writing one here —
/// "a Bark that posts to my own server", say — adds a new kind of service to the
/// add list, and every service of that kind shares this script while keeping its
/// own settings, app list and log.
///
/// The two pages are deliberately not the same page, because they answer
/// different questions: a definition says *how* to send somewhere, an instance
/// says *where* and *whether to*. Keeping them apart is what makes one script
/// worth writing for several destinations.
@objc(NSPCustomServiceListController)
public final class CustomServiceListController: PlainViewController {
    private static let cellIdentifier = "CustomServiceCell"

    private var definitions: [CustomServiceDefinition] = []
    private var tableView: UITableView!

    public override func viewDidLoad() {
        super.viewDidLoad()

        let frame = UIDevice.current.userInterfaceIdiom == .pad
            ? root?.view.bounds ?? view.bounds
            : view.bounds
        tableView = UITableView(frame: frame, style: .insetGrouped)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellIdentifier)
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)

        navigationItem.title = "Custom".localized
        // Both actions sit on the right: the left slot is the back button, and
        // taking it traps the user on this page.
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .add, target: self,
                            action: #selector(addDefinition)),
            UIBarButtonItem(title: "Edit".localized, style: .plain, target: self,
                            action: #selector(toggleEditing(_:))),
        ]
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Theme.setActiveTintColor(nil)
        tintToPusherColor()
        reloadData()
    }

    // MARK: - Data

    private func reloadData() {
        definitions = CustomServiceStore.definitions()
        tableView.reloadData()
        updateEditButton()
    }

    /// The edit button is pointless with nothing to reorder or delete.
    private func updateEditButton() {
        navigationItem.rightBarButtonItems?.last?.isEnabled = !definitions.isEmpty
        if definitions.isEmpty, tableView.isEditing {
            tableView.setEditing(false, animated: true)
        }
    }

    // MARK: - Actions

    @objc private func addDefinition() {
        promptForName(initialValue: CustomServiceStore.uniqueName()) { [weak self] name in
            guard let self else { return }
            let definition = CustomServiceStore.add(name: name)
            self.reloadData()

            // Open it straight away: a definition exists only to be written, and
            // its script starts as a working example to edit.
            self.open(definition)
        }
    }

    private func open(_ definition: CustomServiceDefinition) {
        push(CustomServiceEditorController(definitionID: definition.id))
    }

    @objc private func toggleEditing(_ sender: UIBarButtonItem) {
        tableView.setEditing(!tableView.isEditing, animated: true)
        sender.title = tableView.isEditing ? "Done".localized : "Edit".localized
        // Disabling the button while editing would leave no way out of edit
        // mode, so it is only ever disabled when editing is already off.
        navigationItem.rightBarButtonItems?.last?.isEnabled =
            tableView.isEditing || !definitions.isEmpty
    }

    /// Renames a definition, refusing a name another one already has.
    private func rename(_ definition: CustomServiceDefinition) {
        promptForName(initialValue: definition.name, title: "Rename Service".localized,
                      confirmTitle: "Rename".localized) { [weak self] name in
            guard let self else { return }
            var updated = definition
            updated.name = name
            CustomServiceStore.save(updated)
            self.reloadData()
        }
    }

    /// Deletes a definition, telling the user what will happen to services using
    /// it — they do not disappear, they stop having a script.
    private func delete(_ definition: CustomServiceDefinition) {
        let used = CustomServiceStore.usageCount(of: definition.id)
        guard used > 0 else {
            CustomServiceStore.remove(id: definition.id)
            reloadData()
            return
        }

        let alert = UIAlertController(
            title: "Delete Service".localized,
            message: String(
                format: "%d services use this. They will keep their settings but "
                    .localized + "stop sending until they are given another type."
                    .localized,
                used
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete".localized, style: .destructive) {
            [weak self] _ in
            CustomServiceStore.remove(id: definition.id)
            self?.reloadData()
        })
        present(alert, animated: true)
    }

    /// Asks for a name, re-prompting when it is taken.
    private func promptForName(
        initialValue: String,
        title: String = "New Service".localized,
        confirmTitle: String = "Add".localized,
        completion: @escaping (String) -> Void
    ) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Name".localized
            field.text = initialValue
            field.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel))
        alert.addAction(UIAlertAction(title: confirmTitle, style: .default) { [weak self] _ in
            guard let self else { return }
            let name = alert.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if name.isEmpty {
                self.presentError("Enter a name for this service.".localized)
                return
            }
            guard CustomServiceStore.isNameAvailable(name) else {
                self.presentError(String(
                    format: "Another service is already named \"%@\". Choose a different name."
                        .localized,
                    name
                ))
                return
            }
            completion(name)
        })
        present(alert, animated: true)
    }

    private func presentError(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Ok".localized, style: .default))
        present(alert, animated: true)
    }
}

// MARK: - Table

extension CustomServiceListController: UITableViewDataSource, UITableViewDelegate {
    public func numberOfSections(in tableView: UITableView) -> Int { 1 }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        definitions.count
    }

    public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        definitions.isEmpty ? nil : "Services You Defined".localized
    }

    public func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard definitions.isEmpty else {
            return "Each one becomes a service type you can add on the Services page."
                .localized
        }
        return "Define a service by writing a script, then add it on the Services page."
            .localized
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellIdentifier, for: indexPath)
        cell.textLabel?.text = definitions[indexPath.row].name
        cell.accessoryType = .disclosureIndicator
        cell.imageView?.image = nil
        // A definition is only ever a script, so the artwork is the generic
        // service icon rather than something per-definition.
        cell.imageView?.image = UIImage.pusher(named: "DefaultService")
        return cell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard tableView.isEditing else {
            open(definitions[indexPath.row])
            return
        }
        rename(definitions[indexPath.row])
    }

    public func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { true }

    public func tableView(
        _ tableView: UITableView,
        moveRowAt sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath
    ) {
        let moved = definitions.remove(at: sourceIndexPath.row)
        definitions.insert(moved, at: destinationIndexPath.row)
        // Only the order changed, so the whole list is written back.
        CustomServiceStore.reorder(definitions)
    }

    public func tableView(
        _ tableView: UITableView,
        editingStyleForRowAt indexPath: IndexPath
    ) -> UITableViewCell.EditingStyle {
        .delete
    }

    public func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete else { return }
        delete(definitions[indexPath.row])
    }

    public func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let action = UIContextualAction(style: .destructive, title: "Delete".localized) {
            [weak self] _, _, completion in
            guard let self, indexPath.row < self.definitions.count else {
                completion(false)
                return
            }
            self.delete(self.definitions[indexPath.row])
            completion(true)
        }
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    public func tableView(
        _ tableView: UITableView,
        shouldIndentWhileEditingRowAt indexPath: IndexPath
    ) -> Bool {
        false
    }
}
