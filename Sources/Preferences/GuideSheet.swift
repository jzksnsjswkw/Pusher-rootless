import UIKit

/// A scrollable explanation sheet with a copy-prompt action.
///
/// One presenter serves both guides — a service script's and an instance hook's.
/// They differ only in their sections and in the prompt they copy; the awkward
/// parts are identical, and there are three of them: a bar button's target is
/// held weakly, so it has to be retained elsewhere; the title and the buttons
/// only appear when the controller is inside a navigation controller; and a code
/// block cannot measure itself until the stack it sits in has a width.
enum GuideSheet {

    /// One piece of the explanation, shown in the order given.
    enum Block {
        /// A section title.
        case heading(String)
        /// Body text below the heading.
        case text(String)
        /// A monospaced block: code, or an API written as declarations.
        case code(String)
        /// A picture, from the bundle. Sized to the sheet's width.
        ///
        /// A screenshot says in one glance what a paragraph of instructions
        /// struggles to: which action to add, and what its two fields should
        /// read. Kept in the bundle rather than drawn in code because it is a
        /// picture of another app's interface, which changes without notice.
        case image(String)
        /// A row that does something when tapped, with a line of explanation.
        ///
        /// The sheet has no way to report progress otherwise: fetching the
        /// example Shortcut is a network request, and a button that appears to do
        /// nothing for a second is a button the user presses twice.
        case action(title: String, detail: String, run: (ActionHost) -> Void)
    }

    /// What an ``Block/action(title:detail:run:)`` row is given to work with.
    ///
    /// A protocol rather than the controller itself: the row needs to show
    /// progress and an error, and nothing else, and saying so keeps the block
    /// from quietly reaching into the sheet's view hierarchy.
    protocol ActionHost: AnyObject {
        /// Replaces the row's detail text, and disables it while busy.
        func setActionBusy(_ busy: Bool, detail: String?)
        /// Puts a message in front of the user, or reports success.
        func presentActionAlert(title: String, message: String, share: URL?)
    }

    // MARK: - The copy action

    /// The sheet's button target.
    ///
    /// Retained as an associated object on the presented controller: a bar button
    /// item holds its target weakly, so a target created inside `present` would
    /// be released before anyone could tap it.
    /// Rows and their targets, for the lifetime of the sheet.
    private static var retained: [AnyObject] = []

    private final class Target: NSObject {
        weak var host: UIViewController?
        var prompt: ((String) -> String)?

        @objc func close() {
            host?.dismiss(animated: true)
        }

