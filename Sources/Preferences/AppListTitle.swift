import UIKit

/// Titles for the app-list and app-customization links, whose labels carry a
/// "(N total)" count.
///
/// The suffix handling lives here because the localized format differs from the
/// English one in bracket style (Chinese uses fullwidth parentheses), so
/// stripping by one fixed separator silently fails and the suffix compounds.
enum AppListTitle {
    /// The label with any count suffix removed, in either bracket style.
    static func baseName(of title: String?) -> String {
        guard let title else { return "" }
        for separator in [" (", "（"] {
            if let cut = title.components(separatedBy: separator).first, !cut.isEmpty {
                return cut
            }
        }
        return title
    }

    /// Formats `base` with a fresh count suffix.
    static func titled(_ base: String, count: Int) -> String {
        String(format: "%@ (%d total)".localized, base, count)
    }

    /// Sets `specifier`'s title to `base` plus a fresh count suffix.
    static func apply(_ specifier: PSSpecifier, base: String, count: Int) {
        specifier.name = titled(base, count: count)
    }
}
