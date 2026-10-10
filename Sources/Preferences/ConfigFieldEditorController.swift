import UIKit
import Preferences

/// One declared setting: its name, its label, how it is edited, and what a new
/// service starts with.
///
/// A `PSListController` rather than a hand-built table, because every row here
/// is a standard Preferences cell — a text field, a switch, a segmented control —
/// and the framework's edit cells already do what they need: they read their
/// value through a getter, write it through a setter, and pass touches through
/// to the list so a tap starts editing rather than navigating.
///
/// The page saves on the way out rather than per keystroke: the key has to be
/// validated against the others, and doing that while it is half-typed would
/// reject every name as it is entered.
@objc(NSPConfigFieldEditorController)
public final class ConfigFieldEditorController: ListController {
    private let definitionID: String
    private let isNew: Bool
    private var field: ConfigField

    /// Called after a save, so the list behind this page can reload.
    var onSave: (() -> Void)?

    private static let keyIdentifier = "configFieldKey"
    private static let titleIdentifier = "configFieldTitle"
    private static let kindIdentifier = "configFieldKind"
    private static let groupIdentifier = "configFieldGroup"
    private static let noteIdentifier = "configFieldNote"
    private static let defaultValueIdentifier = "configFieldDefault"
    private static let footerIdentifier = "configFieldFooter"

