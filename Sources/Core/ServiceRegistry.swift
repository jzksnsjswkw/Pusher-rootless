import Foundation

/// A type-erased view of one ``PushService``.
///
/// The registry has to hand back a service it only knows by name. Returning an
/// `any PushService.Type` existential does not work well here: a static protocol
/// requirement cannot be called on an existential metatype without opening it,
/// and the optimizer crashes on that pattern in this toolchain (and the pattern
/// would be awkward to call from the loader anyway).
///
/// Binding each requirement to a closure over the concrete type at construction
/// time sidesteps both problems: what is stored is an ordinary value, and the
/// call sites read exactly as the protocol does.
public struct ServiceDescriptor {
    /// Registry key, unique across built-in services.
    public let name: String

    /// The label the "add service" list shows, and the default name for a new
    /// instance of this type.
    public let displayName: String

    /// Whether the user picks this type from the add list. Built-in services do;
    /// the generic webhook is reached through its own "Custom" entry.
    public let isAddable: Bool

    let url: (_ eventName: String, _ dbName: String, _ serverURL: String) -> String
    let buildRequest: (BulletinContext, ServiceConfig) -> PushRequest?
    let buildRequestAsync: (
        _ context: BulletinContext,
        _ config: ServiceConfig,
        _ completion: @escaping (PushRequest?) -> Void
    ) -> Void
    let defaultPrefs: () -> [String: Any]

    /// The settings a new instance of this type starts with.
    ///
    /// Normally ``defaultPrefs``. A definition-backed descriptor overrides it,
    /// The settings a new instance of this type starts with.
    ///
    /// Normally ``defaultPrefs``. A definition-backed descriptor replaces it,
    /// because the definition page's payload options are what a new instance must
    /// inherit: the script type declares static defaults for the same keys, so
    /// without this the definition's controls would store values that a new
    /// instance never picks up — controls that look live and change nothing.
    ///
    /// A stored closure rather than a method: ``defaultPrefs`` is itself stored,
    /// and only a stored property can be replaced per descriptor.
    var newInstancePrefs: () -> [String: Any]
    let defaultCustomAppPrefs: () -> [String: Any]
    /// Whether this service's payload can carry an icon/image at all.
    ///
    /// Separate from the `shouldInclude…` settings below, which are only asked
    /// when the matching capability is true. The pages read these to decide
    /// whether to offer the switches at all.
    var supportsIcon: Bool
    var supportsImage: Bool
    let shouldIncludeIcon: (ServiceConfig) -> Bool
    let shouldIncludeImage: (ServiceConfig) -> Bool
    let logImageDataProperties: [String]

    /// Binds a concrete service type to the closures above.
    ///
    /// - Parameter displayName: the label shown in the add list. Defaults to the
    ///   registry name, which is already the user-facing spelling for most
    ///   services (`"Bark"`, `"Pushover"`, …).
    /// - Parameter registryName: overrides the name this descriptor answers to.
    ///   A script definition needs it: the descriptor is built from one service
    ///   type, but each definition is a type of its own, identified by its id.
    public init<S: PushService>(
        _ type: S.Type,
        displayName: String? = nil,
        isAddable: Bool = true,
        registryName: String? = nil
    ) {
        name = registryName ?? S.serviceName
        self.displayName = displayName ?? (S.serviceName.isEmpty ? "Custom" : S.serviceName)
        self.isAddable = isAddable
        url = { S.url(eventName: $0, dbName: $1, serverURL: $2) }
        buildRequest = { S.request(context: $0, config: $1) }
        buildRequestAsync = { context, config, completion in
            S.request(context: context, config: config, completion: completion)
        }
        defaultPrefs = { S.defaultPrefs() }
        newInstancePrefs = defaultPrefs
        defaultCustomAppPrefs = { S.defaultCustomAppPrefs() }
        supportsIcon = S.supportsIcon
        supportsImage = S.supportsImage
        shouldIncludeIcon = { S.shouldIncludeIcon(config: $0) }
        shouldIncludeImage = { S.shouldIncludeImage(config: $0) }
        logImageDataProperties = S.logImageDataProperties
    }

