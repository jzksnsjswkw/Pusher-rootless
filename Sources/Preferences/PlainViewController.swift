import UIKit

/// Base class for the pages that build their **own** table view.
///
/// Most settings pages are `PSListController` subclasses and let the framework's
/// table render a specifier array (see ``ListController``). Three pages cannot:
/// the service list, the per-app override list and the log viewer each own their
/// own `UITableView` because their content is not a specifier list at all.
///
/// They must *not* derive from `PSListController`. Its `viewDidLoad` calls
/// `reloadData` on its own table and then asks the data source for a section's
/// header, indexing its internal specifier array with the row count this class
/// reports. With a specifier array the framework never filled, that lookup runs
/// off the end of the array and the process aborts. Deriving from
/// `PSViewController` instead leaves the table entirely in this class's hands.
///
/// Localization is shared with the specifier pages so both kinds of page resolve
/// strings from the bundle the same way.
@objc(NSPViewController)
open class PlainViewController: PSViewController, TintableController {

    // MARK: - Construction

    /// The initializer the Preferences framework uses to build a detail page.
    ///
    /// The vendored `PSViewController.h` declares this on `PSViewController`,
    /// but on-device that class does **not** implement it — only its
    /// `PSListController` subclass does. Swift believes the header: it treats the
    /// initializer as inherited and emits a thunk that forwards to `super` with
    /// `objc_msgSendSuper2`. There is nothing to call at the other end, so the
    /// message raises `doesNotRecognizeSelector` and Preferences aborts as soon
    /// as a detail page is pushed.
    ///
    /// Implementing it here and forwarding to `init(nibName:bundle:)` — a
    /// designated initializer that genuinely exists on the superclass — gives the
    /// framework a working construction path. `PSListController` subclasses do
    /// not need this: that class implements the initializer for real.
    @objc public override init(forContentSize contentSize: CGSize) {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tintToPusherColor()
    }

    // Navigation note: `PSViewController`'s `rootController` property and
    // `pushController:` method are imported by Swift as `root` and `push(_:)`,
    // which is what the pages call — no wrapper is needed.

    /// Recolors the page. The table is reloaded too, so the icons in its cells
    /// pick up the new color.
    open func tintToPusherColor() {
        (self as TintableController).applyActiveTint()
        (view as? UITableView)?.reloadData()
    }

    open override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The table is sized in code rather than by constraints, so it has to be
        // resized when the view's bounds change (rotation, iPad split view).
        for case let table as UITableView in view.subviews where table.frame != view.bounds {
            table.frame = view.bounds
        }
    }

    /// A string from this bundle. Pages here build their titles in code rather
    /// than from a plist, so they localize explicitly.
    func localized(_ key: String) -> String { key.localized }
}
