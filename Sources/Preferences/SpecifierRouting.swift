import UIKit

/// Bridges a `PSSpecifier` back to the store it writes to.
///
/// The Preferences framework loads specifier plists and, for a cell with a
/// `defaults` domain, writes the value straight to that domain under the cell's
/// `key`. That is exactly what this project cannot do: the real storage is the
/// instance's own object inside the `Services` array (`Services[i][key]`, or
/// `Services[i][customApps][appID][key]` for an override), not the flat
/// top-level keys the plists name.
///
/// The framework's extension point for that is the `@public` `SEL setter` and
/// `SEL getter` slots on `PSSpecifier`, which the ObjC version assigned
/// directly. Swift does not import ObjC ivars, so the assignment goes through
/// the runtime — see ``Routing`` below.
public enum SpecifierRouting {
    /// The cell types that must never be routed: group headers carry no value,
    /// buttons run an action, and links push a detail controller that manages
    /// its own storage.
    static let excludedCellTypes: Set<PSCellType> = [.groupCell, .buttonCell, .linkCell]

    /// Selector names of the routing targets in ``PreferencesStorage``.
    enum Selector {
        static let setInstance = "setValue:forInstanceSpecifier:"
        static let getInstance = "readValueForInstanceSpecifier:"
        static let setGlobal = "setValue:forGlobalSpecifier:"
        static let getGlobal = "readValueForGlobalSpecifier:"
    }

    /// Routes every value cell in `specifiers` to `target`.
    ///
    /// `scope` decides which accessors are installed.
    static func route(
        _ specifiers: [PSSpecifier],
        to target: AnyObject,
        scope: StorageScope
    ) {
        for specifier in specifiers where !excludedCellTypes.contains(specifier.cellType) {
            route(specifier, to: target, scope: scope)
        }
    }

    /// Routes one cell.
    static func route(_ specifier: PSSpecifier, to target: AnyObject, scope: StorageScope) {
        specifier.target = target
        switch scope {
        case .instance(let id):
            specifier.setProperty(id, forKey: PropertyKey.instanceID)
            specifier.setProperty(false, forKey: PropertyKey.isCustomApp)
            specifier.setSetter(Selector.setInstance)
            specifier.setGetter(Selector.getInstance)
        case .customApp(let id, let appID):
            specifier.setProperty(id, forKey: PropertyKey.instanceID)
            specifier.setProperty(true, forKey: PropertyKey.isCustomApp)
            specifier.setProperty(appID, forKey: PropertyKey.customAppID)
            specifier.setSetter(Selector.setInstance)
            specifier.setGetter(Selector.getInstance)
        case .global:
            specifier.setSetter(Selector.setGlobal)
            specifier.setGetter(Selector.getGlobal)
        }
    }

    /// Which store a page's cells read and write.
    enum StorageScope {
        /// One instance's own settings.
        case instance(id: String)
        /// One app's overrides inside one instance.
        case customApp(id: String, appID: String)
        /// The settings that are not per-instance.
        case global
    }

    /// Keys the UI stashes on a specifier to remember what it edits.
    enum PropertyKey {
        /// The service *instance* this cell edits.
        static let instanceID = "instanceID"
        /// Whether the cell edits a per-app override rather than a service.
        static let isCustomApp = "isCustomApp"
        /// The registry name of the descriptor that builds this instance's
        /// requests (`"Pushover"`, `"Bark"`, …). A page needs it to load the
        /// right specifier plist, which is the one thing about an instance that
        /// depends on its *type* rather than its own settings.
        static let serviceType = "serviceType"
        /// Whether the `instanceID` names a service *definition* rather than a
        /// service instance: the two live in different arrays, so the storage
        /// routers on this flag.
        static let isDefinition = "isDefinition"
        /// Whether the instance is a user-defined webhook. A link cell carries
        /// it so the page it pushes can seed a new override the same way.
        static let isWebhook = "isWebhook"
        /// The bundle ID of the app an override belongs to.
        static let customAppID = "customAppID"
        /// The per-app override key to read/write.
        static let customAppsPrefsKey = "customAppsPrefsKey"
        /// The settings key this cell reads and writes.
        static let key = "key"
        /// The value shown when nothing is stored.
        static let defaultValue = "default"
        /// A non-retaining back-reference to the list controller, for cells that
        /// need to reload themselves.
        static let listReference = "psListRef"
        /// Which of an instance's two hooks a link cell opens — the engine's
        /// cell handler reads it, so one handler serves both links.
        static let hookPhase = "hookPhase"
        /// Marks the cell that opens the icon picker, which a page intercepts
        /// because the picker must be told which store to write to.
        static let isIconRow = "isIconRow"
    }
}

// MARK: - PSSpecifier ivar access

extension PSSpecifier {
    /// `PSSpecifier` declares `SEL setter;` as an `@public` ivar. Swift does not
    /// import ObjC ivars, and a selector cannot travel through an `AnyObject`
    /// parameter (ARC would retain it as an object), so the bits are stored
    /// straight into the ivar's memory.
    func setSetter(_ selector: String) {
        Runtime.setSelectorIvar(self, "setter", NSSelectorFromString(selector))
    }

    /// See ``setSetter(_:)``.
    func setGetter(_ selector: String) {
        Runtime.setSelectorIvar(self, "getter", NSSelectorFromString(selector))
    }

    /// The currently installed setter, for tests and debugging.
    var setterSelector: Selector? { Runtime.getSelectorIvar(self, "setter") }

    /// The currently installed getter.
    var getterSelector: Selector? { Runtime.getSelectorIvar(self, "getter") }

    /// `propertyForKey:` with a `String` result already narrowed.
    func string(_ key: String) -> String? { property(forKey: key) as? String }

    /// `propertyForKey:` with a `Bool` result, tolerating an `NSNumber`.
    func bool(_ key: String) -> Bool {
        (property(forKey: key) as? NSNumber)?.boolValue ?? false
    }

    /// The value to show when nothing is stored under this cell's key.
    var storedDefault: Any? { property(forKey: SpecifierRouting.PropertyKey.defaultValue) }
}
