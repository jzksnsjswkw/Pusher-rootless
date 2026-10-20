import UIKit
import Preferences

/// One group: which apps it is about, and the rules inside it.
///
/// A `PlainViewController` with its own table, like the group list above it and
/// the rule list it used to be: the scope is two rows at the top and the rules are
/// a draggable list below, which is two different kinds of row in one page.
@objc(NSPFilterGroupEditorController)
public final class FilterGroupEditorController: PlainViewController {
    private static let ruleCell = "RuleCell"

    private var group: FilterRuleGroup
    private let isNew: Bool
    private var tableView: UITableView!

    /// Called with the finished group on every change, so the list behind this page
    /// stays in step and a crash cannot leave the two disagreeing.
    public var onSave: ((FilterRuleGroup) -> Void)?

    public init(group: FilterRuleGroup, isNew: Bool) {
        self.group = group
        self.isNew = isNew
        super.init(nibName: nil, bundle: nil)
    }

    public override init(nibName: String?, bundle: Bundle?) {
        self.group = FilterRuleGroup()
        self.isNew = true
        super.init(nibName: nibName, bundle: bundle)
    }

    @objc public override init(forContentSize contentSize: CGSize) {
        self.group = FilterRuleGroup()
        self.isNew = true
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
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.ruleCell)
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)

        updateTitle()
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .add, target: self,
                            action: #selector(addRule)),
            UIBarButtonItem(title: "Edit".localized, style: .plain, target: self,
                            action: #selector(toggleEditing(_:))),
        ]
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Theme.setActiveTintColor(nil)
        tintToPusherColor()
        // The app picker writes back through the closure it was given, and the row
        // that shows the count has to be redrawn when it returns — this page is not
        // rebuilt by the framework, so it does it itself.
        tableView.reloadData()
        updateTitle()
    }

    // MARK: - Actions

    @objc private func addRule() {
        group.rules.append(FilterRule())
        onSave?(group)
        let index = group.rules.count - 1
        let editor = FilterRuleEditorController(
            rule: group.rules[index], isNew: true, groupName: groupName
        )
        editor.onSave = { [weak self] rule in
            guard let self, index < self.group.rules.count else { return }
            self.group.rules[index] = rule
            self.onSave?(self.group)
            self.tableView.reloadData()
        }
        push(editor)
    }

    @objc private func combinationChanged(_ sender: UISegmentedControl) {
        let all = FilterRuleGroup.Combination.allCases
        guard sender.selectedSegmentIndex < all.count else { return }
        group.combination = all[sender.selectedSegmentIndex]
        onSave?(group)
    }

    @objc private func actionChanged(_ sender: UISegmentedControl) {
        let all = FilterRule.Action.allCases
        guard sender.selectedSegmentIndex < all.count else { return }
        group.action = all[sender.selectedSegmentIndex]
        onSave?(group)
    }

    @objc private func nameChanged(_ field: UITextField) {
        group.name = field.text ?? ""
        updateTitle()
        onSave?(group)
    }

    /// The bar title: the group's own name when it has one, otherwise what it is.
    private func updateTitle() {
        let trimmed = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        navigationItem.title = trimmed.isEmpty
            ? (isNew && group.scope.apps.isEmpty && group.rules.isEmpty
                ? "New Group".localized
                : "Group".localized)
            : trimmed
    }

    /// What a rule is called: where it looks, how it matches, and the word.
    ///
    /// "标题包含 嘿嘿" rather than "嘿嘿": the keyword alone does not say what is
    /// being matched, and two rules on the same word for different fields would
    /// look the same. A rule with no keyword matches everything, and says so.
    static func name(of rule: FilterRule) -> String {
        let head = rule.derivedNameParts.field.localized
            + rule.derivedNameParts.relation.localized
        guard rule.hasKeyword else { return head }
        return head + " " + rule.keyword
    }

    /// The same name the group list would derive, shown as the placeholder.
    static func derivedName(of group: FilterRuleGroup) -> String {
        let verb = group.derivedVerb.localized
        guard !group.scope.apps.isEmpty else {
            return verb + " " + "nothing".localized
        }
        let names = group.scope.apps.map {
            LSApplicationProxy.applicationProxy(forIdentifier: $0)?.localizedName ?? $0
        }
        return verb + " " + names.joined(separator: ",")
    }

    /// The name to prefix a rule page's title with: the group's own, or none.
    private var groupName: String {
        let trimmed = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.derivedName(of: group) : trimmed
    }

    @objc private func toggleRule(_ sender: UISwitch) {
        guard sender.tag < group.rules.count else { return }
        group.rules[sender.tag].isEnabled = sender.isOn
        onSave?(group)
        tableView.reloadData()
    }

    @objc private func toggleEditing(_ sender: UIBarButtonItem) {
        tableView.setEditing(!tableView.isEditing, animated: true)
        sender.title = tableView.isEditing ? "Done".localized : "Edit".localized
    }

    private func editRule(at index: Int) {
        guard index < group.rules.count else { return }
        let editor = FilterRuleEditorController(
            rule: group.rules[index], isNew: false, groupName: groupName
        )
        editor.onSave = { [weak self] rule in
            guard let self, index < self.group.rules.count else { return }
            self.group.rules[index] = rule
            self.onSave?(self.group)
            self.tableView.reloadData()
        }
        push(editor)
    }

    private func deleteRule(at index: Int) {
        guard index < group.rules.count else { return }
        group.rules.remove(at: index)
        onSave?(group)
        tableView.reloadData()
    }

    private func moveRule(from source: Int, to destination: Int) {
        guard source != destination,
              source < group.rules.count, destination <= group.rules.count else { return }
        let rule = group.rules.remove(at: source)
        group.rules.insert(rule, at: destination)
        onSave?(group)
    }

    private func editApps() {
        push(AppListController.standalone(
            title: "Apps".localized,
            selection: { [weak self] in self?.group.scope.apps ?? [] },
            write: { [weak self] appIDs in
                guard let self else { return }
                self.group.scope.apps = appIDs
                self.onSave?(self.group)
            }
        ))
    }

    /// The kind of selection, from the segment.
    ///
    /// The apps are kept: the same ones usually stay interesting, and the only
    /// thing that changed is how they are read.
    @objc private func targetChanged(_ sender: UISegmentedControl) {
        group.scope.target = sender.selectedSegmentIndex == 0 ? .selected : .unselected
        onSave?(group)
    }
}

