import UIKit

/// The extra cells a service adds to its own settings page.
///
/// Most services are configured entirely by their plist, but several need cells
/// that push a detail controller (Pushover's device and sound pickers) or that
/// are not in any plist (Wechat's credentials, Bark's parameters). Those are
/// built and registered here, keyed by service name, so ``ServiceController``
/// can look them up without knowing which services exist — adding a service
/// does not mean editing a dispatch chain.
@objc(NSPushServicePrefs)
public final class ServiceSpecifierBuilders: NSObject {
    /// Builds the shared cells for one service.
    ///
    /// - Parameter appID: non-nil when the page is a per-app override, which
    ///   changes the cells from "the service's setting" to "this app's setting".
    public typealias Builder = (_ appID: String?) -> [PSSpecifier]

    @objc(sharedInstance)
    public static let shared = ServiceSpecifierBuilders()

    private var builders: [String: Builder] = [:]

    private override init() {
        super.init()
        registerAll()
    }

    @objc public func register(builder: @escaping Builder, forService service: String) {
        builders[service] = builder
    }

    /// Registers every service that has extra cells.
    ///
    /// The webhook is registered too: it has no specifier plist of its own
    /// beyond the endpoint fields, so its icon/image options live here with the
    /// other services'. A service without an entry (Feishu, for example)
    /// contributes nothing.
    private func registerAll() {
        register(builder: Self.webhook, forService: CustomService.serviceName)
        register(builder: Self.pushover, forService: PushoverService.serviceName)
        register(builder: Self.pushbullet, forService: PushbulletService.serviceName)
        register(builder: Self.ifttt, forService: IFTTTService.serviceName)
        register(builder: Self.wechat, forService: WechatService.serviceName)
        register(builder: Self.bark, forService: BarkService.serviceName)
        register(builder: Self.pusherReceiver, forService: PusherReceiverService.serviceName)
    }

    /// The cells to append to `service`'s page.
    func builders(for service: String, appID: String?) -> [PSSpecifier] {
        builders[service]?(appID) ?? []
    }

    // MARK: - Custom webhook

    /// The icon/image options for a user-defined service.
    ///
    /// A webhook's *endpoint* is described by `Custom.plist`; what belongs here
    /// is the payload options, which are the same shape as every other
    /// service's. The image sizing is service-wide (a per-app override inherits
    /// it), and the decoded image is what makes the payload large enough for
    /// those numbers to matter.
    private static func webhook(appID: String?) -> [PSSpecifier] {
        let service = CustomService.serviceName
        var specifiers: [PSSpecifier] = [
            toggle("Include Icon", service: service, appID: appID,
                   key: PrefKey.includeIcon, defaultValue: false),
            toggle("Include Image", service: service, appID: appID,
                   key: PrefKey.includeImage, defaultValue: true),
        ]

        if appID == nil {
            specifiers.append(contentsOf: [
                decimalField("Maximum Image Width (pixels)", service: service,
                             key: PrefKey.imageMaxWidth, defaultValue: Pusher.defaultMaxWidth),
                decimalField("Maximum Image Height (pixels)", service: service,
                             key: PrefKey.imageMaxHeight, defaultValue: Pusher.defaultMaxHeight),
                decimalField("Image Shrink Factor Upon Retry", service: service,
                             key: PrefKey.imageShrinkFactor,
                             defaultValue: Pusher.defaultShrinkFactor),
            ])
        }
        return specifiers
    }

    // MARK: - Pushover

    /// Receiving-device and notification-sound pickers.
    private static func pushover(appID: String?) -> [PSSpecifier] {
        let isCustomApp = appID != nil
        let devices = detailLink(
            "Receiving Devices", detail: DeviceListController.self,
            service: PushoverService.serviceName, appID: appID,
            properties: ["isSound": false]
        )
        let sounds = detailLink(
            "Notification Sound", detail: SoundListController.self,
            service: PushoverService.serviceName, appID: appID,
            properties: ["isSound": true]
        )
        _ = isCustomApp
        return [devices, sounds]
    }

    // MARK: - Pushbullet

