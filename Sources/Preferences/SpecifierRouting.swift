import UIKit

/// Bridges a `PSSpecifier` back to the store it writes to.
///
/// The Preferences framework loads specifier plists and, for a cell with a
/// `defaults` domain, writes the value straight to that domain under the cell's
/// `key`. That is exactly what this project cannot do: the real storage is the
/// *nested* `BuiltInServices[service][key]` / `CustomServices[service][key]` /
/// `Global[key]` layout, not the flat top-level keys the plists name.
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
        static let setBuiltIn = "setValue:forBuiltInServiceSpecifier:"
        static let getBuiltIn = "readValueForBuiltInServiceSpecifier:"
        static let setCustom = "setValue:forCustomSpecifier:"
        static let getCustom = "readValueForCustomSpecifier:"
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

    /// Routes one cell. Cells already carrying a `service` property are skipped
    /// by the callers that set it themselves.
    static func route(_ specifier: PSSpecifier, to target: AnyObject, scope: StorageScope) {
        specifier.target = target
        switch scope {
        case .builtIn(let service):
            specifier.setProperty(service, forKey: PropertyKey.service)
            specifier.setProperty(false, forKey: PropertyKey.isCustomApp)
            specifier.setSetter(Selector.setBuiltIn)
            specifier.setGetter(Selector.getBuiltIn)
        case .customService(let service):
            specifier.setProperty(service, forKey: PropertyKey.service)
            specifier.setProperty(false, forKey: PropertyKey.isCustomApp)
            specifier.setSetter(Selector.setCustom)
            specifier.setGetter(Selector.getCustom)
        case .customApp(let service, let appID, let isCustomService):
            specifier.setProperty(service, forKey: PropertyKey.service)
            specifier.setProperty(true, forKey: PropertyKey.isCustomApp)
            specifier.setProperty(appID, forKey: PropertyKey.customAppID)
            specifier.setSetter(Selector.setCustom)
            specifier.setGetter(Selector.getCustom)
            _ = isCustomService
        case .global:
            specifier.setSetter(Selector.setGlobal)
            specifier.setGetter(Selector.getGlobal)
        }
    }

    /// Which store a page's cells read and write.
    enum StorageScope {
        case builtIn(service: String)
        case customService(service: String)
        case customApp(service: String, appID: String, isCustomService: Bool)
        case global
    }

    /// Keys the UI stashes on a specifier to remember what it edits.
    enum PropertyKey {
        /// The service this cell belongs to.
        static let service = "service"
        /// Whether the cell edits a per-app override rather than a service.
        static let isCustomApp = "isCustomApp"
        /// Whether the page belongs to a custom (user-defined) service.
        static let isCustomService = "isCustomService"
        /// The bundle ID of the app an override belongs to.
        static let customAppID = "customAppID"
        /// The per-app override key to read/write.
        static let customAppsPrefsKey = "customAppsPrefsKey"
        /// The plist key to remap onto (`customServiceKey` in the plists).
        static let key = "key"
        /// The plist's name for the key to remap onto.
        static let customServiceKey = "customServiceKey"
        /// A top-level fallback key, for cells whose value may live outside the
        /// service object.
        static let globalKey = "globalKey"
        /// The value shown when nothing is stored.
        static let defaultValue = "default"
        /// A non-retaining back-reference to the list controller, for cells that
        /// need to reload themselves.
        static let listReference = "psListRef"
    }
}

// MARK: - PSSpecifier ivar access

extension PSSpecifier {
    /// `PSSpecifier` declares `SEL setter;` as an `@public` ivar. Swift does not
    /// import ObjC ivars, so it is written through the runtime.
    func setSetter(_ selector: String) {
        Runtime.setIvar(self, "setter", unsafeBitCast(NSSelectorFromString(selector), to: AnyObject.self))
    }

    /// See ``setSetter(_:)``.
    func setGetter(_ selector: String) {
        Runtime.setIvar(self, "getter", unsafeBitCast(NSSelectorFromString(selector), to: AnyObject.self))
    }

    /// The currently installed setter, for tests and debugging.
    var setterSelector: Selector? { Runtime.getIvar(self, "setter", as: Selector.self) }

    /// The currently installed getter.
    var getterSelector: Selector? { Runtime.getIvar(self, "getter", as: Selector.self) }

    /// `propertyForKey:` with a `String` result already narrowed.
    func string(_ key: String) -> String? { property(forKey: key) as? String }

    /// `propertyForKey:` with a `Bool` result, tolerating an `NSNumber`.
    func bool(_ key: String) -> Bool {
        (property(forKey: key) as? NSNumber)?.boolValue ?? false
    }

    /// The value to show when nothing is stored under this cell's key.
    var storedDefault: Any? { property(forKey: SpecifierRouting.PropertyKey.defaultValue) }
}
