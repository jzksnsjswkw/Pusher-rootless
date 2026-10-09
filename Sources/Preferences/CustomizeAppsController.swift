import UIKit

/// The "per-app overrides" page for one service.
///
/// A service's settings normally apply everywhere. This page carves out
/// exceptions: pick an app, and its own copy of the service's settings is stored
/// under `customApps[appID]`, which completely replaces the service-wide values
/// for that app (see ``ServiceConfig/effective(forAppID:)``).
///
/// A new override starts as a *copy* of the service's current values, so an
/// override that is not customized further behaves exactly like the service.
@objc(NSPCustomizeAppsController)
public final class CustomizeAppsController: PlainViewController, UITableViewDataSource, UITableViewDelegate {
    private enum Section: Int, CaseIterable {
        case addApps
        case apps
    }

    private var instanceID: String = ""
    /// The descriptor name, which decides the override template.
    private var serviceType: String = ""
    /// The per-app override objects, keyed by bundle ID.
    private var customApps: [String: [String: Any]] = [:]
    /// The service's own values, which new overrides are seeded from.
    private var serviceDefaults = Prefs()
    private var appIDs: [String] = []
    private var loadedControllers: [String: CustomAppController] = [:]
    private var appsTable: UITableView!

    public override func viewDidLoad() {
        super.viewDidLoad()

        instanceID = specifier?.string(SpecifierRouting.PropertyKey.instanceID) ?? ""
        serviceType = specifier?.string(SpecifierRouting.PropertyKey.serviceType) ?? ""

        let frame = UIDevice.current.userInterfaceIdiom == .pad
            ? root?.view.bounds ?? view.bounds
            : view.bounds
        appsTable = UITableView(frame: frame, style: .grouped)
        appsTable.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellIdentifier)
        appsTable.dataSource = self
        appsTable.delegate = self
        view.addSubview(appsTable)

