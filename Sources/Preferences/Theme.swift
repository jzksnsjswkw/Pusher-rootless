import UIKit

/// The tint color the whole UI follows.
///
/// Each service page recolors itself from its own icon (see
/// ``ServiceController``), so the active color is a single shared value rather
/// than something each controller computes. The default is Pusher's green.
@objc(NSPTheme)
public final class Theme: NSObject {
    /// Pusher's brand green.
    public static let defaultTintColor = UIColor(red: 0, green: 177 / 255, blue: 79 / 255, alpha: 1)

    /// The window background the colored pages sit on.
    private static var storedTintColor: UIColor?

    private override init() { super.init() }

    /// The color the UI is currently tinted with.
    @objc public static var activeTintColor: UIColor {
        storedTintColor ?? defaultTintColor
    }

    /// Sets the active tint. `nil` restores the default, which is what leaving a
    /// service page does.
    @objc public static func setActiveTintColor(_ color: UIColor?) {
        storedTintColor = color
    }

    /// Opens a Twitter profile, preferring the app over the web.
    @objc public static func openTwitter(_ username: String) {
        let appLink = "twitter://user?screen_name=\(username)"
        if let url = URL(string: appLink), UIApplication.shared.canOpenURL(url) {
            openURL(appLink)
        } else {
            openURL("https://twitter.com/\(username)")
        }
    }
}

/// Applies the active tint to a controller's navigation bar and controls.
///
/// Implemented as a protocol rather than a superclass: the colored pages are
/// `PSListController` and `PSViewController` subclasses, which cannot both
/// inherit from a common Swift base.
///
/// The requirement is deliberately *not* named `tintToPusherColor()`: that name
/// belongs to `ListController`, which calls this method. Sharing one name would
/// make `self as TintableController` dispatch straight back into the calling
/// implementation and recurse until the stack overflowed.
public protocol TintableController: UIViewController {
    /// Recolors the navigation bar and the controls inside this controller.
    func applyActiveTint()
}

public extension TintableController {
    func applyActiveTint() {
        let color = Theme.activeTintColor

        // On iPhone the list controller is wrapped in an extra navigation
        // controller, so the bar that is actually on screen is a level up.
        var navigation = navigationController
        if UIDevice.current.userInterfaceIdiom != .pad {
            navigation = navigation?.navigationController
        }
        navigation?.navigationBar.tintColor = color

        // Appearance proxies scope the tint to this controller's own controls,
        // so one service's color does not leak into the rest of Settings.
        // Every `UIViewController` conforms to `UIAppearanceContainer`, so the
        // cast cannot fail; it is needed only to satisfy the proxy's type.
        let containers: [UIAppearanceContainer.Type] = [type(of: self)]
        UISwitch.appearance(whenContainedInInstancesOf: containers).tintColor = color
        UISwitch.appearance(whenContainedInInstancesOf: containers).onTintColor = color
        UISegmentedControl.appearance(whenContainedInInstancesOf: containers).tintColor = color
        UISlider.appearance(whenContainedInInstancesOf: containers).tintColor = color
    }
}
