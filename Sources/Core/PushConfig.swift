import Foundation

/// One service's resolved configuration.
///
/// A service's raw prefs are normalized once at load time (missing fields
/// defaulted, disabled devices/sounds/apps dropped) so the payload builders can
/// read them directly. The typed accessors below are the only way the send path
/// reads a service, which keeps the "guard the plist type" policy in one place.
public struct ServiceConfig {
    /// Registry key, matching the name used in prefs (e.g. `"Pushover"`).
    public let name: String
    public let isCustomService: Bool
    /// The normalized nested prefs object for this service.
    public let raw: Prefs

    public init(name: String, raw: Prefs, isCustomService: Bool) {
        self.name = name
        self.raw = raw
        self.isCustomService = isCustomService
    }

    // MARK: - Filters

    public var appList: [String] { raw.stringArray(PrefKey.appList) }
    /// Defaults to `true` (blacklist) when unset.
    public var appListIsBlacklist: Bool { raw.bool(PrefKey.appListIsBlacklist, default: true) }

    /// The SNS condition keys this service is gated on.
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

    /// This service's config with one app's overrides merged in.
    ///
    /// The service app-list filter compares case-sensitively against the
    /// current app ID (matching the exact-case bundle IDs the UI stores), while
    /// this lookup stays case-insensitive as a separate tolerance layer:
    /// `customApps` may have been entered with different casing, or migrated
    /// from older lowercased storage.
    public func effective(forAppID appID: String) -> ServiceConfig {
        guard let override = customAppOverride(forAppID: appID) else { return self }
        var merged = raw.raw
        for (key, value) in override.raw {
            merged[key] = value
        }
        return ServiceConfig(name: name, raw: Prefs(merged), isCustomService: isCustomService)
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
    public var snsIsAnd = true
    public var snsRequireANWithOR = true
    /// Resolved configs for every service, enabled or not.
    public var serviceConfigs: [String: ServiceConfig] = [:]
    /// Names of the enabled services, in registry order.
    public var enabledServiceNames: [String] = []

    public init() {}

    public func service(_ name: String) -> ServiceConfig? { serviceConfigs[name] }
}

/// Loads the preference snapshot the push pipeline runs on.
public enum ConfigLoader {
    /// Reads, migrates and normalizes the whole preference domain.
    ///
    /// Migration runs first: prefs written by an older build keep their legacy
    /// flat keys until they are folded into the nested layout and persisted.
    public static func loadSnapshot() -> ConfigSnapshot {
        PusherLog.debug("Reloading prefs")

        var prefs = PrefsStore.prefs()
        prefs = Migration.migrateBuiltInServices(prefs)
        prefs = Migration.migrateCustomServices(prefs)
        prefs = Migration.migrateGlobal(prefs)

        var snapshot = ConfigSnapshot()
        snapshot.enabled = prefs.bool(PrefKey.enabled, default: true)
        snapshot.whenToPush = WhenToPush(
            rawValue: prefs.resolvedInt(PrefKey.whenToPush, default: WhenToPush.either.rawValue)
        ) ?? .either
        snapshot.whatNetwork = WhatNetwork(
            rawValue: prefs.resolvedInt(PrefKey.whatNetwork, default: WhatNetwork.any.rawValue)
        ) ?? .any
        snapshot.snsIsAnd = Self.snsFlag(
            PrefKey.snsIsAnd, PrefKey.snsIsAndAlt, in: prefs, default: true
        )
        snapshot.snsRequireANWithOR = Self.snsFlag(
            PrefKey.snsRequireANWithOR, PrefKey.snsRequireANWithORAlt, in: prefs, default: true
        )

        // The global app list lives nested under Global = { appList, … }.
        let global = prefs.dict(PrefKey.global) ?? Prefs()
        snapshot.globalAppListIsBlacklist = global.bool(PrefKey.appListIsBlacklist, default: true)
        snapshot.globalAppList = global.stringArray(PrefKey.appList)

        // Custom services are whatever the user has defined; built-ins come
        // from the registry. Custom names are sorted so the fan-out order is
        // stable across reloads.
        let customServices = prefs.dict(PrefKey.customServices) ?? Prefs()
        let builtInServices = prefs.dict(PrefKey.builtInServices) ?? Prefs()
        let customNames = customServices.keys.sorted()
        let builtInNames = ServiceRegistry.builtInServiceNames
        snapshot.serviceConfigs = [:]
        for name in customNames + builtInNames {
            snapshot.serviceConfigs[name] = loadService(
                named: name, isCustom: customNames.contains(name),
                prefs: prefs, snapshot: snapshot
            )
        }

        // Enabled services: custom first (sorted), then built-ins in registry
        // order — the order the UI's sections imply.
        var enabled: [String] = []
        for name in customNames where customServices.dict(name)?.bool(PrefKey.legacyEnabled) == true {
            enabled.append(name)
        }
        for name in builtInNames where builtInServices.dict(name)?.bool(PrefKey.serviceEnabled) == true {
            enabled.append(name)
        }
        snapshot.enabledServiceNames = enabled

        PusherLog.debug("Reloaded")
        return snapshot
    }

