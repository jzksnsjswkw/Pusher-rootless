import UIKit
import Preferences

/// The per-service settings page.
///
/// A page is one of three shapes, decided by how it was created:
///
///  * a **built-in service** loads its own specifier plist (`Bark.plist`, …),
///  * a **custom service** loads the shared `Custom.plist`,
///  * a **custom app** shows only the override cells for one app.
///
/// In all three cases the value cells are routed to nested storage (see
/// ``SpecifierRouting``), since the plists name flat top-level keys that nothing
/// reads any more.
@objc(NSPServiceController)
public final class ServiceController: ListController, UNUserNotificationCenterDelegate {
    private let service: String
    private let isCustomService: Bool
    private let icon: UIImage?
    private var uiColor: UIColor?
    private var titleView: UIStackView?

    /// - Parameters:
    ///   - service: the registry name (`"Pushover"`), or a custom service's name.
    ///   - icon: the service's artwork, used for the title and the tint.
    ///   - isCustom: whether this is a user-defined custom service.
    @objc public init(service: String, image: UIImage?, isCustom: Bool) {
        self.service = service
        self.isCustomService = isCustom
        self.icon = image
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
        label.text = Localization.serviceDisplayName(service)
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
    /// showing *this* service's settings after a background round trip: the
    /// getter re-derives everything from `service`, so a discarded array can
    /// never be replaced by another page's cells.
    /// Loads the shared tail every service page gets: device conditions, the
    /// SNS page link and the log link (the `GlobalAndServices.plist` cells).
    ///
    /// The plist declares the flat keys the global page owns; on a service page
    /// they address the service's own nested copy, and each segment gains a
    /// "Default" option meaning "follow the global setting". (The global page
    /// does not route these cells and leaves the segment values untouched; see
    /// `GlobalSettingsListController.buildSpecifiers()`.)
    private func globalTailSpecifiers() -> [PSSpecifier] {
        let loaded = (loadSpecifiers(named: "GlobalAndServices") as? [PSSpecifier]) ?? []
        for specifier in loaded {
            specifier.setProperty(service, forKey: SpecifierRouting.PropertyKey.service)
            if specifier.cellType == .segmentCell {
                // The plist's two real values (Locked/Either/Unlocked, Any/WiFi/
                // Cellular) get a leading "Default" whose value is the segment
                // cell's unset sentinel, so an unmodified segment stores nothing
                // and the service follows the global preference.
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
                    isCustomService, forKey: SpecifierRouting.PropertyKey.isCustomService
                )
            }
        }
        // The tail's cells address the service's own nested copy, so a custom
        // service routes them the same way as its Custom.plist cells.
        SpecifierRouting.route(
            loaded, to: PreferencesStorage.self,
            scope: isCustomService
                ? .customService(service: service)
                : .builtIn(service: service)
        )
        return loaded
    }

    private func buildSpecifiers() -> NSMutableArray {
        var all: [PSSpecifier] = []
        if isCustomService {
            // A custom service page reuses the shared Custom.plist, so its value
            // cells have to be routed individually.
            let loaded = loadSpecifiers(named: "Custom") as? [PSSpecifier] ?? []
            for specifier in loaded {
                specifier.setProperty(service, forKey: SpecifierRouting.PropertyKey.service)
                // A custom service's app list lives in the same nested place as
                // a built-in one's (CustomServices[service][appList]); the app
                // list controller needs the flag to pick that storage.
                if specifier.cellType == .linkCell,
                   specifier.name == "App List".localized {
                    specifier.setProperty(true, forKey: SpecifierRouting.PropertyKey.isCustomService)
                }
                all.append(specifier)
            }
            SpecifierRouting.route(loaded, to: PreferencesStorage.self, scope: .customService(service: service))
        } else {
            let loaded = loadSpecifiers(named: service) as? [PSSpecifier] ?? []
            all = loaded
            SpecifierRouting.route(loaded, to: PreferencesStorage.self, scope: .builtIn(service: service))
        }

        // Shared cells (device/sound pickers and the like) come from the
        // service's own builder, looked up by name so a new service needs no
        // change here.
        all.append(contentsOf: ServiceSpecifierBuilders.shared.builders(
            for: service, appID: nil
        ))

        // Device conditions, the SNS page and the log page are shared by every
        // service (built-in and custom alike); they close out the page.
        all.append(contentsOf: globalTailSpecifiers())

        for specifier in all {
            updateTitleCounts(specifier)
        }

        all.append(contentsOf: testPushSection())
        return NSMutableArray(array: all)
    }

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
            count = isCustomService
                ? AppListStorage.custom(service: service).count
                : AppListStorage.builtIn(service: service).count
        } else {
            count = PrefsStore.service(named: service, isCustom: isCustomService)
                .dict(PrefKey.customApps)?.keys.count ?? 0
        }
        AppListTitle.apply(specifier, base: base, count: count)

        // A non-retaining back-reference: a strong one would form
        // controller -> specifiers -> controller and the page would never be
        // deallocated.
        specifier.setProperty(NSValue(nonretainedObject: self),
                              forKey: SpecifierRouting.PropertyKey.listReference)
    }

    /// The "Send Test Notification" button.
    private func testPushSection() -> [PSSpecifier] {
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

    /// Asks SpringBoard to push a test notification to this service.
    ///
    /// SpringBoard owns the push pipeline, so the request goes over
    /// distributed messaging; when no server is listening (SpringBoard has not
    /// been restarted since installation) the send is reported as failed rather
    /// than as an error.
    @objc public func sendTestNotification(_ specifier: PSSpecifier) {
        view.endEditing(true)
        PusherLog.debug("Sending test for \(service)")

        // No server is listening until SpringBoard has been restarted after
        // installation, which is reported as a failed send rather than as an
        // error.
        var success = false
        if let center = CPDistributedMessagingCenter(named: Pusher.messagingCenterName) {
            // The reply is optional: a `nil` result means no server answered,
            // which is treated as a failed send rather than an error.
            let reply = center.sendMessageAndReceiveReplyName(
                Pusher.testPushMessageName, userInfo: ["service": service]
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
