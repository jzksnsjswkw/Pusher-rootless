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
        refreshTitle()
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
        // The name, script or logo may have changed on the pages this one pushes.
        refreshTitle()
        table?.reloadData()
    }

    /// Presents the scripting guide as a sheet.
    /// Draws the title: the definition's logo beside its name, as a service page
    /// does, so a script is identified the same way wherever it is edited — and
    /// so the logo the user just chose is visible on the page they chose it from.
    private func refreshTitle() {
        let name = definition?.name ?? "Custom".localized
        guard let definition,
              let logo = ServiceIcon.logo(forDefinitionID: definition.id) else {
            navigationItem.titleView = nil
            navigationItem.title = name
            return
        }
        let iconView = UIImageView(image: logo)
        // No corner radius here: the tile shape is baked into the image itself,
        // which is what keeps a chosen logo and the bundled artwork identical in
        // shape — the same reason the list row sets none.
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 29),
            iconView.heightAnchor.constraint(equalToConstant: 29),
        ])
        let label = UILabel()
        label.text = name
        label.font = .boldSystemFont(ofSize: 17)
        let stack = UIStackView(arrangedSubviews: [iconView, label])
        stack.alignment = .center
        stack.spacing = 10
        navigationItem.titleView = stack
    }

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
        // them; these cells write to the definition's own object.
        all.append(contentsOf: ServiceSpecifierBuilders.shared.payloadOptions(
            forDefinition: definitionID
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
        if let specifier = specifier(at: indexPath),
           specifier.bool(SpecifierRouting.PropertyKey.isIconRow) {
            tableView.deselectRow(at: indexPath, animated: true)
            view.endEditing(true)
            push(ServiceIconController(
                storage: .definition(id: definitionID), heading: "Icon".localized
            ))
            return
        }

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
    /// The line-number column, and the label inside it that carries the digits.
    private let gutter = UIView()
    private let gutterLabel = UILabel()
    /// Three constraints on the editor's bottom edge, only two of them active at
    /// a time. See the comment where they are created.
    private var editorToSafeArea: NSLayoutConstraint!
    private var editorWithinKeyboard: NSLayoutConstraint!
    private var editorAboveOutput: NSLayoutConstraint!
    private var outputToSafeArea: NSLayoutConstraint!
    private var outputWithinKeyboard: NSLayoutConstraint!

    /// The width of the line-number column.
    private static let gutterWidth: CGFloat = 34
    /// The numbers last laid out, and how tall they are.
    ///
    /// Cached because the two callers want different things: the text changing
    /// means the numbers must be rebuilt (a full text layout), while scrolling
    /// means only the label's position moves. A label holds the whole column,
    /// not just the visible part, so re-assigning its text on every scroll
    /// frame re-renders every line — which is what made a long script refuse to
    /// scroll.
    private var gutterText = "1"
    private var gutterTextHeight: CGFloat = 0
    /// Whether the text changed since the column was last built.
    ///
    /// This is what keeps layout and rebuilding from chasing each other:
    /// assigning the label's text dirties layout, so a layout pass that rebuilt
    /// unconditionally would request another pass, forever — the main thread
    /// never idles, and scrolling stops responding.
    private var gutterNeedsRebuild = true

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

        // The editor owns the page until a run splits the output off, so the
        // output pane starts collapsed: a hidden view still takes part in
        // layout, and leaving it at its full height would reserve a strip of
        // the page for nothing.
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
        // Every inset lives in the text container and none in the scroll view.
        // A scroll view's own bottom inset is added to the content height, so a
        // non-zero one makes content that *is* taller than the box look
        // unscrollable until it exceeds the box by that much — which is exactly
        // what a "threshold" feels like. The container inset gives the same
        // bottom breathing room without touching the scrollable range.
        textView.contentInset = .zero
        textView.contentInsetAdjustmentBehavior = .never
        // The frame already stops above the keyboard, so the keyboard needs no
        // inset; adding one would push the last line out of reach instead.
        textView.scrollIndicatorInsets = .zero
        textView.textContainerInset = UIEdgeInsets(
            top: 8, left: Self.gutterWidth + 4, bottom: 24, right: 8
        )
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        // The numbers are their own view beside the editor rather than text
        // inside it: an edit must not be able to touch them, and a selection
        // must not include them. The editor's inset above is what makes room.
        // The column and its label are positioned by frame and take part in no
        // constraints at all.
        //
        // A frame-positioned view with autoresizing translation left on does
        // enter the constraint system: UIKit derives constraints from the frame.
        // The label is as tall as the whole script, so that derived height would
        // travel through the gutter — pinned to the editor's top and bottom — and
        // stretch the editor itself, which then grew with the text instead of
        // scrolling it. Removing the gutter's own constraints is what keeps the
        // editor's height the page's business and nobody else's.
        gutter.clipsToBounds = true
        // The column overlaps the editor's left edge, so it must not take the
        // touches that belong to the text view — a drag there has to scroll.
        gutter.isUserInteractionEnabled = false
        gutter.backgroundColor = textView.backgroundColor
        gutter.layer.cornerRadius = 10
        gutter.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        view.addSubview(gutter)

        gutterLabel.font = textView.font
        gutterLabel.textColor = .tertiaryLabel
        gutterLabel.numberOfLines = 0
        gutterLabel.textAlignment = .right
        gutterLabel.frame = CGRect(x: 0, y: 0, width: Self.gutterWidth - 6, height: 0)
        gutter.addSubview(gutterLabel)

        outputView.isEditable = false
        outputView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        outputView.backgroundColor = .secondarySystemGroupedBackground
        outputView.layer.cornerRadius = 10
        outputView.isHidden = true
        outputView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(outputView)

        outputHeight = outputView.heightAnchor.constraint(equalToConstant: 0)
        outputHeight.isActive = true
        outputToSafeArea = outputView.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12
        )
        // Just under required, exactly like the editor's: the manual keyboard
        // constant below is a required inequality, and a required equality here
        // would contradict it whenever the keyboard is up — an unsatisfiable
        // pair, and the pane would neither shrink nor sit where it should.
        outputToSafeArea.priority = UILayoutPriority(999)
        // Same as the editor: the keyboard layout guide does not move inside
        // Preferences' container, so the keyboard's height is tracked manually.
        outputWithinKeyboard = outputView.bottomAnchor.constraint(
            lessThanOrEqualTo: view.bottomAnchor, constant: -12
        )

        // The editor's bottom is *two* constraints, not one.
        //
        // The keyboard guide's top, with no keyboard, is the raw bottom of the
        // view — 34 points past the safe area, behind the home indicator. Pinning
        // the editor there makes it report a box taller than what is visible, so
        // a script a few lines short of that box does not scroll while its last
        // lines are hidden: the threshold.
        //
        // The priority is the load-bearing part. A text view resists being
        // squashed below its content at 750, so an equality at `defaultHigh`
        // (also 750) loses the tie: the solver grows the box to fit the text,
        // and the editor stops scrolling. Just under required still beats that
        // resistance, while the required keyboard bound above can still override
        // it when the keyboard appears.
        editorToSafeArea = textView.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12
        )
        editorToSafeArea.priority = UILayoutPriority(999)
        // Preferences detail controllers are nested inside containers that do
        // not propagate the keyboard layout guide, so it never moves. The
        // keyboard's height is tracked manually instead, and this constraint
        // keeps the editor above it.
        editorWithinKeyboard = textView.bottomAnchor.constraint(
            lessThanOrEqualTo: view.bottomAnchor, constant: -12
        )
        // UITextView's Auto Layout integration expands the view to fit its
        // text: a tall script makes the view report a tall intrinsic size, and
        // the solver uses that to stretch the frame — the view grows instead
        // of scrolling. Lowering the vertical priorities breaks that feedback
        // loop: the view no longer insists on being its content's height, and
        // the page's own constraints decide the frame.
        textView.setContentHuggingPriority(.defaultLow, for: .vertical)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        editorAboveOutput = textView.bottomAnchor.constraint(
            equalTo: outputView.topAnchor, constant: -12
        )

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            outputView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            outputView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            // Same pair as the editor: the pane may not go below the keyboard,
            // and it prefers to sit at the visible bottom edge.
            outputToSafeArea,
            outputWithinKeyboard,
        ])
        editorToSafeArea.isActive = true
        editorWithinKeyboard.isActive = true

        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillShowNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil
        )
    }

    /// Keeps the editor and the output pane above the keyboard by shrinking
    /// their bottom constraints when it appears.
    ///
    /// Preferences detail controllers are nested inside containers that do not
    /// propagate the keyboard layout guide, so it never moves. Tracking the
    /// keyboard's frame from the notification is the only reliable way.
    @objc private func keyboardWillChange(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval
        else { return }

        let keyboardHeight: CGFloat
        if note.name == UIResponder.keyboardWillShowNotification {
            // The frame is in screen coordinates; the part below the view's
            // bottom is what the editor must avoid.
            let bottomInWindow = view.convert(view.bounds, to: nil).maxY
            keyboardHeight = max(0, bottomInWindow - frame.minY)
        } else {
            keyboardHeight = 0
        }

        editorWithinKeyboard.constant = -12 - keyboardHeight
        outputWithinKeyboard.constant = -12 - keyboardHeight
        UIView.animate(withDuration: duration) {
            self.view.layoutIfNeeded()
        }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // The text was assigned in viewDidLoad, when the view's width was still
        // zero: every line wrapped at infinity, and the content size came out
        // far too small. Now that the real width is known, the text must be
        // re-laid out so the scroll view sees the true content height — and the
        // line numbers, which are visual-line based, must be rebuilt against
        // the same layout.
        if textView.bounds.width > 0, textView.bounds.width != lastLayoutWidth {
            lastLayoutWidth = textView.bounds.width
            // The text container's width tracks the view's, but only after a
            // layout pass. Setting text at width zero left it sized for that
            // width: the container must be given the real width explicitly,
            // or the text stays wrapped to nothing and the content size is
            // wrong.
            let inset = textView.textContainerInset
            textView.textContainer.size = CGSize(
                width: textView.bounds.width - inset.left - inset.right,
                height: .greatestFiniteMagnitude
            )
            textView.layoutManager.ensureLayout(for: textView.textContainer)
            gutterNeedsRebuild = true
        }

        // The scroll view's content size must be at least the text's laid-out
        // height plus the container insets, or the bottom is unreachable. A
        // text view with a fixed frame computes this itself, but only after it
        // lays out — and with the priorities lowered above, it may not. Setting
        // it directly removes the dependency.
        let textHeight = textView.layoutManager.usedRect(for: textView.textContainer).height
        let inset = textView.textContainerInset
        let needed = textHeight + inset.top + inset.bottom
        if textView.contentSize.height < needed {
            textView.contentSize = CGSize(width: textView.bounds.width, height: needed)
        }

        // The column is placed from the editor's frame, clipped to the part of
        // it the text view is actually showing.
        let editor = textView.frame
        let visible = textView.bounds
        gutter.frame = CGRect(
            x: editor.minX, y: editor.minY,
            width: Self.gutterWidth, height: visible.height
        )
        updateGutter()
    }

    /// The width the text was last laid out at, so a width change (rotation,
    /// or the first real layout after viewDidLoad) triggers a re-wrap.
    private var lastLayoutWidth: CGFloat = 0

    // MARK: - Line numbers

    /// Draws the numbers beside the code, moved by the scroll offset.
    private func updateGutter() {
        moveGutter()
        guard gutterNeedsRebuild else { return }
        gutterNeedsRebuild = false

        let numbers = lineNumbers()
        // The text decides whether the numbers changed; a rebuild that produces
        // the same column must not assign it again, or the assignment dirties
        // layout, which lays out again, which rebuilds again.
        guard numbers != gutterText else { return }
        gutterText = numbers
        gutterLabel.text = numbers

        let width = max(Self.gutterWidth - 6, 1)
        gutterTextHeight = gutterLabel.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height
        moveGutter()
    }

    /// Puts the column at the scroll position. A frame change on a subview does
    /// not lay the view controller out again, so this is safe to call freely.
    private func moveGutter() {
        guard gutterTextHeight > 0 else { return }
        gutterLabel.frame = CGRect(
            x: 0,
            y: textView.textContainerInset.top - textView.contentOffset.y,
            width: max(Self.gutterWidth - 6, 1),
            height: gutterTextHeight
        )
    }

    /// One number per *visual* line, with a wrapped row left blank.
    ///
    /// A wrapped line would otherwise put every number below it out of step
    /// with the code beside it.
    private func lineNumbers() -> String {
        let text = textView.text ?? ""
        guard !text.isEmpty else { return "1" }

        // A fragment reports a UTF-16 offset, so the line starts are counted in
        // the same units — an emoji would shift them otherwise.
        var lineStarts: [Int] = [0]
        for (offset, unit) in text.utf16.enumerated() where unit == 0x0A {
            lineStarts.append(offset + 1)
        }

        let layoutManager = textView.layoutManager
        let container = textView.textContainer
        layoutManager.ensureLayout(for: container)

        var numbers: [String] = []
        var previous = -1
        var glyph = 0
        while glyph < layoutManager.numberOfGlyphs {
            var range = NSRange()
            layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
            let character = layoutManager.characterIndexForGlyph(at: range.location)

            var line = 0
            for (position, start) in lineStarts.enumerated() where start <= character {
                line = position
            }
            numbers.append(line == previous ? "" : String(line + 1))
            previous = line
            glyph = NSMaxRange(range)
        }
        // A trailing newline opens a line the cursor sits on but no glyph
        // occupies, so layout reports nothing for it — the number is added here
        // rather than leaving the cursor's own line unnumbered.
        if text.hasSuffix("\n") {
            numbers.append(String(lineStarts.count))
        }
        return numbers.isEmpty ? "1" : numbers.joined(separator: "\n")
    }

    public func textViewDidChange(_ textView: UITextView) {
        gutterNeedsRebuild = true
        updateGutter()
    }

    /// Scrolling only moves the number column — see ``updateGutter()``.
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        moveGutter()
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
        if editorToSafeArea.isActive {
            // The first run is what splits the page. Before it, the editor keeps
            // the whole of it, which is what makes writing comfortable.
            editorToSafeArea.isActive = false
            editorAboveOutput.isActive = true
        }
        outputView.isHidden = false

        // Two hundred points shows a useful amount of output; more than that
        // scrolls inside the pane rather than pushing the editor off screen.
        outputHeight.constant = min(260, max(120, outputView.contentSize.height + 16))
        view.layoutIfNeeded()
        updateGutter()
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
    /// The API, as runnable snippets.
    ///
    /// The comments are translated, not built by interpolation: a snippet is
    /// text a user reads and edits, and an interpolation marker left inside one
    /// — which is what a `.localized` in the middle of a multi-line literal
    /// produces — ends up in their script.
    static var examples: [(title: String, code: String)] {
        // Comments are translated line by line and joined with "\n", never
        // interpolated into a multi-line literal: an interpolation closed on the
        // wrong side of a delimiter leaves its marker in the user's new script.
        func comment(_ lines: String...) -> [String] {
            lines.map { "// " + $0.localized }
        }

        let header = [
            "push({",
            "    url: \"https://example.com/notify\",",
            "    method: \"POST\",",
            "    headers: { \"Content-Type\": \"application/json\" },",
            "    body: {",
            "        title: bullet.title,",
            "        message: bullet.message,",
            "        app: bullet.appName",
            "    }",
            "});",
        ].joined(separator: "\n")

        let skip = (comment("Calling nothing skips the notification instead of forwarding it.")
            + [""] + [
            "if (bullet.message.includes(\"code\")) {",
            "    push({",
            "        url: \"https://example.com/code\",",
            "        method: \"POST\",",
            "        body: { code: bullet.message }",
            "    });",
            "}",
        ]).joined(separator: "\n")

        let token = (
            comment("Top-level await works: the script is run as an async function.", "")
            + comment("The token is cached in localStorage, so a page of notifications does "
                + "not fetch a new one for every message. It is re-fetched once it is "
                + "older than the expiry the server returned.")
            + [""] + [
            "const key = \"token\";",
            "const cached = JSON.parse(localStorage.getItem(key) || \"null\");",
            "let token = cached && cached.expires > Date.now() ? cached.value : null;",
            "",
            "if (!token) {",
            "    const response = await fetch(\"https://example.com/token\", {",
            "        method: \"POST\",",
            "        headers: { \"Content-Type\": \"application/json\" },",
            "        body: { user: \"me\" }",
            "    });",
            "    const data = await response.json();",
            "    token = data.token;",
        ]
            + comment("The server's own lifetime when it gives one; an hour when it does "
                + "not, since a cache that never expires is worse than one that expires "
                + "too early.")
            + [
            "    const lifetime = Number(data.expires_in) > 0 ? Number(data.expires_in) : 3600;",
            "    localStorage.setItem(key, JSON.stringify({",
            "        value: token,",
        ]
            + comment("A minute early, so a token cannot expire mid-flight.")
            + [
            "        expires: Date.now() + Math.max(lifetime - 60, 30) * 1000",
            "    }));",
            "}",
            "",
            "await fetch(\"https://example.com/send\", {",
            "    method: \"POST\",",
            "    headers: { Authorization: \"Bearer \" + token },",
            "    body: { title: bullet.title, message: bullet.message }",
            "});",
        ]).joined(separator: "\n")

        let storage = (comment("localStorage is kept per service, so two services of this "
            + "type do not share it.")
            + [""] + [
            "let count = Number(localStorage.getItem(\"count\") || \"0\") + 1;",
            "localStorage.setItem(\"count\", String(count));",
            "",
            "push({",
            "    url: \"https://example.com/notify\",",
            "    method: \"POST\",",
            "    body: { seen: count, title: bullet.title }",
            "});",
        ]).joined(separator: "\n")

        let fields = ([
            "console.log(bullet);",
        ]
            + comment("bullet.deviceName, bullet.appName, bullet.appID, bullet.title, "
                + "bullet.subtitle, bullet.message, bullet.date")
            + comment("bullet.icon   — base64 PNG of the app icon")
            + comment("bullet.image  — base64 of the notification's attachment", "")
            + comment("Also available: fetch(url, init), localStorage, console.log()")
        ).joined(separator: "\n")

        return [
            ("Send a notification", header),
            ("Skip some notifications", skip),
            ("Get a token first", token),
            ("Remember values between runs", storage),
            ("What the notification carries", fields),
        ]
    }

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
        gutterNeedsRebuild = true
        updateGutter()
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