// MARK: - Table

extension FilterGroupEditorController: UITableViewDataSource, UITableViewDelegate {
    public func numberOfSections(in tableView: UITableView) -> Int { 4 }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 1          // the name
        case 1: return 2          // when it matches: combination and outcome
        case 2: return 2          // the scope
        default: return group.rules.count
        }
    }

    public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "Name".localized
        case 1: return "When It Matches".localized
        case 2: return "Applies To".localized
        default: return "Rules".localized
        }
    }

    public func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 {
            return ("Leave it empty to name the group after the apps it covers.")
                .localized
        }
        if section == 1 {
            return ("Hiding means SpringBoard never publishes the notification; the "
                + "phone does not draw it.").localized
        }
        if section == 2 {
            return ("These rules only look at notifications from the apps above.")
                .localized
        }
        guard !group.rules.isEmpty else {
            return ("Add a rule to hide or stop forwarding notifications that match a "
                + "keyword. Leaving the keyword empty matches every notification from "
                + "these apps.").localized
        }
        return ("The first rule that matches is the one that applies.").localized
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            // An editable row rather than a settings cell: the name is free text,
            // and the derived name it replaces is shown as the placeholder — so a
            // user who leaves it alone sees what they are leaving it as.
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            let field = UITextField()
            field.text = group.name
            field.placeholder = Self.derivedName(of: group)
            field.clearButtonMode = .whileEditing
            field.autocorrectionType = .no
            field.returnKeyType = .done
            field.translatesAutoresizingMaskIntoConstraints = false
            field.addTarget(self, action: #selector(nameChanged(_:)), for: .editingChanged)
            cell.contentView.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
                field.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
                field.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            ])
            cell.selectionStyle = .none
            return cell
        }

        if indexPath.section == 1, indexPath.row == 0 {
            // Which combination of rules. Two options, both short.
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            let control = UISegmentedControl(items:
                FilterRuleGroup.Combination.allCases.map { $0.label.localized }
            )
            control.selectedSegmentIndex =
                FilterRuleGroup.Combination.allCases.firstIndex(of: group.combination) ?? 0
            control.addTarget(self, action: #selector(combinationChanged(_:)),
                              for: .valueChanged)
            control.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(control)
            NSLayoutConstraint.activate([
                control.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
                control.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
                control.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            ])
            cell.selectionStyle = .none
            return cell
        }

        if indexPath.section == 2 {
            if indexPath.row == 0 {
                // A segment, like every other two-way choice in this app: it shows
                // both options and the current one.
                let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
                let control = UISegmentedControl(items: [
                    FilterRule.Scope.Target.selected.label.localized,
                    FilterRule.Scope.Target.unselected.label.localized,
                ])
                control.selectedSegmentIndex = group.scope.target == .selected ? 0 : 1
                control.addTarget(self, action: #selector(targetChanged(_:)),
                                  for: .valueChanged)
                control.translatesAutoresizingMaskIntoConstraints = false
                cell.contentView.addSubview(control)
                NSLayoutConstraint.activate([
                    control.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
                    control.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
                    control.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
                ])
                cell.selectionStyle = .none
                return cell
            }
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = "Apps".localized
            let count = group.scope.apps.count
            cell.detailTextLabel?.text = count == 0
                ? "None".localized
                : String(format: "%d selected".localized, count)
            cell.accessoryType = .disclosureIndicator
            return cell
        }

        if indexPath.section == 1, indexPath.row == 1 {
            // What happens when the group matches, from the three outcomes.
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            let control = UISegmentedControl(items:
                FilterRule.Action.allCases.map { $0.label.localized }
            )
            control.selectedSegmentIndex =
                FilterRule.Action.allCases.firstIndex(of: group.action) ?? 0
            control.addTarget(self, action: #selector(actionChanged(_:)), for: .valueChanged)
            control.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(control)
            NSLayoutConstraint.activate([
                control.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
                control.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
                control.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            ])
            cell.selectionStyle = .none
            return cell
        }

        let cell = tableView.dequeueReusableCell(withIdentifier: Self.ruleCell, for: indexPath)
        let rule = group.rules[indexPath.row]

        // Named the way it reads: "标题包含 嘿嘿". The keyword alone does not say
        // what is being matched, and two rules on the same word for different
        // fields would look identical.
        cell.textLabel?.text = Self.name(of: rule)
        cell.textLabel?.textColor = rule.isEnabled ? .label : .secondaryLabel
        // The rule no longer decides what happens — the group does — so its own
        // subtitle is only where it looks and its word.
        cell.detailTextLabel?.text = rule.isEnabled ? nil : "Off".localized
        cell.accessoryType = .disclosureIndicator

        let toggle = UISwitch()
        toggle.isOn = rule.isEnabled
        toggle.tag = indexPath.row
        toggle.addTarget(self, action: #selector(toggleRule(_:)), for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 { return }        // the name field handles itself
        if indexPath.section == 1 { return }        // both rows are segments
        if indexPath.section == 2 {
            // Row 0 is a segment and handles its own taps.
            if indexPath.row == 1 { editApps() }
            return
        }
        editRule(at: indexPath.row)
    }

    public func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        indexPath.section == 2
    }

    public func tableView(
        _ tableView: UITableView,
        moveRowAt sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath
    ) {
        moveRule(from: sourceIndexPath.row, to: destinationIndexPath.row)
    }

    public func tableView(
        _ tableView: UITableView,
        editingStyleForRowAt indexPath: IndexPath
    ) -> UITableViewCell.EditingStyle {
        indexPath.section == 3 ? .delete : .none
    }

    public func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete, indexPath.section == 3 else { return }
        deleteRule(at: indexPath.row)
    }

    public func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 3 else { return nil }
        let action = UIContextualAction(style: .destructive, title: "Delete".localized) {
            [weak self] _, _, completion in
            guard let self, indexPath.row < self.group.rules.count else {
                completion(false)
                return
            }
            self.deleteRule(at: indexPath.row)
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
        indexPath.section == 3
    }
}
