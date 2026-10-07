import UIKit

/// The service list: every built-in service plus the user's custom ones, split
/// into Enabled and Disabled sections.
///
/// The list owns the two things that decide whether a push is delivered at all —
/// which services are turned on, and the order they are tried in — so it is the
/// one place that writes `enabled` and the section ordering. Both are only
/// persisted when editing ends, so a half-finished drag is never saved.
@objc(NSPServiceListController)
public final class ServiceListController: PlainViewController, UITableViewDataSource, UITableViewDelegate {
    private enum Section: Int, CaseIterable {
        case enabled
        case disabled

        var title: String {
            switch self {
            case .enabled: return "Enabled"
            case .disabled: return "Disabled"
            }
        }
    }

    /// Built-in services, in registry order.
    private let builtInServices = ServiceRegistry.builtInServiceNames
    /// The raw `CustomServices` object, kept in sync with the UI while editing.
    private var customServices: [String: [String: Any]] = [:]
    /// Service names shown in each section.
    private var sectionItems: [Section: [String]] = [:]
    private var serviceImages: [String: UIImage] = [:]
    private var loadedControllers: [String: ServiceController] = [:]

    private var servicesTable: UITableView!
    private var addButton: UIBarButtonItem!
    /// The row a drag is currently hovering over, used to keep reordering within
    /// a section's alphabetical order.
    private var lastTargetService: String?
    private var lastTargetIndexPath: IndexPath?

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()

