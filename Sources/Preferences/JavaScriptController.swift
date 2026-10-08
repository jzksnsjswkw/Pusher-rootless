import UIKit
import Preferences

/// The settings page for a script service.
///
/// A script service has no endpoint fields, so its page is: the script itself,
/// then the notification options every service offers, then the advanced
/// switches that control how the script is run.
///
/// The script is edited on a page of its own rather than in a text field,
/// because it is code — it needs the whole screen, and a `UITextView` is the only
/// control that behaves reasonably for many lines.
@objc(NSPJavaScriptController)
public final class JavaScriptController: ServiceController {

    private static let scriptRowIdentifier = "script"
    private static let advancedGroupIdentifier = "advanced"

    public init(instanceID: String) {
        super.init(instance: ServiceInstance(
            id: instanceID, type: JavaScriptService.serviceName, name: "",
            isEnabled: true, config: PrefsStore.instance(instanceID)
        ))
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The script editor may have changed the source, so the row's summary is
        // refreshed when this page comes back.
        table?.reloadData()
    }

    // MARK: - Specifiers

    override func buildSpecifiers() -> NSMutableArray {
        var all: [PSSpecifier] = []

        // ── The script ──────────────────────────────────────────────────────
        let scriptGroup = PSSpecifier.emptyGroup()
        scriptGroup?.identifier = "scriptGroup"
        scriptGroup?.setProperty(
            "The script runs for each notification. Call push(req) to send one; "
                .localized + "call it more than once to send several, or not at all "
                .localized + "to skip this notification.".localized,
            forKey: "footerText"
        )

        let scriptRow = PSSpecifier.preferenceSpecifierNamed(
            "Script".localized, target: nil, set: nil, get: nil,
            detail: JavaScriptEditorController.self, cell: .linkCell, edit: nil
        )
        scriptRow?.identifier = Self.scriptRowIdentifier
        scriptRow?.setProperty("DefaultService", forKey: "icon")
        if let scriptGroup { all.append(scriptGroup) }
        if let scriptRow { all.append(scriptRow) }

        // ── The notification's own options, as every service offers ─────────
        let payloadGroup = PSSpecifier.groupSpecifier(withName: "Options".localized)
        if let payloadGroup { all.append(payloadGroup) }

        all.append(contentsOf: ServiceSpecifierBuilders.shared.builders(
            for: ServiceSpecifierBuilders.payloadOptionsKey,
            instanceID: serviceInstanceID, appID: nil
        ))

        // ── How the script is run ───────────────────────────────────────────
        let advancedGroup = PSSpecifier.groupSpecifier(withName: "Advanced".localized)
        advancedGroup?.identifier = Self.advancedGroupIdentifier
        advancedGroup?.setProperty(
            "Sharing a context or a thread is faster but lets one notification's "
                .localized + "variables reach the next. A separate context is the "
                .localized + "safer default; a separate thread keeps a runaway "
                .localized + "script off the others.".localized,
            forKey: "footerText"
        )
        if let advancedGroup { all.append(advancedGroup) }

        for specifier in Self.advancedSpecifiers(instanceID: serviceInstanceID) {
            all.append(specifier)
        }

        // The device conditions, SNS page and log every service page has.
        all.append(contentsOf: globalTailSpecifiers())
        all.append(contentsOf: testPushSection())

        return NSMutableArray(array: all)
    }

    /// The advanced switches.
    ///
    /// The two sharing switches are mutually dependent — a shared context has to
    /// keep its own thread — so changing one reloads the other rather than
    /// letting the page show a combination that cannot take effect.
    private static func advancedSpecifiers(instanceID: String) -> [PSSpecifier] {
        var specifiers: [PSSpecifier] = []

        specifiers.append(switchCell(
            title: "Share Context Between Runs".localized,
            key: PrefKey.scriptShareContext, instanceID: instanceID, defaultValue: false
        ))
        specifiers.append(switchCell(
            title: "Share Thread Between Runs".localized,
            key: PrefKey.scriptShareThread, instanceID: instanceID, defaultValue: false
        ))

        let timeout = PSSpecifier.preferenceSpecifierNamed(
            "Timeout (seconds)".localized,
            target: PreferencesStorage.self,
            set: #selector(PreferencesStorage.setValue(_:forInstanceSpecifier:)),
            get: #selector(PreferencesStorage.readValue(forInstanceSpecifier:)),
            detail: nil, cell: .editTextCell, edit: nil
        )
        timeout?.setProperty(instanceID, forKey: SpecifierRouting.PropertyKey.instanceID)
        timeout?.setProperty(PrefKey.scriptTimeout, forKey: SpecifierRouting.PropertyKey.key)
        timeout?.setProperty(true, forKey: "enabled")
        timeout?.setProperty(true, forKey: "isDecimalPad")
        timeout?.setProperty(Pusher.defaultScriptTimeout, forKey: SpecifierRouting.PropertyKey.defaultValue)
        if let timeout { specifiers.append(timeout) }

        let maxBytes = PSSpecifier.preferenceSpecifierNamed(
            "Max Response Size (bytes)".localized,
            target: PreferencesStorage.self,
            set: #selector(PreferencesStorage.setValue(_:forInstanceSpecifier:)),
            get: #selector(PreferencesStorage.readValue(forInstanceSpecifier:)),
            detail: nil, cell: .editTextCell, edit: nil
        )
        maxBytes?.setProperty(instanceID, forKey: SpecifierRouting.PropertyKey.instanceID)
        maxBytes?.setProperty(PrefKey.scriptMaxResponseBytes, forKey: SpecifierRouting.PropertyKey.key)
        maxBytes?.setProperty(true, forKey: "enabled")
        maxBytes?.setProperty(true, forKey: "isDecimalPad")
        maxBytes?.setProperty(Pusher.defaultMaxResponseBytes,
                              forKey: SpecifierRouting.PropertyKey.defaultValue)
        if let maxBytes { specifiers.append(maxBytes) }

        return specifiers
    }

