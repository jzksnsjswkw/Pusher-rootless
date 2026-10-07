import UIKit
import Preferences

/// The service list: every configured push destination, in the order the
/// pipeline tries them.
///
/// The list is a plain array of instances rather than two fixed sections, because
/// a service type is no longer something you "turn on" — it is something you add.
/// Two Pushover accounts and three Bark servers are ordinary rows here, each with
/// its own settings, app list and log.
///
/// The list owns the two things that decide whether a push is delivered: whether
/// an instance is on, and the order instances are tried in. Both are only
/// persisted when editing ends, so a half-finished drag is never saved.
@objc(NSPServiceListController)
public final class ServiceListController: PlainViewController {
    private static let cellIdentifier = "ServiceCell"

    /// Every instance, in order.
    private var instances: [ServiceInstance] = []
    /// Icons, keyed by instance type (not by instance — two instances of one
    /// service share their artwork).
    private var icons: [String: UIImage] = [:]
    private var loadedControllers: [String: ServiceController] = [:]

    private var servicesTable: UITableView!
    private var addButton: UIBarButtonItem!
    /// Set while the list is reordered, so the visual order is kept without
    /// re-sorting underneath the drag.
    private var isReordering = false

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()

        let frame = UIDevice.current.userInterfaceIdiom == .pad
            ? root?.view.bounds ?? view.bounds
            : view.bounds
        servicesTable = UITableView(frame: frame, style: .insetGrouped)
        servicesTable.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellIdentifier)
        servicesTable.dataSource = self
        servicesTable.delegate = self
        servicesTable.allowsSelectionDuringEditing = true
        view.addSubview(servicesTable)

        addButton = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(addService)
        )
        navigationItem.title = "Services".localized
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Edit".localized, style: .plain, target: self, action: #selector(toggleEditing(_:))
        )
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

    // MARK: - Data

    /// Re-reads the instances and reloads the table.
    private func reloadData() {
        instances = ServiceInstanceStore.instances()
        for instance in instances where icons[instance.type] == nil {
            icons[instance.type] = ServiceIcon.image(forType: instance.type)
        }
        servicesTable.reloadData()
    }

    /// The instance shown at one row.
    private func instance(at indexPath: IndexPath) -> ServiceInstance? {
        guard indexPath.row < instances.count else { return nil }
        return instances[indexPath.row]
    }

    /// Persists the current order and enabled flags.
    private func save() {
        ServiceInstanceStore.reorder(instances)
    }

    // MARK: - Editing

    @objc private func toggleEditing(_ sender: UIBarButtonItem) {
        servicesTable.setEditing(!servicesTable.isEditing, animated: true)
        sender.title = servicesTable.isEditing ? "Done".localized : "Edit".localized
        navigationItem.leftBarButtonItem = servicesTable.isEditing ? addButton : nil

        // Leaving edit mode is the persist point, so a drag in progress is
        // never written.
        if !servicesTable.isEditing { save() }
    }

    // MARK: - Adding

    /// Offers every kind of service to add.
    ///
    /// The picker lists the descriptors, not the configured instances, so adding
    /// a second Pushover account is the same gesture as adding the first.
    @objc private func addService() {
        let picker = ServiceTypePickerController { [weak self] type in
            guard let self else { return }
            ServiceInstanceStore.add(type: type)
            self.reloadData()

            // Open the new instance immediately: a freshly added service exists
            // only to be configured, and making the user find its row (possibly
            // below the fold) would be busywork.
            if let added = self.instances.last,
               let index = self.instances.firstIndex(where: { $0.id == added.id }) {
                self.servicesTable.scrollToRow(
                    at: IndexPath(row: index, section: 0), at: .middle, animated: false
                )
                self.open(added)
            }
        }
        let navigation = UINavigationController(rootViewController: picker)
        navigation.navigationBar.tintColor = Theme.activeTintColor
        present(navigation, animated: true)
    }

    // MARK: - Row actions

    private func rename(_ instance: ServiceInstance) {
        let alert = UIAlertController(
            title: "Rename Service".localized, message: nil, preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "Name".localized
            field.text = instance.name
        }
        alert.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename".localized, style: .default) { [weak self] _ in
            guard let self else { return }
            let name = alert.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return }

            ServiceInstanceStore.update(id: instance.id) { $0[PrefKey.instanceName] = name }
            self.loadedControllers.removeValue(forKey: instance.id)
            self.reloadData()
        })
        present(alert, animated: true)
    }

    private func delete(_ instance: ServiceInstance) {
        // The instance's log goes with it: an id is never reused, so keeping the
        // log would leave an orphan nothing can display.
        ServiceInstanceStore.remove(id: instance.id)
        loadedControllers.removeValue(forKey: instance.id)
        reloadData()
    }

    /// Toggles one instance on or off.
    @objc private func toggleEnabled(_ sender: UISwitch) {
        guard sender.tag < instances.count else { return }
        let instance = instances[sender.tag]
        ServiceInstanceStore.update(id: instance.id) {
            $0[PrefKey.serviceEnabled] = sender.isOn
        }
        instances[sender.tag].isEnabled = sender.isOn
    }

    /// Opens one instance's settings.
    private func open(_ instance: ServiceInstance) {
        let controller: ServiceController
        if let cached = loadedControllers[instance.id] {
            controller = cached
        } else {
            controller = ServiceController(instance: instance)
            loadedControllers[instance.id] = controller
        }
        push(controller)
    }

    // MARK: - First-run tutorial

    /// Explains the Edit/drag interaction, which is not discoverable on its own.
    private func showTutorialIfNeeded() {
        let key = "ServiceListTutorialShown"
        guard !PrefsStore.prefs().bool(key) else { return }
        PrefsStore.setValue(true, forKey: key, notify: false)

        let message = "Add the services you want with the + button, then use 'Edit' to "
            .localized + "drag them into the order you want them tried in. A notification is "
            .localized + "sent to every enabled service."
        TutorialOverlay.present(message, from: self, in: view.window)
    }
}

