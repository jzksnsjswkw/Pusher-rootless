import Foundation

/// One service instance's resolved configuration.
///
/// An instance's raw prefs are normalized once at load time (missing fields
/// defaulted, disabled devices/sounds/apps dropped) so the payload builders can
/// read them directly. The typed accessors below are the only way the send path
/// reads an instance, which keeps the "guard the plist type" policy in one
/// place.
public struct ServiceConfig {
    /// The instance's id, which is also its log key.
    public let name: String

    /// The descriptor that builds this instance's requests.
    public let type: String

    /// The normalized settings.
    public let raw: Prefs

    public init(name: String, type: String, raw: Prefs) {
        self.name = name
        self.type = type
        self.raw = raw
    }

    /// Whether this instance is a user-defined webhook.
    public var isCustomService: Bool {
        ServiceRegistry.isBuiltIn(type) == false
    }

    // MARK: - Filters

    public var appList: [String] { raw.stringArray(PrefKey.appList) }
    /// Defaults to `true` (blacklist) when unset.
    public var appListIsBlacklist: Bool { raw.bool(PrefKey.appListIsBlacklist, default: true) }

    /// The SNS condition keys this instance is gated on.
    public var sns: [String] { raw.stringArray(PrefKey.sns) }
    /// Defaults to `true` (AND) when unset.
    public var snsIsAnd: Bool { raw.bool(PrefKey.snsIsAnd, default: true) }
    /// Defaults to `true` when unset.
    public var snsRequireANWithOR: Bool { raw.bool(PrefKey.snsRequireANWithOR, default: true) }

    /// Defaults to "either" when unset.
    public var whenToPush: WhenToPush {
        WhenToPush(rawValue: raw.resolvedInt(PrefKey.whenToPush, default: WhenToPush.either.rawValue)) ?? .either
    }

    /// Defaults to "any network" when unset.
    public var whatNetwork: WhatNetwork {
        WhatNetwork(rawValue: raw.resolvedInt(PrefKey.whatNetwork, default: WhatNetwork.any.rawValue)) ?? .any
    }

    // MARK: - Per-app overrides

    /// The raw per-app override objects, keyed by bundle ID.
    public var customApps: [String: Prefs] {
        guard let container = raw.dict(PrefKey.customApps) else { return [:] }
        return container.raw.compactMapValues { value in
            (value as? [String: Any]).map(Prefs.init)
        }
    }

    /// This instance's config with one app's overrides merged in.
    ///
    /// The app-list filter compares case-sensitively against the current app ID
    /// (matching the exact-case bundle IDs the UI stores), while this lookup
    /// stays case-insensitive as a separate tolerance layer: `customApps` may
    /// have been entered with different casing.
    public func effective(forAppID appID: String) -> ServiceConfig {
        guard let override = customAppOverride(forAppID: appID) else { return self }
        var merged = raw.raw
        for (key, value) in override.raw {
            merged[key] = value
        }
        return ServiceConfig(name: name, type: type, raw: Prefs(merged))
    }

    /// The per-app override object for one app, tolerating a case difference.
    public func customAppOverride(forAppID appID: String) -> Prefs? {
        let apps = customApps
        guard !apps.isEmpty else { return nil }
        if let exact = apps[appID] { return exact }
        let lowered = appID.lowercased()
        return apps.first { $0.key.lowercased() == lowered }?.value
    }
}

/// An immutable snapshot of every preference the send path needs.
///
/// Reading prefs is comparatively expensive and the pipeline is re-entrant
/// (Darwin notifications can arrive on any thread), so the whole configuration
/// is resolved once per reload into this value and then only read.
public struct ConfigSnapshot {
    public var enabled = true
    public var whenToPush: WhenToPush = .either
    public var whatNetwork: WhatNetwork = .any
    public var globalAppListIsBlacklist = true
    public var globalAppList: [String] = []

    /// Every configured instance, in the user's order, enabled or not.
    public var instances: [ServiceInstance] = []

    /// The instances the pipeline fans out to, in the same order.
    public var enabledInstances: [ServiceInstance] = []

    /// Resolved configs keyed by instance id.
    public var configs: [String: ServiceConfig] = [:]

    public init() {}

    /// The resolved config for one instance id.
    public func config(forID id: String) -> ServiceConfig? { configs[id] }

    /// The instance with this id, if it still exists.
    public func instance(id: String) -> ServiceInstance? {
        instances.first { $0.id == id }
    }
}

/// Loads the preference snapshot the push pipeline runs on.
public enum ConfigLoader {
    /// Reads and normalizes the whole preference domain.
    public static func loadSnapshot() -> ConfigSnapshot {
        PusherLog.debug("Reloading prefs")

        let prefs = PrefsStore.prefs()

        var snapshot = ConfigSnapshot()
        snapshot.enabled = prefs.bool(PrefKey.enabled, default: true)
        snapshot.whenToPush = WhenToPush(
            rawValue: prefs.resolvedInt(PrefKey.whenToPush, default: WhenToPush.either.rawValue)
        ) ?? .either
        snapshot.whatNetwork = WhatNetwork(
            rawValue: prefs.resolvedInt(PrefKey.whatNetwork, default: WhatNetwork.any.rawValue)
        ) ?? .any

        // The global app list lives nested under Global = { appList, … }.
        let global = prefs.dict(PrefKey.global) ?? Prefs()
        snapshot.globalAppListIsBlacklist = global.bool(PrefKey.appListIsBlacklist, default: true)
        snapshot.globalAppList = global.stringArray(PrefKey.appList)

        // One pass over the stored instances: each is normalized against its
        // own descriptor, and the enabled ones form the fan-out order.
        snapshot.instances = ServiceInstanceStore.instances()
        snapshot.configs = [:]
        snapshot.enabledInstances = []
        for instance in snapshot.instances {
            snapshot.configs[instance.id] = normalize(instance, snapshot: snapshot)
            if instance.isEnabled {
                snapshot.enabledInstances.append(instance)
            }
        }

        PusherLog.debug("Reloaded: \(snapshot.enabledInstances.count) enabled of \(snapshot.instances.count)")
        return snapshot
    }

