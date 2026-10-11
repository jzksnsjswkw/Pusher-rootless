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
    }

    // MARK: - The copy action

    /// The sheet's button target.
    ///
    /// Retained as an associated object on the presented controller: a bar button
    /// item holds its target weakly, so a target created inside `present` would
    /// be released before anyone could tap it.
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
        prompt: @escaping (String) -> String
    ) {
        let host = UIViewController()
        host.view.backgroundColor = .systemGroupedBackground
        host.navigationItem.title = title

        let target = Target()
        target.host = host
        target.prompt = prompt
        host.navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Copy AI Prompt".localized, style: .plain,
                            target: target, action: #selector(Target.copyPrompt)),
            UIBarButtonItem(title: "Close".localized, style: .plain,
                            target: target, action: #selector(Target.close)),
        ]

        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(scrollView)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        for block in blocks {
            switch block {
            case .heading(let text):
                let label = UILabel()
                label.text = text
                label.font = .preferredFont(forTextStyle: .headline)
                label.numberOfLines = 0
                stack.addArrangedSubview(label)
            case .text(let text):
                let label = UILabel()
                label.text = text
                label.font = .preferredFont(forTextStyle: .subheadline)
                label.textColor = .secondaryLabel
                label.numberOfLines = 0
                stack.addArrangedSubview(label)
            case .code(let text):
                stack.addArrangedSubview(codeView(text))
            case .image(let name):
                if let view = imageView(name) {
                    stack.addArrangedSubview(view)
                }
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

        // The buttons outlive this method's scope only because of this.
        objc_setAssociatedObject(host, &AssociatedKeys.target, target,
                                 .OBJC_ASSOCIATION_RETAIN)

        // A bare view controller shows no navigation bar, so neither the title
        // nor the two buttons would appear at all.
        let navigation = UINavigationController(rootViewController: host)
        navigation.modalPresentationStyle = .pageSheet
        controller.present(navigation, animated: true)
    }

    /// A bundle image at the sheet's width, keeping its aspect ratio.
    ///
    /// `UIImageView` in an arranged subview has no intrinsic width, so the width
    /// comes from the stack and the height from the picture's own ratio. The
    /// rounding is applied here rather than baked into the file: the screenshot
    /// is of a light interface, and a rounded corner lets it sit on a dark page
    /// as a picture instead of a bright rectangle.
    private static func imageView(_ name: String) -> UIView? {
        guard let image = UIImage.pusher(named: name) else { return nil }

        let rounded = UIGraphicsImageRenderer(size: image.size).image { _ in
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
        // Height follows from the width the stack gives it.
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    /// A monospaced, non-scrolling text view: the text wraps, the view grows.
    ///
    /// Not selectable, so a drag scrolls the sheet rather than starting a text
    /// selection — the block is there to be read, and the copy button is the way
    /// to take the API elsewhere.
    private static func codeView(_ text: String) -> UITextView {
        let view = UITextView()
        view.text = text
        view.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        view.textColor = .label
        view.backgroundColor = .secondarySystemGroupedBackground
        view.layer.cornerRadius = 10
        view.isEditable = false
        view.isSelectable = false
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
