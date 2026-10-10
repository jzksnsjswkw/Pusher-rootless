import UIKit

/// The "Sufficient Notification Settings" page.
///
/// A service can be told to only fire when the app's *own* notification settings
/// meet certain conditions — for example "only when Allow Notifications is on".
/// This page is the editor for those conditions, and for the two flags that
/// change how they combine (AND vs OR, and whether OR requires Allow
/// Notifications).
///
/// The page serves both a service's own copy and the global default. The service
/// copy additionally offers "Synchronize With Global", which deletes the
/// service's overrides so it follows the global values again.
///
/// ## Why the cells are built here rather than loaded from a plist
///
/// They used to come from `SNS.plist`, with their storage redirected afterwards.
/// That is the one arrangement this page cannot use, and the reason is in the
/// framework: a switch cell's action is taken from the specifier's `setter` when
/// the cell is *created*, and a cell loaded from a plist is created with the
/// plist's own `defaults` domain instead. Redirecting the storage afterwards
/// leaves the cell's action pointing at something that does not exist, and the
/// first tap ends in `doesNotRecognizeSelector:`.
///
/// So the cells are constructed with `preferenceSpecifierNamed(target:set:get:)`,
/// which is how every other page in this project builds a value cell — and is the
/// one form where the setter is part of the constructor rather than something
/// patched in later.
@objc(NSPSNSListController)
public final class SNSListController: ListController {
    private var instanceID: String?
    /// Whether this page edits a service (as opposed to the global defaults).
    private var isServiceMode = false
    private var synchronizeButton: PSSpecifier?

    /// No plist: see the note on the class.
    public override var specifierPlistName: String? { nil }

    public override func viewDidLoad() {
        super.viewDidLoad()

        // The "service" property is a string for a service page and absent for
        // the global page, which is what distinguishes the two.
        instanceID = specifier?.string(SpecifierRouting.PropertyKey.instanceID)
        isServiceMode = instanceID != nil

        installSpecifiers(buildSpecifiers())
    }

    /// Rebuilds the page when the framework discards its cells.
    public override func rebuildSpecifiers() -> NSMutableArray? {
        buildSpecifiers()
    }

    // MARK: - The conditions

    /// One row of the page: a condition, or one of the two flags.
    ///
    /// Declared here rather than in a plist so that the label, the key and the
    /// default travel together, and so a reader can see the whole page in one
    /// screen of source.
    private struct Condition {
        let label: String
        let key: String
        /// Whether the condition is on when nothing is stored.
        let defaultValue: Bool
        /// A section heading before this row, if it starts one.
        var groupFooter: String?
        /// The titles and values of a segment, for the AND/OR row.
        var segment: (titles: [String], values: [Any])?
    }

    private var conditions: [Condition] {
        [
            Condition(
                label: "",
                key: PrefKey.snsIsAnd,
                defaultValue: true,
                groupFooter: ("Each app has custom notification settings that determine where "
                    + "their notifications are allowed to show (in Settings → Notifications). "
                    + "This menu lets you require that either all (AND) or at least one (OR) of "
                    + "the options below is enabled in the app's settings.").localized,
                segment: (titles: ["AND (all)", "OR (any)"], values: [true, false])
            ),
            Condition(
                label: "Require Allow Notifications with OR".localized,
                key: PrefKey.snsRequireANWithOR,
                defaultValue: true,
                groupFooter: ("When using OR, you will probably want to require that Allow "
                    + "Notifications is enabled as well. The device keeps the other settings "
                    + "(Lock Screen, Badges, …) even when an app's notifications are turned off "
                    + "entirely, so OR alone would let those apps through. Leave this on unless "
                    + "you have a reason not to.").localized
            ),
            Condition(
                label: "Allow Notifications".localized,
                key: SNSCondition.allowNotifications.rawValue,
                defaultValue: true
            ),
            Condition(
                label: "Lock Screen".localized,
                key: SNSCondition.lockScreen.rawValue,
                defaultValue: false,
                groupFooter: "Shows Previews works when it is set to Always or When Unlocked."
                    .localized
            ),
            Condition(
                label: "Notification Center".localized,
                key: SNSCondition.notificationCenter.rawValue,
                defaultValue: false
            ),
            Condition(
                label: "Banners".localized,
                key: SNSCondition.banners.rawValue,
                defaultValue: false
            ),
            Condition(
                label: "Badges".localized,
                key: SNSCondition.badges.rawValue,
                defaultValue: false
            ),
            Condition(
                label: "Sounds".localized,
                key: SNSCondition.sounds.rawValue,
                defaultValue: false
            ),
            Condition(
                label: "Shows Previews".localized,
                key: SNSCondition.showsPreviews.rawValue,
                defaultValue: false
            ),
        ]
    }