        navigationItem.title = "App Customization".localized
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Edit".localized, style: .plain, target: self, action: #selector(toggleEditing(_:))
        )
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // Commit any text field the service page left open, so its value is
        // stored before the overrides are seeded from it.
        let controllers = navigationController?.viewControllers ?? []
        if controllers.count > 1 {
            controllers[controllers.count - 2].view.endEditing(true)
        }

        reloadFromPrefs()
    }

    private static let cellIdentifier = "CustomAppCell"

    // MARK: - Data

    private func reloadFromPrefs() {
        serviceDefaults = PrefsStore.instance(instanceID)
        customApps = serviceDefaults.dict(PrefKey.customApps)?.raw.compactMapValues {
            $0 as? [String: Any]
        } ?? [:]
        appIDs = customApps.keys.sorted {
            appDisplayName($0).localizedCaseInsensitiveCompare(appDisplayName($1)) == .orderedAscending
        }
        updateSpecifierTitle()
        appsTable.reloadData()
    }

    private func appDisplayName(_ appID: String) -> String {
        LSApplicationProxy.applicationProxy(forIdentifier: appID)?.localizedName
            ?? "UNKNOWN APP".localized
    }

    /// Keeps the link's "(N total)" count in step with the override list.
    private func updateSpecifierTitle() {
        guard let specifier else { return }
        let label = AppListTitle.baseName(of: specifier.name)
        specifier.name = AppListTitle.titled(label.isEmpty ? "App Customization".localized : label,
                                             count: customApps.count)

        // The list page's reload, reached through the non-retaining reference it
        // stashed on the specifier (a strong one would retain the page).
        if let value = specifier.property(forKey: SpecifierRouting.PropertyKey.listReference) as? NSValue,
           let list = value.nonretainedObjectValue as? PSListController {
            list.reloadSpecifier(specifier)
        }
    }

    /// Persists the override map back onto the service.
    private func save() {
        PrefsStore.updateInstance(instanceID) { object in
            object[PrefKey.customApps] = customApps
        }
    }

    /// Seeds a new override from the service's current values.
    ///
    /// Only the fields the service actually reads are seeded, so an override
    /// does not pin values the service ignores. Which fields those are comes
    /// from the descriptor — its declared defaults and capabilities — rather
    /// than from a list kept here, so an option that a type cannot carry is not
    /// seeded and does not appear on the override page either.
    private func makeDefaultOverride() -> [String: Any] {
        var override: [String: Any] = [PrefKey.enabled: true]
        let descriptor = ServiceRegistry.service(named: serviceType)

        // The per-app settings every service's override owns: the app list's
        // siblings. These come from the instance's own values, so an override
        // starts out behaving exactly like the service.
        for (key, value) in descriptor.newOverridePrefs() {
            override[key] = value
        }

        switch serviceType {
        case PushoverService.serviceName:
            override[PrefKey.devices] = serviceDefaults.array(PrefKey.devices)
            override[PrefKey.sounds] = serviceDefaults.array(PrefKey.sounds)
        case PushbulletService.serviceName:
            override[PrefKey.devices] = serviceDefaults.array(PrefKey.devices)
        case WechatService.serviceName:
            override[PrefKey.touser] = serviceDefaults.string(PrefKey.touser, default: "")
        case IFTTTService.serviceName:
            override[PrefKey.eventName] = serviceDefaults.string(PrefKey.eventName, default: "")
        default:
            break
        }

        // The payload options the *type* supports, seeded from this instance's
        // own values. Ask the descriptor rather than assume: a service with no
        // image field must not have one pinned here, or the override would carry
        // a value nothing reads and the page would show a cell for it.
        if descriptor.supportsIcon {
            override[PrefKey.includeIcon] = serviceDefaults.bool(PrefKey.includeIcon)
        }
        if descriptor.supportsImage {
            override[PrefKey.includeImage] = serviceDefaults.bool(PrefKey.includeImage)
            override[PrefKey.imageMaxWidth]
                = serviceDefaults[PrefKey.imageMaxWidth] ?? Pusher.defaultMaxWidth
            override[PrefKey.imageMaxHeight]
                = serviceDefaults[PrefKey.imageMaxHeight] ?? Pusher.defaultMaxHeight
            override[PrefKey.imageShrinkFactor]
                = serviceDefaults[PrefKey.imageShrinkFactor] ?? Pusher.defaultShrinkFactor
        }
        // A webhook's own request controls, which its type carries.
        if serviceType == CustomService.serviceName {
            override[PrefKey.curateData] = serviceDefaults.bool(PrefKey.curateData, default: true)
        }
        return override
    }

    // MARK: - Editing

    @objc private func toggleEditing(_ sender: UIBarButtonItem) {
        appsTable.setEditing(!appsTable.isEditing, animated: true)
        sender.title = appsTable.isEditing ? "Done".localized : "Edit".localized
    }

    /// Adds the picked apps, ignoring ones that already have an override.
    private func addApps(_ picked: [String]) {
        for appID in picked where customApps[appID] == nil {
            customApps[appID] = makeDefaultOverride()
        }
        save()
        reloadFromPrefs()
    }

    private func deleteApp(at indexPath: IndexPath) {
        guard indexPath.section == Section.apps.rawValue, indexPath.row < appIDs.count else { return }
        customApps.removeValue(forKey: appIDs[indexPath.row])
        save()
        reloadFromPrefs()
    }

    /// Presents the multi-select app picker from AltList.
    private func presentAppPicker() {
        let picker = AppMultiSelectionController()
        picker.callback = { [weak self] picked in
            self?.addApps(picked)
        }
        picker.useSearchBar = true

        let navigation = UINavigationController(rootViewController: picker)
        navigation.navigationBar.tintColor = Theme.activeTintColor
        present(navigation, animated: true)
    }

    /// The app's icon, through the private UIKit accessor.
    private func appIcon(_ appID: String) -> UIImage? {
        ApplicationIcon.image(forBundleID: appID)
    }
}

// MARK: - Table