    /// Pushbullet targets one device, so it gets the device picker only.
    private static func pushbullet(appID: String?) -> [PSSpecifier] {
        [
            detailLink(
                "Receiving Devices", detail: DeviceListController.self,
                service: PushbulletService.serviceName, appID: appID,
                properties: ["isSound": false]
            )
        ]
    }

    // MARK: - IFTTT

    /// The event name, plus the "include icon" and "curate request data"
    /// toggles.
    private static func ifttt(appID: String?) -> [PSSpecifier] {
        let service = IFTTTService.serviceName
        return [
            textField("Event Name", service: service, appID: appID,
                      key: PrefKey.eventName, noAutoCorrect: true),
            toggle("Include Icon", service: service, appID: appID,
                   key: PrefKey.includeIcon, defaultValue: false),
            toggle("Curate Request Data", service: service, appID: appID,
                   key: PrefKey.curateData, defaultValue: true),
        ]
    }

    // MARK: - Wechat

    /// The recipient, plus the Corporate ID / secret / agent ID credentials.
    private static func wechat(appID: String?) -> [PSSpecifier] {
        let service = WechatService.serviceName

        // A per-app override only changes who receives the message; the
        // credentials stay service-wide.
        if let appID {
            return [textField("Recipient", service: service, appID: appID, key: PrefKey.touser)]
        }

        return [
            textField("Corp ID", service: service, appID: nil, key: PrefKey.corpid),
            textField("Corp Secret", service: service, appID: nil, key: PrefKey.corpsecret),
            textField("Agent ID", service: service, appID: nil, key: PrefKey.agentID),
            textField("Recipient", service: service, appID: nil, key: PrefKey.touser),
        ]
    }

    // MARK: - Bark

    /// Bark's optional push parameters, all free-form strings.
    ///
    /// The server URL is a service-wide setting, so a per-app override page
    /// shows only the message parameters.
    private static func bark(appID: String?) -> [PSSpecifier] {
        let service = BarkService.serviceName
        var fields: [(title: String, key: String)] = [
            ("Level:", BarkPrefKey.level),
            ("Volume:", BarkPrefKey.volume),
            ("Badge:", BarkPrefKey.badge),
            ("Call:", BarkPrefKey.call),
            ("AutoCopy:", BarkPrefKey.autoCopy),
            ("Sound:", BarkPrefKey.sound),
            ("Image:", BarkPrefKey.image),
            ("Group:", BarkPrefKey.group),
            ("IsArchive:", BarkPrefKey.isArchive),
            ("TTL:", BarkPrefKey.ttl),
            ("URL:", BarkPrefKey.clickURL),
            ("Action:", BarkPrefKey.action),
            ("ID:", BarkPrefKey.id),
            ("Delete:", BarkPrefKey.delete),
        ]
        if appID == nil {
            fields.insert(("Server URL:", PrefKey.serverURL), at: 0)
        }
        return fields.map {
            textField($0.title, service: service, appID: appID,
                      key: $0.key, noAutoCorrect: true)
        }
    }

    // MARK: - Pusher Receiver

    /// The database name, plus the icon/image options.
    private static func pusherReceiver(appID: String?) -> [PSSpecifier] {
        let service = PusherReceiverService.serviceName
        var specifiers: [PSSpecifier] = [
            toggle("Include Icon", service: service, appID: appID,
                   key: PrefKey.includeIcon, defaultValue: true),
            toggle("Include Image", service: service, appID: appID,
                   key: PrefKey.includeImage, defaultValue: true),
        ]

        // The receiver's own image sizing only applies service-wide; a per-app
        // override inherits it.
        if appID == nil {
            specifiers.append(contentsOf: [
                decimalField("Maximum Image Width (pixels)", service: service,
                             key: PrefKey.imageMaxWidth, defaultValue: Pusher.defaultMaxWidth),
                decimalField("Maximum Image Height (pixels)", service: service,
                             key: PrefKey.imageMaxHeight, defaultValue: Pusher.defaultMaxHeight),
                decimalField("Image Shrink Factor Upon Retry", service: service,
                             key: PrefKey.imageShrinkFactor,
                             defaultValue: Pusher.defaultShrinkFactor),
            ])
        }
        return specifiers
    }