    /// The page's cells.
    private func buildSpecifiers() -> NSMutableArray {
        let all = NSMutableArray()

        if isServiceMode {
            let (group, button) = synchronizeControls(isSynchronized: isSynchronized)
            all.add(group)
            all.add(button)
        }

        for condition in conditions {
            if let footer = condition.groupFooter {
                let group = PSSpecifier.emptyGroup()!
                group.setProperty(footer, forKey: "footerText")
                all.add(group)
            }

            guard let cell = valueCell(for: condition) else { continue }
            all.add(cell)
        }

        return all
    }

    /// Builds the one cell a condition needs.
    ///
    /// The selector pair is passed to the initialiser rather than written onto the
    /// specifier afterwards. That is not a style preference: a switch cell looks up
    /// its action from `target`/`setter` *when it is constructed*, so a pair
    /// installed later is a pair the cell never sees.
    private func valueCell(for condition: Condition) -> PSSpecifier? {
        // Both pages use the same two accessors, which forward to the global
        // store when the page is the global one. One pair rather than two means
        // the AND/OR companions are kept in step on both, which is where the
        // two page variants drifted apart before.
        let setter = #selector(setPreferenceValue(_:specifier:))
        let getter = #selector(readPreferenceValue(_:))

        if let segment = condition.segment {
            guard let cell = PSSpecifier.preferenceSpecifierNamed(
                condition.key, target: self, set: setter, get: getter,
                detail: nil, cell: .segmentCell, edit: nil
            ) else { return nil }
            cell.identifier = condition.key
            cell.setProperty(condition.key, forKey: SpecifierRouting.PropertyKey.key)
            cell.setProperty(NSNumber(value: condition.defaultValue),
                            forKey: SpecifierRouting.PropertyKey.defaultValue)
            var values: [Any] = segment.values
            var titles = segment.titles
            // A leading "Default" whose value is the sentinel: an untouched
            // segment stores nothing, so the service keeps following the global.
            if isServiceMode {
                values.insert(NSNumber(value: segmentCellDefault), at: 0)
                titles.insert("Default".localized, at: 0)
                cell.setProperty(NSNumber(value: segmentCellDefault),
                                forKey: SpecifierRouting.PropertyKey.defaultValue)
            }

            // Localized here rather than by `localize(_:)`, which works from
            // `validTitles` — a property this cell does not read.
            titles = titles.map(\.localized)

            // `setValues:titles:` — the real Objective-C setter, which is what
            // fills the ivars the cell reads. `setProperty:forKey:` would not:
            // that writes the specifier's `properties` **dictionary**, and a
            // segment cell reads `[specifier values]` and
            // `[specifier titleDictionary]`, which are ivars at two other offsets.
            // Writing the dictionary left both empty, so the control had no
            // segments at all — which is what a missing option list looks like.
            cell.setValues(values, titles: titles)
            stampIdentity(on: cell)
            return cell
        }

        guard let cell = PSSpecifier.preferenceSpecifierNamed(
            condition.label, target: self, set: setter, get: getter,
            detail: nil, cell: .switchCell, edit: nil
        ) else { return nil }
        cell.identifier = condition.label
        cell.setProperty(condition.key, forKey: SpecifierRouting.PropertyKey.key)
        cell.setProperty(NSNumber(value: condition.defaultValue),
                        forKey: SpecifierRouting.PropertyKey.defaultValue)
        localize(cell)
        stampIdentity(on: cell)
        return cell
    }

