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
public class ServiceListController: PlainViewController, ServiceTransferHost {
    private static let cellIdentifier = "ServiceCell"

    /// Every instance this list shows, in order.
    private var instances: [ServiceInstance] = []
    /// Icons, keyed by instance type (not by instance — two instances of one
    /// service share their artwork).
    private var icons: [String: UIImage] = [:]
    /// One logo per row, in the table's own order.
    private var logos: [UIImage?] = []
    private var loadedControllers: [String: ServiceController] = [:]

    private var servicesTable: UITableView!
    private var addButton: UIBarButtonItem!
    private var transferButton: UIBarButtonItem!
    /// The edit/done button, kept so toggling editing can swap the add button
    /// in beside it without rebuilding the bar.
    private var rightButton: UIBarButtonItem!
    /// Set while the list is reordered, so the visual order is kept without
    /// re-sorting underneath the drag.
    private var isReordering = false

    /// The initializers the Preferences framework uses to build a detail page.
    ///
    /// A specifier plist names a controller *class*, and the framework creates it
    /// through one of these two. Declaring the scoped initializer above took the
    /// inherited ones away, so both have to be written out: without
    /// `init(nibName:bundle:)` the framework's call reaches an unimplemented
    /// initializer, and without `init(forContentSize:)` Swift's synthesized stub
    /// for it forwards through `objc_msgSendSuper2` without putting `self` in the
    /// receiver slot — the same trap that a `PSViewController` subclass hits, and
    /// here it lands in `CreateDetailControllerInstanceWithClass`.
    ///
    /// The page they build is the unscoped one, which is what the home page's
    /// "Instances" row means; the "Services" row — the types a user defines — is
    /// built by ``CustomServiceListController``.
    public override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    @objc public override init(forContentSize contentSize: CGSize) {
        super.init(forContentSize: contentSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
        rightButton = UIBarButtonItem(
            title: "Edit".localized, style: .plain, target: self, action: #selector(toggleEditing(_:))
        )
        // Import and export live behind this menu rather than on a page of their
        // own: there is nothing to look at, only something to do.
        transferButton = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            menu: UIMenu(title: "", children: [])
        )
        navigationItem.title = "Instances".localized
        // Actions sit on the right, as on the Services page: the left slot is the
        // back button, and the add button must stay reachable in edit mode, when
        // tapping a row renames rather than opens.
        navigationItem.rightBarButtonItems = [addButton, rightButton, transferButton]
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
        // The service's own logo wins; the built-in artwork is the fallback, so
        // a row always shows something.
        //
        // Keyed by instance rather than by type: two instances of one service
        // are separate destinations and may carry different logos, which is the
        // whole reason a logo is attached to the instance.
        logos = instances.map { instance in
            ServiceIcon.logo(forInstanceID: instance.id)
                ?? ServiceArtwork.image(forType: instance.type)
        }
        servicesTable.reloadData()
        updateTransferMenu()
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

    /// Shows what an import added.
    ///
    /// The alert is presented over this page, so the list underneath has to be
    /// rebuilt when the user dismisses it — otherwise the services that just
    /// arrived would only appear on the next visit.
    @objc public func reloadAfterTransfer() {
        reloadData()
    }

    /// Rebuilds the transfer menu against what there is right now.
    ///
    /// Export is meaningless with nothing configured, so it is disabled rather
    /// than offered and refused — import stays, since a device with nothing on it
    /// is exactly where an import is most wanted.
    private func updateTransferMenu() {
        let canExport = !instances.isEmpty
        let export = UIAction(
            title: "Export…".localized,
            image: UIImage(systemName: "square.and.arrow.up")
        ) { [weak self] _ in
            guard let self else { return }
            ServiceTransfer.offerExport(from: self, scope: .instances)
        }
        export.attributes = canExport ? [] : .disabled

        let importAction = UIAction(
            title: "Import…".localized,
            image: UIImage(systemName: "square.and.arrow.down")
        ) { [weak self] _ in
            guard let self else { return }
            ServiceTransfer.offerImport(from: self, scope: .instances)
        }
        transferButton?.menu = UIMenu(title: "", children: [export, importAction])
    }

    @objc private func toggleEditing(_ sender: UIBarButtonItem) {
        servicesTable.setEditing(!servicesTable.isEditing, animated: true)
        sender.title = servicesTable.isEditing ? "Done".localized : "Edit".localized
        // The bar never changes shape, so "Done" is always there to leave edit
        // mode with and the add button is always usable.

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
        let picker = ServiceTypePickerController { [weak self] type, name in
            guard let self else { return }
            ServiceInstanceStore.add(type: type, name: name)
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

    /// Renames one instance, refusing a name another instance already has.
    ///
    /// A rename is the same question as the name field when adding, so it goes
    /// through the same check; otherwise the list could still end up with two
    /// rows that read alike.
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

            guard ServiceInstanceStore.isNameAvailable(name, excluding: instance.id) else {
                self.showNameTaken(name)
                return
            }

            ServiceInstanceStore.update(id: instance.id) { $0[PrefKey.instanceName] = name }
            // The page's title view cached the old name.
            self.loadedControllers.removeValue(forKey: instance.id)
            self.reloadData()
        })
        present(alert, animated: true)
    }

