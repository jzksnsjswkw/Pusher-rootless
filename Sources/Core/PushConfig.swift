import Foundation

/// One service instance's resolved configuration.
///
/// An instance's raw prefs are normalized once at load time (missing fields
/// defaulted, disabled devices/sounds/apps dropped) so the payload builders can
/// read them directly. The typed accessors below are the only way the send path
/// reads an instance, which keeps the "guard the plist type" policy in one
/// place.
/// One instance hook: a switch and a source.
///
/// Both have to be present for the hook to run. The switch alone is not enough
/// (an enabled hook with no source would run an empty script for nothing) and
/// the source alone is not enough either (a user who cleared the text expects the
/// hook to stop, not to keep running whatever was there).
public struct HookConfig {
    public let isEnabled: Bool
    public let script: String

    /// Whether this hook should be executed at all.
    public var shouldRun: Bool {
        isEnabled && !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init(isEnabled: Bool, script: String) {
        self.isEnabled = isEnabled
        self.script = script
    }
}

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
    /// `nil` is the segment's "Default" — the instance follows the global list,
    /// which the engine has already applied by the time this is read. `true` and
    /// `false` are the instance's own blacklist and whitelist.
    ///
    /// The earlier form defaulted a missing key to `true`, which made "Default"
    /// and "blacklist" the same setting and silently ignored a global whitelist.
    public var appListIsBlacklist: Bool? {
        raw[PrefKey.appListIsBlacklist] as? Bool
    }

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

    // MARK: - Instance hooks

    /// The "received" hook: runs as soon as a notification arrives.
    public var receivedHook: HookConfig {
        HookConfig(
            isEnabled: raw.bool(PrefKey.hookReceivedEnabled),
            script: raw.string(PrefKey.hookReceivedScript) ?? ""
        )
    }

