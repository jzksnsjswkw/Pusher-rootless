import UIKit
import Preferences

/// One rule: which field to look in, how, for what, and what to do about it.
///
/// A `PSListController` with code-built cells, because a settings page is exactly
/// what this is — and because a plist cannot express "this row only matters when
/// that row says so", which is the whole shape of this page.
@objc(NSPFilterRuleEditorController)
public final class FilterRuleEditorController: ListController {

    private var rule: FilterRule
    private let isNew: Bool

    /// Called with the finished rule when the page is left, or when it changes —
    /// the list page saves on every edit, so a crash cannot leave the two out of
    /// step.
    public var onSave: ((FilterRule) -> Void)?

    /// The identifiers the segment rows are found by.
    private enum ID {
        static let field = "ruleField"
        static let polarity = "rulePolarity"
        static let comparison = "ruleComparison"
        static let keyword = "ruleKeyword"
        static let notes = "ruleNotes"
    }

    /// The group this rule belongs to, for the title.
    private let groupName: String?

    public init(rule: FilterRule, isNew: Bool, groupName: String? = nil) {
        self.rule = rule
        self.isNew = isNew
        self.groupName = groupName
        super.init(nibName: nil, bundle: nil)
    }

    /// The framework may build a detail controller through these, which cannot
    /// carry a rule; the page then shows nothing rather than half of something.
    public override init(nibName: String?, bundle: Bundle?) {
        self.rule = FilterRule()
        self.isNew = true
        self.groupName = nil
        super.init(nibName: nibName, bundle: bundle)
    }

