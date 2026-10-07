import UIKit

/// The "Sufficient Notification Settings" page.
///
/// A service can be told to only fire when the app's *own* notification settings
/// meet certain conditions — for example "only when Allow Notifications is on".
/// This page is the editor for those conditions, and for the two flags that
/// change how they combine (AND vs OR, and whether OR requires Allow
/// Notifications).
///
/// The page serves both a service's own copy and the global default. The
/// service copy additionally offers "Synchronize With Global", which deletes the
/// service's overrides so it follows the global values again.
@objc(NSPSNSListController)
public final class SNSListController: ListController {
    private var service: String?
    private var isCustomService = false
    /// Whether this page edits a service (as opposed to the global defaults).
    private var isServiceMode = false
    private var synchronizeButton: PSSpecifier?

    public override var specifierPlistName: String? { "SNS" }

    public override func viewDidLoad() {
        super.viewDidLoad()

        // Installed here, not lazily: the framework reads the `_specifiers` ivar
        // directly rather than calling the `specifiers` getter.
        loadSpecifiersOnce(named: "SNS")

        // The "service" property is a string for a service page and absent for
        // the global page, which is what distinguishes the two.
        service = specifier?.string(SpecifierRouting.PropertyKey.service)
        isServiceMode = service != nil
        guard let service, isServiceMode else { return }

        isCustomService = specifier?.bool(SpecifierRouting.PropertyKey.isCustomService) ?? false
        let specifiers = (super.specifiers as? [PSSpecifier]) ?? []

        // A service page falls back to the global value for any condition it
        // has not overridden. Whether *every* condition currently falls back is
        // what the synchronize button reports.
        var isSynchronized = true
        let servicePrefs = PrefsStore.service(named: service, isCustom: isCustomService)
        for specifier in specifiers {
            specifier.setProperty(service, forKey: SpecifierRouting.PropertyKey.service)
            specifier.setProperty(isCustomService, forKey: SpecifierRouting.PropertyKey.isCustomService)
            specifier.setProperty(true, forKey: SpecifierRouting.PropertyKey.isCustomApp)

            if isSynchronized, let key = specifier.string(SpecifierRouting.PropertyKey.key) {
                // The plist key is the display name, so the stored key is the
                // same string; a value present on the service means it has been
                // overridden.
                if servicePrefs[key] != nil || servicePrefs[specifier.identifier] != nil {
                    isSynchronized = false
                }
            }

            // The global fallback lookup uses the plist's own key name.
            if let key = specifier.string(SpecifierRouting.PropertyKey.key) {
                specifier.setProperty(key, forKey: SpecifierRouting.PropertyKey.globalKey)
            }
        }

        insertSynchronizeControls(isSynchronized: isSynchronized)
    }

    /// Adds the synchronize button and its explanatory footer at the top.
    private func insertSynchronizeControls(isSynchronized: Bool) {
        let group = PSSpecifier.emptyGroup()!
        group.setProperty(
            "Synchronizes all values with the global preferences. Modifying any of these "
                .localized + "settings will override that preference, but synchronizing will remove "
                .localized + "the override and follow the global preferences again.".localized,
            forKey: "footerText"
        )

        let button = PSSpecifier.preferenceSpecifierNamed(
            isSynchronized ? "Synchronized".localized : "Synchronize With Global".localized,
            target: self, set: nil, get: nil, detail: nil, cell: .buttonCell, edit: nil
        )!
        button.buttonAction = #selector(synchronizeWithGlobal(_:))
        button.setProperty(!isSynchronized, forKey: "enabled")
        synchronizeButton = button

        insertSpecifier(group, at: 0)
        insertSpecifier(button, at: 1)
    }

    /// Removes every condition override so the service follows the globals again.
    @objc public func synchronizeWithGlobal(_ specifier: PSSpecifier) {
        for case let spec as PSSpecifier in (super.specifiers ?? []) {
            // Group/button cells have no key and no stored value.
            guard spec.property(forKey: SpecifierRouting.PropertyKey.key) != nil else { continue }
            spec.performSetter(withValue: nil)
            reloadSpecifier(spec, animated: true)
        }
        specifier.name = "Synchronized".localized
        specifier.setProperty(false, forKey: "enabled")
        reloadSpecifier(specifier, animated: true)
    }

