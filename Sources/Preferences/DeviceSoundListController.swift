import UIKit

/// Base class for the Pushover/Pushbullet device and sound pickers.
///
/// Both lists have the same shape — a set of `{ name, id, enabled }` entries
/// stored under one key, refreshed from the provider's API, and rendered as
/// switches — so the list handling lives here and the two subclasses only say
/// which storage key and which API to use.
///
/// Sound lists and Pushbullet's device list allow exactly one selection;
/// Pushover's device list allows several.
@objc(NSPDeviceSoundListController)
open class DeviceSoundListController: ListController {
    /// The `{ name, id, enabled }` entries currently shown.
    var items: [[String: Any]] = []

    var instanceID: String?
    private var customAppID: String?
    private var isCustomApp = false
    private var updateButton: UIBarButtonItem?
    private var activityIndicator: UIActivityIndicatorView?
    private var activityButton: UIBarButtonItem?

    // MARK: - Subclass hooks

    /// Whether this picker edits sounds rather than devices.
    open var isSoundMode: Bool {
        (specifier?.property(forKey: "isSound") as? NSNumber)?.boolValue ?? false
    }

    /// Whether selecting an entry deselects all the others.
    open var onlyAllowOne: Bool {
        isSoundMode || serviceType == PushbulletService.serviceName
    }

    /// Explanatory text shown above the list.
    open var footerText: String? { nil }

    /// Refreshes the list from the provider. Subclasses override.
    open func updateItems() async throws {}

    /// The storage key for this list.
    var storageKey: String { isSoundMode ? PrefKey.sounds : PrefKey.devices }

    /// The instance's service *type*, which selects the provider API to refresh
    /// from. The instance id identifies where the list is stored; the type
    /// identifies how to fetch it.
    var serviceType: String? {
        specifier?.string(SpecifierRouting.PropertyKey.serviceType)
    }

    // MARK: - Lifecycle

    open override func viewDidLoad() {
        super.viewDidLoad()

        let update = UIBarButtonItem(
            title: "Update".localized, style: .plain, target: self, action: #selector(beginUpdate)
        )
        let indicator = UIActivityIndicatorView(style: .medium)
        updateButton = update
        activityIndicator = indicator
        activityButton = UIBarButtonItem(customView: indicator)
        navigationItem.rightBarButtonItem = update

        // The service and app this picker edits come from the cell that pushed
        // it, which the framework may set after `viewDidLoad`.
        readSpecifierContext()
        loadItems()
        reloadEntries()
    }

    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        readSpecifierContext()

        // Commit any text field the previous page left being edited, so its
        // value is stored before this page reads it.
        let controllers = navigationController?.viewControllers ?? []
        if controllers.count > 1 {
            controllers[controllers.count - 2].view.endEditing(true)
        }

