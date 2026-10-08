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
        observePreferenceChanges()
        // The switches' locked state depends on the stored values, which a
        // previous visit may have left in the forced combination.
        enforceScriptRuntimeDependency()
    }

    public override func rebuildSpecifiers() -> NSMutableArray? {
        buildSpecifiers()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The name or script may have changed on the pages this one pushes.
        navigationItem.title = definition?.name ?? "Custom".localized
        table?.reloadData()
    }

    /// Presents the scripting guide as a sheet.
    @objc private func showScriptingGuide() {
        ScriptingGuide.present(from: self)
    }

    /// Observes writes to the definition's defaults, so the thread switch can be
    /// locked while the context switch says "share".
    ///
    /// The switches write through `PreferencesStorage`, which has no reference
    /// back to this controller, so the dependency is enforced here — at the
    /// observation point — rather than in the setter.
    /// The switches write through PrefsStore, which posts a **Darwin**
    /// notification — `CFNotificationCenter`, which `NotificationCenter` cannot
    /// observe — so the dependency is re-evaluated whenever one arrives.
    private func observePreferenceChanges() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let controller = Unmanaged<CustomServiceEditorController>
                    .fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    controller.enforceScriptRuntimeDependency()
                }
            },
            Pusher.prefsNotification as CFString,
            nil,
            .coalesce
        )
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    /// Enforces the context/thread dependency after a write.
    ///
    /// A shared context must stay on the thread that created it (JSContext's
    /// thread affinity), so sharing the context forces its own thread and the
    /// thread switch is disabled with a footer saying why. Sharing a thread
    /// alone is fine: each run still gets a fresh context.
    private func enforceScriptRuntimeDependency() {
        guard hasInstalledSpecifiers,
              let threadSpecifier = specifier(forID: Self.shareThreadIdentifier)
        else { return }

        let sharing = CustomServiceStore.rawEntry(id: definitionID)
            .bool(PrefKey.scriptShareContext)

        // Sharing the context pins every run to the thread the context was
        // created on, so Share Thread is switched on (in storage, which is what
        // the getter reports), locked, and explained. Sharing a thread alone
        // leaves Share Context free: each run still gets a fresh context.
        if sharing {
            if !CustomServiceStore.rawEntry(id: definitionID)
                .bool(PrefKey.scriptShareThread) {
                CustomServiceStore.update(id: definitionID) { object in
                    object[PrefKey.scriptShareThread] = true
                }
                // The write posts another notification; the re-entry below is
                // idempotent, so returning here is enough.
                return
            }
            threadSpecifier.setProperty(false, forKey: "enabled")
        } else {
            threadSpecifier.setProperty(true, forKey: "enabled")
        }

        // The forced state is explained on the thread switch's own group
        // footer, under the switch it concerns.
        if let threadGroup = specifier(forID: Self.shareThreadGroupIdentifier) {
            threadGroup.setProperty(
                sharing
                    ? ("A shared context must stay on the thread it was created "
                        + "on (JSContext thread affinity), so sharing the thread "
                        + "is required and locked on.").localized
                    : ("Runs queue on one thread. A shared context requires this "
                        + "(JSContext thread affinity); with own contexts it only "
                        + "orders the runs.").localized,
                forKey: "footerText"
            )
            reloadSpecifier(threadGroup, animated: false)
        }
        reloadSpecifier(threadSpecifier, animated: false)
    }

    private static let shareContextIdentifier = "shareContext"
    private static let shareThreadIdentifier = "shareThread"
    private static let shareContextGroupIdentifier = "shareContextGroup"
    private static let shareThreadGroupIdentifier = "shareThreadGroup"
    private static let advancedGroupIdentifier = "advancedGroup"

    /// The run-options cells: share-context, share-thread, timeout, response cap.
    ///
    /// They are written to the definition's defaults, which is what a new
    /// instance of this type starts from; the instance page offers the same
    /// cells for its own copy.
    private static func scriptRuntimeSpecifiers(definitionID: String) -> [PSSpecifier] {
        var specifiers: [PSSpecifier] = []

        // Each switch sits in its own group so the note below it is that
        // switch's: a group footer is where the framework renders a note, and
        // one group per row keeps the two notes from reading as one block.
        let contextGroup = PSSpecifier.emptyGroup()
        contextGroup?.identifier = Self.shareContextGroupIdentifier
        contextGroup?.setProperty(
            ("Every run reuses one JavaScript context — faster, and a script can "
                + "carry state between notifications. Off, each run gets a fresh "
                + "context, so one run's variables can never leak into another.")
                .localized,
            forKey: "footerText"
        )
        if let contextGroup { specifiers.append(contextGroup) }

        let shareContext = switchCell(
            title: "Share Context Between Runs".localized,
            key: PrefKey.scriptShareContext, ownerID: definitionID, defaultValue: false
        )
        shareContext.setProperty(true, forKey: SpecifierRouting.PropertyKey.isDefinition)
        shareContext.identifier = Self.shareContextIdentifier
        specifiers.append(shareContext)

        let threadGroup = PSSpecifier.emptyGroup()
        threadGroup?.identifier = Self.shareThreadGroupIdentifier
        threadGroup?.setProperty(
            ("Runs queue on one thread. A shared context requires this (JSContext "
                + "thread affinity); with own contexts it only orders the runs.")
                .localized,
            forKey: "footerText"
        )
        if let threadGroup { specifiers.append(threadGroup) }

        let shareThread = switchCell(
            title: "Share Thread Between Runs".localized,
            key: PrefKey.scriptShareThread, ownerID: definitionID, defaultValue: false
        )
        shareThread.setProperty(true, forKey: SpecifierRouting.PropertyKey.isDefinition)
        shareThread.identifier = Self.shareThreadIdentifier
        specifiers.append(shareThread)

        // The two numbers are their own block, so the thread note above stays
        // attached to the switch it explains rather than trailing the numbers.
        let limitsGroup = PSSpecifier.emptyGroup()
        limitsGroup?.setProperty(
            ("These seed new services of this type, like the options above.")
                .localized,
            forKey: "footerText"
        )
        if let limitsGroup { specifiers.append(limitsGroup) }

        let timeout = PSSpecifier.preferenceSpecifierNamed(
            "Timeout (seconds)".localized,
            target: PreferencesStorage.self,
            set: #selector(PreferencesStorage.setValue(_:forInstanceSpecifier:)),
            get: #selector(PreferencesStorage.readValue(forInstanceSpecifier:)),
            detail: nil, cell: .editTextCell, edit: nil
        )
        timeout?.setProperty(definitionID, forKey: SpecifierRouting.PropertyKey.instanceID)
        timeout?.setProperty(true, forKey: SpecifierRouting.PropertyKey.isDefinition)
        timeout?.setProperty(PrefKey.scriptTimeout, forKey: SpecifierRouting.PropertyKey.key)
        timeout?.setProperty(true, forKey: "enabled")
        timeout?.setProperty(true, forKey: "isDecimalPad")
        timeout?.setProperty(Pusher.defaultScriptTimeout,
                              forKey: SpecifierRouting.PropertyKey.defaultValue)
        if let timeout { specifiers.append(timeout) }

        let maxBytes = PSSpecifier.preferenceSpecifierNamed(
            "Max Response Size (MB)".localized,
            target: PreferencesStorage.self,
            set: #selector(PreferencesStorage.setValue(_:forInstanceSpecifier:)),
            get: #selector(PreferencesStorage.readValue(forInstanceSpecifier:)),
            detail: nil, cell: .editTextCell, edit: nil
        )
        maxBytes?.setProperty(definitionID, forKey: SpecifierRouting.PropertyKey.instanceID)
        maxBytes?.setProperty(true, forKey: SpecifierRouting.PropertyKey.isDefinition)
        maxBytes?.setProperty(PrefKey.scriptMaxResponseBytes,
                              forKey: SpecifierRouting.PropertyKey.key)
        maxBytes?.setProperty(true, forKey: "enabled")
        maxBytes?.setProperty(true, forKey: "isDecimalPad")
        // Shown and stored in MB; the runner converts to bytes.
        maxBytes?.setProperty(Pusher.defaultMaxResponseMB,
                              forKey: SpecifierRouting.PropertyKey.defaultValue)
        if let maxBytes { specifiers.append(maxBytes) }

        return specifiers
    }

    private static func switchCell(
        title: String,
        key: String,
        ownerID: String,
        defaultValue: Bool
    ) -> PSSpecifier {
        let specifier = PSSpecifier.preferenceSpecifierNamed(
            title, target: PreferencesStorage.self,
            set: #selector(PreferencesStorage.setValue(_:forInstanceSpecifier:)),
            get: #selector(PreferencesStorage.readValue(forInstanceSpecifier:)),
            detail: nil, cell: .switchCell, edit: nil
        )!
        specifier.setProperty(ownerID, forKey: SpecifierRouting.PropertyKey.instanceID)
        specifier.setProperty(key, forKey: SpecifierRouting.PropertyKey.key)
        specifier.setProperty(key, forKey: SpecifierRouting.PropertyKey.customAppsPrefsKey)
        specifier.setProperty(true, forKey: "enabled")
        specifier.setProperty(defaultValue, forKey: SpecifierRouting.PropertyKey.defaultValue)
        return specifier
    }

    // MARK: - Specifiers

    func buildSpecifiers() -> NSMutableArray {
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
        // The group head, the script row, then the guide: the guide sits under
        // the script it explains, inside the same group.
        let scriptGroup = PSSpecifier.emptyGroup()
        if let scriptGroup { all.append(scriptGroup) }

        let scriptRow = PSSpecifier.preferenceSpecifierNamed(
            "Script".localized, target: nil, set: nil, get: nil,
            detail: CustomServiceScriptController.self, cell: .linkCell, edit: nil
        )
        scriptRow?.identifier = Self.scriptRowIdentifier
        scriptRow?.setProperty("DefaultService", forKey: "icon")
        if let scriptRow { all.append(scriptRow) }

        // The guide, as its own tappable row under the script: a footer is not
        // obviously tappable, and the entry point is what makes the AI workflow
        // discoverable.
        if let guideRow = PSSpecifier.preferenceSpecifierNamed(
            "How to write a script".localized, target: self,
            set: nil, get: nil, detail: nil, cell: .buttonCell, edit: nil
        ) {
            guideRow.buttonAction = #selector(showScriptingGuide)
            guideRow.setProperty("DefaultService", forKey: "icon")
            all.append(guideRow)
        }

        scriptGroup?.setProperty(
            ("The script runs for every notification. Call push(req) to send one, "
                + "call it more than once to send several, or not at all to skip "
                + "this notification.").localized,
            forKey: "footerText"
        )

        // ── The defaults for services of this kind ──────────────────────────
        let defaultsGroup = PSSpecifier.groupSpecifier(
            withName: "Defaults for New Services".localized
        )
        defaultsGroup?.setProperty(
            ("Services you add from this type start with these, and can still "
                + "change them individually.").localized,
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

        // ── Advanced: how a run of this type executes ───────────────────────
        // Its own block at the bottom, because these are the options a script
        // author rarely touches: context/thread sharing, the timeout, and the
        // fetch size cap. They seed new instances like the payload options, and
        // an instance can still change its own.
        let advancedGroup = PSSpecifier.groupSpecifier(
            withName: "Advanced Settings".localized
        )
        advancedGroup?.identifier = Self.advancedGroupIdentifier
        advancedGroup?.setProperty(
            "How a run of this type executes.".localized,
            forKey: "footerText"
        )
        if let advancedGroup { all.append(advancedGroup) }
        all.append(contentsOf: Self.scriptRuntimeSpecifiers(definitionID: definitionID))

        return NSMutableArray(array: all)
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
        tableView.deselectRow(at: indexPath, animated: true)

        // The script row is handled here, and *before* super: the framework's
        // selection handling sees the row's detail class and pushes a fresh
        // instance of it, which would open an empty page next to the real one.
        // The definition is already in hand here, so pushing it directly both
        // skips that construction and carries the id.
        if let specifier = specifier(at: indexPath),
           specifier.identifier == Self.scriptRowIdentifier, let definition {
            push(CustomServiceScriptController(definitionID: definition.id))
            return
        }
        super.tableView(tableView, didSelectRowAt: indexPath)
    }
}

