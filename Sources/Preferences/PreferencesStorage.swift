import UIKit

/// The preference accessors the routed specifiers call into.
///
/// The method names match the selectors installed by ``SpecifierRouting``, and
/// the class is the `target` those specifiers point at, so the Preferences
/// framework invokes these directly through `performSelector`.
///
/// Every accessor edits the storage of one *instance* inside the `Services`
/// array: `Services[i][key]`, or `Services[i][customApps][appID][key]` for a
/// per-app override. `appListIsBlacklist` defaults to `true`, so a `true` value
/// is removed rather than stored — reads then fall back to the default and prefs
/// stay clean.
@objc(NSPPreferencesStorage)
public final class PreferencesStorage: NSObject {

    // MARK: - One instance

    @objc(setValue:forInstanceSpecifier:)
    public static func setValue(_ value: Any?, forInstanceSpecifier specifier: PSSpecifier) {
        guard let id = specifier.string(SpecifierRouting.PropertyKey.instanceID) else { return }

        if specifier.bool(SpecifierRouting.PropertyKey.isCustomApp) {
            setCustomAppValue(value, specifier: specifier, id: id)
            return
        }

        guard let key = specifier.string(SpecifierRouting.PropertyKey.key) else { return }

        // A definition page's run-options and payload options edit the
        // *definition* — the same object every instance of the type seeds from.
        // Definitions live in their own array, so an instance lookup here would
        // silently write to nothing and the switch would never save.
        if specifier.bool(SpecifierRouting.PropertyKey.isDefinition) {
            CustomServiceStore.update(id: id) { object in
                if let value {
                    object[key] = value
                } else {
                    object.removeValue(forKey: key)
                }
            }
            // Told like any other write: a definition page carries the image
            // switch too, and returning here without this is what left its
            // sizing rows unable to follow it.
            notifyChangeObserver(of: specifier, key: key, value: value)
            return
        }

        let stored: Any?
        if let value, !isDefaultBool(key: key, value: value) {
            stored = value
        } else {
            stored = nil
        }
        PrefsStore.updateInstance(id) { object in
            if let stored {
                object[key] = stored
            } else {
                object.removeValue(forKey: key)
            }
        }

        // A cell that changes the page's *structure* says so, and the page is
        // told here, with **the value just stored** rather than one it looks up
        // again: this layer is the only place that knows it, and re-deriving it
        // would mean reading a preference file that may not have caught up, or a
        // cell the framework may not have updated yet.
        notifyChangeObserver(of: specifier, key: key, value: stored)
    }

    /// Tells the controller a cell named, if any, what it just changed to.
    private static func notifyChangeObserver(
        of specifier: PSSpecifier, key: String, value: Any?
    ) {
        guard let boxed = specifier.property(
            forKey: SpecifierRouting.PropertyKey.changeObserver
        ) as? NSValue else { return }
        let observer = boxed.nonretainedObjectValue as? NSObject
        let selector = NSSelectorFromString("cellDidChange:to:")
        guard let observer, observer.responds(to: selector) else { return }
        _ = observer.perform(selector, with: key, with: value)
    }

    @objc(readValueForInstanceSpecifier:)
    public static func readValue(forInstanceSpecifier specifier: PSSpecifier) -> Any? {
        guard let id = specifier.string(SpecifierRouting.PropertyKey.instanceID) else { return nil }

        if specifier.bool(SpecifierRouting.PropertyKey.isCustomApp) {
            return customAppValue(specifier: specifier, id: id)
        }

        guard let key = specifier.string(SpecifierRouting.PropertyKey.key) else { return nil }

        if specifier.bool(SpecifierRouting.PropertyKey.isDefinition) {
            return CustomServiceStore.rawEntry(id: id)[key] ?? specifier.storedDefault
        }

        let stored = PrefsStore.instance(id)
        if let value = stored[key] { return value }
        return specifier.storedDefault
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

    private static func setCustomAppValue(_ value: Any?, specifier: PSSpecifier, id: String) {
        guard let appID = specifier.string(SpecifierRouting.PropertyKey.customAppID),
              let key = specifier.string(SpecifierRouting.PropertyKey.key)
                ?? specifier.string(SpecifierRouting.PropertyKey.customAppsPrefsKey)
        else { return }

        var appPrefs = PrefsStore.customAppPrefs(service: id, appID: appID).raw
        if let value {
            appPrefs[key] = value
        } else {
            appPrefs.removeValue(forKey: key)
        }
        PrefsStore.setCustomAppPrefs(appPrefs, service: id, appID: appID)

        // An override page carries the same cells as the service page, so it has
        // the same switch and the same rows following it — and this path returns
        // before the instance write above ever runs, so without this the switch
        // would do nothing here.
        notifyChangeObserver(of: specifier, key: key, value: value)
    }

    private static func customAppValue(specifier: PSSpecifier, id: String) -> Any? {
        guard let appID = specifier.string(SpecifierRouting.PropertyKey.customAppID),
              let key = specifier.string(SpecifierRouting.PropertyKey.key)
                ?? specifier.string(SpecifierRouting.PropertyKey.customAppsPrefsKey)
        else { return nil }

        let appPrefs = PrefsStore.customAppPrefs(service: id, appID: appID)
        if let value = appPrefs[key] { return value }
        // Fall back to the instance-wide value so an override page opens showing
        // what the app currently inherits.
        let instancePrefs = PrefsStore.instance(id)
        return instancePrefs[key] ?? specifier.storedDefault
    }

    // MARK: - Helpers

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
/// A list belongs either to the global settings or to one instance, which is why
/// this is a pair of accessors rather than a single one.
public enum AppListStorage {
    public static func global() -> [String] {
        PrefsStore.global().stringArray(PrefKey.appList)
    }

    public static func setGlobal(_ appList: [String]) {
        PrefsStore.updateGlobal { $0[PrefKey.appList] = appList }
    }

    public static func forInstance(_ id: String) -> [String] {
        PrefsStore.instance(id).stringArray(PrefKey.appList)
    }

    public static func setForInstance(_ appList: [String], id: String) {
        PrefsStore.updateInstance(id) { $0[PrefKey.appList] = appList }
    }
}