    /// Builds the descriptor for one of the user's script definitions.
    ///
    /// The closure captures the definition's id rather than its script, and the
    /// script itself is read from storage at send time: editing a definition then
    /// takes effect for every service already using it, which is the point of
    /// separating a type from the instances of it.
    public init(definition: CustomServiceDefinition) {
        self.init(
            JavaScriptService.self,
            displayName: definition.name,
            // The identity is the definition, so the descriptor answers to the
            // id an instance stores — not to the JavaScript type's own name.
            registryName: definition.id
        )
        // The definition owns the payload options, so an instance of it starts
        // from what the definition page says rather than from the script type's
        // own static defaults.
        newInstancePrefs = { [definition] in
            var prefs = JavaScriptService.defaultPrefs()
            for (key, value) in CustomServiceStore.definitionPrefs(definition) {
                prefs[key] = value
            }
            return prefs
        }

        // A definition *declares* what its script's payload carries, so its own
        // switches are the capability: a script that was written without an
        // icon says so by leaving "Include Icon" off, and its instances then
        // have no icon option to offer. This is what keeps the definition's
        // switches from being a default that a page can silently contradict.
        let declared = CustomServiceStore.definitionPrefs(definition)
        let stored = Prefs(declared)
        supportsIcon = stored.bool(
            PrefKey.includeIcon, default: JavaScriptService.supportsIcon
        )
        supportsImage = stored.bool(
            PrefKey.includeImage, default: JavaScriptService.supportsImage
        )
    }

    /// The settings a new per-app override of this type starts with.
    public func newOverridePrefs() -> [String: Any] { defaultCustomAppPrefs() }
}

/// The set of available built-in services.
///
/// The ObjC version had every service self-register from `+load` and a
/// generated header aggregating their names. Swift has no `+load`, and a
/// generated compile-time list is unnecessary now that the services are plain
/// Swift types: naming them here makes the set explicit and greppable, and the
/// compiler guarantees every entry conforms.
///
/// Adding a service is two steps: write the type, and add it to
/// ``builtInServices``.
public enum ServiceRegistry {
    /// Every service the UI can create an instance of, in the order the add list
    /// shows them. The generic webhook is last because it is the fallback.
    public static let addableServices: [ServiceDescriptor] = [
        .init(BarkService.self),
        .init(DingtalkService.self),
        .init(FeishuService.self),
        .init(GotifyService.self),
        .init(IFTTTService.self),
        .init(PushbulletService.self),
        .init(PusherReceiverService.self),
        .init(PushoverService.self),
        .init(ServerChan3Service.self),
        .init(ServerChanService.self),
        .init(WechatService.self),
        .init(WxPusherService.self),
        .init(ShortcutService.self, displayName: "Shortcut"),
        .init(CustomService.self, displayName: customServiceDisplayName),
    ]

    /// The webhook's name, in one place: it is both the add-service row and the
    /// name the descriptor is registered under, and the localization table is
    /// keyed by it.
    static let customServiceDisplayName = "Custom Webhook"

    /// The generic webhook descriptor.
    public static let customService = ServiceDescriptor(CustomService.self,
                                                        displayName: customServiceDisplayName)

    /// The registry name the webhook descriptor is stored under.
    public static var customServiceName: String { CustomService.serviceName }

    /// The descriptor registered under `name`.
    ///
    /// Resolution covers three cases, in order:
    ///
    ///  1. a built-in service, by its registry name;
    ///  2. a *user-defined* service, by a definition id — which is how a script
    ///     the user wrote becomes a type the service list can reference, and why
    ///     definition ids are prefixed so they cannot collide with case 1;
    ///  3. anything else, which resolves to the generic webhook rather than to
    ///     `nil`, so an instance whose type is unknown (a definition that was
    ///     deleted, a service dropped from a later build) still sends, using
    ///     whatever its config contains.
    public static func service(named name: String) -> ServiceDescriptor {
        if let builtIn = addableServices.first(where: { $0.name == name }) { return builtIn }
        if let definition = CustomServiceStore.definition(id: name) {
            return .init(definition: definition)
        }
        return customService
    }

    /// The descriptor for `name` only when it is a known service.
    ///
    /// "Known" means a built-in one or one of the user's definitions — whatever
    /// the add list can offer.
    public static func knownService(named name: String) -> ServiceDescriptor? {
        if let builtIn = addableServices.first(where: { $0.name == name }) { return builtIn }
        return CustomServiceStore.definition(id: name).map { .init(definition: $0) }
    }

    /// Every type the add list should offer: the built-ins, then the user's own
    /// definitions, in the order they were written.
    public static func allAddableServices() -> [ServiceDescriptor] {
        addableServices + CustomServiceStore.definitions().map { .init(definition: $0) }
    }

    /// Whether `name` is a built-in (non-webhook) service.
    public static func isBuiltIn(_ name: String) -> Bool {
        guard let descriptor = knownService(named: name) else { return false }
        return descriptor.name != customServiceName
    }
}
