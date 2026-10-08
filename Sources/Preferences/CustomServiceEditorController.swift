import UIKit
import Preferences

/// Edits one service definition: its name, its script, and the settings new
/// services of its kind start with.
///
/// The script is the definition, so the page exists mainly to give it room. The
/// options below it are the *defaults* for services of this kind — an instance
/// can still change them — which is what keeps adding a service of this kind a
/// one-tap action rather than another configuration pass.
@objc(NSPCustomServiceEditorController)
public final class CustomServiceEditorController: ListController {
    private let definitionID: String

    private static let scriptRowIdentifier = "script"
    private static let nameRowIdentifier = "name"

    /// The framework builds the page through this initializer when a plist names
    /// it, and through the one below when this code does. Both are needed; see
    /// ``ServiceListController`` for what happens otherwise.
    public override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        self.definitionID = ""
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    @objc public override init(forContentSize contentSize: CGSize) {
        self.definitionID = ""
        super.init(forContentSize: contentSize)
    }

    init(definitionID: String) {
        self.definitionID = definitionID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The definition being edited.
    private var definition: CustomServiceDefinition? {
        CustomServiceStore.definition(id: definitionID)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = definition?.name ?? "Custom".localized
        installSpecifiers(buildSpecifiers())
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The name or script may have changed on the pages this one pushes.
        navigationItem.title = definition?.name ?? "Custom".localized
        table?.reloadData()
    }

    // MARK: - Specifiers

    private func buildSpecifiers() -> NSMutableArray {
        var all: [PSSpecifier] = []

        // ── The identity ────────────────────────────────────────────────────
        let identityGroup = PSSpecifier.groupSpecifier(withName: "Service".localized)
        if let identityGroup { all.append(identityGroup) }

        let name = PSSpecifier.preferenceSpecifierNamed(
            "Name".localized, target: self,
            set: #selector(setName(_:specifier:)), get: #selector(readName(_:)),
            detail: nil, cell: .editTextCell, edit: nil
        )
        name?.identifier = Self.nameRowIdentifier
        name?.setProperty(true, forKey: "enabled")
        if let name { all.append(name) }

        // ── The script ──────────────────────────────────────────────────────
        let scriptGroup = PSSpecifier.emptyGroup()
        scriptGroup?.setProperty(
            "The script runs for every notification. Call push(req) to send one; "
                .localized + "call it more than once to send several, or not at all "
                .localized + "to skip this notification.".localized,
            forKey: "footerText"
        )

        let scriptRow = PSSpecifier.preferenceSpecifierNamed(
            scriptSummary(), target: nil, set: nil, get: nil,
            detail: CustomServiceScriptController.self, cell: .linkCell, edit: nil
        )
        scriptRow?.identifier = Self.scriptRowIdentifier
        scriptRow?.setProperty("DefaultService", forKey: "icon")
        if let scriptGroup { all.append(scriptGroup) }
        if let scriptRow { all.append(scriptRow) }

        // ── The defaults for services of this kind ──────────────────────────
        let defaultsGroup = PSSpecifier.groupSpecifier(
            withName: "Defaults for New Services".localized
        )
        defaultsGroup?.setProperty(
            "Services you add from this type start with these, and can still change "
                .localized + "them individually.".localized,
            forKey: "footerText"
        )
        if let defaultsGroup { all.append(defaultsGroup) }

        // The payload options live on the definition, so a new instance inherits
        // them; they are read from here by ``CustomServiceDefinition``'s
        // descriptor, not from an instance.
        all.append(contentsOf: ServiceSpecifierBuilders.shared.builders(
            for: ServiceSpecifierBuilders.payloadOptionsKey,
            instanceID: definitionID, appID: nil
        ))

        return NSMutableArray(array: all)
    }

    /// A one-line summary of the script, so the row stays a row.
    private func scriptSummary() -> String {
        let script = (definition?.script ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return "Script".localized }
        let lines = script.split(separator: "\n").count
        let firstLine = script
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let shown = firstLine.count > 38 ? String(firstLine.prefix(38)) + "…" : firstLine
        return "\(shown)  (\(lines))"
    }

    // MARK: - Name

    @objc public func readName(_ specifier: PSSpecifier) -> Any? {
        definition?.name ?? ""
    }

    /// Renames the definition, refusing a name another one already has.
    @objc public func setName(_ value: Any?, specifier: PSSpecifier) {
        let name = ((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, CustomServiceStore.isNameAvailable(name, excluding: definitionID),
              var definition else { return }
        definition.name = name
        CustomServiceStore.save(definition, notify: false)
        navigationItem.title = name
    }

    // MARK: - Rows

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        super.tableView(tableView, didSelectRowAt: indexPath)
        tableView.deselectRow(at: indexPath, animated: true)

        guard let specifier = specifier(at: indexPath),
              specifier.identifier == Self.scriptRowIdentifier, let definition
        else { return }
        push(CustomServiceScriptController(definitionID: definition.id))
    }
}

// MARK: - The script editor

/// Edits the script of one definition.
///
/// A text view filling the page, because a script is code: it wants the whole
/// screen, monospaced text and no autocorrection. The navigation bar carries the
/// insertable examples, since a user starting from nothing needs to see the shape
/// of a script before they can write one.
@objc(NSPCustomServiceScriptController)
public final class CustomServiceScriptController: UIViewController {
    private let definitionID: String
    private let textView = UITextView()

    init(definitionID: String) {
        self.definitionID = definitionID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()

        navigationItem.title = "Script".localized
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Examples".localized, style: .plain,
            target: self, action: #selector(showExamples)
        )

        view.backgroundColor = .systemGroupedBackground
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        textView.keyboardType = .asciiCapable
        textView.text = CustomServiceStore.definition(id: definitionID)?.script ?? ""
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // Anchored to the keyboard guide so the caret is never underneath it.
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        save()
    }

    /// Writes the script back onto its definition, which is what makes an edit
    /// take effect for every service using it.
    private func save() {
        guard var definition = CustomServiceStore.definition(id: definitionID) else { return }
        let text = textView.text ?? ""
        guard text != definition.script else { return }
        definition.script = text
        CustomServiceStore.save(definition)
    }

    // MARK: - Examples

    /// The API, as runnable snippets.
    ///
    /// Offering them beats documenting them: a user starting from nothing needs to
    /// see the shape of a script before they can write one, and there is no
    /// reference page inside Settings to point at.
    static let examples: [(title: String, code: String)] = [
        (
            "Send a notification",
            """
            push({
                url: "https://example.com/notify",
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: {
                    title: bullet.title,
                    message: bullet.message,
                    app: bullet.appName
                }
            });
            """
        ),
        (
            "Skip some notifications",
            """
            // Calling nothing skips the notification instead of forwarding it.
            if (bullet.message.includes("code")) {
                push({
                    url: "https://example.com/code",
                    method: "POST",
                    body: { code: bullet.message }
                });
            }
            """
        ),
        (
            "Get a token first",
            """
            // Top-level await works: the script is run as an async function.
            const tokenResp = await fetch("https://example.com/token", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: { user: "me" }
            });
            const token = (await tokenResp.json()).token;

            await fetch("https://example.com/send", {
                method: "POST",
                headers: { Authorization: "Bearer " + token },
                body: { title: bullet.title, message: bullet.message }
            });
            """
        ),
        (
            "Remember values between runs",
            """
            // localStorage is kept per service, so two services of this type do
            // not share it.
            let count = Number(localStorage.getItem("count") || "0") + 1;
            localStorage.setItem("count", String(count));

            push({
                url: "https://example.com/notify",
                method: "POST",
                body: { seen: count, title: bullet.title }
            });
            """
        ),
        (
            "What the notification carries",
            """
            console.log(bullet);
            // bullet.deviceName, bullet.appName, bullet.appID
            // bullet.title, bullet.subtitle, bullet.message, bullet.date
            // bullet.icon   — base64 PNG of the app icon
            // bullet.image  — base64 of the notification's attachment
            //
            // Also available: fetch(url, init), localStorage, console.log()
            """
        ),
    ]

    @objc private func showExamples() {
        let sheet = UIAlertController(title: "Examples".localized, message: nil,
                                      preferredStyle: .actionSheet)
        for example in Self.examples {
            sheet.addAction(UIAlertAction(title: example.title.localized, style: .default) {
                [weak self] _ in
                self?.insert(example.code)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(sheet, animated: true)
    }

    private func insert(_ code: String) {
        let existing = textView.text ?? ""
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n\n"
        textView.text = existing + separator + code.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
        textView.becomeFirstResponder()
    }
}