        let frame = UIDevice.current.userInterfaceIdiom == .pad
            ? root?.view.bounds ?? view.bounds
            : view.bounds
        servicesTable = UITableView(frame: frame, style: .grouped)
        servicesTable.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellIdentifier)
        servicesTable.dataSource = self
        servicesTable.delegate = self
        servicesTable.allowsSelectionDuringEditing = true
        view.addSubview(servicesTable)

        addButton = UIBarButtonItem(
            title: "Add".localized, style: .plain, target: self, action: #selector(addService)
        )

        navigationItem.title = "Services".localized
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Edit".localized, style: .plain, target: self, action: #selector(toggleEditing(_:))
        )
        navigationItem.leftBarButtonItem = nil
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Theme.setActiveTintColor(nil)
        tintToPusherColor()
        reloadData()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        showTutorialIfNeeded()
    }

    private static let cellIdentifier = "ServiceCell"

    // MARK: - Data

    /// Rebuilds the section lists from prefs and reloads the servicesTable.
    private func reloadData() {
        let prefs = PrefsStore.prefs()
        customServices = prefs.dict(PrefKey.customServices)?.raw.compactMapValues {
            $0 as? [String: Any]
        } ?? [:]

        var items: [Section: [String]] = [.enabled: [], .disabled: []]
        let builtIn = prefs.dict(PrefKey.builtInServices) ?? Prefs()

        for service in builtInServices {
            let isEnabled = builtIn.dict(service)?.bool(PrefKey.serviceEnabled) ?? false
            items[isEnabled ? .enabled : .disabled, default: []].append(service)
            serviceImages[service] = UIImage.serviceIcon(named: service, isCustom: false)
        }

        for service in customServices.keys {
            let isEnabled = Prefs(customServices[service] ?? [:]).bool(PrefKey.legacyEnabled)
            items[isEnabled ? .enabled : .disabled, default: []].append(service)
            serviceImages[service] = UIImage.serviceIcon(named: service, isCustom: true)
        }

        for section in Section.allCases {
            items[section]?.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
        sectionItems = items
        servicesTable.reloadData()
    }

    private func service(at indexPath: IndexPath) -> String? {
        let items = sectionItems[Section(rawValue: indexPath.section) ?? .enabled] ?? []
        guard indexPath.row < items.count else { return nil }
        return items[indexPath.row]
    }

    private func isCustom(_ service: String) -> Bool {
        customServices[service] != nil
    }

    /// Persists which services are enabled, in the order the sections show.
    private func saveEnabledState() {
        let enabled = Set(sectionItems[.enabled] ?? [])

        var builtIn = PrefsStore.builtInServices().raw
        for service in builtInServices {
            var object = (builtIn[service] as? [String: Any]) ?? [:]
            object[PrefKey.serviceEnabled] = enabled.contains(service)
            builtIn[service] = object
        }
        PrefsStore.setValue(builtIn, forKey: PrefKey.builtInServices, notify: false)

        // A custom service's own object carries its enabled flag, so the flag is
        // written into the object rather than beside it.
        for service in customServices.keys {
            customServices[service]?[PrefKey.legacyEnabled] = enabled.contains(service)
        }
        saveCustomServices()
    }

    private func saveCustomServices() {
        PrefsStore.setValue(customServices, forKey: PrefKey.customServices)
    }

    // MARK: - Editing

    @objc private func toggleEditing(_ sender: UIBarButtonItem) {
        servicesTable.setEditing(!servicesTable.isEditing, animated: true)
        sender.title = servicesTable.isEditing ? "Done".localized : "Edit".localized
        navigationItem.leftBarButtonItem = servicesTable.isEditing ? addButton : nil

        if !servicesTable.isEditing {
            saveEnabledState()
        }
    }

    // MARK: - Adding, renaming, deleting

    @objc private func addService() {
        promptForServiceName(
            title: "Add Custom Service".localized, initialValue: nil,
            confirmTitle: "Add".localized
        ) { [weak self] name in
            self?.addCustomService(named: name)
        }
    }

    private func addCustomService(named name: String) {
        customServices[name] = [PrefKey.legacyEnabled: false]
        sectionItems[.disabled, default: []].append(name)
        sectionItems[.disabled]?.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        serviceImages[name] = UIImage.serviceIcon(named: name, isCustom: true)
        servicesTable.reloadSections(IndexSet(integer: Section.disabled.rawValue), with: .automatic)
        saveCustomServices()
    }

    private func renameService(_ service: String) {
        promptForServiceName(
            title: String(format: "Rename %@".localized, service),
            initialValue: service,
            confirmTitle: "Rename".localized
        ) { [weak self] newName in
            self?.performRename(from: service, to: newName)
        }
    }

    private func performRename(from oldName: String, to newName: String) {
        serviceImages[newName] = serviceImages.removeValue(forKey: oldName)
        customServices[newName] = customServices.removeValue(forKey: oldName)
        saveCustomServices()

        // Drop the cached page for the old name so the renamed service reloads
        // with fresh data instead of reusing a stale controller.
        loadedControllers.removeValue(forKey: oldName)

        // Legacy flat keys for the old name are renamed too; current installs
        // store everything nested, but a pre-migration install may not.
        migrateLegacyCustomServiceKeys(from: oldName, to: newName)

        let section: Section = Prefs(customServices[newName] ?? [:]).bool(PrefKey.legacyEnabled)
            ? .enabled : .disabled
        sectionItems[section]?.removeAll { $0 == oldName }
        sectionItems[section, default: []].append(newName)
        sectionItems[section]?.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        servicesTable.reloadSections(IndexSet(integersIn: 0..<Section.allCases.count), with: .fade)
    }

    /// Renames the flat `CustomService_<name>_CustomApps` and
    /// `CustomServiceBL_<name>-*` keys, left over from an older build.
    private func migrateLegacyCustomServiceKeys(from oldName: String, to newName: String) {
        var prefs = PrefsStore.snapshot()
        var keysToRemove: [String] = []

        let oldCustomApps = PrefKey.legacyCustomAppsPrefix + oldName + PrefKey.legacyCustomAppsSuffix
        let newCustomApps = PrefKey.legacyCustomAppsPrefix + newName + PrefKey.legacyCustomAppsSuffix
        if let value = prefs[oldCustomApps] {
            prefs[newCustomApps] = value
            prefs.removeValue(forKey: oldCustomApps)
            keysToRemove.append(oldCustomApps)
        }

        let oldPrefix = PrefKey.legacyCustomBlacklistPrefix + oldName + "-"
        let newPrefix = PrefKey.legacyCustomBlacklistPrefix + newName + "-"
        for key in prefs.keys where key.hasPrefix(oldPrefix) {
            prefs[key.replacingOccurrences(of: oldPrefix, with: newPrefix)] = prefs[key]
            prefs.removeValue(forKey: key)
            keysToRemove.append(key)
        }

        guard !keysToRemove.isEmpty else { return }
        PrefsStore.apply(prefs, removing: keysToRemove)
    }

    private func deleteService(_ service: String) {
        customServices.removeValue(forKey: service)
        loadedControllers.removeValue(forKey: service)
        serviceImages.removeValue(forKey: service)
        saveCustomServices()

        // Remove the flat legacy keys too, so recreating a service with the same
        // name does not resurrect its old app list or per-app overrides.
        var prefs = PrefsStore.snapshot()
        var keysToRemove: [String] = []
        let prefix = PrefKey.legacyCustomBlacklistPrefix + service + "-"
        for key in prefs.keys where key.hasPrefix(prefix) {
            prefs.removeValue(forKey: key)
            keysToRemove.append(key)
        }
        let customAppsKey = PrefKey.legacyCustomAppsPrefix + service + PrefKey.legacyCustomAppsSuffix
        if prefs[customAppsKey] != nil {
            prefs.removeValue(forKey: customAppsKey)
            keysToRemove.append(customAppsKey)
        }
        if !keysToRemove.isEmpty {
            PrefsStore.apply(prefs, removing: keysToRemove)
        }
    }

    /// Asks for a service name, rejecting one that is already taken.
    private func promptForServiceName(
        title: String,
        initialValue: String?,
        confirmTitle: String,
        completion: @escaping (String) -> Void
    ) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Service Name".localized
            field.text = initialValue
        }
        alert.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel))

        // The check runs when the alert's handler fires, not before, so the
        // retry re-prompts with the same title.
        alert.addAction(UIAlertAction(title: confirmTitle, style: .default) { [weak self] _ in
            guard let self else { return }
            let name = alert.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty, name != initialValue else { return }

            guard self.customServices[name] == nil, !self.builtInServices.contains(name) else {
                let exists = UIAlertController(
                    title: title,
                    message: "A service with that name already exists.".localized,
                    preferredStyle: .alert
                )
                exists.addAction(UIAlertAction(title: "Ok".localized, style: .default) { _ in
                    self.promptForServiceName(
                        title: title, initialValue: initialValue,
                        confirmTitle: confirmTitle, completion: completion
                    )
                })
                self.present(exists, animated: true)
                return
            }
            completion(name)
        })
        present(alert, animated: true)
    }

    // MARK: - First-run tutorial

    /// Explains the Enabled/Disabled drag interaction the first time the list is
    /// opened; the explained control is not discoverable on its own.
    private func showTutorialIfNeeded() {
        let key = "ServiceListTutorialShown"
        guard !PrefsStore.prefs().bool(key) else { return }
        PrefsStore.setValue(true, forKey: key, notify: false)

        guard let window = keyWindow else { return }
        let overlay = UIView(frame: window.bounds)
        overlay.alpha = 0
        overlay.backgroundColor = UIColor(white: 0, alpha: 0.9)

        let label = UILabel()
        label.font = .systemFont(ofSize: UIFont.systemFontSize * 1.5, weight: .thin)
        label.textColor = .white
        label.text = "After setting up your services, remember to enable them by using the "
            .localized + "'Edit' button in the top right of this page and dragging your services "
            .localized + "to the 'Enabled' section at the top.\n\nTap anywhere to continue.".localized
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(label)

        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: 270),
            label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        ])

        window.addSubview(overlay)
        UIView.animate(withDuration: 0.3) { overlay.alpha = 1 }

        // The dismiss gesture is armed after a beat: an immediate one would let
        // the tap that opened the page also close the tutorial.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            overlay.addGestureRecognizer(
                UITapGestureRecognizer(target: self, action: #selector(self.dismissTutorial(_:)))
            )
        }
    }

    @objc private func dismissTutorial(_ gesture: UITapGestureRecognizer) {
        guard let overlay = gesture.view else { return }
        UIView.animate(withDuration: 0.3, animations: { overlay.alpha = 0 }) { _ in
            overlay.removeFromSuperview()
        }
    }

    /// The frontmost window, which is where the tutorial overlay has to be added
    /// so it covers the whole Settings screen.
    private var keyWindow: UIWindow? {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes
        where scene.activationState == .foregroundActive {
            if let window = scene.windows.first(where: \.isKeyWindow) { return window }
        }
        return nil
    }
}