// MARK: - Table

extension ServiceListController: UITableViewDataSource, UITableViewDelegate {
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        instances.count
    }

    public func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        instances.isEmpty ? "No services yet. Tap + to add one.".localized : nil
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellIdentifier, for: indexPath)
        guard let instance = instance(at: indexPath) else { return cell }

        cell.textLabel?.text = Localization.instanceDisplayName(instance)
        cell.detailTextLabel?.text = nil
        cell.imageView?.image = icons[instance.type]
        cell.accessoryType = .disclosureIndicator

        // The switch is the row's own accessory, so it is rebuilt each time
        // rather than reused from a recycled cell.
        let toggle = UISwitch()
        toggle.isOn = instance.isEnabled
        toggle.tag = indexPath.row
        toggle.addTarget(self, action: #selector(toggleEnabled(_:)), for: .valueChanged)
        cell.accessoryView = toggle

        return cell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let instance = instance(at: indexPath) else { return }

        // While editing, tapping the row renames it (the delete control and the
        // drag handle are the other editing affordances).
        if tableView.isEditing {
            rename(instance)
            return
        }
        open(instance)
    }

    public func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        true
    }

    public func tableView(
        _ tableView: UITableView,
        moveRowAt sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath
    ) {
        guard sourceIndexPath.row < instances.count else { return }
        let moved = instances.remove(at: sourceIndexPath.row)
        let destination = min(destinationIndexPath.row, instances.count)
        instances.insert(moved, at: destination)
        // The order is only written when editing ends; the rows are renumbered
        // here so their switches keep pointing at the right instance.
        tableView.reloadData()
    }

    public func tableView(
        _ tableView: UITableView,
        editingStyleForRowAt indexPath: IndexPath
    ) -> UITableViewCell.EditingStyle {
        .delete
    }

    public func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete, let instance = instance(at: indexPath) else { return }
        delete(instance)
        tableView.deleteRows(at: [indexPath], with: .left)
    }

    public func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard !tableView.isEditing, let instance = instance(at: indexPath) else { return nil }

        let delete = UIContextualAction(style: .destructive, title: "Delete".localized) {
            [weak self] _, _, completion in
            self?.delete(instance)
            completion(true)
        }
        let configuration = UISwipeActionsConfiguration(actions: [delete])
        // A full swipe would delete without confirmation; the list is easy to
        // swipe by accident while scrolling.
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    public func tableView(
        _ tableView: UITableView,
        shouldIndentWhileEditingRowAt indexPath: IndexPath
    ) -> Bool {
        false
    }
}

// MARK: - Service icons

/// The artwork for a service type.
enum ServiceIcon {
    /// The icon for a service type, falling back to the shared default so a
    /// service without its own artwork still shows one.
    static func image(forType type: String) -> UIImage? {
        let name = ServiceRegistry.isBuiltIn(type)
            ? "BuiltInService_\(type)"
            : "CustomService_\(type)"
        return UIImage.pusher(named: name) ?? UIImage.pusher(named: "DefaultService")
    }
}

// MARK: - Type picker

/// The "what do you want to add" list.
///
/// Lists descriptors rather than instances, so it reads the same whether the
/// user already has three Bark servers or none.
@objc(NSPushServiceTypePickerController)
public final class ServiceTypePickerController: UITableViewController {
    private let onPick: (String) -> Void
    private let descriptors = ServiceRegistry.addableServices

    public init(onPick: @escaping (String) -> Void) {
        self.onPick = onPick
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = "Add Service".localized
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancel)
        )
    }

    @objc private func cancel() {
        dismiss(animated: true)
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        descriptors.count
    }

    public override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let descriptor = descriptors[indexPath.row]

        cell.textLabel?.text = Localization.serviceDisplayName(descriptor.displayName)
        cell.imageView?.image = ServiceIcon.image(forType: descriptor.name)
        cell.accessoryType = .none
        return cell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let descriptor = descriptors[indexPath.row]
        // Dismiss first so the presenting page can push the new instance's
        // settings without fighting the modal transition.
        dismiss(animated: true) { [onPick] in
            onPick(descriptor.name)
        }
    }
}
