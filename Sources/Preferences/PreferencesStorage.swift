import UIKit

/// The preference accessors the routed specifiers call into.
///
/// The method names match the selectors installed by ``SpecifierRouting``, and
/// the class is the `target` those specifiers point at, so the Preferences
/// framework invokes these directly through `performSelector`.
///
/// Every accessor edits the *nested* storage for its page:
/// `BuiltInServices[service][key]`, `CustomServices[service][key]`,
/// `CustomServices[service][customApps][appID][key]` or `Global[key]`.
/// `appListIsBlacklist` defaults to `true`, so a `true` value is removed rather
/// than stored — reads then fall back to the default and prefs stay clean.
@objc(NSPPreferencesStorage)
public final class PreferencesStorage: NSObject {

    // MARK: - Built-in services

    @objc(setValue:forBuiltInServiceSpecifier:)
    public static func setValue(_ value: Any?, forBuiltInServiceSpecifier specifier: PSSpecifier) {
        guard let service = specifier.string(SpecifierRouting.PropertyKey.service) else { return }

        if specifier.bool(SpecifierRouting.PropertyKey.isCustomApp) {
            setCustomAppValue(value, specifier: specifier, isCustomService: false)
            return
        }

        let key = specifier.string(SpecifierRouting.PropertyKey.key)
            ?? specifier.string(SpecifierRouting.PropertyKey.customServiceKey)
        guard let key else { return }

        PrefsStore.updateService(named: service, isCustom: false) { object in
            if let value, !isDefaultBool(key: key, value: value) {
                object[key] = value
            } else {
                object.removeValue(forKey: key)
            }
        }
    }

    @objc(readValueForBuiltInServiceSpecifier:)
    public static func readValue(forBuiltInServiceSpecifier specifier: PSSpecifier) -> Any? {
        guard let service = specifier.string(SpecifierRouting.PropertyKey.service) else { return nil }

        if specifier.bool(SpecifierRouting.PropertyKey.isCustomApp) {
            return customAppValue(specifier: specifier, isCustomService: false)
        }

        let key = specifier.string(SpecifierRouting.PropertyKey.key)
            ?? specifier.string(SpecifierRouting.PropertyKey.customServiceKey)
        guard let key else { return nil }
        return storedValue(service: service, isCustom: false, key: key, specifier: specifier)
    }

    // MARK: - Custom services

    @objc(setValue:forCustomSpecifier:)
    public static func setValue(_ value: Any?, forCustomSpecifier specifier: PSSpecifier) {
        guard let service = specifier.string(SpecifierRouting.PropertyKey.service) else { return }

        if specifier.bool(SpecifierRouting.PropertyKey.isCustomApp) {
            setCustomAppValue(value, specifier: specifier, isCustomService: true)
            return
        }

        guard let key = specifier.string(SpecifierRouting.PropertyKey.key) else { return }
        PrefsStore.updateService(named: service, isCustom: true) { object in
            if let value, !isDefaultBool(key: key, value: value) {
                object[key] = value
            } else {
                object.removeValue(forKey: key)
            }
        }
    }

    @objc(readValueForCustomSpecifier:)
    public static func readValue(forCustomSpecifier specifier: PSSpecifier) -> Any? {
        guard let service = specifier.string(SpecifierRouting.PropertyKey.service) else { return nil }

        if specifier.bool(SpecifierRouting.PropertyKey.isCustomApp) {
            return customAppValue(specifier: specifier, isCustomService: true)
        }

        guard let key = specifier.string(SpecifierRouting.PropertyKey.key) else { return nil }
        return storedValue(service: service, isCustom: true, key: key, specifier: specifier)
    }

    // MARK: - Global settings

    @objc(setValue:forGlobalSpecifier:)
    public static func setValue(_ value: Any?, forGlobalSpecifier specifier: PSSpecifier) {
        guard let key = specifier.string(SpecifierRouting.PropertyKey.key) else { return }
        PrefsStore.updateGlobal { object in
            if let value, !isDefaultBool(key: key, value: value) {
                object[key] = value
            } else {
                object.removeValue(forKey: key)
            }
        }
    }