    private static func switchCell(
        title: String,
        key: String,
        instanceID: String,
        defaultValue: Bool
    ) -> PSSpecifier {
        let specifier = PSSpecifier.preferenceSpecifierNamed(
            title, target: PreferencesStorage.self,
            set: #selector(PreferencesStorage.setValue(_:forInstanceSpecifier:)),
            get: #selector(PreferencesStorage.readValue(forInstanceSpecifier:)),
            detail: nil, cell: .switchCell, edit: nil
        )!
        specifier.setProperty(instanceID, forKey: SpecifierRouting.PropertyKey.instanceID)
        specifier.setProperty(key, forKey: SpecifierRouting.PropertyKey.key)
        specifier.setProperty(key, forKey: SpecifierRouting.PropertyKey.customAppsPrefsKey)
        specifier.setProperty(true, forKey: "enabled")
        specifier.setProperty(defaultValue, forKey: SpecifierRouting.PropertyKey.defaultValue)
        return specifier
    }

    // MARK: - Rows

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        super.tableView(tableView, didSelectRowAt: indexPath)
        tableView.deselectRow(at: indexPath, animated: true)

        guard let specifier = specifier(at: indexPath),
              specifier.identifier == Self.scriptRowIdentifier
        else { return }
        push(JavaScriptEditorController(instanceID: serviceInstanceID))
    }
}

// MARK: - The script editor

/// Edits one instance's script.
///
/// A plain text view filling the page, because a script is code: it wants the
/// whole screen, monospaced text, and no autocorrection. The navigation bar
/// carries the insertable snippets, since a script author starting from nothing
/// has a lot of API to discover.
@objc(NSPJavaScriptEditorController)
public final class JavaScriptEditorController: UIViewController, UITextViewDelegate {
    private let instanceID: String
    private let textView = UITextView()

    init(instanceID: String) {
        self.instanceID = instanceID
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
        textView.delegate = self
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        textView.keyboardType = .asciiCapable
        // A script is deep and nested, so tabs are the right width to line code
        // up without wrapping; tab inserts a tab rather than moving focus.
        textView.text = PrefsStore.instance(instanceID).string(PrefKey.script, default: "")
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        save()
    }

    /// Writes the source back to the instance.
    private func save() {
        let text = textView.text ?? ""
        guard text != PrefsStore.instance(instanceID).string(PrefKey.script, default: "") else {
            return
        }
        PrefsStore.updateInstance(instanceID) { $0[PrefKey.script] = text }
    }

    // MARK: - Insertable examples

    /// The API, as runnable snippets.
    ///
    /// Offering them beats documenting them: a user starting from nothing needs
    /// to see the shape of a script before they can write one, and the platforms
    /// this is modelled on have no reference here to read.
    private static let examples: [(title: String, detail: String, code: String)] = [
        (
            "Send a notification",
            "Forward the notification to a webhook.",
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
            "Call nothing and the notification is not forwarded.",
            """
            if (bullet.message.includes("verification code")) {
                push({
                    url: "https://example.com/code",
                    method: "POST",
                    body: { code: bullet.message }
                });
            }
            // Anything else falls through and is skipped.
            """
        ),
        (
            "Fetch a token first",
            "Use await and fetch like a browser would.",
            """
            (async () => {
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
            })();
            """
        ),
        (
            "Remember something between runs",
            "localStorage keeps its values for the next notification.",
            """
            let count = Number(localStorage.getItem("count") || "0");
            count += 1;
            localStorage.setItem("count", String(count));

            push({
                url: "https://example.com/notify",
                method: "POST",
                body: { seen: count, title: bullet.title }
            });
            """
        ),
        (
            "Everything available",
            "The fields the notification carries.",
            """
            console.log(bullet);
            // bullet.deviceName, bullet.appName, bullet.appID
            // bullet.title, bullet.subtitle, bullet.message, bullet.date
            // bullet.icon  (base64 PNG, 58x58)   bullet.image (base64)
            //
            // Also: fetch(url, init), localStorage, console.log
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
        // An action sheet is a popover on iPad and needs an anchor there.
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(sheet, animated: true)
    }

    /// Appends or replaces with a snippet, keeping a blank line between blocks.
    private func insert(_ code: String) {
        let existing = textView.text ?? ""
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n\n"
        textView.text = existing + separator + code.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
        textView.becomeFirstResponder()
    }
}