    // MARK: - Cell builders

    /// A link cell that pushes `detail`, carrying the service and app it edits.
    private static func detailLink(
        _ title: String,
        detail: AnyClass,
        service: String,
        appID: String?,
        properties: [String: Any] = [:]
    ) -> PSSpecifier {
        let specifier = PSSpecifier.preferenceSpecifierNamed(
            title.localized, target: nil, set: nil, get: nil,
            detail: detail, cell: .linkCell, edit: nil
        )!
        specifier.setProperty(service, forKey: SpecifierRouting.PropertyKey.serviceType)
        specifier.setProperty(appID != nil, forKey: SpecifierRouting.PropertyKey.isCustomApp)
        for (key, value) in properties {
            specifier.setProperty(value, forKey: key)
        }
        // The detail controller reads the app from this key, spelled with the
        // "Key" suffix in the plists.
        if let appID {
            specifier.setProperty(appID, forKey: "customAppIDKey")
        }
        return specifier
    }

    private static func textField(
        _ title: String,
        service: String,
        appID: String?,
        key: String,
        noAutoCorrect: Bool = false
    ) -> PSSpecifier {
        let specifier = PSSpecifier.preferenceSpecifierNamed(
            title.localized, target: PreferencesStorage.self,
            set: #selector(PreferencesStorage.setValue(_:forInstanceSpecifier:)),
            get: #selector(PreferencesStorage.readValue(forInstanceSpecifier:)),
            detail: nil, cell: .editTextCell, edit: nil
        )!
        configure(specifier, service: service, appID: appID, key: key)
        specifier.setProperty(true, forKey: "enabled")
        if noAutoCorrect {
            specifier.setProperty(true, forKey: "noAutoCorrect")
        }
        return specifier
    }

    private static func decimalField(
        _ title: String,
        service: String,
        key: String,
        defaultValue: CGFloat
    ) -> PSSpecifier {
        let specifier = PSSpecifier.preferenceSpecifierNamed(
            title.localized, target: PreferencesStorage.self,
            set: #selector(PreferencesStorage.setValue(_:forInstanceSpecifier:)),
            get: #selector(PreferencesStorage.readValue(forInstanceSpecifier:)),
            detail: nil, cell: .editTextCell, edit: nil
        )!
        configure(specifier, service: service, appID: nil, key: key)
        specifier.setProperty(true, forKey: "enabled")
        specifier.setProperty(true, forKey: "isDecimalPad")
        specifier.setProperty(defaultValue, forKey: SpecifierRouting.PropertyKey.defaultValue)
        return specifier
    }

    private static func toggle(
        _ title: String,
        service: String,
        appID: String?,
        key: String,
        defaultValue: Bool
    ) -> PSSpecifier {
        let specifier = PSSpecifier.preferenceSpecifierNamed(
            title.localized, target: PreferencesStorage.self,
            set: #selector(PreferencesStorage.setValue(_:forInstanceSpecifier:)),
            get: #selector(PreferencesStorage.readValue(forInstanceSpecifier:)),
            detail: nil, cell: .switchCell, edit: nil
        )!
        configure(specifier, service: service, appID: appID, key: key)
        specifier.setProperty(true, forKey: "enabled")
        specifier.setProperty(defaultValue, forKey: SpecifierRouting.PropertyKey.defaultValue)
        return specifier
    }

    /// Stamps the routing properties shared by every generated cell.
    private static func configure(
        _ specifier: PSSpecifier,
        service: String,
        appID: String?,
        key: String
    ) {
        specifier.setProperty(service, forKey: SpecifierRouting.PropertyKey.serviceType)
        specifier.setProperty(appID != nil, forKey: SpecifierRouting.PropertyKey.isCustomApp)
        specifier.setProperty(key, forKey: SpecifierRouting.PropertyKey.key)
        // Per-app cells look the key up through this property as well; both are
        // kept in sync so either spelling finds the value.
        specifier.setProperty(key, forKey: SpecifierRouting.PropertyKey.customAppsPrefsKey)
        if let appID {
            specifier.setProperty(appID, forKey: SpecifierRouting.PropertyKey.customAppID)
        }
    }
}
