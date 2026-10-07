import UIKit

/// The app list: which apps a service instance (or the global default) applies
/// to.
///
/// The list itself comes from AltList, which enumerates every installed app with
/// search and alphabetic indexing. This controller only decides which set of app
/// IDs the selection reads and writes, and AltList's own `loadPreferences` /
/// `savePreferences` hooks are the extension points for that — so the two storage
/// locations (global, one instance) share one implementation.
@objc(NSPAppListController)
public final class AppListController: ATLApplicationListMultiSelectionController {
    /// The instance whose list is edited, or `nil` for the global list.
    private var instanceID: String?

    private func readSpecifierContext() {
        instanceID = specifier?.string(SpecifierRouting.PropertyKey.instanceID)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        readSpecifierContext()
        captureLinkBaseName()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyPlainTitle()
    }

    /// Remembers the link's title without its count suffix, so the suffix can be
    /// restored from a clean base later.
    private func captureLinkBaseName() {
        guard let name = specifier?.name else { return }
        let base = AppListTitle.baseName(of: name)
        if !base.isEmpty { linkBaseName = base }
    }

    /// Shows only the plain name in the bar and on the link cell.
    ///
    /// AltList sets the bar title from the specifier once and re-derives it on
    /// its own passes, so a live count here cannot survive — the original had the
    /// same limitation. Dropping the count while this page is open is what keeps
    /// a *stale* number from being displayed; the page that pushed this one
    /// recomputes the real count in its own `viewWillAppear`.
    private func applyPlainTitle() {
        captureLinkBaseName()
        navigationItem.title = linkBaseName
        specifier?.name = linkBaseName
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
    ///
    /// Also captures the specifier this page was pushed from: AltList's
    /// multi-selection controller only has it while the list is being built, and
    /// the toggle handler needs it later to reach the pushing page's link cell.
    public override func loadPreferences() {
        super.loadPreferences()
        readSpecifierContext()
        specifierForApplicationList = specifier

        let selected = NSMutableSet()
        selected.addObjects(from: currentSelection())
        selection = selected
    }

    /// One app's switch was toggled.
    ///
    /// Written through immediately rather than only on dismissal, so a crash or
    /// a swipe-back cannot lose the selection — and the count on the page that
    /// pushed this one follows as it changes.
    public override func setApplicationEnabled(_ enabled: NSNumber, specifier: PSSpecifier) {
        guard let appID = specifier.property(forKey: "applicationIdentifier") as? String else { return }
        if enabled.boolValue != defaultSwitchValue {
            selection.add(appID)
        } else {
            selection.remove(appID)
        }
        write(selection.allObjects.compactMap { $0 as? String })
    }

    /// The specifier this page was pushed from, captured in `loadPreferences`;
    /// see the comment there.
    private var specifierForApplicationList: PSSpecifier?

    /// The link cell's title without the "(N total)" suffix, captured once so
    /// every later retitle starts from the same clean base.
    private var linkBaseName: String = "App List".localized

    // MARK: - Storage

    private func currentSelection() -> [String] {
        guard let instanceID else { return AppListStorage.global() }
        return AppListStorage.forInstance(instanceID)
    }

    private func write(_ appIDs: [String]) {
        guard let instanceID else {
            AppListStorage.setGlobal(appIDs)
            return
        }
        AppListStorage.setForInstance(appIDs, id: instanceID)
    }
}
