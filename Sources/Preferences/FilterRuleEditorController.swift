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
        static let enabled = "ruleEnabled"
        static let field = "ruleField"
        static let relation = "ruleRelation"
        static let action = "ruleAction"
        static let keyword = "ruleKeyword"
    }

    public init(rule: FilterRule, isNew: Bool) {
        self.rule = rule
        self.isNew = isNew
        super.init(nibName: nil, bundle: nil)
    }

    /// The framework may build a detail controller through these, which cannot
    /// carry a rule; the page then shows nothing rather than half of something.
    public override init(nibName: String?, bundle: Bundle?) {
        self.rule = FilterRule()
        self.isNew = true
        super.init(nibName: nibName, bundle: bundle)
    }

    @objc public override init(forContentSize contentSize: CGSize) {
        self.rule = FilterRule()
        self.isNew = true
        super.init(forContentSize: contentSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Page

    public override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = isNew ? "New Rule".localized : "Rule".localized
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

        // ── On/off ───────────────────────────────────────────────────────────
        all.append(PSSpecifier.groupSpecifier(withName: nil)!)
        let enabled = PSSpecifier.preferenceSpecifierNamed(
            "Enabled".localized, target: self,
            set: #selector(setRuleEnabled(_:specifier:)), get: #selector(ruleEnabledValue(_:)),
            detail: nil, cell: .switchCell, edit: nil
        )!
        enabled.identifier = ID.enabled
        all.append(enabled)

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
            identifier: ID.relation,
            values: FilterRule.Relation.allCases.map { $0.rawValue },
            titles: FilterRule.Relation.allCases.map { $0.label.localized },
            setSelector: #selector(setRelation(_:specifier:)),
            getSelector: #selector(relationValue(_:))
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
        keywordNotes.setProperty(
            ("Leave the keyword empty to match every notification from the apps "
                + "this list covers.").localized,
            forKey: "footerText"
        )
        all.append(keywordNotes)

        // ── Outcome ──────────────────────────────────────────────────────────
        all.append(PSSpecifier.groupSpecifier(withName: nil)!)
        all.append(segment(
            title: nil,
            identifier: ID.action,
            values: FilterRule.Action.allCases.map { $0.rawValue },
            titles: FilterRule.Action.allCases.map { $0.label.localized },
            setSelector: #selector(setAction(_:specifier:)),
            getSelector: #selector(actionValue(_:))
        ))

        let footer = PSSpecifier.groupSpecifier(withName: nil)!
        footer.setProperty(
            ("Hiding means SpringBoard never publishes the notification; "
                + "the phone does not draw it.").localized,
            forKey: "footerText"
        )
        all.append(footer)

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

    @objc private func setRuleEnabled(_ value: Any?, specifier: PSSpecifier) {
        rule.isEnabled = (value as? NSNumber)?.boolValue ?? false
        onSave?(rule)
    }

    @objc private func ruleEnabledValue(_ specifier: PSSpecifier) -> Any? {
        NSNumber(value: rule.isEnabled)
    }

    @objc private func setField(_ value: Any?, specifier: PSSpecifier) {
        let raw = (value as? String) ?? ""
        rule.field = FilterRule.Field(rawValue: raw) ?? .any
        onSave?(rule)
    }

    @objc private func fieldValue(_ specifier: PSSpecifier) -> Any? {
        rule.field.rawValue
    }

    @objc private func setRelation(_ value: Any?, specifier: PSSpecifier) {
        let raw = (value as? String) ?? ""
        rule.relation = FilterRule.Relation(rawValue: raw) ?? .contains
        onSave?(rule)
    }

    @objc private func relationValue(_ specifier: PSSpecifier) -> Any? {
        rule.relation.rawValue
    }

    @objc private func setAction(_ value: Any?, specifier: PSSpecifier) {
        let raw = (value as? String) ?? ""
        rule.action = FilterRule.Action(rawValue: raw) ?? .suppressAll
        onSave?(rule)
    }

    @objc private func actionValue(_ specifier: PSSpecifier) -> Any? {
        rule.action.rawValue
    }

    @objc private func setKeyword(_ value: Any?, specifier: PSSpecifier) {
        rule.keyword = (value as? String) ?? ""
        onSave?(rule)
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
