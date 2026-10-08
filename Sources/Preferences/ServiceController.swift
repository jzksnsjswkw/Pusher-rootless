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
        let plistName = isBuiltInType ? serviceType : "Custom"
        let loaded = loadSpecifiers(named: plistName) as? [PSSpecifier] ?? []
        var all: [PSSpecifier] = loaded

        // A script-defined type gets a row for the script it follows, at the top
        // of the page: the script is the one thing about the instance that
        // belongs to its type, and the row is what makes the page say so before
        // it is tapped.
        if let definition = CustomServiceStore.definition(id: serviceType) {
            if let scriptRow = PSSpecifier.preferenceSpecifierNamed(
                "Script".localized, target: nil, set: nil, get: nil,
                detail: CustomServiceScriptController.self, cell: .linkCell, edit: nil
            ) {
                scriptRow.setProperty("DefaultService", forKey: "icon")
                scriptRow.setProperty(
                    String(format: "Defined by \"%@\"".localized, definition.name),
                    forKey: "footerText"
                )
                all.insert(scriptRow, at: 0)
            }
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

        // A script-defined type gets a row for the script it follows, first on
        // the page: the script is the one thing about the instance that belongs
        // to its type, and the row is what makes the page say so.
        if let definition = CustomServiceStore.definition(id: serviceType) {
            let scriptRow = PSSpecifier.preferenceSpecifierNamed(
                "Script".localized, target: nil, set: nil, get: nil,
                detail: CustomServiceScriptController.self, cell: .linkCell, edit: nil
            )!
            scriptRow.setProperty("DefaultService", forKey: "icon")
            scriptRow.setProperty(
                String(format: "Defined by \"%@\"".localized, definition.name),
                forKey: "footerText"
            )
            all.append(scriptRow)
        }

        // Shared cells (device/sound pickers, the payload options) come from the
        // type's own builder, looked up by name so a new service needs no change
        // here.
        all.append(contentsOf: ServiceSpecifierBuilders.shared.builders(
            for: serviceType, instanceID: serviceInstanceID, appID: nil
        ))

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
