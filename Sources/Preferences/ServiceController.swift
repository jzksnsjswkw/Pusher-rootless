import UIKit
import Preferences

/// One service instance's settings page.
///
/// A page shows one *instance*, so its cells are keyed by the instance's id and
/// routed into that instance's own object in the `Services` array (see
/// ``SpecifierRouting``). Which cells to show is the one thing that depends on
/// the instance's *type*: a built-in service loads its own specifier plist
/// (`Bark.plist`, …), the generic webhook loads `Custom.plist`.
@objc(NSPServiceController)
public class ServiceController: ListController, UNUserNotificationCenterDelegate {
    let serviceInstanceID: String
    /// The descriptor name, which selects the specifier plist.
    private let serviceType: String
    private let icon: UIImage?
    private var uiColor: UIColor?
    private var titleView: UIStackView?

    /// - Parameter instance: the instance to configure.
    public init(instance: ServiceInstance) {
        self.serviceInstanceID = instance.id
        self.serviceType = instance.type
        // The same picture the list row shows: the service's, not the instance's.
        // See `ServiceListController.reloadData`.
        self.icon = ServiceArtwork.image(forType: instance.type)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()

        // The test-push result arrives as a local notification; becoming the
        // delegate is what lets it also show while Settings is frontmost.
        UNUserNotificationCenter.current().delegate = self

        // Through the setter so the identity check in the getter works.
        self.specifiers = buildSpecifiers()
        // Seed what the page was built with, so the first toggle has something
        // to compare against. The judgement is the builder's own, read from the
        // same store, so seeding cannot disagree with the rows that were built —
        // unlike asking the cell, which may not be findable yet.
        seedImageSizing()
        seedCipherSettings()

        guard let icon else { return }
        let label = UILabel()
        label.text = Localization.instanceDisplayName(
            ServiceInstanceStore.instance(id: serviceInstanceID)
                ?? ServiceInstance(id: serviceInstanceID, type: serviceType,
                                   name: serviceType, isEnabled: false, config: Prefs())
        )
        label.font = .boldSystemFont(ofSize: 17)
        // The title bar says it too. A page whose only cells are a warning and a
        // log link should not need reading to find out why, and the title is what
        // the user sees while the page animates in.
        if ServiceRegistry.knownService(named: serviceType) == nil {
            label.textColor = .systemRed
        }

        // Sized to match a list row's icon and drawn as the same 29-point tile,
        // so the page's title and the row that opened it show one picture at one
        // size. A `UIImageView` with a bare image would take the bitmap's own
        // size and square corners, which is what made a chosen logo look unlike
        // the built-in artwork beside it.
        let iconView = UIImageView(image: icon)
        // No corner radius here: the tile shape is baked into the image itself,
        // which is what keeps a chosen logo and the bundled artwork identical in
        // shape — the same reason the list row sets none.
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 29),
            iconView.heightAnchor.constraint(equalToConstant: 29),
        ])

        let stack = UIStackView(arrangedSubviews: [iconView, label])
        stack.alignment = .center
        stack.spacing = 10
        navigationItem.titleView = stack
        titleView = stack
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // Only the Shortcut service has a guide: the other instance pages send
        // through a plist-backed request whose fields the page itself explains.
        // Set on each appearance rather than once, because the framework rebuilds
        // the bar as it reloads the page.
        if serviceType == ShortcutService.serviceName {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "Guide".localized, style: .plain,
                target: self, action: #selector(showShortcutGuide)
            )
        }

        // The tint is derived from the icon once; recomputing it on every
        // appearance would make the page flicker between colors.
        if uiColor == nil, let icon {
            uiColor = IconColor.dominantColor(in: icon)
        }
        Theme.setActiveTintColor(uiColor)
        tintToPusherColor()

        // The "(N total)" counts on the app-list links were computed when the
        // cells were built; coming back from the app list with a changed
        // selection would otherwise keep showing the old number.
        refreshTitleCounts()

        // Re-seeded rather than compared: the page is rebuilt on every
        // appearance, so whatever was toggled elsewhere is already reflected.
        seedImageSizing()
        seedCipherSettings()
    }

    /// Colours the encryption footer red when the key is the wrong length.
    ///
    /// Asked as each cell is built, so reloading the encryption group is enough to
    /// have the colour follow the key — and the caption that names the group is
    /// what says which cell this is, since the footer's own text is the
    /// framework's to lay out.
    public override func footerColour(for specifier: PSSpecifier) -> UIColor? {
        guard specifier.cellType == .groupCell,
              specifier.name == "Encryption".localized
        else { return nil }
        let problem = ServiceSpecifierBuilders.cipherProblem(
            stored: PrefsStore.instance(serviceInstanceID)
        )
        return problem == nil ? .secondaryLabel : .systemRed
    }

    /// The Shortcut guide, presented over this page.
    @objc private func showShortcutGuide() {
        view.endEditing(true)
        ShortcutGuide.present(from: self)
    }

    /// Recomputes the "(N total)" suffixes on the installed cells.
    ///
    /// Each title is rebuilt from its name with the suffix stripped, so
    /// repeated appearances neither compound the suffix nor leave a stale count.
    /// (This page owns the counts: the app list strips them while it is open,
    /// because a live count in its own bar cannot survive AltList's title
    /// handling.)
    private func refreshTitleCounts() {
        for case let specifier as PSSpecifier in (super.specifiers ?? []) {
            guard specifier.cellType == .linkCell, specifier.name != nil else { continue }
            let base = AppListTitle.baseName(of: specifier.name)
            guard base == "App List".localized || base == "App Customization".localized else {
                continue
            }
            updateTitleCounts(specifier)
            // The title change is only visible after the row is redrawn.
            reloadSpecifier(specifier, animated: false)
        }
    }


    // MARK: - Rows that follow the image switch

    /// Whether the page currently shows the image-sizing rows.
    ///
    /// Remembered so a rebuild happens only when the answer changes: the rows
    /// are how the picture is scaled, so with the image switched off they
    /// describe nothing and are not built at all.
    ///
    /// Seeded when the page loads, not left empty for the first comparison to
    /// fill in. An unseeded value makes the *first* toggle only record the new
    /// state and return, so the rows would not move until the page was entered
    /// again — which is exactly what a "needs a return visit" report means.
    private var showsImageSizing: Bool?

    /// The same, for the encryption fields: whether the page as built shows them.
    ///
    /// Seeded rather than left empty for the same reason: an unseeded value makes
    /// the first tap only record the state, so the fields would not appear until
    /// the page was entered again.
    private var showsCipherSettings: Bool?

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    /// Records whether the page as built shows the image-sizing rows.
    private func seedImageSizing() {
        showsImageSizing = ServiceSpecifierBuilders.includeImage(
            stored: PrefsStore.instance(serviceInstanceID),
            fallback: Prefs(ServiceRegistry.service(named: serviceType).newInstancePrefs())
        )
    }

    /// Records whether the page as built shows the encryption fields.
    private func seedCipherSettings() {
        let stored = PrefsStore.instance(serviceInstanceID)
        showsCipherSettings = stored.bool(BarkPrefKey.cipherEnabled, default: false)
    }

    /// Rebuilds the page when "Include Image" has been switched.
    ///
    /// Called by the storage layer the moment the value is stored, so the page
    /// follows the tap rather than a file write; the switch names this
    /// controller as its change observer when the row is built.
    ///
    /// - Parameters:
    ///   - key: which setting changed.
    ///   - value: what it changed to, taken from the write itself. Anything but
    ///     a switch cell's boolean (a cleared field, say) reads as off.
    @objc func cellDidChange(_ key: String, to value: Any?) {
        // Two switches decide whether rows below them are shown: the image toggle
        // governs the sizing rows, and the encryption toggle the encryption
        // fields. The value arrives from the write itself, so there is no second
        // read to fall behind.
        switch key {
        case PrefKey.includeImage:
            let isOn = bool(value)
            guard let previous = showsImageSizing else {
                showsImageSizing = isOn
                return
            }
            guard previous != isOn else { return }
            showsImageSizing = isOn
        case BarkPrefKey.cipherEnabled:
            let isOn = bool(value)
            guard let previous = showsCipherSettings else {
                showsCipherSettings = isOn
                return
            }
            guard previous != isOn else { return }
            showsCipherSettings = isOn
        case BarkPrefKey.cipherKey, BarkPrefKey.cipherAlgorithm:
            // The rows do not move, but the footer's verdict does: a key of the
            // wrong length for the chosen algorithm is the one thing this page can
            // tell the user before a push is sent and decryption fails. Reloading
            // the group rebuilds its cell, which is when the colour is decided.
            reloadCipherFooter()
            return
        default:
            return
        }
        installSpecifiers(buildSpecifiers())
    }

    /// Redraws the encryption group so its footer's colour is decided again.
    private func reloadCipherFooter() {
        guard let group = (super.specifiers ?? [])
            .compactMap({ $0 as? PSSpecifier })
            .first(where: { $0.cellType == .groupCell && $0.name == "Encryption".localized })
        else { return }
        reloadSpecifier(group, animated: false)
    }

    /// A switch's value, which arrives as a number.
    private func bool(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? (value as? Bool) ?? false
    }

    // MARK: - Specifiers

    /// Builds the page's cells.
    ///
    /// Called from `viewDidLoad` and, through the `specifiers` getter, whenever
    /// the framework has dropped the array (backgrounding the app does this).
    /// Rebuilding here rather than once at load time is what keeps the page
    /// showing *this* instance's settings after a background round trip: the
    /// getter re-derives everything from the instance, so a discarded array can
    /// never be replaced by another page's cells.
    /// Loads the shared tail every service page gets: device conditions, the
    /// SNS page link and the log link (the `GlobalAndServices.plist` cells).
    ///
    /// The plist declares the flat keys the global page owns; on an instance
    /// page they address the instance's own copy, and each segment gains a
    /// "Default" option meaning "follow the global setting". (The global page
    /// does not route these cells and leaves the segment values untouched; see
    /// `GlobalSettingsListController.buildSpecifiers()`.)
    /// The app black/whitelist cells for a script service.
    ///
    /// Built as code rather than loaded from a plist, because the script page
    /// loads no plist; the segment's titles and values are the ones
    /// `Custom.plist` carries for the same cells.
    func appFilterSpecifiers() -> [PSSpecifier] {
        var specifiers: [PSSpecifier] = []

        if let group = PSSpecifier.groupSpecifier(withName: "Apps".localized) {
            specifiers.append(group)
        }

        if let segment = PSSpecifier.preferenceSpecifierNamed(
            nil, target: PreferencesStorage.self,
            set: #selector(PreferencesStorage.setValue(_:forInstanceSpecifier:)),
            get: #selector(PreferencesStorage.readValue(forInstanceSpecifier:)),
            detail: nil, cell: .segmentCell, edit: nil
        ) {
            segment.identifier = "appListIsBlacklist"
            segment.name = nil
            segment.setProperty(serviceInstanceID, forKey: SpecifierRouting.PropertyKey.instanceID)
            segment.setProperty(PrefKey.appListIsBlacklist, forKey: SpecifierRouting.PropertyKey.key)
            segment.setProperty(PrefKey.appListIsBlacklist,
                                forKey: SpecifierRouting.PropertyKey.customAppsPrefsKey)
            segment.setProperty(true, forKey: "enabled")
            segment.setProperty(true, forKey: SpecifierRouting.PropertyKey.defaultValue)
            segment.setValues([true, false], titles: ["Blacklist".localized, "Whitelist".localized])
            specifiers.append(segment)
        }

        if let appList = PSSpecifier.preferenceSpecifierNamed(
            "App List".localized, target: nil, set: nil, get: nil,
            detail: AppListController.self, cell: .linkCell, edit: nil
        ) {
            appList.setProperty("app_list", forKey: "icon")
            appList.setProperty(serviceInstanceID, forKey: SpecifierRouting.PropertyKey.instanceID)
            appList.setProperty(serviceType, forKey: SpecifierRouting.PropertyKey.serviceType)
            appList.setProperty(isWebhook, forKey: SpecifierRouting.PropertyKey.isWebhook)
            appList.setProperty(true, forKey: "useSearchBar")
            appList.setProperty(true, forKey: "alphabeticIndexingEnabled")
            appList.setProperty(
                NSValue(nonretainedObject: self), forKey: SpecifierRouting.PropertyKey.listReference
            )
            specifiers.append(appList)
        }
        return specifiers
    }

    func globalTailSpecifiers() -> [PSSpecifier] {
        let loaded = (loadSpecifiers(named: "GlobalAndServices") as? [PSSpecifier]) ?? []
        for specifier in loaded {
            specifier.setProperty(serviceInstanceID, forKey: SpecifierRouting.PropertyKey.instanceID)
            specifier.setProperty(serviceType, forKey: SpecifierRouting.PropertyKey.serviceType)
            if specifier.cellType == .segmentCell {
                // The plist's two real values (Locked/Either/Unlocked, Any/WiFi/
                // Cellular) get a leading "Default" whose value is the segment
                // cell's unset sentinel, so an unmodified segment stores nothing
                // and the instance follows the global preference.
                var values: [Any] = specifier.values ?? []
                let titleDictionary = specifier.titleDictionary ?? [:]
                var titles: [String] = ["Default".localized]
                for value in values {
                    guard let key = value as? AnyHashable else { continue }
                    titles.append(titleDictionary[key] as? String ?? "")
                }
                values.insert(NSNumber(value: segmentCellDefault), at: 0)
                specifier.setValues(values, titles: titles)
                specifier.setProperty(
                    NSNumber(value: segmentCellDefault),
                    forKey: SpecifierRouting.PropertyKey.defaultValue
                )
            }
            if specifier.cellType == .linkCell {
                specifier.setProperty(
                    isWebhook, forKey: SpecifierRouting.PropertyKey.isWebhook
                )
            }
        }
        SpecifierRouting.route(loaded, to: PreferencesStorage.self, scope: .instance(id: serviceInstanceID))

        return loaded
    }

    func buildSpecifiers() -> NSMutableArray {
        // An instance whose service was deleted has nothing to configure: its
        // cells come from a service that no longer exists, so the page would show
        // either a stranger's fields or none at all. It gets the warning and the
        // actions that still make sense.
        if ServiceRegistry.knownService(named: serviceType) == nil {
            let cells = missingServiceSpecifiers()
            // Same finishing pass as the full page below: the count suffix on the
            // app-list row is added here for every cell, so the short page cannot
            // drift from the long one.
            for specifier in cells { updateTitleCounts(specifier) }
            return NSMutableArray(array: cells)
        }

        // Which cells describe this instance is a property of its *type*: a
        // built-in service has its own plist, and every user-defined type — the
        // generic webhook and each script a user wrote — is configured like a
        // webhook, because a script says how to send and the instance only says
        // where to.
        // A script-defined type has no plist of its own: the script decides the
        // URL, method and body, so the webhook fields Custom.plist carries would
        // be dead controls. Its page is the Script row followed by the shared
        // cells, which is also why there is exactly one way in to the script.
        let isScriptType = CustomServiceStore.definition(id: serviceType) != nil
        // The Shortcut service is built in code too — it loads an empty plist —
        // so it needs the same two groups a script type gets: the app filter and
        // the payload options. Which apps a Shortcut applies to is the
        // instance's business, and the icon/image switches are what makes the
        // difference between a payload that is a few hundred bytes of text and
        // one that carries pictures.
        let needsBuiltGroups = isScriptType || serviceType == ShortcutService.serviceName
        let loaded: [PSSpecifier]
        var all: [PSSpecifier]
        if isScriptType {
            loaded = []
            all = []
        } else {
            loaded = loadSpecifiers(named: serviceType) as? [PSSpecifier] ?? []
            all = loaded
        }
        for specifier in loaded {
            specifier.setProperty(serviceInstanceID, forKey: SpecifierRouting.PropertyKey.instanceID)
            specifier.setProperty(serviceType, forKey: SpecifierRouting.PropertyKey.serviceType)
            // The app list controller needs to know whether this page belongs to
            // a webhook so it can seed a new override correctly.
            if specifier.cellType == .linkCell, specifier.name == "App List".localized {
                specifier.setProperty(isWebhook, forKey: SpecifierRouting.PropertyKey.isWebhook)
            }
        }
        SpecifierRouting.route(loaded, to: PreferencesStorage.self, scope: .instance(id: serviceInstanceID))

        // ── The settings this service declares ──────────────────────────────
        // Where a service's own vocabulary is filled in: the fields the service
        // declared, with this instance's values. They sit above the shared
        // payload options because they are what makes *this* destination work —
        // a key that is missing means nothing is sent at all.
        all.append(contentsOf: declaredConfigSpecifiers())

        // No icon row here: an instance has none of its own. The icon identifies
        // the *service* — it is the only thing that does — and the name identifies
        // the instance. A logo is chosen on the service's own page.

        // Shared cells (device/sound pickers, the payload options) come from the
        // type's own builder, looked up by name so a new service needs no change
        // here.
        all.append(contentsOf: ServiceSpecifierBuilders.shared.builders(
            for: serviceType, instanceID: serviceInstanceID, appID: nil,
            pageObserver: self
        ))

        // A script service carries the app filter, since which apps it applies
        // to is the instance's business — two services of one script may serve
        // different apps. The segment cell comes with the "Default" option the
        // global tail adds to its own segments, so an untouched filter follows
        // the global app list.
        if needsBuiltGroups {
            all.append(contentsOf: appFilterSpecifiers())

            // A page built without a plist asks for its payload options by the
            // type's own name: for a script the switches offered are the ones
            // *this definition* declared, which is what makes the definition's
            // choices meaningful rather than a default a page can quietly
            // contradict; for the Shortcut service they are its own two.
            all.append(contentsOf: ServiceSpecifierBuilders.shared.payloadOptions(
                forType: serviceType, instanceID: serviceInstanceID, appID: nil,
                pageObserver: self
            ))
        }

        // The instance's own hooks: they apply to this destination only, which
        // is why they live on the instance rather than on the type.
        all.append(contentsOf: hookSpecifiers())

        // Device conditions, the SNS page and the log page are shared by every
        // instance; they close out the page.
        all.append(contentsOf: globalTailSpecifiers())

        for specifier in all {
            updateTitleCounts(specifier)
        }

        all.append(contentsOf: testPushSection())
        return NSMutableArray(array: all)
    }

    /// The page for an instance whose service was deleted.
    ///
    /// Kept deliberately short. The point is not to offer a repair — the user
    /// makes a new instance for that, from the service they now want — but to
    /// explain why nothing works and to keep the two things that remain useful:
    /// the app filter and the log, which say what this instance did before its
    /// service went away.
    private func missingServiceSpecifiers() -> [PSSpecifier] {
        var all: [PSSpecifier] = []

        if let warning = PSSpecifier.groupSpecifier(withName: "") {
            warning.setProperty(
                ("This instance's service was deleted, so it cannot send anything. "
                    + "Its settings are kept below, without the labels and groups the "
                    + "service used to give them, and a new instance of another "
                    + "service can be made from the Instances page.").localized,
                forKey: "footerText"
            )
            all.append(warning)
        }

        // The values that are still on the instance, by key. The declaration that
        // gave them titles and groups went with the service, so what is left is
        // the key — which is still the name the script read it by.
        all.append(contentsOf: declaredConfigSpecifiers())
        // Through `updateTitleCounts`, exactly as the full page does: the app-list
        // row's "(N total)" suffix is what tells the user a filter is set, and a
        // row built without it would lose the count on the next appearance while
        // every *other* page kept it.
        all.append(contentsOf: appFilterSpecifiers())

        // The whole shared tail, not a hand-picked row: the device conditions, the
        // notification-settings link and the log are properties of the *instance*
        // — when it is allowed to fire, what it checks — and they outlive the
        // service. Taking only the log row made the page a different shape from
        // every other instance's, and quietly dropped conditions the user had set
        // or may still want to set.
        all.append(contentsOf: globalTailSpecifiers())

        all.append(contentsOf: hookSpecifiers())
        return all
    }

    /// Whether this instance is a user-defined webhook.
    /// Whether this instance's type is a built-in service.
    private var isBuiltInType: Bool { ServiceRegistry.isBuiltIn(serviceType) }

    /// Whether this instance's type is one the user defined.
    private var isWebhook: Bool { !isBuiltInType }

    /// The cells, rebuilt whenever the framework has discarded the array.
    public override func rebuildSpecifiers() -> NSMutableArray? {
        buildSpecifiers()
    }

    /// Appends "(N total)" to the app-list and app-customization links.
    private func updateTitleCounts(_ specifier: PSSpecifier) {
        guard specifier.cellType == .linkCell, let name = specifier.name else { return }

        let base = AppListTitle.baseName(of: name)
        let isAppList = base == "App List".localized
        let isCustomization = base == "App Customization".localized
        guard isAppList || isCustomization else { return }

        let count: Int
        if isAppList {
            count = AppListStorage.forInstance(serviceInstanceID).count
        } else {
            count = PrefsStore.instance(serviceInstanceID).dict(PrefKey.customApps)?.keys.count ?? 0
        }
        AppListTitle.apply(specifier, base: base, count: count)

        // A non-retaining back-reference: a strong one would form
        // controller -> specifiers -> controller and the page would never be
        // deallocated.
        specifier.setProperty(NSValue(nonretainedObject: self),
                              forKey: SpecifierRouting.PropertyKey.listReference)
    }

    /// The "Send Test Notification" button.
    /// The settings the service declares, as cells this instance fills in.
    ///
    /// Built from the declarations rather than from a plist, because they are
    /// the service's own vocabulary and exist only at runtime. Grouped the way
    /// the service arranged them, so a page and the script that reads the same
    /// fields describe them the same way.
    func declaredConfigSpecifiers() -> [PSSpecifier] {
        var fields = ConfigFields.declared(byDefinition: serviceType)
        if fields.isEmpty {
            // The service is gone, so nothing declares these any more — but the
            // values are still on the instance. Rendered from the values, so the
            // settings the user filled in remain visible and editable instead of
            // the page looking as though they had been lost.
            fields = ConfigFields.savedFields(forInstance: serviceInstanceID)
        }
        guard !fields.isEmpty else { return [] }

        var specifiers: [PSSpecifier] = []
        for group in ConfigFields.grouped(fields) {
            guard let head = PSSpecifier.groupSpecifier(
                withName: group.name.isEmpty ? nil : group.name
            ) else { continue }
            if !group.note.isEmpty {
                head.setProperty(group.note, forKey: "footerText")
            }
            specifiers.append(head)

            for field in group.fields where !field.key.isEmpty {
                switch field.kind {
                case .toggle:
                    guard let cell = PSSpecifier.preferenceSpecifierNamed(
                        field.displayTitle, target: PreferencesStorage.self,
                        set: #selector(PreferencesStorage.setValue(_:forInstanceSpecifier:)),
                        get: #selector(PreferencesStorage.readValue(forInstanceSpecifier:)),
                        detail: nil, cell: .switchCell, edit: nil
                    ) else { continue }
                    cell.identifier = field.key
                    cell.setProperty(serviceInstanceID,
                                     forKey: SpecifierRouting.PropertyKey.instanceID)
                    cell.setProperty(serviceType,
                                     forKey: SpecifierRouting.PropertyKey.serviceType)
                    cell.setProperty(field.key, forKey: SpecifierRouting.PropertyKey.key)
                    cell.setProperty(true, forKey: SpecifierRouting.PropertyKey.isConfigField)
                    // The declaration's default is not a fallback — the value was
                    // seeded when the instance was created — so an unset switch
                    // reads off, which is what the stored value would say anyway.
                    cell.setProperty(false, forKey: SpecifierRouting.PropertyKey.defaultValue)
                    cell.setProperty(true, forKey: "enabled")
                    specifiers.append(cell)

                case .text:
                    guard let cell = PSSpecifier.preferenceSpecifierNamed(
                        field.displayTitle, target: PreferencesStorage.self,
                        set: #selector(PreferencesStorage.setValue(_:forInstanceSpecifier:)),
                        get: #selector(PreferencesStorage.readValue(forInstanceSpecifier:)),
                        detail: nil, cell: .editTextCell, edit: nil
                    ) else { continue }
                    cell.identifier = field.key
                    cell.setProperty(serviceInstanceID,
                                     forKey: SpecifierRouting.PropertyKey.instanceID)
                    cell.setProperty(serviceType,
                                     forKey: SpecifierRouting.PropertyKey.serviceType)
                    cell.setProperty(field.key, forKey: SpecifierRouting.PropertyKey.key)
                    cell.setProperty(true, forKey: SpecifierRouting.PropertyKey.isConfigField)
                    cell.setProperty(true, forKey: "enabled")
                    cell.setProperty(true, forKey: "noAutoCorrect")
                    specifiers.append(cell)
                }
            }
        }
        return specifiers
    }

    /// The two JavaScript hooks of this instance.
    ///
    /// Each is a switch plus a link to its editor. The switch is separate from
    /// the link because the two answer different questions — "does this run?"
    /// and "what does it say?" — and because an abandoned hook has to be
    /// switchable off without deleting its source, which is what keeps it from
    /// costing anything per notification.
    ///
    /// Built as code rather than from a plist: the cell is generic (a switch and
    /// a button), so there is nothing per-service to declare.
    func hookSpecifiers() -> [PSSpecifier] {
        var specifiers: [PSSpecifier] = []
        if let group = PSSpecifier.groupSpecifier(withName: "JavaScript Hooks".localized) {
            group.setProperty(
                ("Runs for every notification this service would receive. A hook "
                    + "cannot send anything: it decides whether to continue "
                    + "(keep) and may rewrite the notification's text.").localized,
                forKey: "footerText"
            )
            specifiers.append(group)
        }

        for phase in [BulletinHookRunner.Phase.received, BulletinHookRunner.Phase.filtered] {
            let isReceived = phase == .received
            let enabledKey = isReceived ? PrefKey.hookReceivedEnabled : PrefKey.hookFilteredEnabled

            if let toggle = PSSpecifier.preferenceSpecifierNamed(
                (isReceived ? "On Receiving" : "After Filtering").localized,
                target: PreferencesStorage.self,
                set: #selector(PreferencesStorage.setValue(_:forInstanceSpecifier:)),
                get: #selector(PreferencesStorage.readValue(forInstanceSpecifier:)),
                detail: nil, cell: .switchCell, edit: nil
            ) {
                toggle.identifier = enabledKey
                toggle.setProperty(serviceInstanceID,
                                   forKey: SpecifierRouting.PropertyKey.instanceID)
                toggle.setProperty(enabledKey, forKey: SpecifierRouting.PropertyKey.key)
                // Off by default. A hook runs JavaScript per notification, so it
                // is something the user turns on deliberately — an instance that
                // has never been near the hook section must not be paying for
                // one.
                toggle.setProperty(false, forKey: SpecifierRouting.PropertyKey.defaultValue)
                toggle.setProperty(true, forKey: "enabled")
                specifiers.append(toggle)
            }

            // A `linkCell` with a placeholder `detail:`, which is the pairing
            // that makes the row usable: the framework greys out a link whose
            // specifier names no detail class (it reads that as "nothing to
            // open"). The class is never instantiated — the tap is handled
            // below, before the framework's own push — it exists only to keep
            // the row enabled and its chevron showing. The real phase travels on
            // the specifier, because the framework builds a detail controller
            // through `init(nibName:bundle:)` and cannot carry one.
            if let link = PSSpecifier.preferenceSpecifierNamed(
                (isReceived ? "Edit Received Hook" : "Edit Filtered Hook").localized,
                target: self, set: nil, get: nil,
                detail: HookEditorController.self, cell: .linkCell, edit: nil
            ) {
                link.setProperty("script", forKey: "icon")
                link.setProperty(serviceInstanceID,
                                 forKey: SpecifierRouting.PropertyKey.instanceID)
                link.setProperty(phase.rawValue, forKey: SpecifierRouting.PropertyKey.hookPhase)
                specifiers.append(link)
            }
        }
        return specifiers
    }

    func testPushSection() -> [PSSpecifier] {
        guard let group = PSSpecifier.emptyGroup() else { return [] }
        guard let button = PSSpecifier.preferenceSpecifierNamed(
            "Send Test Notification".localized,
            target: self, set: nil, get: nil, detail: nil, cell: .buttonCell, edit: nil
        ) else { return [group] }

        // The button's selector is installed through the runtime for the same
        // reason as the value setters: it is an ObjC ivar.
        button.buttonAction = #selector(sendTestNotification(_:))
        button.setProperty(true, forKey: "enabled")
        return [group, button]
    }

    // MARK: - Rows

    /// Opens one hook's editor.
    ///
    /// Intercepted before `super` so the framework's own detail push — which
    /// would build a phase-less `HookEditorController` — never happens. The
    /// phase comes off the specifier, which is the only place it can travel: a
    /// detail class is instantiated through `init(nibName:bundle:)` with no way
    /// to pass one.
    public override func tableView(
        _ tableView: UITableView, didSelectRowAt indexPath: IndexPath
    ) {
        if let specifier = specifier(at: indexPath),
           let name = specifier.property(
               forKey: SpecifierRouting.PropertyKey.hookPhase
           ) as? String,
           let phase = BulletinHookRunner.Phase(rawValue: name) {
            tableView.deselectRow(at: indexPath, animated: true)
            view.endEditing(true)
            push(HookEditorController(instanceID: serviceInstanceID, phase: phase))
            return
        }
        super.tableView(tableView, didSelectRowAt: indexPath)
    }

    // MARK: - Actions

    /// Asks SpringBoard to push a test notification to this instance.
    ///
    /// SpringBoard owns the push pipeline, so the request goes over
    /// distributed messaging; when no server is listening (SpringBoard has not
    /// been restarted since installation) the send is reported as failed rather
    /// than as an error.
    @objc public func sendTestNotification(_ specifier: PSSpecifier) {
        view.endEditing(true)
        PusherLog.debug("Sending test for \(serviceInstanceID)")

        // No server is listening until SpringBoard has been restarted after
        // installation, which is reported as a failed send rather than as an
        // error.
        var success = false
        if let center = CPDistributedMessagingCenter(named: Pusher.messagingCenterName) {
            // The reply is optional: a `nil` result means no server answered,
            // which is treated as a failed send rather than an error.
            let reply = center.sendMessageAndReceiveReplyName(
                Pusher.testPushMessageName, userInfo: ["service": serviceInstanceID]
            ) as? [String: Any]
            success = (reply?["success"] as? NSNumber)?.boolValue ?? false
        }

        let result = success
            ? String(format: "%@Sent".localized, testPushResultPrefix)
            : String(format: "%@Failed to Send".localized, testPushResultPrefix)
        displayNotification(result)
    }

    @objc public func openPushoverAppBuild() {
        openURL("https://pushover.net/apps/build")
    }

    @objc public func openPushoverDashboard() {
        openURL("https://pushover.net/dashboard")
    }

    @objc public func openPushbulletAccount() {
        openURL("https://www.pushbullet.com/#settings/account")
    }

    @objc public func openIFTTTAccount() {
        openURL("https://ifttt.com/services/maker_webhooks/settings")
    }

    @objc public func openDateFormatInstructions() {
        openURL("https://nsdateformatter.com")
    }

    @objc public func openPusherReceiverFirefoxExtension() {
        openURL("https://addons.mozilla.org/en-US/firefox/addon/pusher-receiver/")
    }

    @objc public func openPusherReceiverChromeExtension() {
        openURL("https://chrome.google.com/webstore/detail/pusher-receiver/"
            + "cegndpdokeeegijbkidfcolhomffhibh")
    }

    @objc public func openTwitterBurkybang() {
        Theme.openTwitter("burkybang")
    }

    // MARK: - Notification presentation

    /// Lets a test-push result appear while Settings is in the foreground.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        var options: UNNotificationPresentationOptions = [.sound, .badge]
        if #available(iOS 14.0, *) {
            options.insert(.banner)
        } else {
            options.insert(.alert)
        }
        completionHandler(options)
    }
}
