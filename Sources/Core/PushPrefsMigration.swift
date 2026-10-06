import Foundation

/// Folds preference keys written by an older build into the current nested
/// layout, and persists the result.
///
/// The current layout stores one object per service
/// (`BuiltInServices[name] = { field: value, … }`, likewise `CustomServices`),
/// plus one `Global = { appList, appListIsBlacklist }` object. Older builds
/// wrote flat top-level keys instead (`PushoverToken`, `BarkBL-<appid>`,
/// `GlobalBL-<appid>`, `CustomService_<name>_CustomApps`, …). Each routine
/// below takes the current raw snapshot, folds whatever legacy keys it finds
/// into the nested objects, and writes the cleaned snapshot back.
///
/// Every routine also runs when the nested object *already exists*: a stale or
/// partially migrated object next to leftover flat keys must still absorb them,
/// otherwise the old data would be stranded forever.
public enum Migration {

    // MARK: - Built-in services

    /// Folds the legacy flat per-service keys into `BuiltInServices`.
    public static func migrateBuiltInServices(_ prefs: Prefs) -> Prefs {
        var builtInServices = (prefs.dict(PrefKey.builtInServices)?.raw) ?? [:]
        var migratedAny = false
        var keysToRemove: [String] = []

        for service in ServiceRegistry.builtInServiceNames {
            let legacyKeys = Self.legacyKeys(forService: service)
            let blacklistPrefix = service + PrefKey.legacyBlacklistPrefix
            let flatAppIDs = appIDs(in: prefs, prefix: blacklistPrefix)
            guard legacyKeys.contains(where: { prefs[$0] != nil }) || !flatAppIDs.isEmpty else {
                continue
            }
            migratedAny = true

            // Start from whatever nested object already exists and only fill
            // gaps from the flat keys, so a newer config is never overwritten.
            var serviceObject = (builtInServices[service] as? [String: Any]) ?? [:]
            migrate(into: &serviceObject, prefs: prefs, service: service, legacyKeys: legacyKeys)
            migrateAppList(into: &serviceObject, flatAppIDs: flatAppIDs)
            builtInServices[service] = serviceObject

            keysToRemove.append(contentsOf: legacyKeys.filter { prefs[$0] != nil })
            keysToRemove.append(contentsOf: prefs.keys.filter {
                ($0.hasPrefix(blacklistPrefix) || $0.hasPrefix(service + PrefKey.snsPrefix))
                    && !keysToRemove.contains($0)
            })
        }

        guard migratedAny, !keysToRemove.isEmpty else { return prefs }
        var updated = prefs.raw
        updated[PrefKey.builtInServices] = builtInServices
        for key in keysToRemove { updated.removeValue(forKey: key) }

        PrefsStore.apply(updated, removing: keysToRemove)
        PusherLog.debug("Migrated legacy built-in service prefs")
        return Prefs(updated)
    }

    /// The flat `<service><Field>` keys of one service.
    private static func legacyKeys(forService service: String) -> [String] {
        let suffixes = [
            PrefKey.legacyEnabled, PrefKey.legacyToken, PrefKey.legacyUser, PrefKey.legacyKey,
            PrefKey.legacyEventName, PrefKey.legacyDateFormat, PrefKey.legacyServerURL,
            PrefKey.legacyDBName, PrefKey.legacyAppListIsBlacklist, PrefKey.legacyWhenToPush,
            PrefKey.legacyWhatNetwork, PrefKey.legacySNSIsAnd, PrefKey.legacySNSRequireANWithOR,
            PrefKey.legacyDevices, PrefKey.legacySounds, PrefKey.legacyCustomApps,
            PrefKey.legacyIncludeIcon, PrefKey.legacyCurateData, PrefKey.legacyIncludeImage,
            PrefKey.legacyImageMaxWidth, PrefKey.legacyImageMaxHeight,
            PrefKey.legacyImageShrinkFactor, PrefKey.legacyCorpid, PrefKey.legacyCorpsecret,
            PrefKey.legacyAgentID, PrefKey.legacyTouser,
        ]
        return suffixes.map { service + $0 }
    }

