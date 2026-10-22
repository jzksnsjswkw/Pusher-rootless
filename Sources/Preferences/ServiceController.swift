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

        // Two services have a guide, for the same reason: both hand the user off
        // to another app — a Shortcut to build, a Bark key to read off Bark's own
        // screen — and the pages here cannot show what is over there. The rest
        // explain themselves through their plist.
        //
        // Set on each appearance rather than once, because the framework rebuilds
        // the bar as it reloads the page.
        switch serviceType {
        case ShortcutService.serviceName:
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "Guide".localized, style: .plain,
                target: self, action: #selector(showShortcutGuide)
            )
        case BarkService.serviceName:
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "Guide".localized, style: .plain,
                target: self, action: #selector(showBarkGuide)
            )
        case ServerChan3Service.serviceName:
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "Guide".localized, style: .plain,
                target: self, action: #selector(showServerChan3Guide)
            )
        default:
            break
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
        refreshCipherFooter()
    }

    /// The key field, watched as it is typed into.
    ///
    /// `cellDidChange` only fires when the framework calls the setter, which is
    /// when the field loses focus — so the warning would appear only after the
    /// user looked away. The field's own `editingChanged` is what makes it appear
    /// as they type, which is the same reason the add-service page watches its
    /// name field.
    private weak var cipherKeyField: UITextField?

    /// Watches the key field if it is not already watched.
    ///
    /// A reload builds a new cell and a new field, so the listener is re-attached
    /// whenever the cell is shown rather than once.
    private func observeCipherKeyField(in cell: UITableViewCell) {
        guard let field = Self.firstTextField(in: cell) else { return }
        guard cipherKeyField !== field else { return }
        cipherKeyField = field
        field.addTarget(self, action: #selector(cipherKeyChanged(_:)), for: .editingChanged)
    }

    @objc private func cipherKeyChanged(_ field: UITextField) {
        // The live text, not the stored value: the write has not happened yet.
        refreshCipherFooter(key: field.text ?? "")
    }

    private static func firstTextField(in view: UIView) -> UITextField? {
        for subview in view.subviews {
            if let field = subview as? UITextField { return field }
            if let found = firstTextField(in: subview) { return found }
        }
        return nil
    }

    /// Rewrites the encryption group's explanation to state the key's problem.
    ///
    /// The note is *text*, not a colour. A group's footer is a
    /// `UITableViewHeaderFooterView` the framework builds and lays out, and three
    /// attempts to reach into it and change its colour failed for three different
    /// reasons; the run-options page has changed a footer's wording since it was
    /// written, and that path is known to work. What the user needs to know is
    /// that the key is the wrong length, and a sentence says it more precisely
    /// than a colour does.
    private func refreshCipherFooter(key: String? = nil) {
        guard let group = specifier(forID: ServiceSpecifierBuilders.cipherHeadIdentifier)
        else { return }
        let text = cipherFooterText(key: key)
        guard text != group.property(forKey: "footerText") as? String else { return }

        // Stored for the next rebuild, then written straight into the footer view
        // that is already on screen. Reloading the section instead would rebuild
        // every cell in it — including the key field the user is typing into,
        // which would lose focus and its keyboard on the first keystroke.
        group.setProperty(text, forKey: "footerText")
        updateCipherFooterView(text)
    }

    /// Puts the new text into the section's footer view, if it is on screen.
    ///
    /// The view is asked of the table rather than searched for, so nothing is
    /// rebuilt and no first responder is disturbed. When the section is off screen
    /// there is nothing to update — the paragraph is written from the specifier
    /// when the view is next built.
    private func updateCipherFooterView(_ text: String) {
        guard let table else { return }
        let rows = (super.specifiers ?? []).compactMap { $0 as? PSSpecifier }
        var section = -1
        for specifier in rows where specifier.cellType == .groupCell {
            section += 1
            guard specifier.identifier == ServiceSpecifierBuilders.cipherHeadIdentifier else {
                continue
            }
            guard section < table.numberOfSections,
                  let footer = table.footerView(forSection: section)
            else { return }

            func apply(_ view: UIView) {
                if let label = view as? UILabel { label.text = text }
                view.subviews.forEach(apply)
            }
            apply(footer)
            // The footer's height depends on its text, and a footer whose height
            // was not recomputed draws the new lines outside its own bounds.
            // The footer's height depends on its text, so the section has to be
            // measured again — but only its height. /
            // re-measures without rebuilding the section's cells, which is what
            // keeps the key field's focus.
            footer.setNeedsLayout()
            UIView.performWithoutAnimation {
                table.beginUpdates()
                table.endUpdates()
            }
            return
        }
    }

    /// The encryption notes, led by the key's problem when there is one.
    ///
    /// First rather than last: the paragraph below it is four lines of reference
    /// that is the same every time, and a warning under it is a warning the user
    /// has to read past the text to find.
    private func cipherFooterText(key: String? = nil) -> String {
        let notes = ServiceSpecifierBuilders.cipherNotes()
        guard let problem = ServiceSpecifierBuilders.cipherProblem(
            stored: PrefsStore.instance(serviceInstanceID), key: key
        ) else { return notes }
        return "⚠️ " + problem + "\n\n" + notes
    }

    /// Watches the encryption key field whenever its row is displayed.
    ///
    /// No `super` call: `PSListController` does not implement this delegate
    /// method, so forwarding to it raises `doesNotRecognizeSelector`. The page
    /// filters by the cell it wants, which is why the other page using this hook
    /// does the same.
    public override func tableView(
        _ tableView: UITableView, willDisplay cell: UITableViewCell,
        forRowAt indexPath: IndexPath
    ) {
        guard let specifier = specifierForRow(indexPath),
              specifier.identifier == BarkPrefKey.cipherKey
        else { return }
        observeCipherKeyField(in: cell)
        // Seed the footer from what is in the field, so a page opened with a
        // wrong key says so before anything is typed.
        refreshCipherFooter(key: cipherKeyField?.text
            ?? PrefsStore.instance(serviceInstanceID).string(BarkPrefKey.cipherKey))
    }

    /// The Bark guide, presented over this page.
    @objc private func showBarkGuide() {
        view.endEditing(true)
        BarkGuide.present(from: self)
    }

    /// The ServerChan³ guide, presented over this page.
    @objc private func showServerChan3Guide() {
        view.endEditing(true)
        ServerChan3Guide.present(from: self)
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
        case WxPusherPrefKey.mode:
            // The credential rows appear and disappear with this.
            installSpecifiers(buildSpecifiers())
            return
        case PrefKey.appListIsBlacklist:
            // The row appears and disappears with this, so the page is rebuilt
            // rather than a single cell reloaded.
            installSpecifiers(buildSpecifiers())
            return
        case BarkPrefKey.cipherKey, BarkPrefKey.cipherAlgorithm:
            // The rows do not move, but the footer's verdict does: a key of the
            // wrong length for the chosen algorithm is the one thing this page can
            // tell the user before a push is sent and decryption fails. Reloading
            // the group rebuilds its cell, which is when the colour is decided.
            refreshCipherFooter()
            return
        default:
            return
        }
        installSpecifiers(buildSpecifiers())
    }

    /// Which WxPusher credential rows to show.
    ///
    /// Read from storage, unlike the toggles, and the difference is when this is
    /// asked: it decides which rows exist, so it is read while the list is being
    /// *built* — and at that moment `specifier(forID:)` still answers from the
    /// previous list. Asking the old cell returns the value from before the tap,
    /// which made switching the segment change nothing.
    ///
    /// The write lands in storage before `cellDidChange` is called, so this is
    /// current by the time the rebuild happens.
    private var wxPusherMode: WxPusherMode {
        WxPusherMode(
            rawValue: PrefsStore.instance(serviceInstanceID)
                .string(WxPusherPrefKey.mode, default: "")
        ) ?? .spt
    }

    /// Whether the app-list row is shown: false while the segment reads
    /// "Default", true once the instance has a list of its own.
    private var showsAppList: Bool {
        PrefsStore.instance(serviceInstanceID)[PrefKey.appListIsBlacklist] != nil
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
            segment.setProperty(
                NSValue(nonretainedObject: self),
                forKey: SpecifierRouting.PropertyKey.changeObserver
            )
            // "Default" leads, the same sentinel the device-condition segments
            // carry: chosen, it stores nothing and the instance follows the
            // global list, which the engine applies before the per-instance
            // loop. Without it the segment had only two states, and a global
            // whitelist could not be followed — "blacklist" was the closest the
            // instance could get.
            segment.setProperty(
                NSNumber(value: segmentCellDefault),
                forKey: SpecifierRouting.PropertyKey.defaultValue
            )
            segment.setValues(
                [NSNumber(value: segmentCellDefault), true, false],
                titles: ["Default".localized, "Blacklist".localized, "Whitelist".localized]
            )
            specifiers.append(segment)
        }

        // Hidden while the segment is on "Default": with no list of its own, the
        // row would open a picker whose choices the instance does not use — it
        // follows the global list — and changing them would look as though it had
        // done nothing. The row returns the moment the segment claims blacklist or
        // whitelist, which is when the list starts to mean something.
        if showsAppList, let appList = PSSpecifier.preferenceSpecifierNamed(
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
        var loaded = (loadSpecifiers(named: "GlobalAndServices") as? [PSSpecifier]) ?? []
        // The tail is shared with the global settings page, but two of its rows
        // are global-only: a rule group here would edit the instance's rules while
        // labelling itself as the global one, and there is already a rules row
        // above for this instance. Removed after loading rather than filtered out
        // of the plist, because the global page needs them.
        //
        // Its group header goes with it: a row removed from a group of one leaves
        // an empty section behind, and an empty section draws as a gap between the
        // rows either side of it.
        var kept: [PSSpecifier] = []
        for specifier in loaded {
            if specifier.name == "Notification Filter".localized {
                // Drop the header that was just added for this row, if it is one.
                if let last = kept.last, last.cellType == .groupCell, last.name == nil {
                    kept.removeLast()
                }
                continue
            }
            kept.append(specifier)
        }
        loaded = kept
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
            var rows = loadSpecifiers(named: serviceType) as? [PSSpecifier] ?? []

            // The WxPusher credential rows are cut down to what the chosen mode
            // needs: an SPT names its own recipient, so the app token and the user
            // lists beside it would be fields that do nothing. Here, because this
            // is where the service's own plist is loaded — the array above holds
            // the shared tail, which has none of these keys.
            if serviceType == WxPusherService.serviceName {
                let mode = wxPusherMode
                rows.removeAll { specifier in
                    switch specifier.property(forKey: "key") as? String {
                    case WxPusherPrefKey.spt:
                        return mode != .spt
                    case WxPusherPrefKey.appToken, WxPusherPrefKey.uids,
                         WxPusherPrefKey.topicIds:
                        return mode != .app
                    default:
                        return false
                    }
                }
            }

            loaded = rows
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
            // Every row that decides whether *other rows exist* says so here: the
            // storage layer tells this object what changed, and without the
            // observer it is told nothing — the value is stored, and the page
            // keeps showing the old set of rows until something else rebuilds it
            // (a trip to the background and back, in practice).
            if specifier.property(forKey: "key") as? String == WxPusherPrefKey.mode {
                specifier.setProperty(
                    NSValue(nonretainedObject: self),
                    forKey: SpecifierRouting.PropertyKey.changeObserver
                )
            }

            // The plist's own app-list segment (Blacklist/Whitelist) gets the same
            // leading "Default" the device-condition segments get below: chosen,
            // it stores nothing and the instance follows the global list. The
            // code-built copy of this segment — `appFilterSpecifiers`, for the
            // services with no plist — carries it already; this is the other
            // path, and it had been left at two states.
            if specifier.identifier == "appListIsBlacklist" {
                specifier.setProperty(
                    NSValue(nonretainedObject: self),
                    forKey: SpecifierRouting.PropertyKey.changeObserver
                )
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
        }
        SpecifierRouting.route(loaded, to: PreferencesStorage.self, scope: .instance(id: serviceInstanceID))

        // The plist's own app-list row hides with the segment on "Default", the
        // same way the code-built copy never gets appended in
        // `appFilterSpecifiers`: with the instance following the global list, a
        // picker here would hold choices nothing reads.
        //
        // Removed rather than skipped while the array was being walked. `all`
        // holds the same specifier *objects* as `loaded`, so dropping one here
        // drops it from the page; the walk itself only visits elements, and a
        // `continue` in it would leave the row in the array and on the screen.
        if !showsAppList {
            all.removeAll {
                $0.cellType == .linkCell
                    && AppListTitle.baseName(of: $0.name) == "App List".localized
            }
        }

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

        // And its own rules, which decide before anything else whether this
        // destination sees the notification at all.
        all.append(contentsOf: ruleSpecifiers())

        // Device conditions, the SNS page and the log page are shared by every
        // instance; they close out the page.
        all.append(contentsOf: globalTailSpecifiers())

        for specifier in all {
            updateTitleCounts(specifier)
        }

        all.append(contentsOf: testPushSection())

        // The encryption group's explanation depends on what is stored, so it is
        // written here rather than only on a later reload: the page should state
        // the key's problem the first time it is opened, not after the user
        // touches something.
        if let group = all.first(where: {
            $0.identifier == ServiceSpecifierBuilders.cipherHeadIdentifier
        }) {
            group.setProperty(cipherFooterText(), forKey: "footerText")
        }
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

    /// The instance's notification rules: the same row the global settings page
    /// uses, pointed at this instance.
    ///
    /// The same row rather than a section of its own: it is the same feature, and
    /// a page that presents it differently in two places asks the reader to learn
    /// it twice.
    func ruleSpecifiers() -> [PSSpecifier] {
        guard let group = PSSpecifier.groupSpecifier(withName: nil) else { return [] }

        guard let row = PSSpecifier.preferenceSpecifierNamed(
            "Notification Filter".localized, target: nil, set: nil, get: nil,
            detail: FilterRuleListController.self, cell: .linkCell, edit: nil
        ) else { return [group] }
        row.identifier = Self.rulesRowIdentifier
        // The image itself, not the `icon` name: the framework resolves a *name*
        // through its own lazy icon loading, which only finds bundle-backed artwork
        // for rows it built from a plist. A row built in code gets nothing, which
        // is why this one had no icon while the global page's did.
        row.setProperty(
            UIImage(named: "filter", in: Bundle.pusher, compatibleWith: nil),
            forKey: "iconImage"
        )
        row.setProperty("filter", forKey: "icon")
        let count = FilterRules.instance(serviceInstanceID).ruleCount
        row.setProperty(
            count == 0 ? "None".localized : String(format: "%d".localized, count),
            forKey: "value"
        )
        return [group, row]
    }

    /// The rules row, found again when its count changes.
    static let rulesRowIdentifier = "instanceRulesRow"

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
        // The rules row carries an owner, and a detail class cannot: the page is
        // pushed here and given the instance, rather than instantiated with none.
        if let specifier = specifier(at: indexPath),
           specifier.identifier == Self.rulesRowIdentifier {
            tableView.deselectRow(at: indexPath, animated: true)
            view.endEditing(true)
            let page = FilterRuleListController(owner: .instance(serviceInstanceID))
            page.onSave = { [weak self] in
                guard let self else { return }
                let count = FilterRules.instance(self.serviceInstanceID).ruleCount
                if let row = self.specifier(forID: Self.rulesRowIdentifier) {
                    row.setProperty(
                        count == 0 ? "None".localized
                            : String(format: "%d".localized, count),
                        forKey: "value"
                    )
                    self.reloadSpecifier(row, animated: false)
                }
            }
            push(page)
            return
        }

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
