import Foundation
import UIKit

/// The image-host row shown in Global Settings.
///
/// The value goes on the row's trailing side and the choice is made in a sheet that
/// rises from the bottom — the same shape iOS uses for picking from a short list.
/// A pushed page would work, but it costs a navigation transition and a back button
/// for four names, and the descriptions are one line each.
enum ImageHostRows {
    static let rowIdentifier = "globalImageHost"

    static func entryRow(target: AnyObject) -> PSSpecifier? {
        let row = PSSpecifier.preferenceSpecifierNamed(
            "图片上传".localized, target: target,
            set: nil, get: nil, detail: nil, cell: .linkCell, edit: nil
        )
        row?.identifier = rowIdentifier
        row?.setProperty(true, forKey: "enabled")
        // The chosen host on the trailing side, so the list says which one without
        // opening the sheet.
        row?.setProperty(ImageHostRows.selectedName(), forKey: "detail")

        return row
    }

    /// The value shown on the row.
    static func selectedName() -> String {
        ImageHostRegistry.selected?.displayName ?? "None".localized
    }
}

/// The sheet that picks a host.
///
/// A plain table in a `UINavigationController` so the sheet has a bar with a Done
/// button — the same arrangement the guide sheets use, and the reason is the same:
/// a bare view controller in a sheet has nowhere to put the button.
public final class ImageHostPickerController: UITableViewController {
    /// Called with the identifier once the user picks a host.
    public var onSelect: ((String) -> Void)?

    /// The page and row to redraw once a host is chosen, so the setting behind the
    /// sheet shows the new value without leaving and re-entering it.
    public weak var sourcePage: ListController?
    public var sourceRow: PSSpecifier?

    public init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "图片上传".localized
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(dismissSheet)
        )
        // The sheet sizes itself to content, so a table with one screen of rows
        // should not bounce.
        tableView.alwaysBounceVertical = false
    }

    @objc private func dismissSheet() {
        dismiss(animated: true)
    }

    // MARK: - Table

    public override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    public override func tableView(
        _ tableView: UITableView, numberOfRowsInSection section: Int
    ) -> Int {
        section == 0 ? ImageHostRegistry.all.count : 1
    }

    public override func tableView(
        _ tableView: UITableView, titleForHeaderInSection section: Int
    ) -> String? {
        section == 0 ? "上传到".localized : nil
    }

    public override func tableView(
        _ tableView: UITableView, titleForFooterInSection section: Int
    ) -> String? {
        guard section == 0 else {
            // What the other section is for, since the button there is destructive
            // looking and its effect is invisible until the next push.
            return ("清空后，下次推送时会重新上传。已经上传到图床的图片不会被删除。").localized
        }
        // The consequence, in one sentence: a service that only takes a link will
        // get one from here, and a user choosing between these needs to know what
        // the choice affects.
        return "服务只能接收图片链接时，附件会先上传到这里，再把链接发出去。".localized
    }

    public override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        guard indexPath.section == 0 else {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = "Clear cache".localized
            cell.textLabel?.textColor = .systemRed
            cell.textLabel?.textAlignment = .center
            cell.textLabel?.numberOfLines = 1
            return cell
        }
        let host = ImageHostRegistry.all[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = host.displayName
        // One line about what the host is for, under the name. Four bare names are
        // not enough to choose by when the difference is retention and file size.
        cell.detailTextLabel?.text = host.summary.localized
        cell.detailTextLabel?.numberOfLines = 0
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .caption1)
        cell.accessoryType = ImageHostRegistry.selected?.identifier == host.identifier
            ? .checkmark
            : .none
        // The tint matches the rest of the app rather than the sheet's default.
        cell.tintColor = Theme.activeTintColor
        return cell
    }

    /// Records the choice and moves the tick, without closing the sheet.
    ///
    /// A pick from four rows is easy to get wrong, and closing on the first tap
    /// means reopening the sheet to correct it. The Done button is the way out, so
    /// the choice can be changed as many times as it takes to be sure.
    public override func tableView(
        _ tableView: UITableView, didSelectRowAt indexPath: IndexPath
    ) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 0 else {
            confirmClearCache()
            return
        }
        let host = ImageHostRegistry.all[indexPath.row]
        PrefsStore.updateGlobal { $0[PrefKey.imageHostKey] = host.identifier }
        onSelect?(host.identifier)

        // The tick belongs to the cell, and only the accessory changes, so the rows
        // are reloaded rather than the sheet being rebuilt — a rebuild would drop
        // the scroll position for no gain.
        tableView.reloadData()
    }

    /// Empties the link cache, after asking.
    ///
    /// The next push re-uploads, so nothing breaks — but an icon that has been
    /// cached for months becomes one request per notification until it is cached
    /// again, and a user tapping a red row deserves to know that is what it does.
    private func confirmClearCache() {
        let count = ImageHosts.cachedEntryCount()
        let alert = UIAlertController(
            title: "Clear cache".localized,
            message: String(
                format: "%d cached image links will be removed; the next push uploads them again.".localized,
                count
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear".localized, style: .destructive) { _ in
            ImageHosts.clearCache()
            self.tableView.reloadData()
            let done = UIAlertController(
                title: nil,
                message: "Cleared".localized,
                preferredStyle: .alert
            )
            done.addAction(UIAlertAction(title: "Ok".localized, style: .default))
            self.present(done, animated: true)
        })
        present(alert, animated: true)
    }

    /// Presents the sheet over `presenter`.
    ///
    /// Wrapped in a navigation controller for the bar and the Done button, which a
    /// bare sheet has nowhere to put — the guide sheets are arranged the same way
    /// for the same reason.
    static func present(from presenter: ListController, reloading row: PSSpecifier?) {
        let picker = ImageHostPickerController()
        picker.sourcePage = presenter
        picker.sourceRow = row
        let navigation = UINavigationController(rootViewController: picker)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            // Half the screen: four rows and two lines of text fit, and the setting
            // it came from stays visible behind it.
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        picker.onSelect = { _ in
            guard let row = picker.sourceRow else { return }
            // The value is read from storage when the cell is built, so the
            // specifier has to carry the new one before the row is redrawn —
            // reloading alone would draw the old host.
            row.setProperty(ImageHostRows.selectedName(), forKey: "detail")
            picker.sourcePage?.reloadSpecifier(row)
        }
        presenter.present(navigation, animated: true)
    }
}