    /// Direct field renames from `<service><LegacySuffix>` to the field name.
    private static let fieldMigrations: [(String, String)] = [
        (PrefKey.legacyToken, PrefKey.token),
        (PrefKey.legacyUser, PrefKey.user),
        (PrefKey.legacyKey, PrefKey.key),
        (PrefKey.legacyEventName, PrefKey.eventName),
        (PrefKey.legacyDateFormat, PrefKey.dateFormat),
        (PrefKey.legacyServerURL, PrefKey.serverURL),
        (PrefKey.legacyDBName, PrefKey.dbName),
        (PrefKey.legacyIncludeIcon, PrefKey.includeIcon),
        (PrefKey.legacyCurateData, PrefKey.curateData),
        (PrefKey.legacyIncludeImage, PrefKey.includeImage),
        (PrefKey.legacyImageMaxWidth, PrefKey.imageMaxWidth),
        (PrefKey.legacyImageMaxHeight, PrefKey.imageMaxHeight),
        (PrefKey.legacyImageShrinkFactor, PrefKey.imageShrinkFactor),
        (PrefKey.legacyCorpid, PrefKey.corpid),
        (PrefKey.legacyCorpsecret, PrefKey.corpsecret),
        (PrefKey.legacyAgentID, PrefKey.agentID),
        (PrefKey.legacyTouser, PrefKey.touser),
        (PrefKey.legacyDevices, PrefKey.devices),
        (PrefKey.legacySounds, PrefKey.sounds),
        (PrefKey.legacyCustomApps, PrefKey.customApps),
        (PrefKey.legacyWhenToPush, PrefKey.whenToPush),
        (PrefKey.legacyWhatNetwork, PrefKey.whatNetwork),
        (PrefKey.legacySNSIsAnd, PrefKey.snsIsAndAlt),
        (PrefKey.legacySNSRequireANWithOR, PrefKey.snsRequireANWithORAlt),
    ]

    /// Copies each legacy flat value into its nested field, only where the
    /// nested object has nothing yet.
    private static func migrate(
        into serviceObject: inout [String: Any],
        prefs: Prefs,
        service: String,
        legacyKeys: [String]
    ) {
        // The enabled flag defaults to true when absent, so it is handled
        // first and always written (otherwise a service with no legacy
        // "Enabled" key would end up with no flag at all).
        if let flat = prefs[service + PrefKey.legacyEnabled] {
            serviceObject[PrefKey.serviceEnabled] = serviceObject[PrefKey.serviceEnabled] ?? flat
        }
        serviceObject[PrefKey.serviceEnabled] = serviceObject[PrefKey.serviceEnabled] ?? false

        for (legacySuffix, field) in fieldMigrations {
            guard let value = prefs[service + legacySuffix] else { continue }
            if serviceObject[field] == nil { serviceObject[field] = value }
        }

        // `appListIsBlacklist` defaults to true, so only a non-default value is
        // worth migrating (its absence already means "blacklist").
        if let value = prefs[service + PrefKey.legacyAppListIsBlacklist],
           serviceObject[PrefKey.appListIsBlacklist] == nil,
           !Prefs([PrefKey.appListIsBlacklist: value]).bool(PrefKey.appListIsBlacklist, default: true) {
            serviceObject[PrefKey.appListIsBlacklist] = value
        }

        // SNS toggles use the same `SNS-<condition>` field names as the UI.
        for condition in SNSCondition.allCases {
            let field = PrefKey.snsPrefix + condition.rawValue
            if let value = prefs[service + field], serviceObject[field] == nil {
                serviceObject[field] = value
            }
        }
    }

    /// Merges the flat `<service>BL-<appid>` entries into the service's app
    /// list array.
    private static func migrateAppList(into serviceObject: inout [String: Any], flatAppIDs: [String]) {
        guard !flatAppIDs.isEmpty else { return }
        var appList = (serviceObject[PrefKey.appList] as? [String]) ?? []
        for appID in flatAppIDs where !appList.contains(appID) {
            appList.append(appID)
        }
        serviceObject[PrefKey.appList] = appList
    }