extension CustomizeAppsController {
    public func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .addApps: return 1
        case .apps: return appIDs.count
        case .none: return 0
        }
    }

    public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .addApps: return nil
        case .apps: return appIDs.isEmpty ? "No Apps".localized : "Apps".localized
        case .none: return nil
        }
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellIdentifier, for: indexPath)
        cell.accessoryType = .disclosureIndicator
        cell.imageView?.image = nil

        switch Section(rawValue: indexPath.section) {
        case .addApps:
            cell.textLabel?.text = "Add Apps".localized
        case .apps:
            let appID = appIDs[indexPath.row]
            cell.textLabel?.text = appDisplayName(appID)
            cell.imageView?.image = appIcon(appID)
        case .none:
            break
        }
        return cell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        guard indexPath.section == Section.apps.rawValue else {
            presentAppPicker()
            return
        }

        let appID = appIDs[indexPath.row]
        let controller: CustomAppController
        if let cached = loadedControllers[appID] {
            controller = cached
        } else {
            controller = CustomAppController(
                instanceID: instanceID, serviceType: serviceType,
                appID: appID, appTitle: appDisplayName(appID)
            )
            loadedControllers[appID] = controller
        }
        push(controller)
    }

    public func tableView(
        _ tableView: UITableView,
        editingStyleForRowAt indexPath: IndexPath
    ) -> UITableViewCell.EditingStyle {
        indexPath.section > 0 ? .delete : .none
    }

    public func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete else { return }
        deleteApp(at: indexPath)
    }

    public func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard indexPath.section > 0 else {
            return UISwipeActionsConfiguration(actions: [])
        }
        let delete = UIContextualAction(style: .destructive, title: "Delete".localized) {
            [weak self] _, _, completion in
            self?.deleteApp(at: indexPath)
            completion(true)
        }
        let configuration = UISwipeActionsConfiguration(actions: [delete])
        // A full swipe would delete without confirmation; this list is easy to
        // trigger by accident while scrolling.
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    public func tableView(
        _ tableView: UITableView,
        shouldIndentWhileEditingRowAt indexPath: IndexPath
    ) -> Bool {
        indexPath.section > 0
    }
}

// MARK: - One app's override page

/// The override cells for a single app.
///
/// Reuses the same specifier builders as the service page, with the app ID
/// attached, so the two pages can never drift apart in which settings they
/// offer.
@objc(NSPCustomAppController)
public final class CustomAppController: ListController {
    private let instanceID: String
    private let serviceType: String
    private let appID: String
    private let appTitle: String

    @objc public init(instanceID: String, serviceType: String, appID: String, appTitle: String) {
        self.instanceID = instanceID
        self.serviceType = serviceType
        self.appID = appID
        self.appTitle = appTitle
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = appTitle

        // Installed here as well as through the getter: the framework reads the
        // `_specifiers` ivar directly during setup, and the getter covers the
        // case where it discards the array later (backgrounding the app).
        installSpecifiers(buildSpecifiers())
        seedImageSizing()
    }

    /// Records whether the installed page shows the image-sizing rows, from the
    /// same judgement the builders used.
    private func seedImageSizing() {
        showsImageSizing = ServiceSpecifierBuilders.includeImage(
            stored: PrefsStore.customAppPrefs(service: instanceID, appID: appID),
            fallback: PrefsStore.instance(instanceID)
        )
    }

    /// Builds the page's cells from this app's override.
    private func buildSpecifiers() -> NSMutableArray {
        var all: [PSSpecifier] = []
        if let group = PSSpecifier.groupSpecifier(withName: "Customize".localized) {
            all = [group]
        }

        // The per-app cells come from the same builders the service page uses,
        // with the app ID attached so every value lands in this app's override.
        // The per-app cells come from the same builders the service page uses,
        // already routed into this app's override by the builder.
        let cells = ServiceSpecifierBuilders.shared.builders(
            for: serviceType, instanceID: instanceID, appID: appID,
            pageObserver: self
        )
        all.append(contentsOf: cells)

        return NSMutableArray(array: all)
    }

    /// Rebuilds the page when "Include Image" has been switched, so the sizing
    /// rows follow it here too; see ``ServiceController/cellDidChange(_:to:)``.
    @objc func cellDidChange(_ key: String, to value: Any?) {
        guard key == PrefKey.includeImage else { return }
        let isOn = (value as? NSNumber)?.boolValue ?? (value as? Bool) ?? false
        guard let previous = showsImageSizing else {
            showsImageSizing = isOn
            return
        }
        guard previous != isOn else { return }
        showsImageSizing = isOn
        installSpecifiers(buildSpecifiers())
    }

