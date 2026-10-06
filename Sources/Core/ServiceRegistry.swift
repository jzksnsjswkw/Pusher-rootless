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
    public let name: String

    let url: (_ eventName: String, _ dbName: String, _ serverURL: String) -> String
    let buildRequest: (BulletinContext, ServiceConfig) -> PushRequest?
    let buildRequestAsync: (
        _ context: BulletinContext,
        _ config: ServiceConfig,
        _ completion: @escaping (PushRequest?) -> Void
    ) -> Void
    let extraPrefs: (Prefs) -> [String: Any]?
    let extraCustomAppPrefs: (Prefs) -> [String: Any]?
    let shouldIncludeIcon: (ServiceConfig) -> Bool
    let shouldIncludeImage: (ServiceConfig) -> Bool
    let logImageDataProperties: [String]

    /// Binds a concrete service type to the closures above.
    public init<S: PushService>(_ type: S.Type) {
        name = S.serviceName
        url = { S.url(eventName: $0, dbName: $1, serverURL: $2) }
        buildRequest = { S.request(context: $0, config: $1) }
        buildRequestAsync = { context, config, completion in
            S.request(context: context, config: config, completion: completion)
        }
        extraPrefs = { S.extraPrefs($0) }
        extraCustomAppPrefs = { S.extraCustomAppPrefs($0) }
        shouldIncludeIcon = { S.shouldIncludeIcon(config: $0) }
        shouldIncludeImage = { S.shouldIncludeImage(config: $0) }
        logImageDataProperties = S.logImageDataProperties
    }
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
    /// Every built-in service, in the order the UI lists them.
    public static let builtInServices: [ServiceDescriptor] = [
        .init(BarkService.self),
        .init(FeishuService.self),
        .init(IFTTTService.self),
        .init(PushbulletService.self),
        .init(PusherReceiverService.self),
        .init(PushoverService.self),
        .init(WechatService.self),
    ]

    /// Registry keys of the built-in services.
    public static var builtInServiceNames: [String] {
        builtInServices.map(\.name)
    }

    /// The fallback used for any name that is not a built-in service: an
    /// arbitrary user-defined webhook.
    public static let customService = ServiceDescriptor(CustomService.self)

    /// The service registered under `name`, or ``customService`` when the name
    /// is not a built-in one.
    ///
    /// Custom services are keyed by their user-chosen name in prefs, so an
    /// unknown name means "custom", never "missing".
    public static func service(named name: String) -> ServiceDescriptor {
        builtInServices.first { $0.name == name } ?? customService
    }

    /// The descriptor for `name` only when it is a built-in service.
    public static func builtInService(named name: String) -> ServiceDescriptor? {
        builtInServices.first { $0.name == name }
    }

    /// Whether `name` is a built-in service.
    public static func isBuiltIn(_ name: String) -> Bool {
        builtInService(named: name) != nil
    }
}
