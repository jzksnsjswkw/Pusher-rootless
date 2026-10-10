import UIKit

/// Pusher's top-level settings page.
///
/// Adds the banner image as a table header. The banner is dropped when it would
/// take up more than a third of the screen (on a short or landscape screen), so
/// the settings stay reachable without scrolling past a huge image.
@objc(NSPRootListController)
public final class RootListController: ListController {
    private var priorTintColor: UIColor?
    private var headerImageView: UIImageView?
    private var headerContainer: UIView?
    private var isShowingHeader = false

    public override var specifierPlistName: String? { "Root" }

    public override func viewDidLoad() {
        super.viewDidLoad()

        // Remember the tint Settings had before the page was opened, so leaving
        // it can restore what the user's other tweaks expect.
        if priorTintColor == nil {
            priorTintColor = surroundingNavigationController()?.navigationBar.tintColor
        }

        // The banner is optional: a build without the assets still works.
        if let image = UIImage.pusher(named: "banner") {
            let imageView = UIImageView(image: image)
            let container = UIView()
            container.backgroundColor = .clear
            container.addSubview(imageView)
            headerImageView = imageView
            headerContainer = container
            updateHeader()
        }

        // The cells are installed here rather than lazily, because the
        // Preferences framework does not call the `specifiers` getter to obtain
        // them - it reads the `_specifiers` ivar directly. A page that only
        // filled in the ivar from its getter would render nothing but its
        // table header.
        loadSpecifiersOnce(named: "Root")
        updateHeader()
    }

    // MARK: - Banner

    /// Sizes the banner to the screen and installs or removes it.
    private func updateHeader() {
        guard let imageView = headerImageView, let container = headerContainer else { return }

        var width = UIScreen.main.bounds.width
        if UIDevice.current.userInterfaceIdiom == .pad {
            width = root?.view.frame.width ?? width
        }

        var frame = imageView.frame
        // A missing or zero-sized asset would divide by zero below.
        guard frame.width > 0 else { return }

        let ratio = width / frame.width
        frame.size.width = width
        frame.size.height *= ratio
        imageView.frame = frame
        container.frame = frame

        let tooTall = frame.height >= UIScreen.main.bounds.height / 3
        if isShowingHeader, tooTall {
            table?.tableHeaderView = nil
            title = Pusher.name
            isShowingHeader = false
        } else if !isShowingHeader, !tooTall {
            table?.tableHeaderView = container
            title = nil
            isShowingHeader = true
        }
    }

    public override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        updateHeader()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The root page always uses the default color; a service page may have
        // left its own tint behind.
        Theme.setActiveTintColor(nil)
        tintToPusherColor()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        surroundingNavigationController()?.navigationBar.tintColor = priorTintColor
    }

    // MARK: - Actions

    @objc public func openTwitterNoahSaso() {
        Theme.openTwitter("NoahSaso")
    }

    @objc public func openGitHub() {
        openURL("https://github.com/jzksnsjswkw/Pusher-rootless")
    }

    /// The tweak this one is built from.
    ///
    /// A separate row rather than a note in the footer: the code here has
    /// diverged (Swift, an instance model, JS services), so someone looking for
    /// how the original behaves should land on the original rather than on a
    /// description of it.
    @objc public func openUpstreamGitHub() {
        openURL("https://github.com/NoahSaso/Pusher")
    }

    // MARK: - Helpers

    /// The navigation controller whose bar is visible.
    ///
    /// On iPhone the Preferences list controller is nested inside an extra
    /// navigation controller, so `navigationController` is not the one drawing
    /// the bar.
    private func surroundingNavigationController() -> UINavigationController? {
        guard UIDevice.current.userInterfaceIdiom != .pad else { return navigationController }
        return navigationController?.navigationController
    }
}