    // MARK: - Per-instance normalization

    /// Fills in everything the payload builders read, so they never have to
    /// default a missing value themselves.
    private static func normalize(_ instance: ServiceInstance, snapshot: ConfigSnapshot) -> ServiceConfig {
        let descriptor = instance.descriptor

        // Start from the descriptor's defaults, then the stored values, then
        // overwrite the fields this loader owns. Starting from the defaults is
        // what makes a newly added instance immediately usable; merging the
        // stored values over them preserves anything the user set that the
        // descriptor does not name.
        var raw = descriptor.newInstancePrefs()
        for (key, value) in instance.config.raw {
            raw[key] = value
        }

        let stored = instance.config

        // The identity fields are always present and come from the instance.
        raw[PrefKey.instanceID] = instance.id
        raw[PrefKey.instanceType] = instance.type
        raw[PrefKey.instanceName] = instance.name
        raw[PrefKey.serviceEnabled] = instance.isEnabled

        // Filters, defaulted from the global settings when the instance has no
        // opinion of its own.
        raw[PrefKey.appList] = stored.stringArray(PrefKey.appList)
        raw[PrefKey.appListIsBlacklist] = stored.bool(PrefKey.appListIsBlacklist, default: true)
        raw[PrefKey.whenToPush] = stored.resolvedInt(
            PrefKey.whenToPush, default: snapshot.whenToPush.rawValue
        )
        raw[PrefKey.whatNetwork] = stored.resolvedInt(
            PrefKey.whatNetwork, default: snapshot.whatNetwork.rawValue
        )
        raw[PrefKey.snsIsAnd] = stored.bool(PrefKey.snsIsAnd, default: true)
        raw[PrefKey.snsRequireANWithOR] = stored.bool(PrefKey.snsRequireANWithOR, default: true)
        raw[PrefKey.sns] = snsKeys(from: stored)

        // Only enabled devices/sounds survive normalization, so the payload
        // builders never have to filter them.
        raw[PrefKey.devices] = stored.enabledDictionaries(PrefKey.devices).map(\.raw)
        raw[PrefKey.sounds] = stored.enabledIdentifiers(PrefKey.sounds)

        // The request URL is derived by the descriptor, so an instance that
        // changes a credential also changes where it posts.
        let eventName = stored.string(PrefKey.eventName) ?? ""
        let dbName = (stored.string(PrefKey.dbName) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let serverURL = stored.string(PrefKey.serverURL) ?? ""
        let serviceURL = descriptor.url(eventName, dbName, serverURL)
        raw[PrefKey.url] = serviceURL

        raw[PrefKey.customApps] = normalizedCustomApps(
            from: stored, descriptor: descriptor, isWebhook: instance.isCustom,
            serviceURL: serviceURL, eventName: eventName, dbName: dbName, serverURL: serverURL
        )

        return ServiceConfig(name: instance.id, type: instance.type, raw: Prefs(raw))
    }

    /// The set SNS condition names an instance is gated on.
    private static func snsKeys(from stored: Prefs) -> [String] {
        SNSCondition.allCases.compactMap { condition in
            let key = PrefKey.snsPrefix + condition.rawValue
            guard stored[key] != nil else {
                return condition.defaultValue ? condition.rawValue : nil
            }
            return stored.bool(key) ? condition.rawValue : nil
        }
    }

    /// Per-app overrides with disabled entries removed and descriptor defaults
    /// filled in, keyed by bundle ID.
    ///
    /// An override that changes the app's event name or server URL resolves to a
    /// different endpoint; that URL is stored on the override only when it
    /// actually differs from the instance-wide one, so the common case stays a
    /// one-key lookup at send time.
    private static func normalizedCustomApps(
        from stored: Prefs,
        descriptor: ServiceDescriptor,
        isWebhook: Bool,
        serviceURL: String,
        eventName: String,
        dbName: String,
        serverURL: String
    ) -> [String: [String: Any]] {
        guard let customApps = stored.dict(PrefKey.customApps) else { return [:] }
        var result: [String: [String: Any]] = [:]

        for appID in customApps.keys {
            guard let appPrefs = customApps.dict(appID) else { continue }
            // Default enabled, so only an explicit "no" is skipped.
            if appPrefs[PrefKey.enabled] != nil, !appPrefs.bool(PrefKey.enabled, default: true) {
                continue
            }

            // A webhook's override is user-defined in the same way the webhook
            // is, so it is carried through whole; a built-in service's override
            // holds exactly the fields its descriptor names.
            var override = isWebhook ? appPrefs.raw : [:]
            for (key, value) in descriptor.newOverridePrefs() where override[key] == nil {
                override[key] = value
            }

            override[PrefKey.devices] = appPrefs.enabledDictionaries(PrefKey.devices).map(\.raw)
            override[PrefKey.sounds] = appPrefs.enabledIdentifiers(PrefKey.sounds)

            let appEventName = appPrefs.string(PrefKey.eventName) ?? eventName
            let appServerURL = appPrefs.string(PrefKey.serverURL) ?? serverURL
            let appURL = descriptor.url(appEventName, dbName, appServerURL)
            if appURL != serviceURL {
                override[PrefKey.url] = appURL
            }

            result[appID] = override
        }
        return result
    }
}
