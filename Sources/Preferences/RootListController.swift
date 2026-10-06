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
    }

    /// The page's cells, loaded from `Root.plist` on first access.
    public override var specifiers: NSMutableArray! {
        get {
            if super.specifiers == nil {
                super.specifiers = loadSpecifiers(fromPlistName: "Root", target: self)
            }
            return super.specifiers
        }
        set { super.specifiers = newValue }
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
