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
        self.icon = ServiceIcon.image(forType: instance.type)
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

        guard let icon else { return }
        let label = UILabel()
        label.text = Localization.instanceDisplayName(
            ServiceInstanceStore.instance(id: serviceInstanceID)
                ?? ServiceInstance(id: serviceInstanceID, type: serviceType,
                                   name: serviceType, isEnabled: false, config: Prefs())
        )
        label.font = .boldSystemFont(ofSize: 17)

        let stack = UIStackView(arrangedSubviews: [UIImageView(image: icon), label])
        stack.alignment = .center
        stack.spacing = 10
        navigationItem.titleView = stack
        titleView = stack
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

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


        // Shared cells (device/sound pickers, the payload options) come from the
        // type's own builder, looked up by name so a new service needs no change
        // here.
        all.append(contentsOf: ServiceSpecifierBuilders.shared.builders(
            for: serviceType, instanceID: serviceInstanceID, appID: nil
        ))

        // A script service carries the app filter, since which apps it applies
        // to is the instance's business — two services of one script may serve
        // different apps. The segment cell comes with the "Default" option the
        // global tail adds to its own segments, so an untouched filter follows
        // the global app list.
        if isScriptType {
            all.append(contentsOf: appFilterSpecifiers())
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
                toggle.setProperty(true, forKey: SpecifierRouting.PropertyKey.defaultValue)
                toggle.setProperty(true, forKey: "enabled")
                specifiers.append(toggle)
            }

            if let link = PSSpecifier.preferenceSpecifierNamed(
                (isReceived ? "Edit Received Hook" : "Edit Filtered Hook").localized,
                target: self, set: nil, get: nil, detail: nil, cell: .linkCell, edit: nil
            ) {
                link.setProperty("script", forKey: "icon")
                link.setProperty(serviceInstanceID,
                                 forKey: SpecifierRouting.PropertyKey.instanceID)
                // Which hook to open. The engine's cell handler reads it, so one
                // class serves both links.
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

    /// Opens a hook's editor.
    ///
    /// Handled here rather than by giving the specifier a `detail:` class: the
    /// two hook links differ only by a phase, and the framework instantiates a
    /// detail class through `init(nibName:bundle:)`, which cannot carry one. The
    /// phase travels on the specifier instead, and this is where it is read.
    public override func tableView(
        _ tableView: UITableView, didSelectRowAt indexPath: IndexPath
    ) {
        if let specifier = specifier(at: indexPath),
           let phaseName = specifier.property(
               forKey: SpecifierRouting.PropertyKey.hookPhase
           ) as? String,
           let phase = BulletinHookRunner.Phase(rawValue: phaseName) {
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