        loadItems()
        reloadEntries()
        Task { await refresh() }
    }

    private func readSpecifierContext() {
        instanceID = specifier?.string(SpecifierRouting.PropertyKey.instanceID) ?? instanceID
        isCustomApp = specifier?.bool(SpecifierRouting.PropertyKey.isCustomApp) ?? false
        if isCustomApp {
            customAppID = specifier?.string("customAppIDKey")
        }
    }

    // MARK: - Storage

    /// Reads the stored entries, dropping malformed ones so the list below can
    /// treat every item as a well-formed dictionary.
    ///
    /// Devices and sounds share this shape (`{ name, id, enabled }`); the
    /// normalized service config is what reduces sounds to their IDs.
    func loadItems() {
        guard let instanceID else { return }
        let stored = isCustomApp
            ? PrefsStore.customAppPrefs(service: instanceID, appID: customAppID ?? "")
                .dictionaries(storageKey)
            : PrefsStore.instance(instanceID).dictionaries(storageKey)

        items = stored.compactMap { entry in
            guard let id = entry.string("id") else { return nil }
            // A sound that has never been refreshed has no stored name yet; the
            // ID is shown until the provider supplies one.
            let name = entry.string("name") ?? id
            return ["name": name, "id": id, PrefKey.enabled: entry.bool(PrefKey.enabled)]
        }
    }

    /// Writes the whole list back, preserving the entries the payload builders
    /// ignore so opening this page never drops a device or sound.
    func saveItems() {
        guard let instanceID else { return }
        let write: (inout [String: Any]) -> Void = { object in
            object[self.storageKey] = self.items
        }

        if isCustomApp, let customAppID {
            var appPrefs = PrefsStore.customAppPrefs(service: instanceID, appID: customAppID).raw
            write(&appPrefs)
            PrefsStore.setCustomAppPrefs(appPrefs, service: instanceID, appID: customAppID)
        } else {
            PrefsStore.updateInstance(instanceID, write)
        }
    }

    // MARK: - Remote refresh

    /// Runs the provider's refresh, reporting failures in an alert.
    private func refresh() async {
        showActivityIndicator()
        defer { hideActivityIndicator() }
        do {
            try await updateItems()
            saveItems()
            reloadEntries()
        } catch {
            guard let controller = navigationController else { return }
            let alert = UIAlertController(
                title: "Network Error".localized,
                message: error.localizedDescription,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Ok".localized, style: .default) { _ in
                controller.popViewController(animated: true)
            })
            present(alert, animated: true)
        }
    }

    @objc private func beginUpdate() {
        Task { await refresh() }
    }

    private func showActivityIndicator() {
        guard let activityButton else { return }
        navigationItem.rightBarButtonItem = activityButton
        activityIndicator?.startAnimating()
    }

    private func hideActivityIndicator() {
        DispatchQueue.main.async { [self] in
            activityIndicator?.stopAnimating()
            navigationItem.rightBarButtonItem = updateButton
        }
    }

    /// Merges `fetched` (id -> display name) into the list, keeping the user's
    /// selections and dropping entries the provider no longer offers.
    func merge(fetched: [(id: String, name: String)]) {
        var remaining = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0.name) })
        var merged: [[String: Any]] = []

        for item in items {
            guard let id = item["id"] as? String else { continue }
            if let name = remaining.removeValue(forKey: id) {
                merged.append(["name": name, "id": id, PrefKey.enabled: item[PrefKey.enabled] ?? false])
            }
            // Else: the provider no longer offers this entry, so it is dropped.
        }
        for (id, name) in remaining {
            merged.append(["name": name, "id": id, PrefKey.enabled: false])
        }
        items = merged
    }

    // MARK: - Specifiers

    /// Rebuilds the list's cells from `items`.
    ///
    /// Rebuilds the cells from `items` and installs them.
    ///
    /// Called from `viewDidLoad` and again whenever the list changes; the
    /// framework reads the `_specifiers` ivar directly rather than going through
    /// a getter.
    func reloadEntries() {
        guard let specifiers = specifiersForItems() else { return }
        installSpecifiers(specifiers)
    }

    /// The cells, rebuilt whenever the framework has discarded the array.
    ///
    /// `items` outlives a background round trip, so deriving the array from it
    /// reproduces exactly what was on screen.
    public override func rebuildSpecifiers() -> NSMutableArray? {
        specifiersForItems()
    }

    private func specifiersForItems() -> NSMutableArray? {
        let specifiers = NSMutableArray()

        if !items.isEmpty {
            if let group = PSSpecifier.emptyGroup() {
                if let footer = footerText {
                    group.setProperty(footer, forKey: "footerText")
                }
                specifiers.add(group)
            }
        }

        // Sorted by display name so the list is stable across refreshes.
        for item in items.sorted(by: {
            (($0["name"] as? String) ?? "").localizedCaseInsensitiveCompare(($1["name"] as? String) ?? "") == .orderedAscending
        }) {
            guard let name = item["name"] as? String, let id = item["id"] as? String,
                  let specifier = PSSpecifier.preferenceSpecifierNamed(
                      name, target: self,
                      set: #selector(setItemEnabled(_:specifier:)),
                      get: #selector(readItemEnabled(_:)),
                      detail: nil, cell: .switchCell, edit: nil
                  )
            else { continue }

            specifier.identifier = id
            specifier.setProperty(Pusher.prefsNotification, forKey: "PostNotification")
            specifier.setProperty(true, forKey: "enabled")
            specifier.setProperty(Pusher.appID, forKey: "defaults")
            specifier.setProperty(false, forKey: SpecifierRouting.PropertyKey.defaultValue)
            specifiers.add(specifier)
        }
        return specifiers
    }

    // MARK: - Cell accessors

    @objc public func setItemEnabled(_ value: Any?, specifier: PSSpecifier) {
        let isOn = (value as? NSNumber)?.boolValue ?? false
        for index in items.indices {
            guard let id = items[index]["id"] as? String else { continue }
            if id == specifier.identifier {
                items[index][PrefKey.enabled] = isOn
            } else if onlyAllowOne {
                // Single-selection lists turn every other entry off.
                items[index][PrefKey.enabled] = false
            }
        }
        // The other switches changed too, so the cells have to be rebuilt.
        if onlyAllowOne { reloadEntries() }
        saveItems()
    }

    @objc public func readItemEnabled(_ specifier: PSSpecifier) -> Any? {
        for item in items where (item["id"] as? String) == specifier.identifier {
            return item[PrefKey.enabled] ?? false
        }
        return false
    }
}

