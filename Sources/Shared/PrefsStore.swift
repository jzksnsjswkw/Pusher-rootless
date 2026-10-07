import Foundation

/// Central `CFPreferences` access for the Pusher preference domain
/// (`com.noahsaso.pusher`).
///
/// The tweak core and the Preferences bundle read and write the same nested
/// `BuiltInServices` / `CustomServices` / `Global` layout, so raw plist I/O,
/// nested navigation and the post-write reload notification all live here in
/// one place. No UIKit / SpringBoard / Preferences dependencies, and every
/// accessor is nil-safe.
public enum PrefsStore {
    // MARK: - Raw access

    /// The value stored at a single top-level key.
    public static func value(forKey key: String) -> Any? {
        guard !key.isEmpty else { return nil }
        return CFPreferencesCopyValue(
            key as CFString,
            Pusher.appID as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
    }

    public static func setValue(_ value: Any?, forKey key: String, notify: Bool = true) {
        guard !key.isEmpty else { return }
        CFPreferencesSetValue(
            key as CFString,
            value as CFPropertyList?,
            Pusher.appID as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        synchronize()
        if notify { notifyPrefsChanged() }
    }

    /// A full snapshot of the domain, or `[:]` when it is empty.
    public static func snapshot() -> [String: Any] {
        guard let keys = CFPreferencesCopyKeyList(
            Pusher.appID as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String] else { return [:] }
        return CFPreferencesCopyMultiple(
            keys as CFArray,
            Pusher.appID as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String: Any] ?? [:]
    }

    /// A snapshot wrapped for guarded reads.
    public static func prefs() -> Prefs { Prefs(snapshot()) }

    /// Bulk write-back, optionally removing keys in the same cfprefsd
    /// transaction.
    public static func apply(_ values: [String: Any], removing keys: [String] = [], notify: Bool = true) {
        CFPreferencesSetMultiple(
            values as CFDictionary,
            keys.isEmpty ? nil : (keys as CFArray),
            Pusher.appID as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        synchronize()
        if notify { notifyPrefsChanged() }
    }

    public static func synchronize() {
        CFPreferencesSynchronize(
            Pusher.appID as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
    }

    /// Posts the Darwin notification the tweak observes to reload its config.
    public static func notifyPrefsChanged() {
        notify_post(Pusher.prefsNotification)
    }

    // MARK: - Nested containers

    public static func global() -> Prefs { Prefs.from(value(forKey: PrefKey.global)) }

    // MARK: - One service instance

    /// The stored objects of every configured instance, in order.
    ///
    /// Instances live in one array, so these accessors work on the array rather
    /// than on nested containers — and they do it without depending on the Core
    /// layer's instance model, which the Flipswitch bundle does not compile.
    public static func instances() -> [[String: Any]] {
        prefs().dictionaries(PrefKey.services).map(\.raw)
    }

    /// One instance's stored object, or an empty `Prefs` when it is gone.
    public static func instance(_ id: String) -> Prefs {
        guard !id.isEmpty else { return Prefs() }
        return instances()
            .first { Prefs($0).nonEmptyString(PrefKey.instanceID) == id }
            .map(Prefs.init) ?? Prefs()
    }

    /// Merge fields into one instance's stored object, leaving its identity and
    /// every other instance untouched.
    public static func updateInstance(_ id: String, notify: Bool = true, _ mutate: (inout [String: Any]) -> Void) {
        guard !id.isEmpty else { return }
        var stored = instances()
        guard let index = stored.firstIndex(where: {
            Prefs($0).nonEmptyString(PrefKey.instanceID) == id
        }) else { return }
        mutate(&stored[index])
        setValue(stored, forKey: PrefKey.services, notify: notify)
    }

    // MARK: - One per-app override inside an instance

    public static func customAppPrefs(service id: String, appID: String) -> Prefs {
        guard !appID.isEmpty else { return Prefs() }
        guard let customApps = instance(id).dict(PrefKey.customApps) else { return Prefs() }
        return customApps.dict(appID) ?? Prefs()
    }

    public static func setCustomAppPrefs(
        _ appPrefs: [String: Any]?,
        service id: String,
        appID: String,
        notify: Bool = true
    ) {
        guard !appID.isEmpty else { return }
        updateInstance(id, notify: notify) { object in
            var customApps = (object[PrefKey.customApps] as? [String: Any]) ?? [:]
            if let appPrefs {
                customApps[appID] = appPrefs
            } else {
                customApps.removeValue(forKey: appID)
            }
            object[PrefKey.customApps] = customApps
        }
    }

    /// Replace one instance's whole per-app override map (used by the
    /// "App Customization" UI when an entry is deleted).
    public static func setCustomApps(_ customApps: [String: Any], service id: String) {
        updateInstance(id) { object in
            object[PrefKey.customApps] = customApps
        }
    }

    // MARK: - Global settings

    public static func updateGlobal(_ mutate: (inout [String: Any]) -> Void) {
        var object = global().raw
        mutate(&object)
        setValue(object, forKey: PrefKey.global)
    }
}

/// Central `CFPreferences` access for the Pusher log domain
/// (`com.noahsaso.pusher~log`).
///
/// Both the tweak core and the Preferences log viewer read and write the same
/// per-service `<service>Log` arrays, so raw plist I/O and the reload
/// notification live here in one dependency-free place.
public enum LogStore {
    /// A full snapshot of the log domain.
    public static func snapshot() -> [String: Any] {
        CFPreferencesSynchronize(
            Pusher.logDomain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        guard let keys = CFPreferencesCopyKeyList(
            Pusher.logDomain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String] else { return [:] }
        return CFPreferencesCopyMultiple(
            keys as CFArray,
            Pusher.logDomain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String: Any] ?? [:]
    }

    /// One service's log sections. The empty service name is the global log.
    public static func logSections(forService service: String) -> [[String: Any]] {
        let key = PrefKey.logKey(forService: service)
        return snapshot()[key] as? [[String: Any]] ?? []
    }

    public static func setLogSections(_ sections: [[String: Any]], forService service: String, notify: Bool = true) {
        CFPreferencesSetValue(
            PrefKey.logKey(forService: service) as CFString,
            sections as CFPropertyList,
            Pusher.logDomain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        synchronize()
        if notify { notifyLogChanged() }
    }

    public static func removeLogs(forService service: String) {
        CFPreferencesSetValue(
            PrefKey.logKey(forService: service) as CFString,
            nil,
            Pusher.logDomain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        synchronize()
    }

    /// Remove every `<service>Log` key at once (the viewer's "Clear All Logs").
    public static func removeAllLogs() {
        let keys = snapshot().keys.filter { $0.hasSuffix("Log") }
        guard !keys.isEmpty else { return }
        for key in keys {
            CFPreferencesSetValue(
                key as CFString,
                nil,
                Pusher.logDomain as CFString,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
        }
        synchronize()
    }

    public static func synchronize() {
        CFPreferencesSynchronize(
            Pusher.logDomain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
    }

    public static func notifyLogChanged() {
        notify_post(Pusher.logPrefsNotification)
    }
}