    @objc public override init(forContentSize contentSize: CGSize) {
        self.rule = FilterRule()
        self.isNew = true
        self.groupName = nil
        super.init(forContentSize: contentSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Page

    public override func viewDidLoad() {
        super.viewDidLoad()
        // "过滤淘宝 规则" when the group has a name, "规则" alone when it does
        // not: the group is the context, and a page titled just "Rule" in a list
        // of several groups says nothing about which one.
        let rule = isNew ? "New Rule".localized : "Rule".localized
        if let groupName, !groupName.isEmpty {
            navigationItem.title = groupName + " " + rule
        } else {
            navigationItem.title = rule
        }
        // Installed once, through the setter that records the array's identity.
        // Without this the getter compares the framework's array against `nil` on
        // every read, concludes it was substituted, and rebuilds — a page that
        // rebuilds its own cells continuously is a page whose taps never land.
        installSpecifiers(NSMutableArray(array: buildSpecifiers()))
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Theme.setActiveTintColor(nil)
        tintToPusherColor()
    }

    /// The page builds its cells, so the framework's plist reload has nothing to
    /// answer with — this hook is where the code-built ones are put back.
    ///
    /// Without it a page's cells vanish on backgrounding: the framework discards
    /// the array and asks again on return, and a page with no plist to reload has
    /// nothing to hand it.
    public override func rebuildSpecifiers() -> NSMutableArray? {
        NSMutableArray(array: buildSpecifiers())
    }

    private func buildSpecifiers() -> [Any] {
        var all: [PSSpecifier] = []

        // ── The picture ──────────────────────────────────────────────────────
        // First, because it is what the rows under it are asking about: "match the
        // message" is a question about the third line of a notification, and the
        // picture is the only thing on this page that says which line that is.
        all.append(PSSpecifier.groupSpecifier(withName: nil)!)
        if let preview = PSSpecifier.preferenceSpecifierNamed(
            nil, target: nil, set: nil, get: nil, detail: nil,
            cell: .staticTextCell, edit: nil
        ) {
            preview.setProperty(NotificationPreviewCell.self, forKey: "cellClass")
            all.append(preview)
        }

        // ── Condition ────────────────────────────────────────────────────────
        all.append(PSSpecifier.groupSpecifier(withName: nil)!)

        all.append(segment(
            title: "Look in".localized,
            identifier: ID.field,
            values: FilterRule.Field.allCases.map { $0.rawValue },
            titles: FilterRule.Field.allCases.map { $0.label.localized },
            setSelector: #selector(setField(_:specifier:)),
            getSelector: #selector(fieldValue(_:))
        ))

        all.append(segment(
            title: "Match".localized,
            identifier: ID.polarity,
            values: ["positive", "negative"],
            titles: ["Matches".localized, "Does not match".localized],
            setSelector: #selector(setPolarity(_:specifier:)),
            getSelector: #selector(polarityValue(_:))
        ))

        all.append(segment(
            title: nil,
            identifier: ID.comparison,
            values: FilterRule.Comparison.allCases.map { $0.rawValue },
            titles: FilterRule.Comparison.allCases.map { $0.label.localized },
            setSelector: #selector(setComparison(_:specifier:)),
            getSelector: #selector(comparisonValue(_:))
        ))

        let keyword = PSSpecifier.preferenceSpecifierNamed(
            "Keyword".localized, target: self,
            set: #selector(setKeyword(_:specifier:)), get: #selector(keywordValue(_:)),
            detail: nil, cell: .editTextCell, edit: nil
        )!
        keyword.identifier = ID.keyword
        keyword.setProperty(false, forKey: "noAutoCorrect")
        all.append(keyword)

        let keywordNotes = PSSpecifier.groupSpecifier(withName: nil)!
        keywordNotes.identifier = ID.notes
        keywordNotes.setProperty(keywordNotesText(), forKey: "footerText")
        all.append(keywordNotes)



        return all
    }

    // MARK: - Cells

    /// A segment row whose selection is written straight into the rule.
    ///
    /// Code-built rather than loaded: a switch or segment loaded from a plist gets
    /// its action from the specifier at construction time, and this page has no
    /// plist to name a selector in.
    /// A segment row whose selection is written through a setter.
    ///
    /// The setter has to be named at construction, as the other code-built
    /// segments in this app do: a segment cell reads its action from the specifier
    /// when the cell is built, so a property set afterwards reaches nothing. The
    /// getter is what makes the row draw with the right segment already selected.
    private func segment(
        title: String?, identifier: String, values: [String], titles: [String],
        setSelector: Selector, getSelector: Selector
    ) -> PSSpecifier {
        let specifier = PSSpecifier.preferenceSpecifierNamed(
            title, target: self, set: setSelector, get: getSelector,
            detail: nil, cell: .segmentCell, edit: nil
        )!
        specifier.identifier = identifier
        specifier.setProperty(true, forKey: "enabled")
        specifier.setValues(values, titles: titles)
        return specifier
    }

    // MARK: - Setters and getters

    // The value a segment cell writes arrives as the segment's `values` entry —
    // a string here — and the getter returns the same shape, which is what makes
    // the row draw with the current choice selected.

    @objc private func setField(_ value: Any?, specifier: PSSpecifier) {
        let raw = (value as? String) ?? ""
        rule.field = FilterRule.Field(rawValue: raw) ?? .any
        onSave?(rule)
    }

    @objc private func fieldValue(_ specifier: PSSpecifier) -> Any? {
        rule.field.rawValue
    }

    @objc private func setPolarity(_ value: Any?, specifier: PSSpecifier) {
        let negated = (value as? String) == "negative"
        rule.relation = FilterRule.Relation(
            comparison: rule.relation.comparison, isNegated: negated
        )
        onSave?(rule)
    }

    @objc private func polarityValue(_ specifier: PSSpecifier) -> Any? {
        rule.relation.isNegated ? "negative" : "positive"
    }

    @objc private func setComparison(_ value: Any?, specifier: PSSpecifier) {
        guard let raw = value as? String,
              let comparison = FilterRule.Comparison(rawValue: raw) else { return }
        rule.relation = FilterRule.Relation(
            comparison: comparison, isNegated: rule.relation.isNegated
        )
        onSave?(rule)
    }

    @objc private func comparisonValue(_ specifier: PSSpecifier) -> Any? {
        rule.relation.comparison.rawValue
    }

    @objc private func setKeyword(_ value: Any?, specifier: PSSpecifier) {
        rule.keyword = (value as? String) ?? ""
        onSave?(rule)
        refreshNotes()
    }

    // MARK: - The pattern's verdict

    /// The paragraph under the keyword.
    ///
    /// A regular expression that does not compile matches nothing, and without a
    /// word about it a rule that can never match looks exactly like a rule that
    /// never happens to. The wording follows the encryption key's, which reports
    /// its own problem the same way.
    private func keywordNotesText(keyword live: String? = nil) -> String {
        let notes = ("Leave the keyword empty to match every notification from the apps "
            + "this list covers.").localized
        guard let problem = patternProblem(keyword: live) else { return notes }
        return "⚠️ " + problem + "\n\n" + notes
    }

    /// What is wrong with the pattern, or `nil` when it compiles.
    private func patternProblem(keyword live: String? = nil) -> String? {
        guard rule.relation.comparison == .matches else { return nil }
        let pattern = (live ?? rule.keyword).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return nil }      // empty matches everything
        guard let reported = RegexDiagnosis.problem(with: pattern) else { return nil }
        // The key, and the offset ICU reported after a bar.
        let parts = reported.split(separator: "|", maxSplits: 1)
        let sentence = String(parts[0]).localized
        guard parts.count == 2, let offset = Int(parts[1]) else { return sentence }
        return sentence + String(format: " (position %d)".localized, offset)
    }

    /// The keyword field, watched as it is typed into.
    ///
    /// `setKeyword` fires when the framework calls the setter, which is when the
    /// field loses focus — so the warning would appear only after the user looked
    /// away. The field's own `editingChanged` is what makes it appear as they type.
    private weak var keywordField: UITextField?

    private func observeKeywordField(in cell: UITableViewCell) {
        guard let field = Self.firstTextField(in: cell) else { return }
        guard keywordField !== field else { return }
        keywordField = field
        field.addTarget(self, action: #selector(keywordChanged(_:)), for: .editingChanged)
    }

    @objc private func keywordChanged(_ field: UITextField) {
        // The live text, not the stored value: the write has not happened yet.
        refreshNotes(keyword: field.text ?? "")
    }

    private static func firstTextField(in view: UIView) -> UITextField? {
        for subview in view.subviews {
            if let field = subview as? UITextField { return field }
            if let found = firstTextField(in: subview) { return found }
        }
        return nil
    }

    /// Rewrites the paragraph under the keyword, without rebuilding the section.
    ///
    /// Reloading would rebuild every cell in it — including the field being typed
    /// into, which would lose focus and its keyboard on the first keystroke.
    private func refreshNotes(keyword live: String? = nil) {
        guard let group = specifier(forID: ID.notes) else { return }
        let text = keywordNotesText(keyword: live)
        guard text != group.property(forKey: "footerText") as? String else { return }
        group.setProperty(text, forKey: "footerText")
        updateFooterView(text, identifier: ID.notes)
    }

    private func updateFooterView(_ text: String, identifier: String) {
        guard let table else { return }
        let rows = (super.specifiers ?? []).compactMap { $0 as? PSSpecifier }
        var section = -1
        for specifier in rows where specifier.cellType == .groupCell {
            section += 1
            guard specifier.identifier == identifier else { continue }
            guard section < table.numberOfSections,
                  let footer = table.footerView(forSection: section)
            else { return }

            func apply(_ view: UIView) {
                if let label = view as? UILabel { label.text = text }
                view.subviews.forEach(apply)
            }
            apply(footer)
            footer.setNeedsLayout()
            UIView.performWithoutAnimation {
                table.beginUpdates()
                table.endUpdates()
            }
            return
        }
    }

    @objc private func keywordValue(_ specifier: PSSpecifier) -> Any? {
        rule.keyword
    }
}

private extension Array {
    /// Bounds-checked access, for a segment index that may be out of range after
    /// the values change.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
