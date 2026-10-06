import UIKit

/// The app list: which apps a service (or the global default) applies to.
///
/// The list itself comes from AltList, which enumerates every installed app with
/// search and alphabetic indexing. This controller only decides which set of app
/// IDs the selection reads and writes, and AltList's own `loadPreferences` /
/// `savePreferences` hooks are the extension points for that — so the three
/// storage locations (global, built-in service, custom service) share one
/// implementation.
@objc(NSPAppListController)
public final class AppListController: ATLApplicationListMultiSelectionController {
    /// The service whose list is edited, or `nil` for the global list.
    private var service: String?
    private var isCustomService = false

    private func readSpecifierContext() {
        service = specifier?.string(SpecifierRouting.PropertyKey.service)
        isCustomService = specifier?.bool(SpecifierRouting.PropertyKey.isCustomService) ?? false
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        readSpecifierContext()
    }

    /// `_selectedApplications` is AltList's own `@protected` ivar holding the
    /// selection. It has no accessor, and Swift cannot see ObjC ivars, so it is
    /// read and written through the runtime.
    private var selection: NSMutableSet {
        get {
            if let existing = Runtime.getIvar(self, "_selectedApplications", as: NSMutableSet.self) {
                return existing
            }
            let created = NSMutableSet()
            Runtime.setIvar(self, "_selectedApplications", created)
            return created
        }
        set { Runtime.setIvar(self, "_selectedApplications", newValue) }
    }

    /// The value AltList treats as "not selected" for the switches it builds.
    private var defaultSwitchValue: Bool {
        Runtime.getScalarIvar(self, "_defaultApplicationSwitchValue", as: Bool.self) ?? false
    }

    /// Called by AltList to seed the switch states.
    public override func loadPreferences() {
        readSpecifierContext()
        let selected = NSMutableSet()
        selected.addObjects(from: currentSelection())
        selection = selected
    }

    /// One app's switch was toggled.
    ///
    /// Written through immediately rather than only on dismissal, so a crash or
    /// a swipe-back cannot lose the selection.
    public override func setApplicationEnabled(_ enabled: NSNumber, specifier: PSSpecifier) {
        guard let appID = specifier.property(forKey: "applicationIdentifier") as? String else { return }
        if enabled.boolValue != defaultSwitchValue {
            selection.add(appID)
        } else {
            selection.remove(appID)
        }
        write(selection.allObjects.compactMap { $0 as? String })
    }

    // MARK: - Storage

    private func currentSelection() -> [String] {
        guard let service else { return AppListStorage.global() }
        return isCustomService
            ? AppListStorage.custom(service: service)
            : AppListStorage.builtIn(service: service)
    }

    private func write(_ appIDs: [String]) {
        guard let service else {
            AppListStorage.setGlobal(appIDs)
            return
        }
        if isCustomService {
            AppListStorage.setCustom(appIDs, service: service)
        } else {
            AppListStorage.setBuiltIn(appIDs, service: service)
        }
    }
}
