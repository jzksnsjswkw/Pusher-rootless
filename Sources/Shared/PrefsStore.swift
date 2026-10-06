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

    public static func builtInServices() -> Prefs { Prefs.from(value(forKey: PrefKey.builtInServices)) }
    public static func customServices() -> Prefs { Prefs.from(value(forKey: PrefKey.customServices)) }
    public static func global() -> Prefs { Prefs.from(value(forKey: PrefKey.global)) }

    // MARK: - One service

    /// One service's nested object, or an empty `Prefs` when it has none.
    public static func service(named name: String, isCustom: Bool) -> Prefs {
        guard !name.isEmpty else { return Prefs() }
        let container = isCustom ? customServices() : builtInServices()
        return container.dict(name) ?? Prefs()
    }

    /// Persist one service's nested object. A `nil` object removes the service
    /// from its container.
    public static func setService(_ object: [String: Any]?, named name: String, isCustom: Bool, notify: Bool = true) {
        guard !name.isEmpty else { return }
        var container = (isCustom ? customServices() : builtInServices()).raw
        if let object {
            container[name] = object
        } else {
            container.removeValue(forKey: name)
        }
        setValue(container, forKey: isCustom ? PrefKey.customServices : PrefKey.builtInServices, notify: notify)
    }

    /// Merge fields into one service's nested object, leaving other services
    /// untouched.
    public static func updateService(named name: String, isCustom: Bool, _ mutate: (inout [String: Any]) -> Void) {
        var object = service(named: name, isCustom: isCustom).raw
        mutate(&object)
        setService(object, named: name, isCustom: isCustom)
    }

    // MARK: - One per-app override inside a service

    public static func customAppPrefs(service name: String, appID: String, isCustom: Bool) -> Prefs {
        guard !appID.isEmpty else { return Prefs() }
        let servicePrefs = service(named: name, isCustom: isCustom)
        guard let customApps = servicePrefs.dict(PrefKey.customApps) else { return Prefs() }
        return customApps.dict(appID) ?? Prefs()
    }

    public static func setCustomAppPrefs(
        _ appPrefs: [String: Any]?,
        service name: String,
        appID: String,
        isCustom: Bool,
        notify: Bool = true
    ) {
        guard !appID.isEmpty else { return }
        updateService(named: name, isCustom: isCustom) { object in
            var customApps = (object[PrefKey.customApps] as? [String: Any]) ?? [:]
            if let appPrefs {
                customApps[appID] = appPrefs
            } else {
                customApps.removeValue(forKey: appID)
            }
            object[PrefKey.customApps] = customApps
        }
    }

    /// Replace a service's whole per-app override map (used by the
    /// "App Customization" UI when an entry is deleted).
    public static func setCustomApps(_ customApps: [String: Any], service name: String, isCustom: Bool) {
        updateService(named: name, isCustom: isCustom) { object in
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
