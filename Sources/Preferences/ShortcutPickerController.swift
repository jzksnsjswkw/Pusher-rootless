import UIKit

/// Picks which Shortcut a service instance runs.
///
/// The list comes from the device itself, so a name can only be chosen from
/// shortcuts that exist. That matters more here than for most pickers: a
/// mistyped name fails at push time, in the background, and the only trace is a
/// log line — so the choice is made from a list rather than typed.
@objc(NSPShortcutPickerController)
public final class ShortcutPickerController: ListController {

    /// Every shortcut name on the device.
    private var names: [String] = []

    /// The instance whose shortcut is being chosen.
    private var instanceID: String?

    public override init(nibName: String?, bundle: Bundle?) {
        super.init(nibName: nibName, bundle: bundle)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override init(forContentSize size: CGSize) {
        super.init(forContentSize: size)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        instanceID = specifier?.string(SpecifierRouting.PropertyKey.instanceID)
        title = "Shortcut".localized
        names = ShortcutRunner.names()
        installSpecifiers(buildSpecifiers())
    }

    public override func rebuildSpecifiers() -> NSMutableArray? {
        buildSpecifiers()
    }

    private func buildSpecifiers() -> NSMutableArray {
        var items: [PSSpecifier] = []
        let current = currentSelection()

        items.append(group(localized: "Runs this Shortcut"))

        if names.isEmpty {
            let empty = PSSpecifier.preferenceSpecifierNamed(
                "No shortcuts found".localized, target: nil, set: nil, get: nil,
                detail: nil, cell: .groupCell, edit: nil
            )
            empty?.setProperty(
                "Create one in the Shortcuts app, then come back.".localized,
                forKey: "footerText"
            )
            items.append(empty!)
        } else {
            for name in names {
                let cell = PSSpecifier.preferenceSpecifierNamed(
                    name, target: self,
                    set: nil, get: nil, detail: nil,
                    cell: .buttonCell, edit: nil
                )
                cell?.setProperty(name, forKey: "shortcutName")
                if let instanceID {
                    cell?.setProperty(instanceID,
                                      forKey: SpecifierRouting.PropertyKey.instanceID)
                }
                cell?.setProperty(name == current, forKey: "checked")
                cell?.buttonAction = #selector(choose(_:))
                items.append(cell!)
            }
        }

        return NSMutableArray(array: items)
    }

    /// The shortcut this instance currently runs, if any.
    private func currentSelection() -> String? {
        guard let instanceID else { return nil }
        let stored = PrefsStore.instance(instanceID)[ShortcutPrefKey.shortcutName]
        return stored as? String
    }

    /// Stores the choice on the instance and returns to its settings page.
    @objc private func choose(_ sender: PSSpecifier) {
        guard let instanceID,
              let name = sender.property(forKey: "shortcutName") as? String
        else { return }

        PrefsStore.updateInstance(instanceID) { object in
            object[ShortcutPrefKey.shortcutName] = name
        }

        navigationController?.popViewController(animated: true)
    }

    /// A group cell with a localized header.
    private func group(localized label: String) -> PSSpecifier {
        let cell = PSSpecifier.preferenceSpecifierNamed(
            label, target: nil, set: nil, get: nil, detail: nil, cell: .groupCell, edit: nil
        )
        return cell!
    }
}
