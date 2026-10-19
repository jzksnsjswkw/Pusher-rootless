import UIKit
import Preferences

/// The list of rule groups.
///
/// One level above the rules: each group is an app selection plus the rules that
/// apply within it, and a user who deals with two kinds of notification — ads from
/// shopping apps, everything from a work chat — has two groups rather than one long
/// list with a single selection that cannot describe both.
///
/// Built like the service list: a `+`, an Edit button, rows that drag and swipe.
/// The order is precedence — the first group with an opinion decides, and within a
/// group the first matching rule does.
@objc(NSPFilterRuleListController)
public final class FilterRuleListController: PlainViewController {
    private static let cell = "GroupCell"

    /// Which list this page edits.
    public enum Owner {
        case global
        case instance(String)
    }

    private let owner: Owner
    private var groups: [FilterRuleGroup] = []
    private var tableView: UITableView!

    /// Called after a change, so the page that pushed this one can refresh the
    /// count it shows.
    public var onSave: (() -> Void)?

    public init(owner: Owner) {
        self.owner = owner
        super.init(nibName: nil, bundle: nil)
    }

    /// The framework may build a detail controller through this initializer, which
    /// cannot carry an owner; a page reached that way has nothing to edit.
    public override init(nibName: String?, bundle: Bundle?) {
        self.owner = .global
        super.init(nibName: nibName, bundle: bundle)
    }

    @objc public override init(forContentSize contentSize: CGSize) {
        self.owner = .global
        super.init(forContentSize: contentSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()

        let frame = UIDevice.current.userInterfaceIdiom == .pad
            ? root?.view.bounds ?? view.bounds
            : view.bounds
        tableView = UITableView(frame: frame, style: .insetGrouped)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cell)
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)

        navigationItem.title = "Notification Filter".localized
        // Both actions on the right: the left slot is the back button, and taking
        // it is how a user gets trapped on a page.
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .add, target: self,
                            action: #selector(addGroup)),
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

    private func currentSet() -> FilterRuleSet {
        switch owner {
        case .global: return FilterRules.global()
        case .instance(let id): return FilterRules.instance(id)
        }
    }

    private func store(_ set: FilterRuleSet) {
        switch owner {
        case .global: FilterRules.setGlobal(set)
        case .instance(let id): FilterRules.setInstance(id, set)
        }
        onSave?()
    }

    private func reloadData() {
        groups = currentSet().groups
        tableView.reloadData()
        updateEditButton()
    }

    private func save() {
        store(FilterRuleSet(groups: groups))
    }

    private func updateEditButton() {
        navigationItem.rightBarButtonItems?.last?.isEnabled = !groups.isEmpty
        if groups.isEmpty, tableView.isEditing {
            tableView.setEditing(false, animated: true)
            navigationItem.rightBarButtonItems?.last?.title = "Edit".localized
        }
    }

    // MARK: - Actions

    /// Adds a group and opens it.
    ///
    /// Appended before the editor opens, and the editor replaces it in place: it
    /// reports on every change — each segment tap, each app selection — and
    /// appending on each report would add one group per tap. A group with no rules
    /// has no opinion, so the empty one that exists briefly is inert.
    @objc private func addGroup() {
        groups.append(FilterRuleGroup())
        save()
        let index = groups.count - 1
        let editor = FilterGroupEditorController(group: groups[index], isNew: true)
        editor.onSave = { [weak self] group in
            guard let self, index < self.groups.count else { return }
            self.groups[index] = group
            self.save()
            self.reloadData()
        }
        push(editor)
    }

    @objc private func toggleEditing(_ sender: UIBarButtonItem) {
        tableView.setEditing(!tableView.isEditing, animated: true)
        sender.title = tableView.isEditing ? "Done".localized : "Edit".localized
        navigationItem.rightBarButtonItems?.last?.isEnabled =
            tableView.isEditing || !groups.isEmpty
    }

    private func editGroup(at index: Int) {
        guard index < groups.count else { return }
        let editor = FilterGroupEditorController(group: groups[index], isNew: false)
        editor.onSave = { [weak self] group in
            guard let self, index < self.groups.count else { return }
            self.groups[index] = group
            self.save()
            self.reloadData()
        }
        push(editor)
    }

    private func deleteGroup(at index: Int) {
        guard index < groups.count else { return }
        groups.remove(at: index)
        save()
        reloadData()
    }

    /// Moves a group, and with it its precedence: the first group with an opinion
    /// decides, so the order is the meaning.
    private func moveGroup(from source: Int, to destination: Int) {
        guard source != destination,
              source < groups.count, destination <= groups.count else { return }
        let group = groups.remove(at: source)
        groups.insert(group, at: destination)
        save()
    }
}

// MARK: - Table

extension FilterRuleListController: UITableViewDataSource, UITableViewDelegate {
    public func numberOfSections(in tableView: UITableView) -> Int { 1 }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        groups.count
    }

    public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        groups.isEmpty ? nil : "Groups".localized
    }

    public func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard !groups.isEmpty else {
            return ("Add a group to hide or stop forwarding notifications. Each group "
                + "has its own apps and its own keywords.").localized
        }
        return ("Groups are checked in this order, and the first one that matches "
            + "decides.").localized
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cell, for: indexPath)
        let group = groups[indexPath.row]

        // The apps are the title: a group is "these apps", and the keywords inside
        // it are the detail.
        let appCount = group.scope.apps.count
        switch group.scope.target {
        case .selected:
            cell.textLabel?.text = appCount == 0
                ? "Filter selected apps".localized
                : String(format: "Filter %d apps".localized, appCount)
        case .unselected:
            cell.textLabel?.text = appCount == 0
                ? "Do not filter selected apps".localized
                : String(format: "Except %d apps".localized, appCount)
        }

        let ruleCount = group.rules.count
        cell.detailTextLabel?.text = ruleCount == 0
            ? "No rules, does nothing".localized
            : String(format: "%d rules".localized, ruleCount)
        cell.accessoryType = .disclosureIndicator
        cell.textLabel?.textColor = .label
        return cell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        editGroup(at: indexPath.row)
    }

    public func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { true }

    public func tableView(
        _ tableView: UITableView,
        moveRowAt sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath
    ) {
        moveGroup(from: sourceIndexPath.row, to: destinationIndexPath.row)
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
        // The framework's own delete action for edit mode removes the row itself
        // after this returns, so the data source is reloaded by `deleteGroup` and
        // nothing else is touched here.
        guard editingStyle == .delete else { return }
        deleteGroup(at: indexPath.row)
    }

    public func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let action = UIContextualAction(style: .destructive, title: "Delete".localized) {
            [weak self] _, _, completion in
            guard let self, indexPath.row < self.groups.count else {
                completion(false)
                return
            }
            self.deleteGroup(at: indexPath.row)
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
