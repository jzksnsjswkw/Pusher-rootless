import Foundation

/// Localized string lookup for the Preferences bundle.
///
/// The bundle is loaded into the Preferences app, so `NSLocalizedString` (which
/// looks in the main bundle) is not sufficient — it has to resolve the string
/// from *this* bundle. When no translation exists the key itself is returned, so
/// English remains the fallback without a second string table.
public enum Localization {
    private static let bundle: Bundle = Bundle(for: RootListController.self)

    /// Looks up `key` in the bundle's `Localizable.strings`.
    public static func string(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// A human-readable display name for a service type.
    ///
    /// Registry names (e.g. `"Feishu"`) stay English in prefs and the log so they
    /// remain stable identifiers; the UI shows the localized name. An instance's
    /// own name is already user-facing and is shown as-is — see
    /// ``instanceDisplayName(_:)``.
    public static func serviceDisplayName(_ service: String?) -> String {
        string(service ?? "")
    }

    /// A display name for a descriptor, localized only when it is a built-in.
    ///
    /// A user's own service is named by them, and their text is shown as it was
    /// written. The distinction is by registry name rather than by asking whether
    /// the descriptor came from a definition, because a definition's name is the
    /// id an instance stores and a built-in's is the type's own — see
    /// `ServiceRegistry`.
    ///
    /// Without this the picker localized every row it drew, so a service a user
    /// had called exactly `"Custom Service"` was listed as `"自定义服务"`:
    /// their name replaced by a translation, in the one list that exists to tell
    /// their services apart.
    public static func descriptorDisplayName(_ descriptor: ServiceDescriptor) -> String {
        let isBuiltIn = ServiceRegistry.addableServices.contains { $0.name == descriptor.name }
        return isBuiltIn ? serviceDisplayName(descriptor.displayName) : descriptor.displayName
    }

    /// A human-readable name for one instance.
    ///
    /// The name is the user's own text and is shown unchanged. It used to be
    /// localized whenever it matched the descriptor's display name, on the theory
    /// that a match meant the user had left the default in place — but the name
    /// is always typed, and a user-defined service's name is theirs as much as an
    /// instance's. Two ways that misfired: a service the user called exactly
    /// "Custom Service" displayed as "自定义服务", and so did an instance of it,
    /// which made the name they had chosen unreadable in the list that exists to
    /// tell their entries apart.
    ///
    /// Built-in service *types* are still localized, through
    /// ``serviceDisplayName(_:)``, which is where the add list gets its labels.
    public static func instanceDisplayName(_ instance: ServiceInstance) -> String {
        instance.name
    }
}

/// `String` conveniences so call sites read as `"Services".localized` rather
/// than `Localization.string("Services")` — the plists and code use these keys
/// as display text, so they are looked up as literals throughout.
extension String {
    /// This string, localized through the Preferences bundle.
    var localized: String { Localization.string(self) }
}

/// Access to the bundle's resources (icons, banner, specifier plists).
extension Bundle {
    /// The installed Pusher Preferences bundle.
    static var pusher: Bundle { Bundle(for: RootListController.self) }
}
