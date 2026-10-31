import Foundation
import UIKit

/// The image-host setting, shown at the top of Global Settings.
///
/// One page of its own rather than cells inline: a host has a name, a description
/// and sometimes a key, and squeezing three rows per host into the settings list
/// would push everything else off the screen. The inline part is a single row that
/// says which host is in use.
enum ImageHostRows {
    static let rowIdentifier = "globalImageHost"

    /// The row that opens the picker.
    static func entryRow() -> PSSpecifier? {
        let host = ImageHostRegistry.selected
        let row = PSSpecifier.preferenceSpecifierNamed(
            "图片上传".localized, target: ImageHostSettingsController.self,
            set: nil, get: nil,
            detail: ImageHostSettingsController.self, cell: .linkCell, edit: nil
        )
        row?.identifier = rowIdentifier
        // The chosen host is the value, so the list says what it is without opening
        // anything. `detailText` rather than the row's own label: the label is the
        // setting's name and belongs to the app, not to the host.
        row?.setProperty(host?.displayName ?? "None".localized, forKey: "detail")
        row?.setProperty(true, forKey: "enabled")
        return row
    }
}

/// Picks the host, and collects its key if it wants one.
///
/// Built in code rather than from a plist because the list of hosts is the registry
/// — a plist would be a second copy that could disagree with it, and the key field
/// appears and disappears with the selection.
public final class ImageHostSettingsController: ListController {
    /// The framework creates detail controllers with two different initialisers.
    /// A custom one would hide both, and the page would fail to open rather than
    /// fail to build.
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override init(nibName: String?, bundle: Bundle?) {
        super.init(nibName: nibName, bundle: bundle)
    }

    @objc public override init(forContentSize contentSize: CGSize) {
        super.init(forContentSize: contentSize)
    }

    private var builtSpecifiers: NSMutableArray?

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "图片上传".localized
        buildSpecifiers()
    }

    /// The framework replaces a code-built page's specifiers with the plist's on
    /// background/foreground; this one has no plist, so it has to put its own back.
    public override func rebuildSpecifiers() -> NSMutableArray? {
        builtSpecifiers
    }

    private func buildSpecifiers() {
        guard !hasInstalledSpecifiers else { return }
        let rows = buildRows()
        builtSpecifiers = rows
        installSpecifiers(rows)
    }

    private func buildRows() -> NSMutableArray {
        let rows = NSMutableArray()

        // One group per host: a name, what it is for, and a checkmark on the one in
        // use. A segment control would fit them in one row but could not carry the
        // description, and which host to trust is not a decision to make from four
        // bare names.
        let header = PSSpecifier.groupSpecifier(withName: "上传到".localized)
        header?.setProperty(
            "服务只能接收图片链接时，附件会先上传到这里，再把链接发出去。".localized,
            forKey: "footerText"
        )
        rows.add(header as Any)

        let selected = ImageHostRegistry.selected
        for host in ImageHostRegistry.all {
            // A plain cell, with the tick drawn in `cellForRowAt`: the framework's
            // list picker asks each cell to check itself, and a specifier property
            // named `checked` is read by nothing.
            let row = PSSpecifier.preferenceSpecifierNamed(
                host.displayName, target: self,
                set: nil, get: nil, detail: nil, cell: .linkCell, edit: nil
            )!
            row.identifier = "host." + host.identifier
            // The description rides along as the cell's subtitle, so choosing a host
            // does not require opening anything.
            row.setProperty(host.summary.localized, forKey: "subtitle")
            row.setProperty(host.identifier, forKey: "hostIdentifier")
            row.setProperty(selectHost, forKey: "action")
            rows.add(row)
        }

        // The key field belongs to the selected host only. A field per host would
        // be four fields for one decision, three of them irrelevant.
        if let host = selected, host.requiresKey {
            let group = PSSpecifier.groupSpecifier(withName: host.displayName)
            // The host's name is interpolated, so the whole string is localised
            // before it is formatted — a fragment-based key would look up English
            // and fall back.
            group?.setProperty(
                String(format: "Enter the API key for %@.".localized, host.displayName),
                forKey: "footerText"
            )
            rows.add(group as Any)

            let field = PSSpecifier.preferenceSpecifierNamed(
                "API Key".localized, target: self,
                set: #selector(setKey(_:forSpecifier:)),
                get: #selector(key(forSpecifier:)),
                detail: nil, cell: .editTextCell, edit: nil
            )!
            field.identifier = "hostKey"
            field.setProperty(host.identifier, forKey: "hostIdentifier")
            // A key is a secret typed by hand; the keyboard should not autocorrect
            // or capitalise it.
            field.setProperty(true, forKey: "enabled")
            rows.add(field)
        }

        return rows
    }

    /// The tick on the host in use.
    ///
    /// Drawn here because it belongs to the cell: the framework's own pickers call
    /// `setChecked:` on each cell, and a `checked` property on the specifier is
    /// read by nothing — setting it looked like it worked and drew nothing.
    public override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = super.tableView(tableView, cellForRowAt: indexPath)
        guard let specifier = specifierForRow(indexPath),
              let identifier = specifier.property(forKey: "hostIdentifier") as? String,
              let tableCell = cell as? PSTableCell
        else { return cell }
        tableCell.setChecked(ImageHostRegistry.selected?.identifier == identifier)
        return cell
    }

    // MARK: - Actions

    private var selectHost: Selector { #selector(chooseHost(_:)) }

    @objc private func chooseHost(_ sender: PSSpecifier) {
        guard let identifier = sender.property(forKey: "hostIdentifier") as? String else {
            return
        }
        PrefsStore.updateGlobal { $0[PrefKey.imageHostKey] = identifier }
        // Rebuilt rather than patched: the key field appears or disappears with the
        // choice, and the checkmark has to move to a different row. One page, so a
        // full rebuild costs nothing.
        rebuildPage()
    }

    @objc private func setKey(_ value: Any?, forSpecifier specifier: PSSpecifier) {
        guard let host = specifier.property(forKey: "hostIdentifier") as? String else {
            return
        }
        let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        PrefsStore.updateGlobal { global in
            global[PrefKey.imageHostKeyKey(for: host)] = text
        }
    }

    @objc private func key(forSpecifier specifier: PSSpecifier) -> Any? {
        guard let host = specifier.property(forKey: "hostIdentifier") as? String else {
            return ""
        }
        return PrefsStore.global().string(PrefKey.imageHostKeyKey(for: host)) ?? ""
    }

    /// Replaces the page's cells with freshly built ones.
    ///
    /// `hasInstalledSpecifiers` guards the first build, so it has to be cleared
    /// before asking for another — otherwise the build would return immediately and
    /// nothing would change.
    private func rebuildPage() {
        builtSpecifiers = nil
        installSpecifiers(buildRows())
    }
}
