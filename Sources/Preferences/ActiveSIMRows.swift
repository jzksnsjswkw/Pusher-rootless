import Foundation
import UIKit

/// The SIM name cells shown inside Global Settings.
///
/// Two cells and a button, built here rather than on a page of their own: a
/// nickname is one short string, and a whole sub-page for two of them is more
/// navigation than the setting deserves.
///
/// The number is not editable. It is read from CoreTelephony — which is what
/// identifies the card in the first place — and typed-in numbers were the reason
/// this page used to fail: a hand-entered value that no longer matched the device
/// made every message unrecognisable. It is still shown, so the two names can be
/// told apart at a glance, but only the name is the user's to set.
enum ActiveSIMRows {
    /// The slots the page shows, in order.
    public static let slots = [1, 2]

    private enum Key {
        static let namePrefix = "globalSIMName"
        static let fetchRow = "globalSIMFetch"
    }

    /// The cells to append to Global Settings: one group, two name fields, a button.
    static func rows(target: AnyObject) -> [PSSpecifier] {
        let group = PSSpecifier.groupSpecifier(withName: "")
        group?.setProperty(
            "短信到达时显示收件卡槽的名字。点「获取」用手机号填入。".localized,
            forKey: "footerText"
        )

        // The name cells read and write global preferences through the shared
        // routing, the same way every other global value cell does. The button is
        // left alone: its `buttonAction` is sent to `target`.
        let names = [nameRow(slot: 1), nameRow(slot: 2)]
        SpecifierRouting.route(names, to: PreferencesStorage.self, scope: .global)

        return ([group] + names + [fetchButton(target: target)]).compactMap { $0 }
    }

    // MARK: - Rows

    private static func nameRow(slot: Int) -> PSSpecifier {
        // No setter or getter: the framework reads and writes the cell by `key`,
        // which is the storage itself. A `set:` selector is invoked as an instance
        // message on the specifier's target, so pointing it at a class method
        // silently fails to send — that is what made typing crash.
        let row = PSSpecifier.preferenceSpecifierNamed(
            slot == 1 ? "卡 1".localized : "卡 2".localized, target: nil,
            set: nil, get: nil,
            detail: nil, cell: .editTextCell, edit: nil
        )!
        row.identifier = Key.namePrefix + "\(slot)"
        // The storage key *is* the specifier's key: `PreferencesStorage` reads and
        // writes `global[specifier.key]` directly, so no per-row code is needed and
        // nothing has to be looked up by slot at edit time.
        row.setProperty(PrefKey.simNameKey(slot: slot), forKey: "key")
        row.setProperty(true, forKey: "enabled")
        // The placeholder shows the card's number, so an empty field still says
        // which one it is.
        let placeholder = SIMSubscriptions.subscription(forSlot: slot)?.phoneNumber ?? ""
        if !placeholder.isEmpty { row.setProperty(placeholder, forKey: "placeholder") }
        return row
    }

    static func fetchButton(target: AnyObject) -> PSSpecifier {
        let row = PSSpecifier.preferenceSpecifierNamed(
            "获取".localized, target: target,
            set: nil, get: nil, detail: nil, cell: .buttonCell, edit: nil
        )!
        // `buttonAction` is an ObjC ivar rather than a property, and `PSButtonCell`
        // sends it with one argument.
        row.buttonAction = #selector(GlobalSettingsListController.fetchSIMNumbers(_:))
        row.setProperty(true, forKey: "enabled")
        row.identifier = Key.fetchRow
        return row
    }

    /// Reads the device's current SIMs and writes each number into its name.
    ///
    /// An unconditional overwrite. The button is the answer to "this is wrong, show
    /// me what the device actually has" — refusing to replace a value would make it
    /// useless exactly when it is needed. The number is used rather than the
    /// system's label because the label is often blank, and an empty name would
    /// leave the push saying "slot 2" and nothing else.
    static func fillNamesFromDevice() {
        let sims = SIMSubscriptions.refreshed()
        PrefsStore.updateGlobal { global in
            for slot in ActiveSIMRows.slots {
                let match = sims.first { $0.slot == slot }
                global[PrefKey.simNumberKey(slot: slot)] = match?.phoneNumber ?? ""
                global[PrefKey.simNameKey(slot: slot)] = match?.phoneNumber ?? ""
            }
        }
    }

}
