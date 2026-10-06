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
    }

    // MARK: - Specifiers

    public override var specifiers: NSMutableArray! {
        get { buildSpecifiers() }
        set { super.specifiers = newValue }
    }

    /// Builds the page's cells once; later reads return the same array so the
    /// table's indices stay valid.
    private func buildSpecifiers() -> NSMutableArray {
        guard super.specifiers == nil else { return super.specifiers }

        var all: [PSSpecifier] = []
        if isCustomService {
            // A custom service page reuses the shared Custom.plist, so its value
            // cells have to be routed individually.
            let loaded = loadSpecifiers(fromPlistName: "Custom", target: self) as? [PSSpecifier] ?? []
            for specifier in loaded {
                specifier.setProperty(service, forKey: SpecifierRouting.PropertyKey.service)
                all.append(specifier)
            }
            SpecifierRouting.route(loaded, to: PreferencesStorage.self, scope: .customService(service: service))
        } else {
            let loaded = loadSpecifiers(fromPlistName: service, target: self) as? [PSSpecifier] ?? []
            all = loaded
            SpecifierRouting.route(loaded, to: PreferencesStorage.self, scope: .builtIn(service: service))
        }

        // Shared cells (device/sound pickers and the like) come from the
        // service's own builder, looked up by name so a new service needs no
        // change here.
        all.append(contentsOf: ServiceSpecifierBuilders.shared.builders(
            for: service, appID: nil
        ))

        for specifier in all {
            updateTitleCounts(specifier)
        }

        all.append(contentsOf: testPushSection())
        super.specifiers = NSMutableArray(array: all)
        return super.specifiers
    }

    /// Appends "(N total)" to the app-list and app-customization links.
    private func updateTitleCounts(_ specifier: PSSpecifier) {
        guard specifier.cellType == .linkCell, let name = specifier.name else { return }

        let isAppList = name == "App List".localized
        let isCustomization = name == "App Customization".localized
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
        specifier.name = String(format: "%@ (%d total)".localized, specifier.name, count)

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