    // MARK: - Per-service normalization

    private static func loadService(
        named name: String,
        isCustom: Bool,
        prefs: Prefs,
        snapshot: ConfigSnapshot
    ) -> ServiceConfig {
        let source = isCustom
            ? (prefs.dict(PrefKey.customServices)?.dict(name) ?? Prefs())
            : (prefs.dict(PrefKey.builtInServices)?.dict(name) ?? Prefs())

        // Start from everything the user stored, then overwrite the keys that
        // need normalizing. Copying first matters for a custom service: its
        // fields are user-defined (`includeIcon`, `includeImage`, `url`, any
        // future option), so a white-listed copy would silently drop settings
        // this type does not happen to name — a missing `includeIcon` is not a
        // default, it is a lost preference.
        var servicePrefs: [String: Any] = source.raw

        servicePrefs[PrefKey.appList] = source.stringArray(PrefKey.appList)
        servicePrefs[PrefKey.appListIsBlacklist] = source.bool(PrefKey.appListIsBlacklist, default: true)
        servicePrefs[PrefKey.whenToPush] = source.resolvedInt(
            PrefKey.whenToPush, default: snapshot.whenToPush.rawValue
        )
        servicePrefs[PrefKey.whatNetwork] = source.resolvedInt(
            PrefKey.whatNetwork, default: snapshot.whatNetwork.rawValue
        )
        // Two spellings exist for each flag: the long original (what the UI
        // plists and older builds write) and the short normalized one. The long
        // one wins, so a service that has both set follows the plist value.
        servicePrefs[PrefKey.snsIsAnd] = Self.snsFlag(
            PrefKey.snsIsAndAlt, PrefKey.snsIsAnd, in: source, default: snapshot.snsIsAnd
        )
        servicePrefs[PrefKey.snsRequireANWithOR] = Self.snsFlag(
            PrefKey.snsRequireANWithORAlt, PrefKey.snsRequireANWithOR,
            in: source, default: snapshot.snsRequireANWithOR
        )
        servicePrefs[PrefKey.sns] = Self.snsKeys(from: source, fallback: prefs, prefix: PrefKey.snsPrefix)

        // Only enabled devices/sounds survive normalization, so the payload
        // builders never have to filter them.
        servicePrefs[PrefKey.devices] = source.enabledDictionaries(PrefKey.devices).map(\.raw)
        servicePrefs[PrefKey.sounds] = source.enabledIdentifiers(PrefKey.sounds)

        // A custom service has no dedicated descriptor (the fallback is the
        // generic webhook type), so its extra prefs come from that fallback.
        let service = ServiceRegistry.service(named: name)

        if isCustom {
            // Custom services are fully user-defined; these are only the fields
            // that need a concrete value rather than a default at each call
            // site.
            servicePrefs[PrefKey.isCustomService] = true
            servicePrefs[PrefKey.url] = source.string(PrefKey.url) ?? ""
            servicePrefs[PrefKey.key] = source.string(PrefKey.key) ?? ""
            servicePrefs[PrefKey.paramName] = source.string(PrefKey.paramName) ?? ""
            servicePrefs[PrefKey.method] = source.string(PrefKey.method) ?? "POST"
            servicePrefs[PrefKey.bodyType] = source.string(PrefKey.bodyType) ?? "json"
            servicePrefs[PrefKey.authenticationMethod] = source.int(PrefKey.authenticationMethod)
            servicePrefs[PrefKey.customApps] = Self.normalizedCustomApps(
                from: source, service: service, isCustom: true
            )
        } else {
            servicePrefs[PrefKey.token] = source.string(PrefKey.token) ?? ""
            servicePrefs[PrefKey.user] = source.string(PrefKey.user) ?? ""
            servicePrefs[PrefKey.key] = source.string(PrefKey.key) ?? ""
            servicePrefs[PrefKey.dateFormat] = source.string(PrefKey.dateFormat) ?? ""

            let eventName = source.string(PrefKey.eventName) ?? ""
            let dbName = (source.string(PrefKey.dbName) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let serverURL = source.string(PrefKey.serverURL) ?? ""
            let serviceURL = service.url(eventName, dbName, serverURL)
            servicePrefs[PrefKey.url] = serviceURL

            // A per-app override may point at a different endpoint (Bark's
            // server URL, IFTTT's event name); that URL is resolved with the
            // same service hook and stored on the override only when it
            // differs from the service-wide one.
            servicePrefs[PrefKey.customApps] = Self.normalizedCustomApps(
                from: source, service: service, isCustom: false,
                serviceURL: serviceURL, eventName: eventName,
                dbName: dbName, serverURL: serverURL
            )
        }

        // Service-specific keys (Bark's parameters, Wechat's credentials,
        // IFTTT's toggles, …). For a custom service this is where the
        // user-defined fields (`includeIcon`, `includeImage`, …) are read
        // through; see `CustomService.extraPrefs`.
        if let extra = service.extraPrefs(source) {
            servicePrefs.merge(extra) { _, new in new }
        }

        return ServiceConfig(name: name, raw: Prefs(servicePrefs), isCustomService: isCustom)
    }

    /// Reads a boolean preference that may be stored under either of two key
    /// spellings, preferring `primary` and falling back to `secondary`.
    ///
    /// `nil` from both yields `defaultValue`, which is what keeps an unset flag
    /// following the global default rather than reading as false.
    private static func snsFlag(
        _ primary: String,
        _ secondary: String,
        in prefs: Prefs,
        default defaultValue: Bool
    ) -> Bool {
        if prefs[primary] != nil { return prefs.bool(primary, default: defaultValue) }
        if prefs[secondary] != nil { return prefs.bool(secondary, default: defaultValue) }
        return defaultValue
    }

    /// The set SNS condition names for one service.
    ///
    /// Reads `<prefix><condition>` from the service object, falling back to the
    /// same key at the top level (which is where older builds wrote them) and
    /// finally to the condition's own default (only "Allow Notifications" is on
    /// by default).
    private static func snsKeys(from source: Prefs, fallback: Prefs, prefix: String) -> [String] {
        SNSCondition.allCases.compactMap { condition in
            let key = prefix + condition.rawValue
            if source[key] != nil {
                return source.bool(key) ? condition.rawValue : nil
            }
            if fallback[key] != nil {
                return fallback.bool(key) ? condition.rawValue : nil
            }
            return condition.defaultValue ? condition.rawValue : nil
        }
    }

    /// Per-app overrides with disabled entries removed and service-specific
    /// fields filled in, keyed by bundle ID.
    ///
    /// For a built-in service, an override that changes the app's event name or
    /// server URL resolves to a different endpoint; that URL is stored on the
    /// override only when it actually differs from the service-wide one, so the
    /// common case stays a one-key lookup at send time.
    private static func normalizedCustomApps(
        from source: Prefs,
        service: ServiceDescriptor,
        isCustom: Bool,
        serviceURL: String? = nil,
        eventName: String? = nil,
        dbName: String? = nil,
        serverURL: String? = nil
    ) -> [String: [String: Any]] {
        guard let customApps = source.dict(PrefKey.customApps) else { return [:] }
        var result: [String: [String: Any]] = [:]
        for appID in customApps.keys {
            guard let appPrefs = customApps.dict(appID) else { continue }
            // Default enabled, so only an explicit "no" is skipped.
            if appPrefs[PrefKey.enabled] != nil, !appPrefs.bool(PrefKey.enabled, default: true) {
                continue
            }

            // The two service kinds store their overrides differently in the
            // original, and the difference is load-bearing:
            //
            // - A custom service's override is user-defined in the same way the
            //   service is, so it is copied wholesale and then normalized.
            // - A built-in service's override holds exactly the fields that
            //   service reads, rebuilt from the app's own values, so it is a
            //   known set rather than a copy.
            var override: [String: Any]
            if isCustom {
                override = appPrefs.raw
            } else {
                override = [:]
            }
            override[PrefKey.devices] = appPrefs.enabledDictionaries(PrefKey.devices).map(\.raw)
            override[PrefKey.sounds] = appPrefs.enabledIdentifiers(PrefKey.sounds)

            if !isCustom {
                let appEventName = appPrefs.string(PrefKey.eventName) ?? eventName ?? ""
                let appServerURL = appPrefs.string(PrefKey.serverURL) ?? serverURL ?? ""
                let appURL = service.url(appEventName, dbName ?? "", appServerURL)
                if let serviceURL, appURL != serviceURL {
                    override[PrefKey.url] = appURL
                }
            }

            if let extra = service.extraCustomAppPrefs(appPrefs) {
                override.merge(extra) { _, new in new }
            }
            result[appID] = override
        }
        return result
    }
}
