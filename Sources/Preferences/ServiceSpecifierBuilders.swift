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
    /// Builds a service's own cells. The service's name and defaults are passed
    /// in as well, so a builder that wants the shared payload options can ask
    /// the service what it can carry without re-deriving any of it.
    public typealias Builder = (
        _ service: String, _ appID: String?, _ defaults: ServiceConfig?
    ) -> [PSSpecifier]

    @objc(sharedInstance)
    public static let shared = ServiceSpecifierBuilders()

    private var builders: [String: Builder] = [:]

    private override init() {
        super.init()
        registerAll()
    }

    /// Not `@objc`: the builder takes a `ServiceConfig` so a service can be
    /// asked about itself, and that type has no Objective-C representation.
    /// Nothing outside Swift calls this.
    public func register(builder: @escaping Builder, forService service: String) {
        builders[service] = builder
    }

    /// The builder key for the payload options a service shares.
    ///
    /// A definition page has no service of its own to ask, so it names this
    /// builder directly; the script type's capabilities stand in for the
    /// definition's, since a definition is a script.
    static let payloadOptionsKey = "\u{1}payloadOptions"

    /// Registers every service that has extra cells.
    ///
    /// The webhook is registered too: it has no specifier plist of its own
    /// beyond the endpoint fields, so its icon/image options live here with the
    /// other services'. A service without an entry (Feishu, for example)
    /// contributes nothing.
    private func registerAll() {
        register(builder: Self.payloadOptions, forService: Self.payloadOptionsKey)
        register(builder: Self.webhook, forService: CustomService.serviceName)
        register(builder: Self.pushover, forService: PushoverService.serviceName)
        register(builder: Self.pushbullet, forService: PushbulletService.serviceName)
        register(builder: Self.ifttt, forService: IFTTTService.serviceName)
        register(builder: Self.wechat, forService: WechatService.serviceName)
        register(builder: Self.bark, forService: BarkService.serviceName)
        register(builder: Self.pusherReceiver, forService: PusherReceiverService.serviceName)
        // Services with no cells of their own still get the payload options when
        // they can carry an icon or an image.
        for name in [FeishuService.serviceName, WechatService.serviceName] {
            if builders[name] == nil {
                register(builder: { service, appID, defaults in
                    Self.payloadOptions(service: service, appID: appID, defaults: defaults)
                }, forService: name)
            }
        }
    }

    /// The cells to append to `service`'s page, ready to use.
    ///
    /// The routing is done here rather than by each caller: a builder's cells are
    /// generated, not loaded from a plist, so nothing else would give them the
    /// instance they edit or the setter/getter pair that stores their value. A
    /// caller that forgot would get cells that silently discard every change.
    ///
    /// - Parameters:
    ///   - service: the descriptor name, which selects the builder.
    ///   - instanceID: the instance the page edits.
    ///   - appID: non-nil on a per-app override page.
    func builders(for service: String, instanceID: String, appID: String?) -> [PSSpecifier] {
        // The service's declared defaults, which is where the payload options'
        // switch positions come from.
        let defaults = ServiceConfig(
            name: instanceID, type: service,
            raw: Prefs(ServiceRegistry.service(named: service).defaultPrefs())
        )
        guard let built = builders[service]?(service, appID, defaults) else { return [] }

        for specifier in built {
            specifier.setProperty(instanceID, forKey: SpecifierRouting.PropertyKey.instanceID)
            specifier.setProperty(service, forKey: SpecifierRouting.PropertyKey.serviceType)
            // A detail picker reads the app from its own key, spelled
            // differently from the value cells'.
            if specifier.cellType == .linkCell, let appID {
                specifier.setProperty(appID, forKey: "customAppIDKey")
            }
        }

        SpecifierRouting.route(
            built, to: PreferencesStorage.self,
            scope: appID.map { .customApp(id: instanceID, appID: $0) } ?? .instance(id: instanceID)
        )
        return built
    }

    // MARK: - Payload options

    /// The icon/image options, for the services that have them.
    ///
    /// The sizing fields appear only when the service can carry an image: a
    /// maximum width means nothing to a destination with no image field, and the
    /// switch above it would already be absent, so they would be three numbers
    /// with nothing to size.
    private static func payloadOptions(
        service: String, appID: String?, defaults: ServiceConfig?
    ) -> [PSSpecifier] {
        // The definition page names the pseudo-service, so the capabilities come
        // from the script type it stands for.
        let descriptor = ServiceRegistry.service(
            named: service == Self.payloadOptionsKey ? JavaScriptService.serviceName : service
        )
        var specifiers: [PSSpecifier] = []

        // The default is the service's own, read from its declared defaults so
        // there is one source of truth: publishing an icon and publishing the
        // attachment are separate decisions per service (Bark publishes both by
        // default, a webhook publishes the image but not the icon).
        let iconDefault = defaults?.raw.bool(PrefKey.includeIcon) ?? true
        let imageDefault = defaults?.raw.bool(PrefKey.includeImage) ?? true

        if descriptor.supportsIcon {
            specifiers.append(toggle("Include Icon", service: service, appID: appID,
                                     key: PrefKey.includeIcon, defaultValue: iconDefault))
        }
        if descriptor.supportsImage {
            specifiers.append(toggle("Include Image", service: service, appID: appID,
                                     key: PrefKey.includeImage, defaultValue: imageDefault))
        }

        if appID == nil, descriptor.supportsImage {
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

    // MARK: - Custom webhook

    /// The icon/image options for a user-defined service.
    ///
    /// A webhook's *endpoint* is described by `Custom.plist`; what belongs here
    /// is the payload options, which are the same shape as every other
    /// service's. The image sizing is service-wide (a per-app override inherits
    /// it), and the decoded image is what makes the payload large enough for
    /// those numbers to matter.
    private static func webhook(service: String, appID: String?, defaults: ServiceConfig?) -> [PSSpecifier] {
        // The endpoint fields come from Custom.plist; the payload options come
        // from the shared builder, which is what the webhook type registers.
        payloadOptions(service: service, appID: appID, defaults: defaults)
    }

    // MARK: - Pushover

    /// Receiving-device and notification-sound pickers.
    private static func pushover(service: String, appID: String?, defaults: ServiceConfig?) -> [PSSpecifier] {
        let isCustomApp = appID != nil
        let devices = detailLink(
            "Receiving Devices", detail: DeviceListController.self,
            service: service, appID: appID,
            properties: ["isSound": false]
        )
        let sounds = detailLink(
            "Notification Sound", detail: SoundListController.self,
            service: service, appID: appID,
            properties: ["isSound": true]
        )
        _ = isCustomApp
        // Pushover's payload is fixed (token, user, message, title, priority,
        // sound); it carries no image, so there are no payload options.
        return [devices, sounds]
    }

    // MARK: - Pushbullet

    /// Pushbullet targets one device, so it gets the device picker only.
    private static func pushbullet(service: String, appID: String?, defaults: ServiceConfig?) -> [PSSpecifier] {
        // The device picker only: Pushbullet's note carries a title and a body.
        [
            detailLink(
                "Receiving Devices", detail: DeviceListController.self,
                service: service, appID: appID,
                properties: ["isSound": false]
            )
        ]
    }

    // MARK: - IFTTT

    /// The event name, plus the "include icon" and "curate request data"
    /// toggles.
    private static func ifttt(service: String, appID: String?, defaults: ServiceConfig?) -> [PSSpecifier] {
        // The event name; the icon switch and the image size fields come from
        // the shared payload options, which ask the service what it can carry
        // (IFTTT has no image field).
        return [
            textField("Event Name", service: service, appID: appID,
                      key: PrefKey.eventName, noAutoCorrect: true),
            toggle("Curate Request Data", service: service, appID: appID,
                   key: PrefKey.curateData, defaultValue: true),
        ] + payloadOptions(service: service, appID: appID, defaults: defaults)
    }

    // MARK: - Wechat

    /// The recipient, plus the Corporate ID / secret / agent ID credentials.
    private static func wechat(service: String, appID: String?, defaults: ServiceConfig?) -> [PSSpecifier] {
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
    private static func bark(service: String, appID: String?, defaults: ServiceConfig?) -> [PSSpecifier] {
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
        } + payloadOptions(service: service, appID: appID, defaults: defaults)
    }

    // MARK: - Pusher Receiver

    /// The database name, plus the icon/image options.
    private static func pusherReceiver(service: String, appID: String?, defaults: ServiceConfig?) -> [PSSpecifier] {
        // The database name; the icon/image options come from the shared payload
        // options, which read the service's declared defaults.
        [textField("Database Name", service: service,
                   appID: appID, key: PrefKey.dbName, noAutoCorrect: true)]
            + payloadOptions(service: service, appID: appID, defaults: defaults)
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