    // MARK: - Value accessors

    /// Stores a condition, forwarding it to the right storage for this page.
    ///
    /// The global page keeps the plist's native flat keys (they *are* the global
    /// defaults); a service page routes into the service's nested object and
    /// re-enables the synchronize button, since the value is now an override.
    @objc public func setValue(_ value: Any?, specifier: PSSpecifier) {
        if !isServiceMode {
            super.setPreferenceValue(value, specifier: specifier)

            // The AND/OR flag also drives two other conditions, so changing it
            // updates them here rather than relying on the user to do it.
            if specifier.identifier?.contains("SufficientNotificationSettingsIsAnd") == true {
                // "Allow Notifications" is mirrored onto the AND flag.
                if let allow = self.specifier(forID: "Allow Notifications".localized) {
                    allow.performSetter(withValue: value)
                    reloadSpecifier(allow, animated: true)
                }
                // Turning AND *off* means OR is now in play, where "Require
                // Allow Notifications with OR" is what keeps the filter from
                // matching apps with notifications switched off entirely.
                let isAnd = (value as? NSNumber)?.boolValue ?? false
                if !isAnd, let requireAN = self.specifier(
                    forID: "Require Allow Notifications with OR".localized
                ) {
                    requireAN.performSetter(withValue: true)
                    reloadSpecifier(requireAN, animated: true)
                }
            }
            return
        }

        // Any edit makes this page out of sync with the globals.
        if let synchronizeButton {
            synchronizeButton.name = "Synchronize With Global".localized
            synchronizeButton.setProperty(true, forKey: "enabled")
            reloadSpecifier(synchronizeButton, animated: true)
        }

        if isCustomService {
            PreferencesStorage.setValue(value, forCustomSpecifier: specifier)
        } else {
            PreferencesStorage.setValue(value, forBuiltInServiceSpecifier: specifier)
        }
    }

    @objc public func readValue(_ specifier: PSSpecifier) -> Any? {
        guard isServiceMode else { return super.readPreferenceValue(specifier) }
        return isCustomService
            ? PreferencesStorage.readValue(forCustomSpecifier: specifier)
            : PreferencesStorage.readValue(forBuiltInServiceSpecifier: specifier)
    }
}

// MARK: - Global settings

/// The global settings page: the app list, plus the default device conditions.
@objc(NSPGlobalSettingsListController)
public final class GlobalSettingsListController: ListController {
    public override func viewDidLoad() {
        super.viewDidLoad()
        buildSpecifiers()
    }

    /// The page's cells are two plists combined; see `rebuildSpecifiers()`.
    private var builtSpecifiers: NSMutableArray?

    /// Rebuilds both plists into one array when the framework discards them.
    public override func rebuildSpecifiers() -> NSMutableArray? {
        builtSpecifiers
    }

    private func buildSpecifiers() {
        guard !hasInstalledSpecifiers else { return }

        let appList = (loadSpecifiers(named: "GlobalAppList") as? [PSSpecifier]) ?? []
        let conditions = (loadSpecifiers(named: "GlobalAndServices") as? [PSSpecifier]) ?? []

        // The app-list cells are stored nested under `Global[appList]`, while
        // the condition cells (`WhenToPush` / `WhatNetwork`) *are* the global
        // defaults and keep their flat top-level keys.
        SpecifierRouting.route(appList, to: PreferencesStorage.self, scope: .global)

        let all = appList + conditions
        for specifier in all
        where specifier.cellType == .linkCell && specifier.name == "Global App List".localized {
            specifier.name = String(
                format: "%@ (%d total)".localized, specifier.name, AppListStorage.global().count
            )
            // A non-retaining back-reference: a strong one would retain the page.
            specifier.setProperty(
                NSValue(nonretainedObject: self), forKey: SpecifierRouting.PropertyKey.listReference
            )
            break
        }

        builtSpecifiers = NSMutableArray(array: all)
        installSpecifiers(builtSpecifiers!)
    }
}