    /// Re-presents the rename prompt after a rejected name, so the user can
    /// correct it without starting over.
    private func showNameTaken(_ name: String) {
        let alert = UIAlertController(
            title: "Name Already Used".localized,
            message: String(
                format: "Another service is already named \"%@\". Choose a different name.".localized,
                name
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Ok".localized, style: .default))
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
            // Every service — built-in, webhook or script-defined — is
            // configured through the same page; only the cells differ, and those
            // come from the type's own description.
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

        // A content configuration rather than `textLabel`: the marked row needs a
        // second line, and a plain `UITableViewCell` has no detail label to put it
        // in — assigning to one would silently do nothing.
        var content = UIListContentConfiguration.subtitleCell()
        content.text = Localization.instanceDisplayName(instance)
        if instance.hasMissingService {
            content.secondaryText = "Service deleted".localized
            content.secondaryTextProperties.color = .systemRed
        }
        content.image = indexPath.row < logos.count
            ? logos[indexPath.row]
            : icons[instance.type]
        content.imageProperties.maximumSize = CGSize(width: 29, height: 29)
        cell.contentConfiguration = content
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
        // `delete` reloads the table itself, so there is no row deletion here.
        //
        // Telling the table to delete the row as well is what crashed the edit
        // mode: by then the table has already been reloaded against the new
        // array, and `deleteRows` then removes a row the data source no longer
        // has — an inconsistency UIKit asserts on. The swipe path never had this
        // because it does not touch the table directly.
        delete(instance)
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
/// The built-in artwork a service type ships with.
///
/// Distinct from ``ServiceIcon``, which is the *user's own* icon for a service:
/// this is the bundled fallback the service list draws when they have not
/// chosen one.
enum ServiceArtwork {
    /// The bundle resource name for a service type's artwork.
    ///
    /// A specifier's `icon` property takes the *name*, which the framework then
    /// loads from the page's bundle — so the name is what the rows are given.
    ///
    /// The generic webhook has no artwork of its own (there is one shared image
    /// for every user-defined service), and the framework does not fall back
    /// when a named resource is missing, so its rows name the shared image.
    static func resourceName(forType type: String) -> String {
        guard ServiceRegistry.isBuiltIn(type) else { return "DefaultService" }
        return "BuiltInService_\(type)"
    }

    /// The icon for a service type, falling back to the shared default so a
    /// service without its own artwork still shows one.
    static func image(forType type: String) -> UIImage? {
        UIImage.pusher(named: resourceName(forType: type))
            ?? UIImage.pusher(named: "DefaultService")
    }
}

// MARK: - Type picker

/// The "what do you want to add" page: the instance's name, then the service
/// type to create it as.
///
/// The name is entered here rather than defaulted after the fact because it is
/// the only thing distinguishing two instances of one service in the list: two
/// rows reading "Pushover" would be indistinguishable, and a name chosen
/// afterwards is easy to forget to change. It is therefore required, and a
/// duplicate is refused.
///
/// The page is a `PSListController` so the name row is the framework's own
/// editing cell — the same cell the service pages use. That is not just a
/// shortcut for the look: an editable cell's text field is created while the
/// framework lays the row out, so a cell constructed outside a real table (as a
/// hand-built row would be) never gets one at all.
@objc(NSPushServiceTypePickerController)
public final class ServiceTypePickerController: ListController {
    private let onPick: (String, String) -> Void
    private let descriptors: [ServiceDescriptor]
    /// Names already in use, case-folded for comparison.
    private let takenNames: Set<String>

    private static let nameGroupIdentifier = "nameGroup"
    private static let nameCellIdentifier = "nameCell"
    /// The identifier assigned to a type row, prefixed so it cannot collide with
    /// the name cell's.
    private static func typeIdentifier(_ type: String) -> String { "type:\(type)" }
    private static let typePropertyKey = "serviceType"
    /// The row's image, passed to the cell directly.
    private static let iconImagePropertyKey = "iconImage"
    /// The cell class the framework renders the row with (`PSCellClassKey`).
    private static let cellClassPropertyKey = "cellClass"

    /// What the user has typed so far.
    private var enteredName = ""
    /// Why the current name cannot be used, shown under the field.
    private var nameError: String?
    private var builtSpecifiers: NSMutableArray?
    /// Fields already given a change listener, so a recycled row is not wired up
    /// twice.
    private var observedFields: Set<ObjectIdentifier> = []

    /// - Parameters:
    ///   - restrictedTo: the types to offer, or `nil` for every type. The custom
    ///     list passes its own scope, so the page it opens offers only the kinds
    ///     of service that can be listed there.
    ///   - onPick: called with the chosen service type and the name the user
    ///     entered (already trimmed).
    public init(
        restrictedTo: Set<String>? = nil,
        onPick: @escaping (String, String) -> Void
    ) {
        self.onPick = onPick
        // The user's own definitions are types too, so they appear here next to
        // the built-ins; that is what makes writing a script worthwhile.
        self.descriptors = ServiceRegistry.allAddableServices().filter { descriptor in
            restrictedTo.map { $0.contains(descriptor.name) } ?? true
        }
        self.takenNames = Set(ServiceInstanceStore.instances().map { Self.normalized($0.name) })
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A name reduced to the form two names are compared in: trimmed, and
    /// case-folded so "bark" cannot sit beside "Bark".
    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = "Add Instance".localized
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancel)
        )
        buildSpecifiers()
        installSpecifiers(builtSpecifiers ?? NSMutableArray())
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Focus the required field so the cursor starts where the user has to
        // act first. Deferred to here because the cell's field does not exist
        // until the row has been laid out.
        observeNameField()
        nameField?.becomeFirstResponder()
    }

    public override func rebuildSpecifiers() -> NSMutableArray? {
        buildSpecifiers()
        return builtSpecifiers
    }

    @objc private func cancel() {
        dismiss(animated: true)
    }

    // MARK: - Specifiers

    private func buildSpecifiers() {
        var all: [PSSpecifier] = []

        // Group specifiers are what the framework derives its sections from, so
        // the layout is expressed here rather than by overriding the table's
        // section/row counts (which the framework's own flat array would
        // contradict).
        let nameGroup = PSSpecifier.emptyGroup()
        nameGroup?.identifier = Self.nameGroupIdentifier
        nameGroup?.setProperty(nameError, forKey: "footerText")

        let nameSpecifier = PSSpecifier.preferenceSpecifierNamed(
            "Name".localized,
            target: self,
            set: #selector(setName(_:specifier:)),
            get: #selector(readName(_:)),
            detail: nil,
            cell: .editTextCell,
            edit: nil
        )
        nameSpecifier?.identifier = Self.nameCellIdentifier
        nameSpecifier?.setProperty(true, forKey: "enabled")
        nameSpecifier?.setProperty(true, forKey: "noAutoCorrect")

        all.append(contentsOf: [nameGroup, nameSpecifier].compactMap { $0 })

        let typesGroup = PSSpecifier.groupSpecifier(withName: "Service Type".localized)
        if let typesGroup { all.append(typesGroup) }

        for descriptor in descriptors {
            let specifier = PSSpecifier.preferenceSpecifierNamed(
                Localization.serviceDisplayName(descriptor.displayName),
                target: nil, set: nil, get: nil,
                detail: nil, cell: .linkCell, edit: nil
            )
            specifier?.identifier = Self.typeIdentifier(descriptor.name)
            // The image travels on the specifier rather than as an `icon` name:
            // that property is resolved through the framework's lazy icon
            // loading, which a row without a bundle-backed icon set never
            // triggers. Handing the cell the image directly is unconditional.
            // A user's definition shows the logo its author chose — the same
            // picture the definition's own row and its instances show — so one
            // kind of service is not drawn two ways depending on the page.
            specifier?.setProperty(
                ServiceIcon.logo(forDefinitionID: descriptor.name)
                    ?? ServiceArtwork.image(forType: descriptor.name),
                forKey: Self.iconImagePropertyKey
            )
            // The row does not navigate, so it needs a detail controller to be
            // treated as a live link, and a cell class that draws no chevron.
            specifier?.detailControllerClass = ServiceTypeDetailPlaceholder.self
            specifier?.setProperty(ServiceTypeCell.self, forKey: Self.cellClassPropertyKey)
            specifier?.setProperty(descriptor.name, forKey: Self.typePropertyKey)
            if let specifier { all.append(specifier) }
        }

        builtSpecifiers = NSMutableArray(array: all)
    }

    /// The name row's text field, once the framework has laid the row out.
    ///
    /// `PSTableCell` keeps the field in its subviews and exposes no accessor, so
    /// the first descendant that is a `UITextField` is the one.
    private var nameField: UITextField? {
        guard let specifier = specifier(forID: Self.nameCellIdentifier),
              let indexPath = indexPath(for: specifier),
              let cell = table?.cellForRow(at: indexPath)
        else { return nil }
        return Self.firstTextField(in: cell)
    }

    /// The name as it stands *right now*.
    ///
    /// The field's own text is authoritative rather than ``enteredName``: the
    /// framework's editing cell calls its setter when editing ends, so between
    /// keystrokes and that moment the setter's value is stale. Reading the field
    /// is what makes a type row tapped straight after typing create the name the
    /// user just entered.
    private func currentName() -> String {
        (nameField?.text ?? enteredName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Watches the field so the duplicate warning appears as the user types,
    /// rather than only when the framework calls the setter.
    private func observeNameField() {
        guard let field = nameField, !observedFields.contains(ObjectIdentifier(field)) else { return }
        observedFields.insert(ObjectIdentifier(field))
        field.addTarget(self, action: #selector(nameFieldChanged(_:)), for: .editingChanged)
    }

    @objc private func nameFieldChanged(_ field: UITextField) {
        enteredName = field.text ?? ""
        setError(duplicateError(for: currentName()))
    }

    private static func firstTextField(in view: UIView) -> UITextField? {
        for subview in view.subviews {
            if let field = subview as? UITextField { return field }
            if let found = firstTextField(in: subview) { return found }
        }
        return nil
    }

    /// Re-attaches the name field's listener when its row is (re)displayed.
    ///
    /// A section reload — which a changing validation message triggers — builds a
    /// new cell and a new field, which the one-off wiring in `viewDidAppear`
    /// would not reach.
    public override func tableView(
        _ tableView: UITableView,
        willDisplay cell: UITableViewCell,
        forRowAt indexPath: IndexPath
    ) {
        guard let specifier = specifier(at: indexPath),
              specifier.identifier == Self.nameCellIdentifier
        else { return }
        observeNameField()
    }

    // MARK: - Selection

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        guard let specifier = specifier(at: indexPath),
              let type = specifier.property(forKey: Self.typePropertyKey) as? String
        else { return }

        // The name is settled before the type is chosen, so a rejected tap
        // returns the cursor to the field rather than leaving the user to work
        // out why nothing happened.
        let name = currentName()
        guard let error = validationError(for: name) else {
            // Dismiss first so the presenting page can push the new instance's
            // settings without fighting the modal transition.
            dismiss(animated: true) { [onPick] in
                onPick(type, name)
            }
            return
        }
        setError(error)
        nameField?.becomeFirstResponder()
    }

    // MARK: - Name value

    /// The cell's getter.
    ///
    /// Returns the field's live text, untrimmed. Both parts matter: the
    /// framework re-reads this whenever it refreshes the row (including when the
    /// field regains focus), so returning a stored value would overwrite what the
    /// user is typing with the last value the setter saw; and returning a trimmed
    /// value would eat a trailing space mid-word.
    @objc public func readName(_ specifier: PSSpecifier) -> Any? {
        nameField?.text ?? enteredName
    }

    /// The cell's setter.
    ///
    /// The framework's editing cell calls this when editing ends, so it is not a
    /// per-keystroke signal; ``observeNameField()`` covers the live case.
    @objc public func setName(_ value: Any?, specifier: PSSpecifier) {
        enteredName = (value as? String) ?? ""
        setError(duplicateError(for: currentName()))
    }

    /// Updates the footer under the name field.
    ///
    /// A group specifier's `footerText` is read when the section is laid out, so
    /// the section is reloaded for a newly shown or newly hidden message to take
    /// effect.
    private func setError(_ message: String?) {
        guard nameError != message else { return }
        nameError = message

        guard let group = specifier(forID: Self.nameGroupIdentifier),
              let indexPath = indexPath(for: group)
        else { return }
        group.setProperty(message, forKey: "footerText")
        table?.reloadSections(IndexSet(integer: indexPath.section), with: .none)
    }

    // MARK: - Validation

    /// Why a name cannot be used, or `nil` when it can.
    private func validationError(for name: String) -> String? {
        guard !name.isEmpty else { return "Enter a name for this service.".localized }
        return duplicateError(for: name)
    }

    private func duplicateError(for name: String) -> String? {
        guard takenNames.contains(Self.normalized(name)) else { return nil }
        return String(
            format: "Another service is already named \"%@\". Choose a different name.".localized,
            name
        )
    }
}

// MARK: - Type row cell

/// The cell a service type is listed with.
///
/// It is the framework's own `PSLinkCell` — so the row keeps the standard
/// Settings metrics and icon placement — with two differences, both because this
/// row does not navigate:
///
///  * the disclosure chevron is hidden, since there is no page to point at;
///  * the icon is taken from the specifier as an image, because the framework's
///    own `icon` handling resolves a *name* through lazy icon loading that a row
///    without bundle-backed artwork never triggers.
///
/// The class reaches the framework through the specifier's `cellClass` property;
/// a subclass of a cell is never picked up on its own, because the class is
/// chosen from the specifier.
@objc(NSPushServiceTypeCell)
final class ServiceTypeCell: PSTableCell {
    override func refreshCellContents(with specifier: PSSpecifier) {
        super.refreshCellContents(with: specifier)

        cellEnabled = true
        // `forceHideDisclosureIndicator` is the framework's own switch for a
        // tappable row that does not navigate. It is absent from the vendored
        // header, so it goes through the runtime like this project's other
        // unexposed members.
        Runtime.sendBool(self, "setForceHideDisclosureIndicator:", true)

        if let image = specifier.property(forKey: "iconImage") as? UIImage {
            icon = image
        }
    }
}

/// Never instantiated. It exists so a type row has a `detailControllerClass`,
/// which is what tells the framework the row is a live link rather than a
/// disabled one.
final class ServiceTypeDetailPlaceholder: PSViewController {}
