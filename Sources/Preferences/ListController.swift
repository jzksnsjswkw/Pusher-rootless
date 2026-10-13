import UIKit

/// Base class for every list page in the tweak's settings.
///
/// Two behaviors are shared by all of them and are easy to forget in each
/// subclass, so they live here:
///
///  * **Localization.** Specifier plists are loaded by the Preferences
///    framework, which does not apply this bundle's `Localizable.strings` to
///    their labels, footers or segment titles. Every specifier is localized on
///    the way in.
///  * **Icon tinting.** Each cell's icon is drawn in the active tint color, so
///    a service page's icons match the color extracted from its own icon.
@objc(NSPListController)
open class ListController: PSListController, TintableController {

    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tintToPusherColor()
    }

    /// Recolors the page and reloads so the icons pick up the new color.
    ///
    /// Callers use this name; the actual tinting lives in the
    /// ``TintableController/applyActiveTint()`` protocol extension.
    open func tintToPusherColor() {
        (self as TintableController).applyActiveTint()
        table?.reloadData()
    }

    open override func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        view.endEditing(true)
    }

    // MARK: - Cell appearance

    open override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = super.tableView(tableView, cellForRowAt: indexPath)

        guard let cell = cell as? PSTableCell else { return cell }

        if cell.type == .linkCell, let iconView = cell.iconImageView(), let icon = iconView.image {
            iconView.image = icon.replacingColor(Theme.defaultTintColor, with: Theme.activeTintColor)
        }
        if cell.type == .buttonCell {
            cell.titleLabel?.textColor = Theme.activeTintColor
        }
        cell.tintColor = Theme.activeTintColor
        return cell
    }

    // MARK: - Specifier loading

    /// Whether this page has already installed its cells.
    ///
    /// A flag rather than a check on `specifiers == nil`: the framework reads
    /// that property during setup and may leave a non-nil *empty* array behind,
    /// which would make a nil check skip loading forever and leave the page
    /// blank.
    var hasLoadedSpecifiers = false

    /// Rebuilds the page's cells when the framework has discarded them.
    ///
    /// The Preferences framework clears a list controller's specifier array on
    /// some events (backgrounding the app among them), then asks the controller
    /// for its cells again at `viewWillAppear`. A page that cannot answer has
    /// nothing to show - the reported "all settings vanish after switching
    /// away and back". The original implementation answered through an
    /// overridden `specifiers` getter that reloaded the plist; this hook is the
    /// same idea, expressed as an overridable method the getter calls.
    ///
    /// Return the fresh cells, or `nil` when the page builds its own (those
    /// pages override this to return `nil` and rebuild themselves instead).
    open func rebuildSpecifiers() -> NSMutableArray? {
        guard let plistName = specifierPlistName else { return nil }
        return loadSpecifiers(named: plistName)
    }

    /// The plist this page's cells come from, or `nil` when the page builds its
    /// cells in code.
    open var specifierPlistName: String? { nil }

    /// The array this page last installed, compared by identity.
    ///
    /// Count is not a valid condition: while the app is backgrounded the
    /// framework re-derives `_specifiers` from the plist on its own, producing a
    /// *plausible-looking* array (same plist cells, no programmatically appended
    /// ones) whose count is nonzero. Only object identity distinguishes "the
    /// array I built" from "the array the framework substituted".
    private weak var installedSpecifiers: NSMutableArray?

    /// Set while this getter is rebuilding, so a rebuild that reads
    /// `self.specifiers` cannot start another one.
    ///
    /// A page that looks a cell up by identifier *while building* — which is a
    /// natural thing to do, a group cell's footer depending on a switch above it
    /// — would otherwise ask the framework for its cells, get the array it has
    /// not installed yet, and have this getter conclude that the framework had
    /// substituted one. It would then rebuild, look the cell up again, and recurse
    /// until the stack ran out.
    ///
    /// Returning the framework's array during a rebuild is the safe answer: the
    /// page is mid-construction, so there is nothing installed to find, and a
    /// lookup that fails is what the caller already handles.
    private var isRebuilding = false

    /// The page's cells, reloading them when the framework has substituted its
    /// own plist-derived array for the one this page built.
    ///
    /// This is the property the framework reads, so it is where the array has
    /// to be rebuilt - the equivalent of the original ObjC version, whose
    /// `specifiers` getter re-derived everything from `_service`.
    public override var specifiers: NSMutableArray! {
        get {
            let current = super.specifiers
            guard !isRebuilding else { return current }
            if current !== installedSpecifiers {
                isRebuilding = true
                defer { isRebuilding = false }
                if let rebuilt = rebuildSpecifiers() {
                    super.specifiers = rebuilt
                    installedSpecifiers = rebuilt
                }
            }
            return super.specifiers
        }
        set {
            super.specifiers = newValue
            installedSpecifiers = newValue
        }
    }

    /// Loads a specifier plist from this bundle once, then installs the cells.
    ///
    /// Kept for pages whose cells only exist after side effects have run (a
    /// service page appends its test-push section, for example); those pages
    /// call this from `viewDidLoad`. The getter above covers the discarded-
    /// array case for every page that declares a `specifierPlistName`.
    func loadSpecifiersOnce(named plistName: String) {
        guard !hasLoadedSpecifiers else { return }
        hasLoadedSpecifiers = true
        guard let loaded = loadSpecifiers(named: plistName) else { return }
        installSpecifiers(loaded)
    }

    /// Loads several plists and installs them as one list.
    func loadSpecifiersOnce(named plistNames: [String]) {
        guard !hasLoadedSpecifiers else { return }
        hasLoadedSpecifiers = true
        let loaded = plistNames.compactMap { loadSpecifiers(named: $0) as? [PSSpecifier] }
            .flatMap { $0 }
        installSpecifiers(NSMutableArray(array: loaded))
    }

    /// Whether the cells have been installed, so a subclass can decide whether
    /// to append its own.
    var hasInstalledSpecifiers: Bool { hasLoadedSpecifiers }

    /// Installs already-built cells (for a page that does not load a plist).
    func installSpecifiers(_ specifiers: NSArray) {
        hasLoadedSpecifiers = true
        // Through the setter, which records the array's identity so the getter
        // can tell it apart from the framework's own plist reload.
        self.specifiers = NSMutableArray(array: specifiers as! [Any])
    }

    /// Whether a toggle in this page's **installed** cells is currently on.
    ///
    /// Read from the cell rather than from storage because the cell is what the
    /// user just touched: the framework writes the new value through the
    /// specifier's setter and keeps its own copy, so asking the cell is the one
    /// answer that cannot lag behind the tap.
    func isToggleOn(_ identifier: String) -> Bool? {
        guard let specifier = specifier(forID: identifier) else { return nil }
        if let value = specifier.property(forKey: "value") as? NSNumber {
            return value.boolValue
        }
        return specifier.storedDefault as? Bool
    }

    /// Loads a specifier plist from this bundle.
    ///
    /// The bundle is passed explicitly rather than relying on
    /// `PSListController.bundle`: that property is assigned by the Preferences
    /// framework during its own `viewDidLoad`, so a page that reads its plist
    /// before then would resolve it to nil and come up empty. `Bundle(for:)`
    /// returns the bundle this class was compiled into, which is the installed
    /// `.bundle` directory.
    open func loadSpecifiers(named plistName: String) -> NSMutableArray? {
        let loaded = loadSpecifiers(
            fromPlistName: plistName, target: self, bundle: Bundle(for: type(of: self))
        )
        guard let loaded else { return nil }
        localize(loaded as! [Any])
        return loaded
    }

    open override func loadSpecifiers(fromPlistName plistName: String, target: PSListController?) -> NSMutableArray? {
        let specifiers = super.loadSpecifiers(fromPlistName: plistName, target: target)
        guard let specifiers else { return specifiers }
        localize(specifiers as! [Any])
        return specifiers
    }

    /// The colour a section's footer should be drawn in, or `nil` to leave it.
    ///
    /// A group's explanation is not a cell — it is the section's footer view, a
    /// `UITableViewHeaderFooterView` the framework builds — so it is reached here
    /// rather than through the cell hooks. `viewForFooterInSection` is a delegate
    /// method the framework does implement; `willDisplayCell` is one it does not,
    /// and forwarding to that closed the page.
    open func footerColour(forSection section: Int) -> UIColor? { nil }

    open override func tableView(
        _ tableView: UITableView, viewForFooterInSection section: Int
    ) -> UIView? {
        let view = super.tableView(tableView, viewForFooterInSection: section)
        guard let view, let colour = footerColour(forSection: section) else { return view }

        func recolour(_ subview: UIView) {
            if let label = subview as? UILabel { label.textColor = colour }
            subview.subviews.forEach(recolour)
        }
        recolour(view)
        return view
    }

    /// The specifier behind a table row.
    ///
    /// `PSListController` keeps one flat array and derives sections from its group
    /// cells, so a row's index in the table is not its index in that array — the
    /// offset of the section's first row has to be added.
    open func specifierForRow(_ indexPath: IndexPath) -> PSSpecifier? {
        guard let rows = super.specifiers as? [PSSpecifier] else { return nil }
        var group = -1
        var offset = 0
        for (index, specifier) in rows.enumerated() where specifier.cellType == .groupCell {
            group += 1
            if group == indexPath.section {
                offset = index + 1
                break
            }
        }
        let row = offset + indexPath.row
        guard group >= 0, row < rows.count else { return nil }
        return rows[row]
    }

    /// Localizes every label, footer and segment title in place.
    ///
    /// The plists hold English keys, so an untranslated build shows English
    /// rather than nothing.
    open func localize(_ specifiers: [Any]) {
        for case let specifier as PSSpecifier in specifiers {
            localize(specifier)
        }
        if let title, !title.isEmpty {
            self.title = title.localized
        }
    }

    /// Localizes one specifier's user-visible strings.
    open func localize(_ specifier: PSSpecifier) {
        if let name = specifier.name, !name.isEmpty {
            specifier.name = name.localized
        }
        if let footer = specifier.property(forKey: "footerText") as? String, !footer.isEmpty {
            specifier.setProperty(footer.localized, forKey: "footerText")
        }
        if let groupFooter = specifier.property(forKey: "footerText") as? String, !groupFooter.isEmpty {
            specifier.setProperty(groupFooter.localized, forKey: "footerText")
        }

        // A segment/radio cell's choices live in parallel title and value
        // arrays, so they are localized together and only rewritten when the
        // two still line up (a mismatch means the plist is malformed, and the
        // titles would lose their values).
        guard let titles = specifier.property(forKey: "validTitles") as? [Any], !titles.isEmpty else {
            return
        }
        let localizedTitles = titles.map { ($0 as? String)?.localized ?? $0 }
        if let values = specifier.property(forKey: "validValues") as? [Any],
           values.count == localizedTitles.count {
            specifier.setValues(values, titles: localizedTitles)
        } else {
            specifier.setProperty(localizedTitles, forKey: "validTitles")
        }
    }

    // MARK: - Test notification feedback

    /// Shows a result from a test push without leaving Settings.
    ///
    /// Posted as a local notification so it appears exactly where a real push
    /// would; if the user has not granted notification permission the failure
    /// is reported in an alert instead.
    open func displayNotification(_ message: String) {
        TestNotification.present(message, from: self)
    }
}
