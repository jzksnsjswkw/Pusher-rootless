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
    let defaultCustomAppPrefs: () -> [String: Any]
    let shouldIncludeIcon: (ServiceConfig) -> Bool
    let shouldIncludeImage: (ServiceConfig) -> Bool
    let logImageDataProperties: [String]

    /// Binds a concrete service type to the closures above.
    ///
    /// - Parameter displayName: the label shown in the add list. Defaults to the
    ///   registry name, which is already the user-facing spelling for most
    ///   services (`"Bark"`, `"Pushover"`, …).
    public init<S: PushService>(
        _ type: S.Type,
        displayName: String? = nil,
        isAddable: Bool = true
    ) {
        name = S.serviceName
        self.displayName = displayName ?? (S.serviceName.isEmpty ? "Custom" : S.serviceName)
        self.isAddable = isAddable
        url = { S.url(eventName: $0, dbName: $1, serverURL: $2) }
        buildRequest = { S.request(context: $0, config: $1) }
        buildRequestAsync = { context, config, completion in
            S.request(context: context, config: config, completion: completion)
        }
        defaultPrefs = { S.defaultPrefs() }
        defaultCustomAppPrefs = { S.defaultCustomAppPrefs() }
        shouldIncludeIcon = { S.shouldIncludeIcon(config: $0) }
        shouldIncludeImage = { S.shouldIncludeImage(config: $0) }
        logImageDataProperties = S.logImageDataProperties
    }

    /// The settings a new instance of this type starts with.
    public func newInstancePrefs() -> [String: Any] { defaultPrefs() }

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
        .init(FeishuService.self),
        .init(IFTTTService.self),
        .init(PushbulletService.self),
        .init(PusherReceiverService.self),
        .init(PushoverService.self),
        .init(WechatService.self),
        .init(CustomService.self, displayName: "Custom Webhook"),
        .init(JavaScriptService.self, displayName: "JavaScript"),
    ]

    /// The generic webhook descriptor.
    public static let customService = ServiceDescriptor(CustomService.self,
                                                        displayName: "Custom Webhook")

    /// The registry name the webhook descriptor is stored under.
    public static var customServiceName: String { CustomService.serviceName }

    /// The descriptor registered under `name`.
    ///
    /// An unknown name resolves to the webhook descriptor rather than to `nil`:
    /// an instance whose type is not in this build (a service removed from a
    /// later version, say) still has to be sendable, and the webhook's builder
    /// works off whatever that instance's config happens to contain.
    public static func service(named name: String) -> ServiceDescriptor {
        addableServices.first { $0.name == name } ?? customService
    }

    /// The descriptor for `name` only when it is a known service.
    public static func knownService(named name: String) -> ServiceDescriptor? {
        addableServices.first { $0.name == name }
    }

    /// Whether `name` is a built-in (non-webhook) service.
    public static func isBuiltIn(_ name: String) -> Bool {
        guard let descriptor = knownService(named: name) else { return false }
        return descriptor.name != customServiceName
    }
}