    /// App IDs of the enabled flat `<prefix><appID>` keys, keeping their
    /// original case (bundle IDs are compared case-sensitively at send time).
    private static func appIDs(in prefs: Prefs, prefix: String) -> [String] {
        prefs.keys
            .filter { $0.hasPrefix(prefix) && prefs.bool($0) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    // MARK: - Custom services

    /// Folds the legacy `CustomService_<name>_CustomApps` and
    /// `CustomServiceBL_<name>-<appID>` keys into `CustomServices`.
    ///
    /// Scans the top-level keys rather than iterating `CustomServices`: the
    /// flat keys must be cleaned up even when the service no longer exists, or
    /// the orphaned keys would linger forever.
    public static func migrateCustomServices(_ prefs: Prefs) -> Prefs {
        var legacyNames = Set<String>()
        for key in prefs.keys {
            if key.hasPrefix(PrefKey.legacyCustomAppsPrefix), key.hasSuffix(PrefKey.legacyCustomAppsSuffix) {
                let start = key.index(key.startIndex, offsetBy: PrefKey.legacyCustomAppsPrefix.count)
                let end = key.index(key.endIndex, offsetBy: -PrefKey.legacyCustomAppsSuffix.count)
                legacyNames.insert(String(key[start..<end]))
            } else if key.hasPrefix(PrefKey.legacyCustomBlacklistPrefix) {
                let rest = String(key.dropFirst(PrefKey.legacyCustomBlacklistPrefix.count))
                if let dash = rest.firstIndex(of: "-") {
                    legacyNames.insert(String(rest[rest.startIndex..<dash]))
                }
            }
        }
        guard !legacyNames.isEmpty else { return prefs }

        var customServices = prefs.dict(PrefKey.customServices)?.raw ?? [:]
        var keysToRemove: [String] = []
        var migratedAny = false

        for service in legacyNames {
            // Only fold data into services that still exist; orphaned flat keys
            // for deleted services are removed outright.
            var serviceObject = customServices[service] as? [String: Any]

            // `CustomService_<service>_CustomApps` -> nested `customApps`.
            let legacyCustomAppsKey = PrefKey.legacyCustomAppsPrefix + service
                + PrefKey.legacyCustomAppsSuffix
            if let serviceObject_ = serviceObject,
               let flatCustomApps = prefs[legacyCustomAppsKey] as? [String: Any],
               !flatCustomApps.isEmpty {
                var nested = (serviceObject_[PrefKey.customApps] as? [String: Any]) ?? [:]
                nested.merge(flatCustomApps) { _, new in new }
                serviceObject![PrefKey.customApps] = nested
                migratedAny = true
            }
            keysToRemove.append(legacyCustomAppsKey)

            // `CustomServiceBL_<service>-<appID>` -> nested `appList`.
            let prefix = PrefKey.legacyCustomBlacklistPrefix + service + "-"
            let flatAppIDs = appIDs(in: prefs, prefix: prefix)
            if serviceObject != nil, !flatAppIDs.isEmpty {
                var appList = (serviceObject?[PrefKey.appList] as? [String]) ?? []
                for appID in flatAppIDs where !appList.contains(appID) {
                    appList.append(appID)
                }
                serviceObject?[PrefKey.appList] = appList
                migratedAny = true
            }
            keysToRemove.append(contentsOf: prefs.keys.filter {
                $0.hasPrefix(prefix) && !keysToRemove.contains($0)
            })

            if let serviceObject { customServices[service] = serviceObject }
        }

        // `migratedAny` only covers data moved into nested storage; a cleanup
        // that removed nothing but orphans still has to be written back.
        if !migratedAny {
            migratedAny = keysToRemove.contains { prefs[$0] != nil }
        }
        guard migratedAny else { return prefs }

        var updated = prefs.raw
        updated[PrefKey.customServices] = customServices
        for key in keysToRemove { updated.removeValue(forKey: key) }

        PrefsStore.apply(updated, removing: keysToRemove)
        PusherLog.debug("Migrated legacy custom service prefs")
        return Prefs(updated)
    }

    // MARK: - Global settings

    /// Folds the legacy flat `GlobalBL-<appID>` and `GlobalAppListIsBlacklist`
    /// keys into `Global`.
    ///
    /// A blacklist entry stored as `NO` is an orphan left by the old toggle
    /// behavior (which wrote `NO` instead of removing the entry) and is dropped
    /// along with the rest of the prefix.
    public static func migrateGlobal(_ prefs: Prefs) -> Prefs {
        var keysToRemove: [String] = []
        var flatAppIDs: [String] = []
        var isBlacklist: Any?

        for key in prefs.keys {
            if key.hasPrefix(PrefKey.globalBlacklistPrefix) {
                if prefs.bool(key) {
                    flatAppIDs.append(String(key.dropFirst(PrefKey.globalBlacklistPrefix.count)))
                }
                keysToRemove.append(key)
            } else if key == PrefKey.legacyGlobalAppListIsBlacklist {
                isBlacklist = prefs[key]
                keysToRemove.append(key)
            }
        }
        guard !keysToRemove.isEmpty else { return prefs }

        var global = prefs.dict(PrefKey.global)?.raw ?? [:]
        var appList = (global[PrefKey.appList] as? [String]) ?? []
        for appID in flatAppIDs where !appList.contains(appID) {
            appList.append(appID)
        }
        if !appList.isEmpty { global[PrefKey.appList] = appList }

        if let isBlacklist {
            // Blacklist is the default, so only an explicit `NO` is stored.
            if Prefs([PrefKey.appListIsBlacklist: isBlacklist])
                .bool(PrefKey.appListIsBlacklist, default: true) {
                global.removeValue(forKey: PrefKey.appListIsBlacklist)
            } else {
                global[PrefKey.appListIsBlacklist] = isBlacklist
            }
        }

        var updated = prefs.raw
        updated[PrefKey.global] = global
        for key in keysToRemove { updated.removeValue(forKey: key) }

        PrefsStore.apply(updated, removing: keysToRemove)
        PusherLog.debug("Migrated legacy global prefs")
        return Prefs(updated)
    }
}