// MARK: - Device list

/// The device picker.
@objc(NSPDeviceListController)
public final class DeviceListController: DeviceSoundListController {
    public override var onlyAllowOne: Bool {
        serviceType == PushbulletService.serviceName
    }

    public override var footerText: String? {
        switch serviceType {
        case PushoverService.serviceName:
            return "Selecting none will forward push notifications to all devices.".localized
        case PushbulletService.serviceName:
            return "Pushbullet only allows one receiving device. Selecting none will "
                .localized + "forward push notifications to all devices.".localized
        default:
            return nil
        }
    }

    public override func updateItems() async throws {
        switch serviceType {
        case PushoverService.serviceName:
            try await updatePushoverDevices()
        case PushbulletService.serviceName:
            try await updatePushbulletDevices()
        default:
            break
        }
    }

    /// Pushover has no device-list endpoint, so the credentials are validated
    /// and the stored devices kept as-is.
    private func updatePushoverDevices() async throws {
        guard let instanceID else { return }
        let credentials = PrefsStore.instance(instanceID)
        let body = [
            "token": credentials.string(PrefKey.token, default: ""),
            "user": credentials.string(PrefKey.user, default: ""),
        ]
        let json = try await PushoverAPI.post(
            path: "users/validate.json", body: body
        )
        // `status` is 1 on success; anything else carries a reason.
        let status = (json["status"] as? NSNumber)?.intValue ?? 0
        guard status != 0 else {
            let errors = json["errors"] as? [String] ?? []
            throw ProviderError.server(
                errors.isEmpty ? "Server response: \(json)" : errors.joined(separator: "\n")
            )
        }
    }

    /// Pushbullet returns the account's devices; only active ones are offered.
    private func updatePushbulletDevices() async throws {
        let response = try await PushbulletAPI.get("devices")
        let devices = response["devices"] as? [[String: Any]] ?? []
        let fetched = devices.compactMap { device -> (String, String)? in
            // `active` is absent on older accounts, where the device is usable.
            guard (device["active"] as? NSNumber)?.boolValue ?? true,
                  let id = device["iden"] as? String, !id.isEmpty
            else { return nil }
            let name = (device["nickname"] as? String) ?? (device["model"] as? String) ?? ""
            return (id, name)
        }
        merge(fetched: fetched.map { (id: $0.0, name: $0.1) })
    }
}

// MARK: - Sound list

/// The notification-sound picker. Only one sound can be selected.
@objc(NSPSoundListController)
public final class SoundListController: DeviceSoundListController {
    public override var onlyAllowOne: Bool { true }

    public override func updateItems() async throws {
        guard let instanceID, let service = serviceType else { return }
        let token = PrefsStore.instance(instanceID).string(PrefKey.token, default: "")

        switch service {
        case PushoverService.serviceName:
            let json = try await PushoverAPI.getSounds(token: token)
            let status = (json["status"] as? NSNumber)?.intValue ?? 0
            guard status != 0 else {
                let errors = json["errors"] as? [String] ?? []
                throw ProviderError.server(
                    errors.isEmpty ? "Server response: \(json)" : errors.joined(separator: "\n")
                )
            }
            // Pushover returns the sounds as an id -> display-name dictionary.
            let sounds = json["sounds"] as? [String: String] ?? [:]
            merge(fetched: sounds.map { (id: $0.key, name: $0.value) })
        case PushbulletService.serviceName:
            try await updatePushbulletSounds()
        default:
            break
        }
    }

    /// Pushbullet has no sound list, so the list is left as it is.
    private func updatePushbulletSounds() async throws {}
}