    /// The "filtered" hook: runs after every filter has passed.
    public var filteredHook: HookConfig {
        HookConfig(
            isEnabled: raw.bool(PrefKey.hookFilteredEnabled),
            script: raw.string(PrefKey.hookFilteredScript) ?? ""
        )
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

    /// The global SNS defaults every instance falls back to.
    ///
    /// Kept as the flat set the page edits rather than as resolved keys, because
    /// "which conditions are on globally" and "which are on for this service" are
    /// different questions that happen to share a shape.
    public var snsIsAnd = true
    public var snsRequireANWithOR = true
    public var globalSNSConditions: Set<SNSCondition> = [.allowNotifications]

    /// Whether a condition is on globally.
    public func snsCondition(_ condition: SNSCondition) -> Bool {
        globalSNSConditions.contains(condition)
    }

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

        // The global SNS settings, in the two places they have been kept.
        //
        // The switches are the *flat top-level* keys the original's page wrote —
        // both spellings — while the conditions live both flat and inside `Global`
        // (the app's own page wrote them nested at one point). Read flat first,
        // then nested, so a configuration from either era answers the same.
        snapshot.snsIsAnd = snsToggle(
            PrefKey.snsIsAnd, alias: PrefKey.SNSAlias.isAnd,
            in: prefs, fallback: true
        )
        snapshot.snsRequireANWithOR = snsToggle(
            PrefKey.snsRequireANWithOR, alias: PrefKey.SNSAlias.requireANWithOR,
            in: prefs, fallback: true
        )
        var conditions: Set<SNSCondition> = []
        for condition in SNSCondition.allCases {
            let key = PrefKey.snsPrefix + condition.rawValue
            if prefs[key] != nil {
                if prefs.bool(key, default: false) { conditions.insert(condition) }
            } else if global[key] != nil {
                if global.bool(key, default: false) { conditions.insert(condition) }
            } else if condition.defaultValue {
                conditions.insert(condition)
            }
        }
        snapshot.globalSNSConditions = conditions

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
        // A definition-backed instance inherits its definition's payload options
        // through the descriptor's `newInstancePrefs` — see
        // ``ServiceDescriptor/init(definition:)`` — so there is nothing to layer
        // here. What is added below is only the *fallback* case: an instance that
        // never chose an icon of its own takes the definition's, so editing a
        // definition updates the instances that are following it and leaves the
        // ones that chose for themselves alone.
        if let definition = CustomServiceStore.definition(id: instance.type),
           !ServiceIcon.isCustomized(Prefs(raw)) {
            let fromDefinition = CustomServiceStore.definitionPrefs(definition)
            for key in [PrefKey.customIcon, PrefKey.customIconSymbol,
                        PrefKey.customIconTint, PrefKey.customIconSource,
                        PrefKey.customIconSize] {
                if raw[key] == nil, let value = fromDefinition[key] {
                    raw[key] = value
                }
            }
        }

        let stored = instance.config

        // The instance's identity is *not* written here. A service may name a
        // parameter the same as an identity key — Bark's push-updating `id` does —
        // and overwriting it replaced the user's value with the instance's UUID on
        // every request. Nothing reads these from `raw`: the engine and the UI hold
        // the `ServiceInstance` itself, and the store reads the array. What a
        // service reads from `raw` is its settings, and the settings alone.

        // Filters. The blacklist mode is copied as stored — absent, "Default",
        // true or false — and not defaulted here: a missing key is the segment's
        // third state, and writing `true` over its absence collapsed "follow the
        // global list" into "blacklist". The list itself stays as stored too; the
        // engine skips the instance-level check entirely when no mode is set.
        raw[PrefKey.appList] = stored.stringArray(PrefKey.appList)
        if let mode = stored[PrefKey.appListIsBlacklist] {
            raw[PrefKey.appListIsBlacklist] = mode
        }
        raw[PrefKey.whenToPush] = stored.resolvedInt(
            PrefKey.whenToPush, default: snapshot.whenToPush.rawValue
        )
        raw[PrefKey.whatNetwork] = stored.resolvedInt(
            PrefKey.whatNetwork, default: snapshot.whatNetwork.rawValue
        )
        // Both spellings are read, the long one first, and the *global* value is
        // the fallback rather than a hard-coded `true`. That is the original's
        // chain (`SufficientNotificationSettingsIsAnd` ?: `snsIsAnd` ?: global)
        // and it is what makes a service that never chose follow the global —
        // before this, an instance silently used AND whatever the user had set
        // globally.
        raw[PrefKey.snsIsAnd] = snsToggle(
            PrefKey.snsIsAnd, alias: PrefKey.SNSAlias.isAnd,
            in: stored, fallback: snapshot.snsIsAnd
        )
        raw[PrefKey.snsRequireANWithOR] = snsToggle(
            PrefKey.snsRequireANWithOR, alias: PrefKey.SNSAlias.requireANWithOR,
            in: stored, fallback: snapshot.snsRequireANWithOR
        )
        raw[PrefKey.sns] = snsKeys(from: stored, global: snapshot)

        // Only enabled devices/sounds survive normalization, so the payload
        // builders never have to filter them.
        raw[PrefKey.devices] = stored.enabledDictionaries(PrefKey.devices).map(\.raw)
        raw[PrefKey.sounds] = stored.enabledIdentifiers(PrefKey.sounds)

        // A built-in service derives its endpoint from its settings, so an
        // instance that changes a credential also changes where it posts. A
        // webhook is the opposite: its URL *is* a setting the user typed, and
        // its descriptor returns nothing — so the stored value is kept.
        let eventName = stored.string(PrefKey.eventName) ?? ""
        let dbName = (stored.string(PrefKey.dbName) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let serverURL = stored.string(PrefKey.serverURL) ?? ""
        let serviceURL = descriptor.url(eventName, dbName, serverURL)
        if !serviceURL.isEmpty {
            raw[PrefKey.url] = serviceURL
        }

        raw[PrefKey.customApps] = normalizedCustomApps(
            from: stored, descriptor: descriptor, isWebhook: instance.isCustom,
            serviceURL: serviceURL, eventName: eventName, dbName: dbName, serverURL: serverURL
        )

        return ServiceConfig(name: instance.id, type: instance.type, raw: Prefs(raw))
    }

    /// One SNS toggle, read under either spelling, defaulting to the global.
    private static func snsToggle(
        _ key: String, alias: String, in stored: Prefs, fallback: Bool
    ) -> Bool {
        for candidate in [key, alias] where stored[candidate] != nil {
            return stored.bool(candidate, default: fallback)
        }
        return fallback
    }

    /// The set SNS condition names an instance is gated on.
    ///
    /// A condition the instance has not chosen falls back to the **global** one,
    /// not to a compiled-in default. That distinction is the whole point of the
    /// page: a service that follows the global has to keep following it when the
    /// global changes.
    private static func snsKeys(from stored: Prefs, global: ConfigSnapshot) -> [String] {
        SNSCondition.allCases.compactMap { condition in
            let key = PrefKey.snsPrefix + condition.rawValue
            guard stored[key] != nil else {
                return global.snsCondition(condition) ? condition.rawValue : nil
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

            // Only a service that derives its endpoint gets a per-app URL; for a
            // webhook there is nothing to derive and the instance-wide URL is
            // already the app's.
            let appEventName = appPrefs.string(PrefKey.eventName) ?? eventName
            let appServerURL = appPrefs.string(PrefKey.serverURL) ?? serverURL
            let appURL = descriptor.url(appEventName, dbName, appServerURL)
            if !appURL.isEmpty, appURL != serviceURL {
                override[PrefKey.url] = appURL
            }

            result[appID] = override
        }
        return result
    }
}
