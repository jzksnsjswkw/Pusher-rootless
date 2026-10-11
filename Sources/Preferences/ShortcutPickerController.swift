import UIKit

/// Picks which Shortcut a service instance runs.
///
/// The choice is made from a list rather than typed, and that matters more here
/// than for most pickers: a name that is one character off fails at push time,
/// in the background, with nothing but a log line to show for it.
///
/// The page is built in code — there is no plist — which means it must supply
/// both things a plist page gets for free: the cells, and the array the
/// framework re-derives when the app returns from the background. Without the
/// second, a backgrounded page comes back showing whichever plist the framework
/// happened to substitute.
@objc(NSPShortcutPickerController)
public final class ShortcutPickerController: ListController {

    /// Every shortcut name on the device.
    private var names: [String] = []

    /// The instance whose shortcut is being chosen.
    private var instanceID: String?

    /// The shortcut this instance currently runs.
    private var selected: String = ""

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
        title = "Shortcut".localized
        loadSelection()
        installSpecifiers(buildSpecifiers())
    }

    /// Rebuilds on the framework's own reload, so returning from the background
    /// shows this page's cells rather than a substituted plist's.
    public override func rebuildSpecifiers() -> NSMutableArray? {
        loadSelection()
        return buildSpecifiers()
    }

    /// Reads the instance's current choice.
    private func loadSelection() {
        instanceID = specifier?.string(SpecifierRouting.PropertyKey.instanceID)
        names = ShortcutRunner.names()
        if let instanceID,
           let stored = PrefsStore.instance(instanceID)[ShortcutPrefKey.shortcutName] as? String {
            selected = stored
        } else {
            selected = ""
        }
    }

    private func buildSpecifiers() -> NSMutableArray {
        var items: [PSSpecifier] = []

        // The group header is the prompt, so the first row can be the choice
        // itself rather than a button that opens another page.
        let heading = PSSpecifier.preferenceSpecifierNamed(
            "Runs this Shortcut".localized, target: nil, set: nil, get: nil,
            detail: nil, cell: .groupCell, edit: nil
        )!
        items.append(heading)

        if names.isEmpty {
            let empty = PSSpecifier.preferenceSpecifierNamed(
                "No shortcuts found".localized, target: nil, set: nil, get: nil,
                detail: nil, cell: .groupCell, edit: nil
            )!
            empty.setProperty(
                "Create one in the Shortcuts app, then come back.".localized,
                forKey: "footerText"
            )
            items.append(empty)
            return NSMutableArray(array: items)
        }

        // One row per shortcut, named for the shortcut itself. The chosen one
        // carries a tick, which is how a list page says "this is the current
        // value" without a separate field echoing it.
        for name in names {
            let cell = PSSpecifier.preferenceSpecifierNamed(
                name, target: self, set: nil, get: nil,
                detail: nil, cell: .buttonCell, edit: nil
            )!
            cell.identifier = name
            cell.setProperty(name, forKey: "shortcutName")
            cell.buttonAction = #selector(choose(_:))
            if let instanceID {
                cell.setProperty(instanceID,
                                 forKey: SpecifierRouting.PropertyKey.instanceID)
            }
            items.append(cell)
        }

        return NSMutableArray(array: items)
    }

    /// Draws a tick on the row that is the current choice.
    ///
    /// The tick belongs to the *cell*, not to the specifier: the framework's own
    /// list picker asks each cell to check itself against the selected row, and
    /// a `checked` property on the specifier is read by nothing. Setting it there
    /// looked like it worked and drew nothing.
    public override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = super.tableView(tableView, cellForRowAt: indexPath)
        guard let specifier = cellSpecifier(at: indexPath),
              let name = specifier.property(forKey: "shortcutName") as? String,
              let tableCell = cell as? PSTableCell
        else { return cell }
        tableCell.setChecked(name == selected)
        return cell
    }

    /// The cell's specifier, or `nil` for a row that is not one.
    private func cellSpecifier(at indexPath: IndexPath) -> PSSpecifier? {
        guard let rows = super.specifiers as? [PSSpecifier] else { return nil }
        let flatIndex = indexPath.row + sectionStart(indexPath.section, in: rows)
        guard flatIndex >= 0, flatIndex < rows.count else { return nil }
        return rows[flatIndex]
    }

    /// The index in the flat specifier array where a section begins.
    ///
    /// `PSListController` keeps one flat array and derives sections from the
    /// group cells, so a row's index in the table is not its index in the array.
    private func sectionStart(_ section: Int, in rows: [PSSpecifier]) -> Int {
        var seen = -1
        for (index, specifier) in rows.enumerated() {
            guard specifier.cellType == .groupCell else { continue }
            seen += 1
            if seen == section { return index + 1 }
        }
        return 0
    }

    /// Stores the choice and returns to the instance's page.
    @objc private func choose(_ sender: PSSpecifier) {
        guard let instanceID,
              let name = sender.property(forKey: "shortcutName") as? String
        else { return }

        PrefsStore.updateInstance(instanceID) { object in
            object[ShortcutPrefKey.shortcutName] = name
        }

        navigationController?.popViewController(animated: true)
    }
}