    init(definitionID: String, field: ConfigField, isNew: Bool) {
        self.definitionID = definitionID
        self.field = field
        self.isNew = isNew
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override init(nibName: String?, bundle: Bundle?) {
        self.definitionID = ""
        self.field = ConfigField(key: "field")
        self.isNew = true
        super.init(nibName: nibName, bundle: bundle)
    }

    @objc public override init(forContentSize contentSize: CGSize) {
        self.definitionID = ""
        self.field = ConfigField(key: "field")
        self.isNew = true
        super.init(forContentSize: contentSize)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = isNew ? "New Setting".localized : "Edit Setting".localized
        installSpecifiers(buildSpecifiers())
    }

    /// Rebuilds the page from the field it is editing.
    ///
    /// Without this the framework's own plist-derived array — ten cells of
    /// Pushover's settings, this page having no plist of its own — replaces the
    /// real one whenever the app is backgrounded, and the page comes back showing
    /// a stranger's settings. Every code-built page needs this hook; this one was
    /// missing it.
    public override func rebuildSpecifiers() -> NSMutableArray? {
        buildSpecifiers()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        save()
    }

    // MARK: - Cells

    private func buildSpecifiers() -> NSMutableArray {
        var all: [PSSpecifier] = []

        // ── What the script reads it by ─────────────────────────────────────
        let identity = PSSpecifier.groupSpecifier(withName: "Name".localized)
        identity?.setProperty(
            ("The script reads this setting as pref.<name>. It is the storage key, "
                + "so changing it after a script uses it breaks that script.").localized,
            forKey: "footerText"
        )
        if let identity { all.append(identity) }

        all.append(editCell("configFieldKey", title: "Name", placeholder: "apiKey",
                            identifier: Self.keyIdentifier,
                            set: #selector(setKey(_:specifier:)), get: #selector(readKey(_:))))

        // The name problem, shown under the field it is about. The row is always
        // present so the page's shape does not change as the user types; its text
        // is what comes and goes.
        let footer = PSSpecifier.emptyGroup()
        footer?.identifier = Self.footerIdentifier
        if let footer { all.append(footer) }
        refreshKeyProblem()

        // ── How it is presented ─────────────────────────────────────────────
        let presentation = PSSpecifier.groupSpecifier(withName: "Presentation".localized)
        if let presentation { all.append(presentation) }

        all.append(editCell("configFieldTitle", title: "Label", placeholder: "API Key",
                            identifier: Self.titleIdentifier,
                            set: #selector(setTitleField(_:specifier:)),
                            get: #selector(readTitleField(_:))))

        if let kind = PSSpecifier.preferenceSpecifierNamed(
            "Type".localized, target: self,
            set: #selector(setKind(_:specifier:)), get: #selector(readKind(_:)),
            detail: nil, cell: .segmentCell, edit: nil
        ) {
            kind.identifier = Self.kindIdentifier
            kind.setProperty(true, forKey: "enabled")
            kind.setValues(
                [ConfigField.Kind.text.rawValue, ConfigField.Kind.toggle.rawValue],
                titles: [ConfigField.Kind.text.label.localized,
                         ConfigField.Kind.toggle.label.localized]
            )
            all.append(kind)
        }

        all.append(editCell("configFieldGroup", title: "Group", placeholder: "Connection",
                            identifier: Self.groupIdentifier,
                            set: #selector(setGroup(_:specifier:)), get: #selector(readGroup(_:))))
        all.append(editCell("configFieldNote", title: "Note", placeholder: "",
                            identifier: Self.noteIdentifier,
                            set: #selector(setNote(_:specifier:)), get: #selector(readNote(_:)),
                            noAutoCorrect: false))

        let presentationGroup = all.lastIndex { $0.cellType == .groupCell }
        if let presentationGroup {
            all[presentationGroup].setProperty(
                ("Fields sharing a group appear under one heading, with the note "
                    + "as its explanation.").localized,
                forKey: "footerText"
            )
        }

        // ── What a new service starts with ──────────────────────────────────
        let defaults = PSSpecifier.groupSpecifier(
            withName: "Default for New Services".localized
        )
        defaults?.setProperty(
            ("Fills the field in when a service of this type is added. A service "
                + "you have already added keeps its own value, and one you leave "
                + "empty stays empty.").localized,
            forKey: "footerText"
        )
        if let defaults { all.append(defaults) }

        // The default's control follows the kind, because a switch's default can
        // only be on or off and a text field's can only be text.
        if field.kind == .toggle {
            let toggle = PSSpecifier.preferenceSpecifierNamed(
                "Default".localized, target: self,
                set: #selector(setDefaultToggle(_:specifier:)),
                get: #selector(readDefaultToggle(_:)),
                detail: nil, cell: .switchCell, edit: nil
            )
            toggle?.identifier = Self.defaultValueIdentifier
            toggle?.setProperty(true, forKey: "enabled")
            if let toggle { all.append(toggle) }
        } else {
            all.append(editCell("configFieldDefault", title: "Default", placeholder: "",
                                identifier: Self.defaultValueIdentifier,
                                set: #selector(setDefaultText(_:specifier:)),
                                get: #selector(readDefaultText(_:))))
        }

        return NSMutableArray(array: all)
    }

    /// One editable text row.
    ///
    /// The setter and getter are this controller's rather than the storage
    /// layer's: the field is held here until the page is left, so that the whole
    /// declaration is validated and written once rather than cell by cell.
    private func editCell(
        _ label: String,
        title: String,
        placeholder: String,
        identifier: String,
        set: Selector,
        get: Selector,
        noAutoCorrect: Bool = true
    ) -> PSSpecifier {
        let specifier = PSSpecifier.preferenceSpecifierNamed(
            title.localized, target: self, set: set, get: get,
            detail: nil, cell: .editTextCell, edit: nil
        ) ?? PSSpecifier()
        specifier.identifier = identifier
        specifier.setProperty(true, forKey: "enabled")
        // The placeholder is localised: it is a hint about what goes in the field
        // ("API Key", "Connection"), and the ones that are example *values*
        // ("apiKey") pass through unchanged because the string table has no entry
        // for them.
        specifier.setProperty(placeholder.localized, forKey: "placeholder")
        if noAutoCorrect {
            specifier.setProperty(true, forKey: "noAutoCorrect")
        }
        return specifier
    }

    // MARK: - Reading and writing the field

    @objc private func readKey(_ specifier: PSSpecifier) -> String { field.key }
    @objc private func setKey(_ value: Any?, specifier: PSSpecifier) {
        field.key = (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        refreshKeyProblem()
    }

    @objc private func readTitleField(_ specifier: PSSpecifier) -> String { field.title }
    @objc private func setTitleField(_ value: Any?, specifier: PSSpecifier) {
        field.title = value as? String ?? ""
    }

    @objc private func readGroup(_ specifier: PSSpecifier) -> String { field.group }
    @objc private func setGroup(_ value: Any?, specifier: PSSpecifier) {
        field.group = (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func readNote(_ specifier: PSSpecifier) -> String { field.note }
    @objc private func setNote(_ value: Any?, specifier: PSSpecifier) {
        field.note = value as? String ?? ""
    }

    @objc private func readKind(_ specifier: PSSpecifier) -> String { field.kind.rawValue }
    @objc private func setKind(_ value: Any?, specifier: PSSpecifier) {
        let name = value as? String ?? ConfigField.Kind.text.rawValue
        let kind = ConfigField.Kind(rawValue: name) ?? .text
        guard kind != field.kind else { return }
        field.kind = kind
        // The default's control differs by kind, so the page is rebuilt rather
        // than left showing a switch for a text field.
        field.defaultValue = kind == .toggle ? false : ""
        installSpecifiers(buildSpecifiers())
    }

    @objc private func readDefaultText(_ specifier: PSSpecifier) -> String { field.defaultString }
    @objc private func setDefaultText(_ value: Any?, specifier: PSSpecifier) {
        field.defaultValue = value as? String ?? ""
    }

    @objc private func readDefaultToggle(_ specifier: PSSpecifier) -> NSNumber {
        NSNumber(value: field.defaultBool)
    }
    @objc private func setDefaultToggle(_ value: Any?, specifier: PSSpecifier) {
        field.defaultValue = (value as? NSNumber)?.boolValue ?? false
    }

    /// Shows, under the name field, why the name cannot be used.
    ///
    /// The row is a group cell, so its footer is the message — which is where a
    /// Preferences page puts a problem with the row above it.
    private func refreshKeyProblem() {
        guard let footer = specifier(forID: Self.footerIdentifier) else { return }
        footer.setProperty(keyProblemText(), forKey: "footerText")
        reloadSpecifier(footer, animated: false)
    }

    private func keyProblemText() -> String? {
        let key = field.key
        guard let problem = ConfigField.keyProblem(key) else {
            // A name that is fine but already taken is the same kind of problem.
            let taken = ConfigFields.declared(byDefinition: definitionID)
                .filter { isNew || $0.key != originalKey }
                .map(\.key)
            if taken.contains(key) {
                return String(
                    format: "\"%@\" is already a setting of this service.".localized, key
                )
            }
            return nil
        }
        switch problem {
        case .isEmpty:
            return "The name cannot be empty.".localized
        case .isNotAnIdentifier:
            return ("The name must start with a letter and contain only letters, "
                + "digits and underscores.").localized
        case .isReserved(let name):
            return String(
                format: "\"%@\" is already used by the script environment.".localized, name
            )
        }
    }

    /// The key the field had when this page opened, so renaming it to the same
    /// name is not reported as a clash with itself.
    private var originalKey: String {
        get { objc_getAssociatedObject(self, &Self.originalKeyKey) as? String ?? field.key }
        set { objc_setAssociatedObject(self, &Self.originalKeyKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }
    private static var originalKeyKey = 0

    // MARK: - Saving

    /// Writes the declaration, or complains and stays.
    ///
    /// Validated here rather than per keystroke so a half-typed name is not
    /// rejected as it is entered; refusing to leave would be worse than losing
    /// the edit, so a problem is reported and the page stays open to fix it.
    private func save() {
        guard !definitionID.isEmpty, hasLoadedSpecifiers else { return }
        view.endEditing(true)

        if let problem = keyProblemText() {
            presentProblem(problem)
            return
        }

        var fields = ConfigFields.declared(byDefinition: definitionID)
        if isNew {
            fields.append(field)
        } else if let index = fields.firstIndex(where: { $0.key == originalKey }) {
            // A rename moves the stored values with it, so a service filling the
            // field in does not lose what it had.
            if originalKey != field.key {
                ConfigFields.renameValue(from: originalKey, to: field.key,
                                        forDefinition: definitionID)
            }
            fields[index] = field
        } else {
            fields.append(field)
        }
        ConfigFields.setDeclared(fields, forDefinition: definitionID)
        onSave?()
    }

    /// Reports a problem and keeps the page open, so it can be fixed.
    private func presentProblem(_ message: String) {
        // Marked as already-saved so leaving the page after dismissing the alert
        // does not try to save again and re-report it.
        isReportingProblem = true
        let alert = UIAlertController(
            title: "This setting needs a name".localized,
            message: message, preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Ok".localized, style: .default) { [weak self] _ in
            self?.isReportingProblem = false
        })
        present(alert, animated: true)
    }

    private var isReportingProblem = false

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }
}