// MARK: - Table data source

extension ServiceListController {
    public func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sectionItems[Section(rawValue: section) ?? .enabled]?.count ?? 0
    }

    public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        (Section(rawValue: section) ?? .enabled).title.localized
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellIdentifier, for: indexPath)
        guard let service = service(at: indexPath) else { return cell }

        cell.textLabel?.text = Localization.serviceDisplayName(service)
        cell.accessoryType = .disclosureIndicator
        cell.imageView?.image = serviceImages[service]
        return cell
    }

    public func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { true }

    public func tableView(
        _ tableView: UITableView,
        moveRowAt sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath
    ) {
        lastTargetService = nil
        lastTargetIndexPath = nil
        guard let service = service(at: sourceIndexPath),
              let from = Section(rawValue: sourceIndexPath.section),
              let to = Section(rawValue: destinationIndexPath.section)
        else { return }

        sectionItems[from]?.remove(at: sourceIndexPath.row)
        sectionItems[to]?.insert(service, at: destinationIndexPath.row)
    }

    public func tableView(
        _ tableView: UITableView,
        editingStyleForRowAt indexPath: IndexPath
    ) -> UITableViewCell.EditingStyle {
        guard let service = service(at: indexPath) else { return .none }
        return isCustom(service) ? .delete : .none
    }

    public func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete, let service = service(at: indexPath),
              let section = Section(rawValue: indexPath.section) else { return }

        deleteService(service)
        sectionItems[section]?.remove(at: indexPath.row)
        tableView.deleteRows(at: [indexPath], with: .left)
    }

    /// Keeps a dragged row alphabetical within its target section.
    ///
    /// Without this a row would land wherever it was dropped, and the list would
    /// re-sort out from under it the next time it reloaded.
    public func tableView(
        _ tableView: UITableView,
        targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath,
        toProposedIndexPath proposedDestinationIndexPath: IndexPath
    ) -> IndexPath {
        // A drop back onto the row's own section is not a move.
        guard sourceIndexPath.section != proposedDestinationIndexPath.section else {
            return sourceIndexPath
        }
        guard let service = service(at: sourceIndexPath), let section = Section(rawValue: proposedDestinationIndexPath.section)
        else { return proposedDestinationIndexPath }

        // During a drag the servicesTable asks repeatedly for the same row; the previous
        // answer is reused so the row does not jitter between two positions.
        if lastTargetService == service, let lastTargetIndexPath {
            return lastTargetIndexPath
        }
        lastTargetService = service

        let sorted = ((sectionItems[section] ?? []) + [service])
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let indexPath = IndexPath(
            row: sorted.firstIndex(of: service) ?? 0, section: proposedDestinationIndexPath.section
        )
        lastTargetIndexPath = indexPath
        return indexPath
    }
}

// MARK: - Table delegate

extension ServiceListController {
    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let service = service(at: indexPath) else { return }

        // While editing, tapping a custom service renames it.
        if tableView.isEditing {
            if isCustom(service) { renameService(service) }
            return
        }

        let controller: ServiceController
        if let cached = loadedControllers[service] {
            controller = cached
        } else {
            controller = ServiceController(
                service: service,
                image: serviceImages[service] ?? UIImage.serviceIcon(named: service, isCustom: isCustom(service)),
                isCustom: isCustom(service)
            )
            loadedControllers[service] = controller
        }
        push(controller)
    }

    public func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        false
    }
}
