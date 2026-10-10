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
    private var instanceID: String?
    /// Whether this page edits a service (as opposed to the global defaults).
    private var isServiceMode = false
    private var synchronizeButton: PSSpecifier?

    public override var specifierPlistName: String? { "SNS" }

    public override func viewDidLoad() {
        super.viewDidLoad()

        // Installed here, not lazily: the framework reads the `_specifiers` ivar
        // directly rather than calling the `specifiers` getter.
        loadSpecifiersOnce(named: "SNS")

        // Every value cell is routed before anything reads it.
        //
        // Without this the cells keep the plist's `defaults` domain and the
        // framework writes their values to the *program's top-level* preferences —
        // which is where the global values live.
        // On a service's copy that meant the page edited the globals while the
        // service's own object stayed empty: nothing was ever an override, so the
        // synchronize button had nothing to report and nothing to remove, and
        // always said "Synchronized".
        if let loaded = super.specifiers as? [PSSpecifier] {
            route(loaded)
        }

        // The "service" property is a string for a service page and absent for
        // the global page, which is what distinguishes the two.
        instanceID = specifier?.string(SpecifierRouting.PropertyKey.instanceID)
        isServiceMode = instanceID != nil
        guard let instanceID, isServiceMode else { return }

        let specifiers = (super.specifiers as? [PSSpecifier]) ?? []

        // A service page falls back to the global value for any condition it
        // has not overridden. Whether *every* condition currently falls back is
        // what the synchronize button reports.
        var isSynchronized = true
        let servicePrefs = PrefsStore.instance(instanceID)
        for specifier in specifiers {
            specifier.setProperty(instanceID, forKey: SpecifierRouting.PropertyKey.instanceID)
            specifier.setProperty(true, forKey: SpecifierRouting.PropertyKey.isCustomApp)

            if isSynchronized, let key = specifier.string(SpecifierRouting.PropertyKey.key) {
                // The plist key is the display name, so the stored key is the
                // same string; a value present on the service means it has been
                // overridden.
                if servicePrefs[key] != nil || servicePrefs[specifier.identifier] != nil {
                    isSynchronized = false
                }
            }
        }

        insertSynchronizeControls(isSynchronized: isSynchronized)
    }

    /// Points each value cell at the store this page edits.
    ///
    /// A service's copy has to use *this page's* accessors rather than
    /// ``PreferencesStorage``'s, because three things happen on every write and
    /// only this page knows about them: it falls back to the global value when the
    /// service has no override, it keeps the two AND/OR companions in step, and it
    /// re-enables the synchronize button. The global page uses the ordinary global
    /// accessors, since it *is* the globals.
    private func route(_ specifiers: [PSSpecifier]) {
        for specifier in specifiers
        where !SpecifierRouting.excludedCellTypes.contains(specifier.cellType) {
            specifier.target = self
            specifier.setProperty(instanceID, forKey: SpecifierRouting.PropertyKey.instanceID)
            specifier.setProperty(true, forKey: SpecifierRouting.PropertyKey.isCustomApp)
            if isServiceMode {
                specifier.setSetter("setValue:specifier:")
                specifier.setGetter("readValue:")
            } else {
                specifier.setSetter(SpecifierRouting.Selector.setGlobal)
                specifier.setGetter(SpecifierRouting.Selector.getGlobal)
            }
        }
    }

    /// Adds the synchronize button and its explanatory footer at the top.
    private func insertSynchronizeControls(isSynchronized: Bool) {
        let group = PSSpecifier.emptyGroup()!
        group.setProperty(
            ("Synchronizes all values with the global preferences. Modifying any "
                + "of these settings will override that preference, but synchronizing "
                + "will remove the override and follow the global preferences again.")
                .localized,
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
            // The global page: these cells *are* the globals, so the ordinary
            // global accessor is right — the plist's own domain would work too,
            // but routing it keeps one path for every stored value.
            PreferencesStorage.setValue(value, forGlobalSpecifier: specifier)

            // The AND/OR flag also drives two other conditions, so changing it
            // updates them here rather than relying on the user to do it.
            if specifier.identifier?.contains(PrefKey.snsIsAnd) == true {
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

        PreferencesStorage.setValue(value, forInstanceSpecifier: specifier)

        // The AND/OR flag drives two other conditions on a service's copy as well
        // as on the global page — the relationship is a property of the flag, not
        // of which page it was set from.
        guard specifier.identifier?.contains(PrefKey.snsIsAnd) == true else { return }
        // "Allow Notifications" is mirrored onto the AND flag: requiring
        // notifications to be allowed is what AND means.
        if let allow = self.specifier(forID: "Allow Notifications".localized) {
            allow.performSetter(withValue: value)
            reloadSpecifier(allow, animated: true)
        }
        // Turning AND *off* means OR is now in play, where requiring the permission
        // is what keeps the filter from matching apps whose notifications are
        // switched off entirely.
        let isAnd = (value as? NSNumber)?.boolValue ?? false
        if !isAnd, let requireAN = self.specifier(
            forID: "Require Allow Notifications with OR".localized
        ) {
            requireAN.performSetter(withValue: true)
            reloadSpecifier(requireAN, animated: true)
        }
    }

    /// The value to show: the service's own override, or the global default.
    ///
    /// The fallback is the whole point of this page. A condition the service has
    /// not touched shows what it is *currently* following, so the user is editing
    /// against what actually happens rather than against a blank cell. Which of
    /// the two a value came from is what the synchronize button reports, and it is
    /// decided by whether the service holds the key — not by comparing values: a
    /// deliberate override that happens to equal the global is still an override,
    /// and removing it is still something the button should be able to do.
    @objc public func readValue(_ specifier: PSSpecifier) -> Any? {
        guard isServiceMode else { return super.readPreferenceValue(specifier) }
        let id = specifier.string(SpecifierRouting.PropertyKey.instanceID) ?? ""
        let key = specifier.string(SpecifierRouting.PropertyKey.key)
        if let key, let own = PrefsStore.instance(id)[key] { return own }
        return PreferencesStorage.readValue(forGlobalSpecifier: specifier)
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
            specifier.name = AppListTitle.titled(
                AppListTitle.baseName(of: specifier.name), count: AppListStorage.global().count
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
