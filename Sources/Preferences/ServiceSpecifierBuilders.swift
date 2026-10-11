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
        _ service: String,
        _ appID: String?,
        _ defaults: ServiceConfig?,
        _ pageObserver: AnyObject?
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
        register(builder: Self.shortcut, forService: ShortcutService.serviceName)
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
    /// The cells a service type contributes to one instance's page.
    ///
    /// - Parameter pageObserver: the controller to tell when a switch changes
    ///   what the page shows. Passed down rather than read from a global so a
    ///   page can never be told about a change it does not own.
    func builders(
        for service: String,
        instanceID: String,
        appID: String?,
        pageObserver: AnyObject? = nil
    ) -> [PSSpecifier] {
        // The service's declared defaults, which is where the payload options'
        // switch positions come from.
        let defaults = ServiceConfig(
            name: instanceID, type: service,
            raw: Prefs(ServiceRegistry.service(named: service).defaultPrefs())
        )
        guard let built = builders[service]?(service, appID, defaults, pageObserver)
        else { return [] }
        return route(built, service: service, instanceID: instanceID, appID: appID)
    }

    /// The payload options for a service *definition*.
    ///
    /// A definition's options are stored on the definition, not on an instance —
    /// they are what a new instance of the type inherits — so the cells are
    /// routed to the definitions array. Routed as an instance they would read
    /// and write an instance that does not exist, which is what makes the
    /// switches look live while the values shown (the type's defaults) never
    /// change.
    func payloadOptions(
        forDefinition definitionID: String,
        pageObserver: AnyObject? = nil
    ) -> [PSSpecifier] {
        let defaults = ServiceConfig(
            name: definitionID, type: definitionID,
            raw: Prefs(ServiceRegistry.service(named: definitionID).newInstancePrefs())
        )
        // Both switches are always offered *here*, using the script type's
        // capabilities rather than the definition's own declared ones. These two
        // cells are the declaration: gating them on the value they store would
        // make turning an option off hide the switch that turns it back on.
        // The instance page is where a declaration is honored, and that is what
        // `payloadOptions(forType:)` does.
        let built = Self.payloadOptions(
            service: JavaScriptService.serviceName,
            appID: nil, defaults: defaults,
            // The cells edit the definition, but the descriptor name they are
            // stamped with must be the definition's so the storage router and
            // the title lookups resolve it.
            routingName: definitionID,
            // The definition is what the sizing rows are read from: its own
            // object is the store, since a new instance inherits from it.
            storedImage: CustomServiceStore.rawEntry(id: definitionID),
            pageObserver: pageObserver
        )
        for specifier in built {
            specifier.setProperty(definitionID,
                                  forKey: SpecifierRouting.PropertyKey.instanceID)
            specifier.setProperty(definitionID,
                                  forKey: SpecifierRouting.PropertyKey.serviceType)
            // Which array the storage router writes to. Without it the write
            // goes to an instance lookup by this id, finds nothing, and returns
            // without saving — a switch that never moves.
            specifier.setProperty(true, forKey: SpecifierRouting.PropertyKey.isDefinition)
            SpecifierRouting.route(specifier, to: PreferencesStorage.self, scope: .instance(id: definitionID))
        }
        return built
    }

    /// The payload options for an instance whose type the caller names.
    ///
    /// Used by a script instance, and distinct from naming the pseudo-service:
    /// the switches offered must be the ones *that definition* declared, and a
    /// definition is a type of its own — the script type's own capabilities
    /// would offer an icon option to a script that has none.
    func payloadOptions(
        forType type: String, instanceID: String, appID: String?,
        pageObserver: AnyObject? = nil
    ) -> [PSSpecifier] {
        let descriptor = ServiceRegistry.service(named: type)
        let defaults = ServiceConfig(
            name: instanceID, type: type,
            raw: Prefs(descriptor.newInstancePrefs())
        )
        // `descriptor` here is the *definition's* descriptor, so its
        // capabilities are the ones the definition declared: a script written
        // without an icon offers its instances no icon option.
        let built = Self.payloadOptions(
            service: type, appID: appID, defaults: defaults, pageObserver: pageObserver
        )
        return route(built, service: type, instanceID: instanceID, appID: appID)
    }

    /// Gives generated cells the instance they edit and the routing that stores
    /// their value.
    private func route(
        _ built: [PSSpecifier], service: String, instanceID: String, appID: String?
    ) -> [PSSpecifier] {
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

    // MARK: - The service's own icon

    /// Whether a service's image is switched on, read from the same place the
    /// switch reads: the per-app override, then the instance, then the type's own
    /// default. A row that only makes sense with the image on is shown from this,
    /// so it must not answer differently from the switch beside it.
    static func includeImage(stored: Prefs, fallback: Prefs?) -> Bool {
        for source in [stored, fallback ?? Prefs()] {
            if let value = source[PrefKey.includeImage] {
                return Prefs([PrefKey.includeImage: value]).bool(PrefKey.includeImage)
            }
        }
        return true
    }

    /// The cell that opens the icon picker.
    ///
    /// Offered by every service whose payload carries an icon, and never when it
    /// does not: the same rule the payload switches follow, because a user's own
    /// icon is one of those fields.
    ///
    /// The row shows the current choice as its icon, so the list reads the same
    /// way the notification will.
    /// The logo row, for a service *instance*.
    ///
    /// Built by the page rather than by `payloadOptions`, because a logo
    /// identifies the service: it belongs beside the name it labels, not among
    /// the payload options. The row shows the current logo as its icon, so the
    /// page reads the way the list row does.
    static func iconRow(
        service: String, instanceID: String, appID: String? = nil
    ) -> PSSpecifier? {
        let descriptor = ServiceRegistry.service(named: service)
        guard descriptor.supportsIcon else { return nil }

        guard let specifier = PSSpecifier.preferenceSpecifierNamed(
            "Icon".localized, target: nil, set: nil, get: nil,
            detail: ServiceIconController.self, cell: .linkCell, edit: nil
        ) else { return nil }
        specifier.setProperty(service, forKey: SpecifierRouting.PropertyKey.serviceType)
        specifier.setProperty(instanceID, forKey: SpecifierRouting.PropertyKey.instanceID)
        specifier.setProperty(appID != nil, forKey: SpecifierRouting.PropertyKey.isCustomApp)
        // Marks the row for the pages that intercept the tap: the picker needs to
        // know *which* store to write to, and a detail controller is built
        // through `init(nibName:bundle:)` with nowhere to pass one.
        specifier.setProperty(true, forKey: SpecifierRouting.PropertyKey.isIconRow)
        if let appID {
            specifier.setProperty(appID, forKey: "customAppIDKey")
        }
        if let logo = appID == nil
            ? ServiceIcon.logo(forInstanceID: instanceID)
            : ServiceIcon.image(from: PrefsStore.customAppPrefs(service: instanceID, appID: appID!)) {
            specifier.setProperty(logo, forKey: "iconImage")
        }
        return specifier
    }

    /// The logo row, for a service *definition*.
    ///
    /// A definition is not an instance: its logo is stored on the definitions
    /// array, which the storage router reaches through `isDefinition`.
    static func definitionIconRow(definitionID: String) -> PSSpecifier? {
        guard let specifier = PSSpecifier.preferenceSpecifierNamed(
            "Icon".localized, target: nil, set: nil, get: nil,
            detail: ServiceIconController.self, cell: .linkCell, edit: nil
        ) else { return nil }
        specifier.setProperty(definitionID, forKey: SpecifierRouting.PropertyKey.instanceID)
        specifier.setProperty(definitionID, forKey: SpecifierRouting.PropertyKey.serviceType)
        specifier.setProperty(true, forKey: SpecifierRouting.PropertyKey.isIconRow)
        specifier.setProperty(true, forKey: SpecifierRouting.PropertyKey.isDefinition)
        if let logo = ServiceIcon.logo(forDefinitionID: definitionID) {
            specifier.setProperty(logo, forKey: "iconImage")
        }
        return specifier
    }

    // MARK: - Payload options

    /// The icon/image options, for the services that have them.
    ///
    /// The sizing fields appear only when the service can carry an image: a
    /// maximum width means nothing to a destination with no image field, and the
    /// switch above it would already be absent, so they would be three numbers
    /// with nothing to size.
    private static func payloadOptions(
        service: String,
        appID: String?,
        defaults: ServiceConfig?,
        routingName: String? = nil,
        storedImage: Prefs? = nil,
        pageObserver: AnyObject? = nil
    ) -> [PSSpecifier] {
        let name = routingName ?? service
        let descriptor = ServiceRegistry.service(
            named: routingName == nil ? service : JavaScriptService.serviceName
        )
        var specifiers: [PSSpecifier] = []

        // The default is the service's own, read from its declared defaults so
        // there is one source of truth: publishing an icon and publishing the
        // attachment are separate decisions per service (Bark publishes both by
        // default, a webhook publishes the image but not the icon).
        let iconDefault = defaults?.raw.bool(PrefKey.includeIcon) ?? true
        let imageDefault = defaults?.raw.bool(PrefKey.includeImage) ?? true

        // The icon row is deliberately *not* built here: a logo identifies the
        // service, so it belongs beside its name rather than among the payload
        // options. The pages place it there (see the identity group each builds).
        if descriptor.supportsIcon {
            specifiers.append(toggle("Include Icon", service: name, appID: appID,
                                     key: PrefKey.includeIcon, defaultValue: iconDefault))
        }
        if descriptor.supportsImage {
            // The sizing rows below belong to this switch: they are how the
            // picture it includes is scaled, so with the image off they describe
            // nothing and are not shown. The switch tells the page directly when
            // it changes, which is what rebuilds the rows in the same visit.
            specifiers.append(toggle("Include Image", service: name, appID: appID,
                                     key: PrefKey.includeImage, defaultValue: imageDefault,
                                     changeObserver: pageObserver))
        }

        // The sizing rows follow the switch beside them: they are how the picture
        // is scaled, so with the image off they describe nothing. Read from the
        // stored values the switch itself writes, so the two cannot disagree.
        // On a definition page `storedImage` is the definition's own object and
        // there is no second store to fall back to: the definition *is* where
        // the value lives.
        let imageState = storedImage ?? appID.map {
            PrefsStore.customAppPrefs(service: defaults?.name ?? "", appID: $0)
        } ?? (defaults.map { PrefsStore.instance($0.name) } ?? Prefs())
        let imageFallback = storedImage != nil ? nil : defaults?.raw
        if descriptor.supportsImage,
           includeImage(stored: imageState, fallback: imageFallback) {
            specifiers.append(contentsOf: [
                decimalField("Maximum Image Width (pixels)", service: name,
                             key: PrefKey.imageMaxWidth, defaultValue: Pusher.defaultMaxWidth),
                decimalField("Maximum Image Height (pixels)", service: name,
                             key: PrefKey.imageMaxHeight, defaultValue: Pusher.defaultMaxHeight),
                decimalField("Image Shrink Factor Upon Retry", service: name,
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
    private static func webhook(service: String, appID: String?, defaults: ServiceConfig?, pageObserver: AnyObject?) -> [PSSpecifier] {
        // The endpoint fields come from Custom.plist; the payload options come
        // from the shared builder, which is what the webhook type registers.
        payloadOptions(service: service, appID: appID, defaults: defaults, pageObserver: pageObserver)
    }

    // MARK: - Pushover

    /// Receiving-device and notification-sound pickers.
    private static func pushover(service: String, appID: String?, defaults: ServiceConfig?, pageObserver: AnyObject?) -> [PSSpecifier] {
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
    private static func pushbullet(service: String, appID: String?, defaults: ServiceConfig?, pageObserver: AnyObject?) -> [PSSpecifier] {
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
    private static func ifttt(service: String, appID: String?, defaults: ServiceConfig?, pageObserver: AnyObject?) -> [PSSpecifier] {
        // The event name; the icon switch and the image size fields come from
        // the shared payload options, which ask the service what it can carry
        // (IFTTT has no image field).
        return [
            textField("Event Name", service: service, appID: appID,
                      key: PrefKey.eventName, noAutoCorrect: true),
            toggle("Curate Request Data", service: service, appID: appID,
                   key: PrefKey.curateData, defaultValue: true),
        ] + payloadOptions(service: service, appID: appID, defaults: defaults, pageObserver: pageObserver)
    }

    // MARK: - Wechat

    /// The recipient, plus the Corporate ID / secret / agent ID credentials.
    private static func wechat(service: String, appID: String?, defaults: ServiceConfig?, pageObserver: AnyObject?) -> [PSSpecifier] {
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


    // MARK: - Shortcut

    /// The one setting this service has: which Shortcut to run.
    ///
    /// A link cell rather than a text field, even though the value is a string.
    /// A typed name has to match exactly, and a mismatch only shows up at push
    /// time, in the background, as a line in the log — so the name is chosen from
    /// what is actually installed.
    private static func shortcut(
        service: String, appID: String?, defaults: ServiceConfig?, pageObserver: AnyObject?
    ) -> [PSSpecifier] {
        // The prompt is the group's header and the row shows the choice, rather
        // than the row being labelled "Choose Shortcut" — a row named after the
        // action says what it does but not what it is set to, so finding the
        // current value would mean opening the picker to look for the tick.
        let heading = PSSpecifier.preferenceSpecifierNamed(
            "Shortcut".localized, target: nil, set: nil, get: nil,
            detail: nil, cell: .groupCell, edit: nil
        )!

        // `get:` reads the shortcut the instance holds, so the cell's own text is
        // rebuilt from the value by the framework — the same way its value is.
        // Naming the row after the choice and re-naming it on each appearance
        // looked equivalent and was not: the framework substitutes its own array
        // when the app returns from the background, and the substituted cell
        // carries the name from the specifier it was derived from, so the row
        // reverted to whatever that said.
        let specifier = PSSpecifier.preferenceSpecifierNamed(
            "Choose Shortcut".localized, target: Interaction.self,
            set: #selector(Interaction.writeShortcutName(_:specifier:)),
            get: #selector(Interaction.readShortcutName(_:)),
            detail: NSClassFromString("NSPShortcutPickerController"), cell: .linkCell, edit: nil
        )!
        configure(specifier, service: service, appID: appID,
                  key: ShortcutPrefKey.shortcutName)
        return [heading, specifier]
    }

    // MARK: - Bark

    /// Bark's optional push parameters, all free-form strings.
    ///
    /// The server URL is a service-wide setting, so a per-app override page
    /// shows only the message parameters.
    private static func bark(service: String, appID: String?, defaults: ServiceConfig?, pageObserver: AnyObject?) -> [PSSpecifier] {
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
        } + payloadOptions(service: service, appID: appID, defaults: defaults, pageObserver: pageObserver)
    }

    // MARK: - Pusher Receiver

    /// The database name, plus the icon/image options.
    private static func pusherReceiver(service: String, appID: String?, defaults: ServiceConfig?, pageObserver: AnyObject?) -> [PSSpecifier] {
        // The database name; the icon/image options come from the shared payload
        // options, which read the service's declared defaults.
        [textField("Database Name", service: service,
                   appID: appID, key: PrefKey.dbName, noAutoCorrect: true)]
            + payloadOptions(service: service, appID: appID, defaults: defaults, pageObserver: pageObserver)
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
        defaultValue: Bool,
        changeObserver: AnyObject? = nil
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
        if let changeObserver {
            // Non-retaining: the controller owns its cells, so a cell must not
            // own the controller back.
            specifier.setProperty(
                NSValue(nonretainedObject: changeObserver),
                forKey: SpecifierRouting.PropertyKey.changeObserver
            )
        }
        return specifier
    }

    /// Stamps the routing properties shared by every generated cell.
    private static func configure(
        _ specifier: PSSpecifier,
        service: String,
        appID: String?,
        key: String
    ) {
        // The cell's identity, which is what `specifier(forID:)` finds it by.
        // A page reads its own cells back through this — to see what a switch is
        // set to, to reload one row, to strip a count from a title — so a cell
        // built without it is invisible to the page that built it.
        specifier.identifier = key
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

// MARK: - Rows whose text is their value

/// Reads and writes the Shortcut choice for the row that opens the picker.
///
/// Separate from `PreferencesStorage` because that stores *values*, and this row
/// has none: its text is the choice. Routing it through a getter is what makes
/// the framework rebuild the text on its own passes — and it rebuilds, on
/// returning from the background, from an array it substituted itself, whose
/// cells are named from their specifiers. A row renamed after the fact reverts at
/// that point; a row whose name comes from its getter does not.
@objc final class Interaction: NSObject {

    /// The shortcut name to show on the row.
    @objc static func readShortcutName(_ specifier: PSSpecifier) -> NSString {
        let chosen: String? = storedName(on: specifier)
        if let chosen, !chosen.isEmpty { return chosen as NSString }
        return "Choose Shortcut".localized as NSString
    }

    /// Writes a shortcut name onto the instance the row belongs to.
    @objc static func writeShortcutName(_ value: Any?, specifier: PSSpecifier) {
        PreferencesStorage.setValue(value, forInstanceSpecifier: specifier)
    }

    /// Reads the shortcut name from the instance the row belongs to.
    private static func storedName(on specifier: PSSpecifier) -> String? {
        if let direct = PreferencesStorage.readValue(forInstanceSpecifier: specifier) as? String {
            return direct
        }
        guard let id = specifier.string(SpecifierRouting.PropertyKey.instanceID) else { return nil }
        return PrefsStore.instance(id)[ShortcutPrefKey.shortcutName] as? String
    }
}