// MARK: - The script editor

/// Edits the script of one definition.
///
/// A text view filling the page, because a script is code: it wants the whole
/// screen, monospaced text and no autocorrection. The navigation bar carries the
/// insertable examples, since a user starting from nothing needs to see the shape
/// of a script before they can write one.
// MARK: - The script editor, with the run button

@objc(NSPCustomServiceScriptController)
public final class CustomServiceScriptController: PSViewController, UITextViewDelegate {
    private let definitionID: String
    private let textView = UITextView()
    private let outputView = UITextView()
    private let runButton = UIButton(type: .system)
    private var outputHeight: NSLayoutConstraint!

    /// The sample notification the run button feeds the script.
    private static let testBullet: [String: Any] = [
        "deviceName": UIDevice.current.name,
        "appName": "Bark",
        "appID": "me.fin.bark",
        "title": "Test Title",
        "subtitle": "Test Subtitle",
        "message": "Hello from Pusher",
        "date": "Jan 1, 12:00 PM",
    ]

    /// The framework builds a `detail`-named controller through these, so both
    /// are written out even though this page is normally pushed directly: a
    /// class that adds its own initializer hides the inherited ones, and the
    /// framework's call would land on an unimplemented one.
    public override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        self.definitionID = ""
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    public override init(forContentSize contentSize: CGSize) {
        self.definitionID = ""
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    init(definitionID: String) {
        self.definitionID = definitionID
        super.init(nibName: nil, bundle: nil)
    }

    // MARK: - Layout

    public override func viewDidLoad() {
        super.viewDidLoad()

        navigationItem.title = "Script".localized
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(
                title: "Run".localized, style: .plain,
                target: self, action: #selector(runScript)
            ),
            UIBarButtonItem(
                title: "Examples".localized, style: .plain,
                target: self, action: #selector(showExamples)
            ),
        ]

        view.backgroundColor = .systemGroupedBackground

        // The editor takes the upper area; the output pane sits below it and
        // grows with its content.
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        textView.keyboardType = .asciiCapable
        textView.delegate = self
        textView.backgroundColor = .secondarySystemGroupedBackground
        textView.layer.cornerRadius = 10
        textView.text = CustomServiceStore.definition(id: definitionID)?.script ?? ""
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        outputView.isEditable = false
        outputView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        outputView.backgroundColor = .secondarySystemGroupedBackground
        outputView.layer.cornerRadius = 10
        outputView.isHidden = true
        outputView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(outputView)

        outputHeight = outputView.heightAnchor.constraint(equalToConstant: 200)
        outputHeight.isActive = true

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            textView.bottomAnchor.constraint(equalTo: outputView.topAnchor, constant: -12),

            outputView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            outputView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            outputView.bottomAnchor.constraint(
                equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12
            ),
        ])
    }

    // MARK: - Running

    /// Runs the script as it stands, against a sample notification.
    ///
    /// The script is saved first so what runs is what is on screen. The run uses
    /// the same runner the pipeline does — same options, same `fetch` — so a
    /// script that works here behaves the same when a notification arrives.
    /// Runs the script as it stands, against a sample notification.
    ///
    /// The script is saved first so what runs is what is on screen. The run is
    /// the pipeline's run: same runner, same options, same real `fetch`, so what
    /// works here behaves identically when a notification arrives. Real requests
    /// do go out — the test bullet is what differs from production, not the
    /// network.
    @objc private func runScript() {
        save()
        guard let script = textView.text, !script.isEmpty else { return }

        let outcome = JavaScriptRunner.run(
            script: script,
            bullet: Self.testBullet,
            options: .init(usesOwnContext: true, usesOwnThread: true,
                           timeout: Pusher.defaultScriptTimeout,
                           maximumResponseBytes: Pusher.defaultMaxResponseBytes),
            fetch: ScriptHTTP.perform
        )

        // The trace is the run, in script order, each entry colored by kind:
        // console stays default, the raw HTTP is purple, and the response is
        // green or red by outcome.
        let output = NSMutableAttributedString()
        var requestIndex = 0
        for entry in outcome.trace {
            switch entry {
            case .console(let line):
                output.appendColored(line, .label)
            case .request(_, let raw):
                output.appendColored(raw, .systemPurple)
                // A push(req) request is only described by the runner; the
                // caller performs it, so its result is fetched here and shown
                // after the request it belongs to.
                if requestIndex < outcome.requests.count {
                    let sent = Self.send(outcome.requests[requestIndex])
                    output.appendColored(
                        sent, sent.hasPrefix("← failed") ? .systemRed : Self.successColor
                    )
                    requestIndex += 1
                }
            case .response(let text):
                output.appendColored(
                    text, text.hasPrefix("failed") ? .systemRed : Self.successColor
                )
            }
        }
        if let failure = outcome.failure {
            output.appendColored(failure.message, .systemRed)
        }
        if output.length == 0 {
            output.appendColored(
                "No output. The script ran and sent nothing — that is how it "
                    + "skips a notification.", .secondaryLabel
            )
        }

        showOutput(output)
    }

    /// The color a successful response line is drawn in.
    ///
    /// A deep green rather than the system's: the system green is tuned for
    /// glyphs and fills, and at text size on a light background it reads as
    /// pale. This resolves per theme, because a green dark enough for white
    /// paper is unreadable on a black one.
    private static var successColor: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.35, green: 0.78, blue: 0.40, alpha: 1)
                : UIColor(red: 0.00, green: 0.42, blue: 0.17, alpha: 1)
        }
    }

    /// Sends one `push(req)` request and describes the outcome in one line.
    ///
    /// Run performs the requests for real — that is the point of the button:
    /// what the script builds is only half of it, and a service's rejection
    /// (a bad token, a wrong field name) is invisible until the request is
    /// actually made.
    private static func send(_ request: PushRequest) -> String {
        guard let url = URL(string: request.urlString) else {
            return "← failed: invalid URL"
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = Pusher.scriptFetchTimeout
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }

        let method = request.method.uppercased()
        let isBodyless = method == "GET" || method == "HEAD"
        if !isBodyless {
            let body = request.infoDict
            if let data = try? JSONSerialization.data(withJSONObject: body) {
                urlRequest.httpBody = data
                if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            }
        } else if !request.infoDict.isEmpty,
                  var components = URLComponents(string: request.urlString) {
            var items = components.queryItems ?? []
            for (key, value) in request.infoDict {
                items.append(URLQueryItem(name: key, value: String(describing: value)))
            }
            components.queryItems = items
            urlRequest.url = components.url
        }

        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var line = "← failed: no response" }
        let box = Box()
        URLSession.shared.dataTask(with: urlRequest) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                box.line = "← failed: \(error.localizedDescription)"
                return
            }
            guard let http = response as? HTTPURLResponse else {
                box.line = "← failed: no response"
                return
            }
            let bytes = data?.count ?? 0
            let size = bytes < 1024
                ? "\(bytes) B"
                : String(format: "%.1f KB", Double(bytes) / 1024)
            // The status alone is not enough to debug a service: its error text
            // is what names the wrong field.
            var detail = "\(http.statusCode)  \(size)"
            if !(200..<300).contains(http.statusCode),
               let data, let text = String(data: data, encoding: .utf8), !text.isEmpty {
                let trimmed = text.count > 300 ? String(text.prefix(300)) + "…" : text
                detail += "  \(trimmed.replacingOccurrences(of: "\n", with: " "))"
            }
            box.line = "← \(detail)"
        }.resume()

        _ = semaphore.wait(timeout: .now() + Pusher.scriptFetchTimeout + 5)
        return box.line
    }

    /// Presents the run's report below the editor.
    private func showOutput(_ attributed: NSAttributedString) {
        outputView.attributedText = attributed
        outputView.isHidden = false

        // Two hundred points shows a useful amount of output; more than that
        // scrolls inside the pane rather than pushing the editor off screen.
        outputHeight.constant = min(260, max(120, outputView.contentSize.height + 16))
        view.layoutIfNeeded()
    }

    // MARK: - Saving

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        save()
    }

    /// Writes the script back onto its definition, which is what makes an edit
    /// take effect for every service using it.
    @discardableResult
    private func save() -> Bool {
        guard var definition = CustomServiceStore.definition(id: definitionID) else { return false }
        let text = textView.text ?? ""
        guard text != definition.script else { return false }
        definition.script = text
        CustomServiceStore.save(definition)
        return true
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
            // \("Calling nothing skips the notification instead of forwarding it.".localized)
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
            // \("Top-level await works: the script is run as an async function.".localized)
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
            // \(("localStorage is kept per service, so two services of this type "
                + "do not share it.").localized)
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
            // \(("bullet.deviceName, bullet.appName, bullet.appID, "
                + "bullet.title, bullet.subtitle, bullet.message, bullet.date").localized)
            // \(("bullet.icon   — base64 PNG of the app icon\n"
                + "bullet.image  — base64 of the notification's attachment").localized)
            //
            // \(("Also available: fetch(url, init), localStorage, console.log()").localized)
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
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.last
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

// MARK: - Output coloring

private extension NSMutableAttributedString {
    /// Appends `text` as its own block in `color`.
    func appendColored(_ text: String, _ color: UIColor) {
        if length > 0 {
            append(NSAttributedString(string: "\n"))
        }
        append(NSAttributedString(
            string: text,
            attributes: [.font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                         .foregroundColor: color]
        ))
    }
}
