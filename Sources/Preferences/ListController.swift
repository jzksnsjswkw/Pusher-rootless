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
    open func tintToPusherColor() {
        (self as TintableController).tintToPusherColor()
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

    open override func loadSpecifiers(fromPlistName plistName: String, target: PSListController?) -> NSMutableArray? {
        let specifiers = super.loadSpecifiers(fromPlistName: plistName, target: target)
        guard let specifiers else { return specifiers }
        localize(specifiers as! [Any])
        return specifiers
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
