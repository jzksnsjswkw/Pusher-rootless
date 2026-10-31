import UIKit

extension UIColor {
    /// The color a successful response is drawn in.
    ///
    /// A deep green rather than the system's: system green is tuned for glyphs and
    /// fills, and at text size on a light background it reads as pale. Resolves
    /// per theme, because a green dark enough for white paper is unreadable on a
    /// black one.
    ///
    /// Shared by both editors — a script's Run and a hook's Run describe the same
    /// kind of answer, so they draw it in the same color.
    static var successResponse: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.35, green: 0.78, blue: 0.40, alpha: 1)
                : UIColor(red: 0.00, green: 0.42, blue: 0.17, alpha: 1)
        }
    }
}