    /// Puts the page's identity on a freshly built cell.
    ///
    /// `PreferencesStorage` finds the instance to write to from this property, so a
    /// cell without it is a cell whose writes are dropped in silence — the switch
    /// moves, the value goes nowhere, and re-entering shows it back where it was.
    ///
    /// Set here rather than after the fact because the cells are built in code: the
    /// framework would have stamped it for a plist-loaded cell, and there is no
    /// longer a plist to do that.
    private func stampIdentity(on cell: PSSpecifier) {
        // Told like every other page's cells: the observers that redraw a service
        // page after a change key on this, and a switch here changes what the
        // filter will do on the next notification.
        cell.setProperty(Pusher.prefsNotification, forKey: "PostNotification")
        guard let instanceID else { return }
        cell.setProperty(instanceID, forKey: SpecifierRouting.PropertyKey.instanceID)
    }

    // MARK: - The synchronize button

    /// Whether every condition currently holds the same value as the global.
    ///
    /// Compared by *value*, not by whether the service holds an override.
    ///
    /// The two answers differ in exactly one case, and it decided the design: a
    /// user toggles a switch and toggles it back. The stored override is then real
    /// but equal to the global, and the page shows the global's value — so as far
    /// as the user is concerned nothing changed, and a button reading "Synchronize
    /// With Global" that would remove nothing is the worse of the two
    /// contradictions. What the button is named is what it must be true of.
    private var isSynchronized: Bool {
        guard let instanceID else { return true }
        let stored = PrefsStore.instance(instanceID)
        let global = PrefsStore.global()
        // Through the same resolution the page reads with, so a value that is
        // absent on both sides counts as equal rather than as a difference.
        return conditions.allSatisfy { condition in
            resolved(condition.key, instance: stored) == resolved(condition.key, instance: global)
        }
    }

    /// One condition's effective value, as a comparable scalar.
    ///
    /// Booleans throughout: the segment's `true`/`false` and the sentinel for
    /// "follow the global" are the only values these keys take, and comparing an
    /// `NSNumber` to a `Bool` is how two equal settings come out as different.
    private func resolved(_ key: String, instance: Prefs) -> Bool {
        guard let value = instance[key] else {
            // Nothing stored: the condition's own default, which is also what the
            // global page shows for a switch it has never been given.
            return conditions.first { $0.key == key }?.defaultValue ?? false
        }
        return Prefs([key: value]).bool(key, default: false)
    }

    /// The synchronize button and its footer, built but not installed.
    ///
    /// A pair rather than two separate calls, because every place that installs one
    /// has to install the other.
    private func synchronizeControls(
        isSynchronized: Bool
    ) -> (group: PSSpecifier, button: PSSpecifier) {
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

        return (group, button)
    }

    /// Removes every condition override so the service follows the globals again.
    @objc public func synchronizeWithGlobal(_ specifier: PSSpecifier) {
        guard let instanceID else { return }
        PrefsStore.updateInstance(instanceID) { object in
            for condition in self.conditions {
                // The default value is stored as nothing, so "synchronized" is the
                // store with these keys simply absent.
                object.removeValue(forKey: condition.key)
            }
        }
        // Redrawn from the store rather than patched in place: the values shown now
        // have to come from the globals, which is what a rebuild reads.
        installSpecifiers(buildSpecifiers())
    }

    // MARK: - Value accessors