        @objc func copyPrompt() {
            let alert = UIAlertController(
                title: "Copy AI Prompt".localized,
                message: ("The prompt describes this API. Add what you want "
                    + "below — the AI writes the code, it does not decide what "
                    + "you need.").localized,
                preferredStyle: .alert
            )
            alert.addTextField { field in
                field.placeholder = "What should it do?".localized
                field.autocorrectionType = .yes
            }
            alert.addAction(UIAlertAction(title: "Copy".localized, style: .default) { _ in
                UIPasteboard.general.string =
                    self.prompt?(alert.textFields?.first?.text ?? "")
                let done = UIAlertController(
                    title: nil,
                    message: "Copied. Paste it into your AI assistant.".localized,
                    preferredStyle: .alert
                )
                done.addAction(UIAlertAction(title: "Ok".localized, style: .default))
                self.host?.present(done, animated: true)
            })
            alert.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel))
            host?.present(alert, animated: true)
        }
    }

    private enum AssociatedKeys {
        static var target = 0
    }

    // MARK: - Presenting

    /// Presents the guide over `controller`.
    ///
    /// - Parameter prompt: builds what the copy button puts on the pasteboard,
    ///   from the requirement the user typed.
    static func present(
        from controller: UIViewController,
        title: String,
        blocks: [Block],
        prompt: ((String) -> String)? = nil
    ) {
        let host = UIViewController()
        host.view.backgroundColor = .systemGroupedBackground
        host.navigationItem.title = title

        let target = Target()
        target.host = host
        target.prompt = prompt
        // The copy button is for the guides whose subject is code an AI can
        // write. A guide whose subject is a sequence of taps in another app has
        // nothing to hand over, and offering the button would suggest otherwise.
        host.navigationItem.rightBarButtonItems = [
            prompt == nil
                ? nil
                : UIBarButtonItem(title: "Copy AI Prompt".localized, style: .plain,
                                  target: target, action: #selector(Target.copyPrompt)),
            UIBarButtonItem(title: "Close".localized, style: .plain,
                            target: target, action: #selector(Target.close)),
        ].compactMap { $0 }

        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(scrollView)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        retained.removeAll()
        var actionRows: [RowHost] = []

        for block in blocks {
            switch block {
            case .heading(let text):
                let label = UILabel()
                label.text = text
                label.font = .preferredFont(forTextStyle: .headline)
                label.numberOfLines = 0
                stack.addArrangedSubview(label)
            case .text(let text):
                stack.addArrangedSubview(bodyView(text))
            case .code(let text):
                stack.addArrangedSubview(codeView(text))
            case .image(let name):
                if let view = imageView(name) {
                    stack.addArrangedSubview(view)
                }
            case .action(let title, let detail, let run):
                let row = actionView(title, detail, run)
                actionRows.append(row)
                stack.addArrangedSubview(row.container)
            }
        }

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(
                equalTo: host.view.safeAreaLayoutGuide.topAnchor
            ),
            scrollView.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            scrollView.bottomAnchor.constraint(
                equalTo: host.view.safeAreaLayoutGuide.bottomAnchor
            ),
            stack.topAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20
            ),
            stack.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20
            ),
            stack.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -20
            ),
            stack.bottomAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -20
            ),
            // The width the code blocks measure themselves against.
            stack.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40
            ),
        ])

        // The rows present their own alerts and share sheets, so they need the
        // controller — which does not exist until the container is built.
        actionRows.forEach { $0.attach(to: host) }

        // The buttons outlive this method's scope only because of this.
        objc_setAssociatedObject(host, &AssociatedKeys.target, target,
                                 .OBJC_ASSOCIATION_RETAIN)

        // A bare view controller shows no navigation bar, so neither the title
        // nor the two buttons would appear at all.
        let navigation = UINavigationController(rootViewController: host)
        navigation.modalPresentationStyle = .pageSheet
        controller.present(navigation, animated: true)
    }

    /// A tappable row: a title, a line of explanation, and a chevron.
    ///
    /// Built from a `UIButton` in a container so that the title and the
    /// explanation can wrap independently — a button's own label will not show
    /// two lines at different weights.
    private static func actionView(
        _ title: String, _ detail: String, _ run: @escaping (ActionHost) -> Void
    ) -> RowHost {
        let container = UIView()
        container.backgroundColor = .secondarySystemGroupedBackground
        container.layer.cornerRadius = 10
        container.clipsToBounds = true

        // A row is a button, so its labels stay plain: making them selectable
        // would put a text-selection drag in competition with the tap that
        // starts the download.
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0

        let detailLabel = UILabel()
        detailLabel.text = detail
        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(spinner)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            stack.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -8),
            spinner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            spinner.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        let rows = RowHost(container: container, detailLabel: detailLabel,
                           spinner: spinner, run: run)
        container.addGestureRecognizer(
            UITapGestureRecognizer(target: rows, action: #selector(RowHost.tapped))
        )
        retained.append(rows)
        return rows
    }

    /// Holds a row's views and runs its action.
    ///
    /// Retained by the sheet: a gesture recognizer holds its target weakly, so a
    /// target created in `actionView` would be released before the tap.
    fileprivate final class RowHost: NSObject, ActionHost {
        let container: UIView
        private let detailLabel: UILabel
        private let spinner: UIActivityIndicatorView
        private let run: (ActionHost) -> Void
        private weak var host: UIViewController?
        private var originalDetail: String?

        init(container: UIView, detailLabel: UILabel,
             spinner: UIActivityIndicatorView, run: @escaping (ActionHost) -> Void) {
            self.container = container
            self.detailLabel = detailLabel
            self.spinner = spinner
            self.run = run
            self.originalDetail = detailLabel.text
        }

        func attach(to controller: UIViewController) { host = controller }

        @objc func tapped() {
            run(self)
        }

        func setActionBusy(_ busy: Bool, detail: String?) {
            container.isUserInteractionEnabled = !busy
            if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
            detailLabel.text = detail ?? originalDetail
        }

        func presentActionAlert(title: String, message: String, share: URL?) {
            guard let host else { return }
            let alert = UIAlertController(
                title: title, message: message, preferredStyle: .alert
            )
            if let share {
                alert.addAction(UIAlertAction(title: "Open".localized, style: .default) { _ in
                    // The Shortcuts app opens its import screen for a signed
                    // file; the share sheet is the way to hand it one.
                    let sheet = UIActivityViewController(
                        activityItems: [share], applicationActivities: nil
                    )
                    host.present(sheet, animated: true)
                })
            }
            alert.addAction(UIAlertAction(title: "Close".localized, style: .cancel))
            host.present(alert, animated: true)
        }
    }

    /// Body text, selectable.
    ///
    /// A `UITextView` rather than a `UILabel` because the guide is something a
    /// user copies out of — the Shortcut has to be built by hand in another app,
    /// and the action names, the field names and the steps are all things they
    /// will want on the clipboard. Not scrolling, so a drag inside it selects
    /// text and a drag outside it scrolls the sheet.
    private static func bodyView(_ text: String) -> UITextView {
        let view = UITextView()
        view.text = text
        view.font = .preferredFont(forTextStyle: .subheadline)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .secondaryLabel
        view.backgroundColor = .clear
        view.isEditable = false
        view.isScrollEnabled = false
        view.isSelectable = true
        view.dataDetectorTypes = []
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    /// Bundle images at the sheet's width, keeping their aspect ratio.
    ///
    /// `UIImageView` in an arranged subview has no intrinsic width, so the width
    /// comes from the stack and the height from the picture's own ratio. The
    /// rounding is applied here rather than baked into the file: the screenshot
    /// is of a light interface, and a rounded corner lets it sit on a dark page
    /// as a picture instead of a bright rectangle.
    private static func imageView(_ name: String) -> UIView? {
        guard let image = UIImage.pusher(named: name) else { return nil }

        // The renderer's format is taken from the image rather than left at its
        // default: the default follows the screen, so a @3x picture on a @2x
        // device would be redrawn at @2x and lose detail for no reason.
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        let rounded = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            let rect = CGRect(origin: .zero, size: image.size)
            let radius = image.size.height * 0.045
            UIBezierPath(roundedRect: rect, cornerRadius: radius).addClip()
            image.draw(in: rect)
        }

        let view = UIImageView(image: rounded)
        view.contentMode = .scaleAspectFit
        view.layer.cornerRadius = 6
        view.clipsToBounds = true
        view.isAccessibilityElement = true
        view.accessibilityLabel = name
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The height has to be tied to the width. `scaleAspectFit` only decides
        // how the picture is drawn inside the view — the view still claims the
        // image's own height, so a 670pt-wide picture in a 335pt column was laid
        // out twice as tall as it drew, with the excess showing as blank space
        // above and below. The ratio comes from the image rather than from a
        // number here, so replacing the picture needs no change in this file.
        if rounded.size.width > 0 {
            view.heightAnchor.constraint(
                equalTo: view.widthAnchor,
                multiplier: rounded.size.height / rounded.size.width
            ).isActive = true
        }
        return view
    }

    /// A monospaced, non-scrolling text view: the text wraps, the view grows.
    ///
    /// Selectable: a field list is something a user types into another app, and
    /// the guide that has no copy-prompt button — the Shortcut one — is exactly
    /// the one whose block is a list of names to reproduce by hand.
    private static func codeView(_ text: String) -> UITextView {
        let view = UITextView()
        view.text = text
        view.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        view.textColor = .label
        view.backgroundColor = .secondarySystemGroupedBackground
        view.layer.cornerRadius = 10
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }
}

/// The frame an AI prompt is written in.
///
/// Both guides hand the user a *system* prompt: a fixed description of the API
/// plus a marker, after which the user writes what they want. Keeping the shape
/// in one place means the two prompts cannot drift apart in how they ask, and
/// that the instruction to write a requirement — the part a user gets wrong most
/// often — is worded once.
enum AIRequirement {
    /// What the user is told to replace.
    static var placeholder: String { "★ Write here what you want it to do.".localized }

    /// The opening line: this is context for the AI, not a question from it.
    static var preamble: String {
        ("This is a SYSTEM PROMPT. Everything before the marker below is fixed "
            + "context you must follow; after the marker is what the user wants. "
            + "Do not answer the system part — generate code only.").localized
    }

    /// The closing marker and the user's own requirement.
    static func tail(requirement: String) -> String {
        let trimmed = requirement.trimmingCharacters(in: .whitespacesAndNewlines)
        return "────────────────\n"
            + ("USER REQUIREMENT — replace the line below with what you want, or "
                + "write your requirement after this prompt:").localized
            + "\n"
            + (trimmed.isEmpty ? placeholder : trimmed)
    }
}
