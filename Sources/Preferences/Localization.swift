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

    /// A human-readable display name for a service.
    ///
    /// Internal service keys (e.g. `"Feishu"`) stay English in prefs and the log
    /// so they remain stable identifiers; the UI shows the localized name, and a
    /// custom service name passes through unchanged.
    public static func serviceDisplayName(_ service: String?) -> String {
        string(service ?? "")
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