    /// Stores a condition, forwarding it to the right place for this page.
    ///
    /// Routed through the framework's own hook rather than a custom selector,
    /// because that is the pair a plist-free cell is built with and the one the
    /// framework knows.
    @objc(setPreferenceValue:specifier:)
    public override func setPreferenceValue(_ value: Any?, specifier: PSSpecifier) {
        guard isServiceMode else {
            PreferencesStorage.setValue(value, forGlobalSpecifier: specifier)
            // The global page has no synchronize button, but its change *is* the new
            // global, so a service's copy opened later reads it — nothing to do here
            // beyond keeping the two companions in step.
            mirrorCompanions(of: specifier, value: value)
            return
        }

        // The "Default" segment's sentinel means "follow the global", and storing it
        // would not: `NSNumber(-1).boolValue` is true, so a service following the
        // global would read as AND whatever the global says. Folded to nil here,
        // which is the store's own spelling of "no override".
        let normalized: Any? = (value as? NSNumber)?.intValue == segmentCellDefault
            ? nil : value

        PreferencesStorage.setValue(normalized, forInstanceSpecifier: specifier)
        mirrorCompanions(of: specifier, value: normalized)
        // Decided from what was just stored rather than assumed: an edit that puts
        // the value back where the global has it leaves nothing to synchronize, and
        // the button has to say so.
        refreshSynchronizeButton()
    }

    /// The value to show: the service's own override, or the global default.
    ///
    /// The fallback is the point of this page: a condition the service has not
    /// touched shows what it is currently following, so the user edits against what
    /// actually happens rather than against a blank cell.
    @objc(readPreferenceValue:)
    public override func readPreferenceValue(_ specifier: PSSpecifier) -> Any? {
        if isServiceMode, let instanceID,
           let key = specifier.string(SpecifierRouting.PropertyKey.key),
           let own = PrefsStore.instance(instanceID)[key] {
            return own
        }
        return PreferencesStorage.readValue(forGlobalSpecifier: specifier)
    }

    /// Re-reads the button's state from the store.
    ///
    /// Called after every write rather than set optimistically, because whether an
    /// edit makes the service diverge is a question only the store can answer — and
    /// it answered "no" in the case that prompted this: a switch toggled and
    /// toggled back.
    private func refreshSynchronizeButton() {
        guard let synchronizeButton else { return }
        let synchronized = isSynchronized
        synchronizeButton.name = (synchronized
            ? "Synchronized" : "Synchronize With Global").localized
        synchronizeButton.setProperty(!synchronized, forKey: "enabled")
        reloadSpecifier(synchronizeButton, animated: true)
    }

    /// Keeps the two conditions the AND/OR flag governs in step.
    ///
    /// The relationship belongs to the flag, not to the page it was set from, so
    /// this runs on both variants — it used to run only on the global one, and a
    /// service's copy then behaved differently for no reason a user could see.
    private func mirrorCompanions(of specifier: PSSpecifier, value: Any?) {
        guard specifier.string(SpecifierRouting.PropertyKey.key) == PrefKey.snsIsAnd
        else { return }

        // "Allow Notifications" is mirrored onto the AND flag.
        if let allow = cell(forCondition: SNSCondition.allowNotifications.rawValue) {
            allow.performSetter(withValue: value)
            reloadSpecifier(allow, animated: true)
        }
        // Turning AND *off* puts OR in play, where requiring the permission is what
        // keeps the filter from matching apps whose notifications are off entirely.
        let isAnd = (value as? NSNumber)?.boolValue ?? false
        if !isAnd, let requireAN = cell(forCondition: PrefKey.snsRequireANWithOR) {
            requireAN.performSetter(withValue: true)
            reloadSpecifier(requireAN, animated: true)
        }
    }

    /// The installed cell for a condition key.
    private func cell(forCondition key: String) -> PSSpecifier? {
        (super.specifiers as? [PSSpecifier])?
            .first { $0.string(SpecifierRouting.PropertyKey.key) == key }
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
