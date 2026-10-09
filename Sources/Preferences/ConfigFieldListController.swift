import UIKit
import Preferences

/// A service's own settings: the list the user declares, and where it is edited.
///
/// Modelled on the service list — a `+`, an Edit button, rows that reorder by
/// dragging — because it is the same kind of thing: an ordered list the user
/// keeps. A settings *editor* that looked like a settings page would suggest the
/// values here are what gets sent; they are the declarations, and the values are
/// filled in per service instance.
///
/// The row shows the key as its title and the kind as its detail, because those
/// are the two things that decide what a script can do with it, and the label is
/// cosmetic by comparison.
@objc(NSPConfigFieldListController)
public final class ConfigFieldListController: PlainViewController {
    private static let cellIdentifier = "ConfigFieldCell"

    /// Which service's fields these are.
    private let definitionID: String

    private var fields: [ConfigField] = []
    private var tableView: UITableView!

    public init(definitionID: String) {
        self.definitionID = definitionID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The framework builds a detail controller through `init(nibName:bundle:)`,
    /// which cannot carry the definition, so a page reached that way has nothing
    /// to edit — see the launcher row that pushes this one instead.
    public override init(nibName: String?, bundle: Bundle?) {
        self.definitionID = ""
        super.init(nibName: nibName, bundle: bundle)
    }

    @objc public override init(forContentSize contentSize: CGSize) {
        self.definitionID = ""
        super.init(forContentSize: contentSize)
    }

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

        navigationItem.title = "Configuration".localized
        // Both actions on the right: the left slot belongs to the back button,
        // and taking it is how a user gets trapped on a page.
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .add, target: self,
                            action: #selector(addField)),
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
        fields = ConfigFields.declared(byDefinition: definitionID)
        tableView.reloadData()
        updateEditButton()
    }

    private func updateEditButton() {
        navigationItem.rightBarButtonItems?.last?.isEnabled = !fields.isEmpty
        if fields.isEmpty, tableView.isEditing {
            tableView.setEditing(false, animated: true)
        }
    }

    // MARK: - Actions

    @objc private func addField() {
        let editor = ConfigFieldEditorController(
            definitionID: definitionID,
            field: ConfigField(
                key: ConfigField.uniqueKey(taken: fields.map(\.key)),
                // The group of the last field, which is almost always the one the
                // user is working in: asking them to retype it on every addition
                // would be the most repeated action on the page.
                group: fields.last?.group ?? ""
            ),
            isNew: true
        )
        editor.onSave = { [weak self] in self?.reloadData() }
        push(editor)
    }

    @objc private func toggleEditing(_ sender: UIBarButtonItem) {
        tableView.setEditing(!tableView.isEditing, animated: true)
        sender.title = tableView.isEditing ? "Done".localized : "Edit".localized
        navigationItem.rightBarButtonItems?.last?.isEnabled =
            tableView.isEditing || !fields.isEmpty
    }

    private func edit(_ field: ConfigField) {
        let editor = ConfigFieldEditorController(
            definitionID: definitionID, field: field, isNew: false
        )
        editor.onSave = { [weak self] in self?.reloadData() }
        push(editor)
    }

    private func delete(_ field: ConfigField) {
        // A value stored under a field that no longer exists is unreachable, so
        // deleting the declaration takes its values with it. Otherwise a service
        // re-declaring the same key would silently inherit values nobody could
        // see or clear.
        ConfigFields.setDeclared(fields.filter { $0.key != field.key }, forDefinition: definitionID)
        ConfigFields.forgetValues(ofKey: field.key, forDefinition: definitionID)
        reloadData()
    }

    /// Moves the row, and with it the field's *position* — which is what decides
    /// where it appears on an instance page. Groups are read from the field
    /// itself, so reordering across a group boundary moves the field into the
    /// group it now sits in, which is what dragging it there should mean.
    private func move(from source: Int, to destination: Int) {
        guard source != destination else { return }
        var moved = fields
        let field = moved.remove(at: source)
        moved.insert(field, at: destination)

        // Dragging a row next to another group's rows is how a field is moved
        // between groups: adopt the group of whatever it landed beside, so the
        // list the user sees is the list that is stored.
        if let neighbour = (destination > 0 ? moved[safe: destination - 1] : nil)
            ?? moved[safe: destination + 1] {
            moved[destination].group = neighbour.group
        }
        fields = moved
        ConfigFields.setDeclared(fields, forDefinition: definitionID)
    }
}

// MARK: - Table

extension ConfigFieldListController: UITableViewDataSource, UITableViewDelegate {
    public func numberOfSections(in tableView: UITableView) -> Int { 1 }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        fields.count
    }

    public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        fields.isEmpty ? nil : "Settings This Service Has".localized
    }

    public func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard fields.isEmpty else {
            return ("Each one is a value a service of this type fills in, read "
                + "by the script as pref.<name>.").localized
        }
        return ("Add a setting here, then the script reads it as pref.<name> and "
            + "every service of this type gets a field to fill in.").localized
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellIdentifier, for: indexPath)
        let field = fields[indexPath.row]
        cell.textLabel?.text = field.key
        cell.detailTextLabel?.text = nil

        // The kind and, when it has one, the label: the kind decides what a
        // script reads, and the label tells two fields with similar keys apart.
        var detail = field.kind.label.localized
        if !field.group.isEmpty { detail = "\(field.group) · \(detail)" }
        if field.displayTitle != field.key { detail = "\(field.displayTitle) · \(detail)" }
        cell.detailTextLabel?.text = detail
        cell.accessoryType = .disclosureIndicator
        // A monospaced key, because it is an identifier rather than prose.
        cell.textLabel?.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        return cell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        edit(fields[indexPath.row])
    }

    public func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { true }

    public func tableView(
        _ tableView: UITableView,
        moveRowAt sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath
    ) {
        move(from: sourceIndexPath.row, to: destinationIndexPath.row)
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
        guard editingStyle == .delete, indexPath.row < fields.count else { return }
        delete(fields[indexPath.row])
    }

    public func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let action = UIContextualAction(style: .destructive, title: "Delete".localized) {
            [weak self] _, _, completion in
            guard let self, indexPath.row < self.fields.count else {
                completion(false)
                return
            }
            self.delete(self.fields[indexPath.row])
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

private extension Array {
    /// Bounds-checked access, for the neighbour lookups that decide a group.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