    @objc(readValueForGlobalSpecifier:)
    public static func readValue(forGlobalSpecifier specifier: PSSpecifier) -> Any? {
        guard let key = specifier.string(SpecifierRouting.PropertyKey.key) else { return nil }
        if let value = PrefsStore.global()[key] { return value }
        return specifier.storedDefault
    }

    // MARK: - Per-app overrides

    private static func setCustomAppValue(
        _ value: Any?,
        specifier: PSSpecifier,
        isCustomService: Bool
    ) {
        guard let service = specifier.string(SpecifierRouting.PropertyKey.service),
              let appID = specifier.string(SpecifierRouting.PropertyKey.customAppID),
              let key = specifier.string(SpecifierRouting.PropertyKey.key)
                ?? specifier.string(SpecifierRouting.PropertyKey.customAppsPrefsKey)
        else { return }

        var appPrefs = PrefsStore.customAppPrefs(
            service: service, appID: appID, isCustom: isCustomService
        ).raw
        if let value {
            appPrefs[key] = value
        } else {
            appPrefs.removeValue(forKey: key)
        }
        PrefsStore.setCustomAppPrefs(
            appPrefs, service: service, appID: appID, isCustom: isCustomService
        )
    }

    private static func customAppValue(specifier: PSSpecifier, isCustomService: Bool) -> Any? {
        guard let service = specifier.string(SpecifierRouting.PropertyKey.service),
              let appID = specifier.string(SpecifierRouting.PropertyKey.customAppID),
              let key = specifier.string(SpecifierRouting.PropertyKey.key)
                ?? specifier.string(SpecifierRouting.PropertyKey.customAppsPrefsKey)
        else { return nil }

        let appPrefs = PrefsStore.customAppPrefs(
            service: service, appID: appID, isCustom: isCustomService
        )
        if let value = appPrefs[key] { return value }
        // Fall back to the service-wide value so an override page opens showing
        // what the app currently inherits.
        let servicePrefs = PrefsStore.service(named: service, isCustom: isCustomService)
        return servicePrefs[key] ?? specifier.storedDefault
    }

    // MARK: - Helpers

    /// Reads one stored key, falling back to the cell's `globalKey` and then to
    /// its declared default.
    private static func storedValue(
        service: String,
        isCustom: Bool,
        key: String,
        specifier: PSSpecifier
    ) -> Any? {
        let servicePrefs = PrefsStore.service(named: service, isCustom: isCustom)
        if let value = servicePrefs[key] { return value }
        // Cells whose value predates the nested layout (or lives at the top
        // level by design) name a fallback key.
        if let globalKey = specifier.string(SpecifierRouting.PropertyKey.globalKey),
           let value = PrefsStore.value(forKey: globalKey) {
            return value
        }
        return specifier.storedDefault
    }

    /// `appListIsBlacklist` defaults to `true`, so storing `true` is a no-op and
    /// the entry is dropped instead (reads fall back to the default).
    private static func isDefaultBool(key: String, value: Any) -> Bool {
        guard key == PrefKey.appListIsBlacklist else { return false }
        return Prefs([key: value]).bool(key, default: true)
    }
}

// MARK: - App lists

/// The app-list accessors the app selection controllers use.
///
/// The lists live in three different places depending on which page is open
/// (global, a built-in service, or a custom service), which is why they are not
/// a single accessor pair.
public enum AppListStorage {
    public static func global() -> [String] {
        PrefsStore.global().stringArray(PrefKey.appList)
    }

    public static func setGlobal(_ appList: [String]) {
        PrefsStore.updateGlobal { $0[PrefKey.appList] = appList }
    }

    public static func builtIn(service: String) -> [String] {
        PrefsStore.service(named: service, isCustom: false).stringArray(PrefKey.appList)
    }

    public static func setBuiltIn(_ appList: [String], service: String) {
        PrefsStore.updateService(named: service, isCustom: false) { $0[PrefKey.appList] = appList }
    }

    public static func custom(service: String) -> [String] {
        PrefsStore.service(named: service, isCustom: true).stringArray(PrefKey.appList)
    }

    public static func setCustom(_ appList: [String], service: String) {
        PrefsStore.updateService(named: service, isCustom: true) { $0[PrefKey.appList] = appList }
    }
}
