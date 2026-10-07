import Foundation

/// One configured push destination.
///
/// The unit of configuration is an *instance*, not a service type: the same
/// built-in service can be added several times (two Pushover accounts, two Bark
/// servers), each with its own credentials, app list and log. An instance is
/// therefore identified by ``id`` — a stable, opaque string — while ``type``
/// only says which ``ServiceDescriptor`` knows how to build its request.
public struct ServiceInstance {
    /// Stable identifier, unique within the preference domain. Used as the
    /// storage key for the instance's config and its log.
    public let id: String

    /// The ``ServiceDescriptor`` name that builds this instance's requests.
    public let type: String

    /// The user-visible label. Defaults to the type's display name, and is
    /// editable so two instances of one type can be told apart.
    public var name: String

    /// Whether the push pipeline fans out to this instance.
    public var isEnabled: Bool

    /// This instance's own settings, already normalized by the descriptor.
    public var config: Prefs

    public init(id: String, type: String, name: String, isEnabled: Bool, config: Prefs) {
        self.id = id
        self.type = type
        self.name = name
        self.isEnabled = isEnabled
        self.config = config
    }

    /// The descriptor that builds this instance's requests.
    public var descriptor: ServiceDescriptor {
        ServiceRegistry.service(named: type)
    }

    /// Whether this instance is a user-defined webhook rather than a built-in
    /// service.
    public var isCustom: Bool {
        ServiceRegistry.customServiceName == type
    }
}

// MARK: - Instance identifiers

public extension ServiceInstance {
    /// A fresh instance identifier.
    ///
    /// Opaque and random rather than derived from the service name: the name is
    /// editable, and deriving the id from it would make a rename look like a
    /// different instance to the log and to stored state.
    static func makeID() -> String {
        UUID().uuidString
    }
}

// MARK: - Storage shape

/// Reading and writing the `Services` array in prefs.
///
/// The array is the single source of truth for which pushes are sent, in what
/// order. Keeping the encode/decode in one place means the UI and the pipeline
/// cannot disagree about the layout.
public enum ServiceInstanceStore {
    /// The raw array as stored, in order.
    public static func rawInstances() -> [[String: Any]] {
        PrefsStore.prefs().dictionaries(PrefKey.services).map(\.raw)
    }

    /// Every stored instance, in order, without a descriptor in hand — the
    /// minimal fields only. ``ConfigLoader`` fills in the normalized config.
    public static func instances() -> [ServiceInstance] {
        rawInstances().compactMap { raw in
            let prefs = Prefs(raw)
            guard let id = prefs.nonEmptyString(PrefKey.instanceID),
                  let type = prefs.nonEmptyString(PrefKey.instanceType)
            else { return nil }
            return ServiceInstance(
                id: id,
                type: type,
                name: prefs.nonEmptyString(PrefKey.instanceName)
                    ?? ServiceRegistry.service(named: type).displayName,
                isEnabled: prefs.bool(PrefKey.serviceEnabled),
                config: prefs
            )
        }
    }

    /// Writes the whole array back.
    public static func setInstances(_ instances: [[String: Any]], notify: Bool = true) {
        PrefsStore.setValue(instances, forKey: PrefKey.services, notify: notify)
    }

    /// Appends a new instance of `type` and returns it.
    ///
    /// The instance starts with the descriptor's defaults, so it is immediately
    /// usable (and immediately visible in the list) rather than a blank entry.
    @discardableResult
    public static func add(type: String, name: String? = nil) -> ServiceInstance {
        let descriptor = ServiceRegistry.service(named: type)
        let instance = ServiceInstance(
            id: ServiceInstance.makeID(),
            type: type,
            name: name ?? uniqueName(for: descriptor),
            isEnabled: true,
            config: Prefs(descriptor.defaultPrefs())
        )
        var stored = rawInstances()
        stored.append(encoded(instance))
        setInstances(stored)
        return instance
    }

    /// A display name that is not already taken, so two instances of one type
    /// read as "Bark" and "Bark 2" instead of two identical rows.
    public static func uniqueName(for descriptor: ServiceDescriptor) -> String {
        let existing = Set(instances().map(\.name))
        let base = descriptor.displayName
        guard existing.contains(base) else { return base }
        var index = 2
        while existing.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    /// Serializes one instance.
    public static func encoded(_ instance: ServiceInstance) -> [String: Any] {
        var raw = instance.config.raw
        // The identity fields are authoritative on the instance, so they are
        // written last and cannot be shadowed by a stale value in its config.
        raw[PrefKey.instanceID] = instance.id
        raw[PrefKey.instanceType] = instance.type
        raw[PrefKey.instanceName] = instance.name
        raw[PrefKey.serviceEnabled] = instance.isEnabled
        return raw
    }

    // MARK: - One instance

    /// One instance by id, or `nil` when it no longer exists.
    public static func instance(id: String) -> ServiceInstance? {
        instances().first { $0.id == id }
    }

    /// Merges fields into one instance's stored object.
    public static func update(id: String, notify: Bool = true, _ mutate: (inout [String: Any]) -> Void) {
        var stored = rawInstances()
        guard let index = stored.firstIndex(where: {
            Prefs($0).nonEmptyString(PrefKey.instanceID) == id
        }) else { return }
        mutate(&stored[index])
        setInstances(stored, notify: notify)
    }

    /// Removes one instance and its log.
    public static func remove(id: String) {
        var stored = rawInstances()
        stored.removeAll { Prefs($0).nonEmptyString(PrefKey.instanceID) == id }
        setInstances(stored)
        LogStore.removeLogs(forService: id)
    }

    /// Replaces the whole array, preserving the given order. Used by the list's
    /// reorder/enable editing.
    public static func reorder(_ ordered: [ServiceInstance]) {
        setInstances(ordered.map(encoded))
    }
}
