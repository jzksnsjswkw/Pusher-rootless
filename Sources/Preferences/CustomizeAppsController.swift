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

    private var service: String = ""
    private var isCustomService = false
    /// The per-app override objects, keyed by bundle ID.
    private var customApps: [String: [String: Any]] = [:]
    /// The service's own values, which new overrides are seeded from.
    private var serviceDefaults = Prefs()
    private var appIDs: [String] = []
    private var loadedControllers: [String: CustomAppController] = [:]
    private var appsTable: UITableView!

    public override func viewDidLoad() {
        super.viewDidLoad()

        service = specifier?.string(SpecifierRouting.PropertyKey.service) ?? ""
        isCustomService = specifier?.bool(SpecifierRouting.PropertyKey.isCustomService) ?? false

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
        serviceDefaults = PrefsStore.service(named: service, isCustom: isCustomService)
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
        let label = specifier.name?.components(separatedBy: " (").first ?? "App Customization"
        specifier.name = String(format: "%@ (%d total)".localized, label, customApps.count)

        // The list page's reload, reached through the non-retaining reference it
        // stashed on the specifier (a strong one would retain the page).
        if let value = specifier.property(forKey: SpecifierRouting.PropertyKey.listReference) as? NSValue,
           let list = value.nonretainedObjectValue as? PSListController {
            list.reloadSpecifier(specifier)
        }
    }

    /// Persists the override map back onto the service.
    private func save() {
        PrefsStore.updateService(named: service, isCustom: isCustomService) { object in
            object[PrefKey.customApps] = customApps
        }
    }

    /// Seeds a new override from the service's current values.
    ///
    /// Only the fields the service actually reads are seeded, so an override
    /// does not pin values the service ignores.
    private func makeDefaultOverride() -> [String: Any] {
        var override: [String: Any] = [PrefKey.enabled: true]

        switch service {
        case PushoverService.serviceName:
            override[PrefKey.devices] = serviceDefaults.array(PrefKey.devices)
            override[PrefKey.sounds] = serviceDefaults.array(PrefKey.sounds)
        case PushbulletService.serviceName:
            override[PrefKey.devices] = serviceDefaults.array(PrefKey.devices)
        case IFTTTService.serviceName:
            override[PrefKey.eventName] = serviceDefaults.string(PrefKey.eventName, default: "")
            override[PrefKey.includeIcon] = serviceDefaults.bool(PrefKey.includeIcon)
            override[PrefKey.curateData] = serviceDefaults.bool(PrefKey.curateData, default: true)
        case PusherReceiverService.serviceName:
            override[PrefKey.includeIcon] = serviceDefaults.bool(PrefKey.includeIcon, default: true)
            override[PrefKey.includeImage] = serviceDefaults.bool(PrefKey.includeImage, default: true)
            override[PrefKey.imageMaxWidth] = serviceDefaults[PrefKey.imageMaxWidth] ?? Pusher.defaultMaxWidth
            override[PrefKey.imageMaxHeight] = serviceDefaults[PrefKey.imageMaxHeight] ?? Pusher.defaultMaxHeight
            override[PrefKey.imageShrinkFactor] = serviceDefaults[PrefKey.imageShrinkFactor]
                ?? Pusher.defaultShrinkFactor
        case WechatService.serviceName:
            override[PrefKey.touser] = serviceDefaults.string(PrefKey.touser, default: "")
        default:
            guard isCustomService else { break }
            override[PrefKey.includeIcon] = serviceDefaults.bool(PrefKey.includeIcon)
            override[PrefKey.includeImage] = serviceDefaults.bool(PrefKey.includeImage)
            override[PrefKey.imageMaxWidth] = serviceDefaults[PrefKey.imageMaxWidth] ?? Pusher.defaultMaxWidth
            override[PrefKey.imageMaxHeight] = serviceDefaults[PrefKey.imageMaxHeight] ?? Pusher.defaultMaxHeight
            override[PrefKey.imageShrinkFactor] = serviceDefaults[PrefKey.imageShrinkFactor]
                ?? Pusher.defaultShrinkFactor
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
                service: service, appID: appID, appTitle: appDisplayName(appID),
                isCustomService: isCustomService
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
    private let service: String
    private let appID: String
    private let appTitle: String

    @objc public init(service: String, appID: String, appTitle: String, isCustomService: Bool) {
        self.service = service
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
    }

    /// Builds the page's cells from this app's override.
    private func buildSpecifiers() -> NSMutableArray {
        var all: [PSSpecifier] = []
        if let group = PSSpecifier.groupSpecifier(withName: "Customize".localized) {
            all = [group]
        }

        // The per-app cells come from the same builders the service page uses,
        // with the app ID attached so every value lands in this app's override.
        let cells = ServiceSpecifierBuilders.shared.builders(for: service, appID: appID)
        for specifier in cells {
            specifier.setProperty(service, forKey: SpecifierRouting.PropertyKey.service)
            specifier.setProperty(appID, forKey: SpecifierRouting.PropertyKey.customAppID)
            // A detail picker (Pushover's devices) reads the app from its own
            // key, spelled differently from the value cells'.
            if specifier.cellType == .linkCell {
                specifier.setProperty(appID, forKey: "customAppIDKey")
            }
        }
        all.append(contentsOf: cells)

        return NSMutableArray(array: all)
    }

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
@objc(NSPAppSelectionController)
public final class AppSelectionController: ATLApplicationListSelectionController {
    @objc public var callback: ((String) -> Void)?

    /// The currently selected app ID, exposed so the caller can preselect it.
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

    /// AltList calls this to seed the selection when the page opens.
    public override func loadPreferences() {}

    /// Reports the picked app.
    ///
    /// AltList has no dismissal hook for the single-select list, so the value is
    /// reported as the page goes away — which is when the framework has finished
    /// writing the selection into its own ivar.
    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        callback?(selectedAppID ?? "")
    }
}
