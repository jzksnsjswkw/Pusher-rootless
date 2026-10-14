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

        let specifier = PSSpecifier.preferenceSpecifierNamed(
            "Choose Shortcut".localized, target: PreferencesStorage.self,
            set: #selector(PreferencesStorage.setValue(_:forInstanceSpecifier:)),
            get: #selector(PreferencesStorage.readValue(forInstanceSpecifier:)),
            detail: NSClassFromString("NSPShortcutPickerController"), cell: .linkCell, edit: nil
        )!
        configure(specifier, service: service, appID: appID,
                  key: ShortcutPrefKey.shortcutName)
        // The row's title is the choice, and it is set *here* rather than by a
        // getter. A link cell's title comes from `specifier.name`, which the cell
        // reads when it is built — the getter supplies the cell's *value*, which a
        // link cell does not display. Since this builder runs on every rebuild,
        // naming it here covers the background round trip as well.
        // `defaults` carries the instance id as its `name` — it is built with
        // one on the way in, before the cells exist to be routed.
        if let instanceID = defaults?.name,
           let chosen = chosenShortcut(instanceID: instanceID) {
            specifier.name = chosen
        }
        // The picker reloads this row when it stores a choice, through the
        // non-retaining reference stashed here — the same mechanism the app-list
        // link uses. Without it the row keeps the name it was built with until
        // something else rebuilds the page, which is why the choice only appeared
        // after a background round trip.
        if let observer = pageObserver as? PSListController {
            specifier.setProperty(
                NSValue(nonretainedObject: observer),
                forKey: SpecifierRouting.PropertyKey.listReference
            )
        }
        return [heading, specifier]
    }

    /// The Shortcut an instance has chosen, or `nil` when it has none.
    private static func chosenShortcut(instanceID: String) -> String? {
        let instance = ServiceInstanceStore.instance(id: instanceID)
        let stored = (instance?.config ?? Prefs())[ShortcutPrefKey.shortcutName] as? String
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }

    // MARK: - Bark

    /// Bark's optional push parameters, all free-form strings.
    ///
    /// The server URL is a service-wide setting, so a per-app override page
    /// shows only the message parameters.
    /// What each optional parameter does, shown under the last of them.
    ///
    /// The string is the localization key, so it has to match the table entry
    /// exactly, line breaks included — which is why it is assembled line by line
    /// rather than written as one long literal a stray space could break.
    private static let barkFieldNotes: String = (
        "Optional Bark push parameters. Leave empty to not send that parameter."
        + "\n"
        + "Markdown: body as Markdown, ignores the notification's own formatting"
        + "\n"
        + "Group: group name to group notifications"
        + "\n"
        + "Icon: HTTPS icon URL, replaces the Bark icon (iOS 15+)"
        + "\n"
        + "Image: HTTPS image URL, shown as a large picture"
        + "\n"
        + "Badge: badge number, 0 clears it"
        + "\n"
        + "Level: critical / active / timeSensitive / passive (default active)"
        + "\n"
        + "Volume: 0-10, only for critical alerts (default 5)"
        + "\n"
        + "Call: 1 to repeat the ringtone for 30 seconds"
        + "\n"
        + "Sound: ringtone name"
        + "\n"
        + "Copy: the text to copy when the notification is copied"
        + "\n"
        + "AutoCopy: 1 to copy automatically on arrival"
        + "\n"
        + "URL: URL to open when the push is tapped"
        + "\n"
        + "Action: alert shows an action popup, none makes tapping do nothing"
        + "\n"
        + "IsArchive: 1 to save the push to history"
        + "\n"
        + "TTL: retention time in seconds for archived pushes"
        + "\n"
        + "ID: update the push with the same ID"
        + "\n"
        + "Delete: 1 to delete the push with the given ID (requires ID)"
    ).localized

    private static func bark(service: String, appID: String?, defaults: ServiceConfig?, pageObserver: AnyObject?) -> [PSSpecifier] {
        // Every parameter the push API takes, in the documentation's own order
        // and grouping. A field left empty is not sent, which is what makes
        // "unset" the same as "leave it to the app".
        let fields: [(title: String, key: String)] = [
            ("Markdown:", BarkPrefKey.markdown),
            ("Group:", BarkPrefKey.group),
            ("Icon:", BarkPrefKey.icon),
            ("Image:", BarkPrefKey.image),
            ("Badge:", BarkPrefKey.badge),
            ("Level:", BarkPrefKey.level),
            ("Volume:", BarkPrefKey.volume),
            ("Call:", BarkPrefKey.call),
            ("Sound:", BarkPrefKey.sound),
            ("Copy:", BarkPrefKey.copy),
            ("AutoCopy:", BarkPrefKey.autoCopy),
            ("URL:", BarkPrefKey.clickURL),
            ("Action:", BarkPrefKey.action),
            ("IsArchive:", BarkPrefKey.isArchive),
            ("TTL:", BarkPrefKey.ttl),
            ("ID:", BarkPrefKey.id),
            ("Delete:", BarkPrefKey.delete),
        ]
        // The server URL is a cell of the plist's Credentials group, beside the key
        // — not a group of its own in code. Its own group, heading-less, put a
        // second section between the parameters and the heading that names them,
        // which read as a large unexplained gap; and the note about the default
        // belongs under the key it sits with.
        var specifiers: [PSSpecifier] = []
        specifiers.append(contentsOf: cipherSpecifiers(
            service: service, appID: appID, defaults: defaults, pageObserver: pageObserver
        ))

        // The heading the parameters sit under, and the paragraph explaining them:
        // one group, so the note is drawn after the fields it describes. A footer
        // belongs to its group and is drawn at the end of it, so putting the note
        // on a heading of its own — with the fields in a *later*, heading-less
        // group — printed it above them, between the heading and the first field.
        let head = PSSpecifier.groupSpecifier(withName: "Optional Parameters".localized)!
        head.setProperty(Self.barkFieldNotes, forKey: "footerText")
        specifiers.append(head)

        return specifiers + fields.map {
            textField($0.title, service: service, appID: appID,
                      key: $0.key, noAutoCorrect: true)
        } + payloadOptions(service: service, appID: appID, defaults: defaults, pageObserver: pageObserver)
    }

    /// The Bark encryption settings, shown only when the switch is on.
    ///
    /// Off, the page is the parameter list and nothing else, which is the state
    /// most instances are in. On, the three fields that decide how the request is
    /// encrypted appear. There is no IV field and no mode-dependent row: the app
    /// has no setting for an IV either — it reads the one the request carries —
    /// so a row here would be asking for something the phone cannot be told to
    /// expect.
    ///
    /// The switch stores a flag rather than being inferred from whether a key is
    /// present: the two would disagree the moment someone turned encryption off
    /// without clearing the key, and the page would show it still on.
    private static func cipherSpecifiers(
        service: String, appID: String?, defaults: ServiceConfig?, pageObserver: AnyObject?
    ) -> [PSSpecifier] {
        // Which rows to build reads the *instance's* settings, not the type's
        // defaults: the switch belongs to this destination, and two Bark
        // instances may encrypt differently. `defaults.name` carries the instance
        // id — the builder is handed it on the way in.
        let instanceID = defaults?.name ?? ""
        let stored: Prefs
        if let appID {
            // A per-app page shows what that app inherits: its own override if it
            // has one, the instance's value otherwise. Same fallback the storage
            // layer applies when it reads a cell.
            let override = PrefsStore.customAppPrefs(service: instanceID, appID: appID)
            stored = override.raw[BarkPrefKey.cipherEnabled] != nil
                ? override
                : PrefsStore.instance(instanceID)
        } else {
            stored = PrefsStore.instance(instanceID)
        }

        // Off, the switch alone: an instance that does not encrypt should not read
        // as a form it left blank.
        guard cipherEnabled(stored: stored, fallback: defaults?.raw) else {
            return [cipherHead(), toggle("Enable", service: service, appID: appID,
                                         key: BarkPrefKey.cipherEnabled, defaultValue: false,
                                         changeObserver: pageObserver)]
        }

        let specifiers: [PSSpecifier] = [
            toggle("Enable", service: service, appID: appID,
                   key: BarkPrefKey.cipherEnabled, defaultValue: false,
                   changeObserver: pageObserver),
            segment("Algorithm", service: service, appID: appID,
                    key: BarkPrefKey.cipherAlgorithm,
                    values: BarkCipher.Algorithm.allCases.map(\.rawValue),
                    titles: BarkCipher.Algorithm.allCases.map(\.rawValue),
                    defaultValue: BarkCipher.Algorithm.aes128.rawValue,
                    changeObserver: pageObserver),
            segment("Mode", service: service, appID: appID,
                    key: BarkPrefKey.cipherMode,
                    values: BarkCipher.Mode.allCases.map(\.rawValue),
                    titles: BarkCipher.Mode.allCases.map(\.rawValue),
                    defaultValue: BarkCipher.Mode.cbc.rawValue,
                    changeObserver: pageObserver),
            textField("Key", service: service, appID: appID,
                      key: BarkPrefKey.cipherKey, noAutoCorrect: true,
                      changeObserver: pageObserver),
        ]
        return [cipherHead()] + specifiers
    }

    /// The encryption group, with its explanation.
    ///
    /// The identifier is what lets the page find this cell again to recolour its
    /// footer when the key or the algorithm changes; without it the footer would
    /// say the key is wrong in the ordinary colour.
    static let cipherHeadIdentifier = "barkCipherHead"

    private static func cipherHead() -> PSSpecifier {
        let head = PSSpecifier.groupSpecifier(withName: "Encryption".localized)!
        head.identifier = cipherHeadIdentifier
        head.setProperty(Self.barkCipherNotes, forKey: "footerText")
        return head
    }

    /// What is wrong with the encryption settings, or `nil` when they are usable.
    ///
    /// The app requires the key to be *exactly* the algorithm's length — not a
    /// minimum — so a key that is too long is as unusable as one that is too
    /// short, and the app says so in those words ("请输入 16 位密钥"). Reporting
    /// only the long case would leave the other half of the same mistake silent.
    static func cipherProblem(stored: Prefs, key liveKey: String? = nil) -> String? {
        guard stored.bool(BarkPrefKey.cipherEnabled, default: false) else { return nil }
        // The live text when the caller has it — mid-typing, the stored value is
        // whatever was last committed, not what is on screen.
        let key = liveKey ?? stored.string(BarkPrefKey.cipherKey) ?? ""
        guard !key.isEmpty else { return nil }   // nothing typed yet is not an error

        guard let algorithm = BarkCipher.Algorithm(
            rawValue: stored.string(BarkPrefKey.cipherAlgorithm) ?? ""
        ) else { return nil }

        guard key.count == algorithm.keyLength else {
            return String(
                format: "The key must be exactly %d characters for %@ (currently %d)."
                    .localized,
                algorithm.keyLength, algorithm.rawValue, key.count
            )
        }
        return nil
    }

    /// What the encryption settings mean, and the lengths each one needs.
    ///
    /// The lengths are the app's own validation, not a suggestion: a key of the
    /// wrong length is not sent at all, and a wrong IV produces "Decryption
    /// Failed" on the phone rather than an error the sender can see.
    static func cipherNotes() -> String { barkCipherNotes }

    private static let barkCipherNotes: String = (
        "Encrypts the whole request, so the server and Apple cannot read it. "
        + "Set the same values in the app under Push Encryption."
        + "\n"
        + "Key length: AES128 needs 16 characters, AES192 24, AES256 32."
        + "\n"
        + "The IV is generated for each push and sent with it."
        + "\n"
        + "A key of the wrong length leaves the request unencrypted rather than "
        + "failing it, so the push still arrives."
    ).localized

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
        noAutoCorrect: Bool = false,
        changeObserver: AnyObject? = nil
    ) -> PSSpecifier {
        let specifier = PSSpecifier.preferenceSpecifierNamed(
            title.localized, target: PreferencesStorage.self,
            set: #selector(PreferencesStorage.setValue(_:forInstanceSpecifier:)),
            get: #selector(PreferencesStorage.readValue(forInstanceSpecifier:)),
            detail: nil, cell: .editTextCell, edit: nil
        )!
        configure(specifier, service: service, appID: appID, key: key)
        specifier.setProperty(true, forKey: "enabled")
        if let changeObserver {
            specifier.setProperty(
                NSValue(nonretainedObject: changeObserver),
                forKey: SpecifierRouting.PropertyKey.changeObserver
            )
        }
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
        if let changeObserver {
            specifier.setProperty(
                NSValue(nonretainedObject: changeObserver),
                forKey: SpecifierRouting.PropertyKey.changeObserver
            )
        }
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

    /// A segmented control, for a choice between a few named values.
    ///
    /// `setValues(_:titles:)` rather than setting the properties: the framework's
    /// segment cell reads its choices from the specifier's own ivars, and a
    /// `setProperty` would write to the properties dictionary instead — leaving
    /// the control with no options at all.
    private static func segment(
        _ title: String,
        service: String,
        appID: String?,
        key: String,
        values: [String],
        titles: [String],
        defaultValue: String,
        changeObserver: AnyObject? = nil
    ) -> PSSpecifier {
        let specifier = PSSpecifier.preferenceSpecifierNamed(
            title.localized, target: PreferencesStorage.self,
            set: #selector(PreferencesStorage.setValue(_:forInstanceSpecifier:)),
            get: #selector(PreferencesStorage.readValue(forInstanceSpecifier:)),
            detail: nil, cell: .segmentCell, edit: nil
        )!
        configure(specifier, service: service, appID: appID, key: key)
        specifier.setProperty(true, forKey: "enabled")
        if let changeObserver {
            specifier.setProperty(
                NSValue(nonretainedObject: changeObserver),
                forKey: SpecifierRouting.PropertyKey.changeObserver
            )
        }
        specifier.setValues(values, titles: titles)
        specifier.setProperty(defaultValue, forKey: SpecifierRouting.PropertyKey.defaultValue)
        if let changeObserver {
            specifier.setProperty(
                NSValue(nonretainedObject: changeObserver),
                forKey: SpecifierRouting.PropertyKey.changeObserver
            )
        }
        return specifier
    }

    /// Whether the encryption fields should be shown.
    ///
    /// Read the same way for the page that builds the rows and the controller
    /// that seeds its comparison, so the two cannot disagree about what was on
    /// screen.
    static func cipherEnabled(stored: Prefs, fallback: Prefs?) -> Bool {
        if let value = stored.raw[BarkPrefKey.cipherEnabled] as? NSNumber {
            return value.boolValue
        }
        return fallback?.bool(BarkPrefKey.cipherEnabled, default: false) ?? false
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