    /// Whether the installed page shows the image-sizing rows.
    private var showsImageSizing: Bool?

    /// The cells, rebuilt whenever the framework has discarded the array.
    public override func rebuildSpecifiers() -> NSMutableArray? {
        buildSpecifiers()
    }
}

// MARK: - App icons

/// Resolves an app's icon through the private UIKit accessor that Settings
/// itself uses.
enum ApplicationIcon {
    private typealias IconFunction = @convention(c) (
        AnyObject, Selector, NSString, Int32, CGFloat
    ) -> AnyObject?

    /// The installed app's icon, or `nil` when the app is unknown.
    static func image(forBundleID appID: String) -> UIImage? {
        let selector = NSSelectorFromString("_applicationIconImageForBundleIdentifier:format:scale:")
        guard let cls = Runtime.cls("UIImage"),
              let method = class_getClassMethod(cls, selector)
        else { return nil }
        let call = unsafeBitCast(method_getImplementation(method), to: IconFunction.self)
        return call(cls, selector, appID as NSString, 0, UIScreen.main.scale) as? UIImage
    }
}

// MARK: - AltList pickers

/// The multi-select app picker, used to add apps to a list.
///
/// AltList reports the selection by reading its own ivars when the page is
/// dismissed; this bridges that to a Swift callback so the callers do not have
/// to reach into AltList's state.
@objc(NSPAppMultiSelectionController)
public final class AppMultiSelectionController: ATLApplicationListMultiSelectionController {
    @objc public var callback: (([String]) -> Void)?

    public override func prepareForPopulatingSections() {
        alphabeticIndexingEnabled = true
    }

    /// AltList calls this on dismissal, which is where the selection is read.
    ///
    /// `_selectedApplications` is AltList's own `@protected` ivar with no
    /// accessor, so it is read through the runtime.
    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let selected = Runtime.getIvar(self, "_selectedApplications", as: NSSet.self)
        callback?(selected?.allObjects.compactMap { $0 as? String } ?? [])
    }
}

/// The single-select app picker, used by the log viewer's app filter.
///
/// AltList calls `loadPreferences` when the page is built and
/// `savePreferences` when a selection is made, so the value travels through the
/// framework's own lifecycle rather than a view-transition hook.
@objc(NSPAppSelectionController)
public final class AppSelectionController: ATLApplicationListSelectionController {
    @objc public var callback: ((String) -> Void)?

    /// The app ID to preselect, set by the caller before pushing.
    ///
    /// `_selectedApplicationID` is AltList's own `@protected` ivar; it has no
    /// accessor, so it is read and written through the runtime.
    @objc public var selectedAppID: String? {
        get { Runtime.getIvar(self, "_selectedApplicationID", as: NSString.self) as String? }
        set { Runtime.setIvar(self, "_selectedApplicationID", newValue as NSString?) }
    }

    public override func prepareForPopulatingSections() {
        alphabeticIndexingEnabled = true
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        // Without a way to unset a wrong pick, the only way back to "no filter"
        // is deleting the preference by hand. The deselect button reports an
        // empty selection through the same callback.
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Deselect".localized, style: .plain,
            target: self, action: #selector(deselect)
        )
    }

    @objc private func deselect() {
        Runtime.setIvar(self, "_selectedApplicationID", nil as NSString?)
        savePreferences()
    }

    /// Seeds the picker with the caller's preselection.
    public override func loadPreferences() {
        Runtime.setIvar(self, "_selectedApplicationID", selectedAppID as NSString?)
    }

    /// Reports the picked app and pops, exactly as the original did.
    ///
    /// Anything that is not a picked identifier — no selection, or an ivar that
    /// is not a string — reports an empty string, which the caller treats as
    /// "no filter".
    public override func savePreferences() {
        let picked = Runtime.getIvar(self, "_selectedApplicationID", as: NSString.self) as String?
        callback?(picked ?? "")
        navigationController?.popViewController(animated: true)
    }
}
