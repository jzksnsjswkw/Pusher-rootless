import UIKit

/// Titles for the app-list and app-customization links, whose labels carry a
/// "(N total)" count.
///
/// The suffix handling lives here because the localized format differs from the
/// English one in bracket style, so a single hard-coded separator does not
/// match every language.
enum AppListTitle {
    /// The label with any trailing count suffix removed.
    ///
    /// The cut is taken at the *earliest* occurrence of either bracket style.
    /// Splitting on one separator at a time does not work: `components(separatedBy:)`
    /// returns the whole string when the separator is absent, so a first attempt
    /// that "succeeds" on an unmatched separator silently swallows the real
    /// suffix.
    static func baseName(of title: String?) -> String {
        guard let title else { return "" }

        var cut: String.Index?
        for separator in [halfwidthSeparator, fullwidthSeparator] {
            guard let range = title.range(of: separator) else { continue }
            if cut == nil || range.lowerBound < cut! {
                cut = range.lowerBound
            }
        }
        guard let cut, cut > title.startIndex else { return title }
        return String(title[title.startIndex..<cut])
    }

    /// Formats `base` with a fresh count suffix.
    static func titled(_ base: String, count: Int) -> String {
        String(format: "%@ (%d total)".localized, base, count)
    }

    /// Sets `specifier`'s title to `base` plus a fresh count suffix.
    static func apply(_ specifier: PSSpecifier, base: String, count: Int) {
        specifier.name = titled(base, count: count)
    }

    // MARK: - Separators

    /// The separator the English format string uses: `"%@ (%d total)"`.
    private static let halfwidthSeparator = " ("

    /// The separator the zh-Hans translation uses: `"%@（共 %d 个）"`. Both
    /// spellings are matched because a title may be built from either format
    /// string depending on the language the page was first rendered in.
    private static let fullwidthSeparator = "（"
}
