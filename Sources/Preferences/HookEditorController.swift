import UIKit

/// Edits one instance's JavaScript hook.
///
/// Structurally the script editor — a full-page monospaced text view with a line
/// number column — because a hook is code and wants the same room. What differs
/// is the contract, and the page says so: a hook cannot send anything, it decides,
/// so the Run button reports the decision rather than a request, and the API
/// reference describes `keep()`.
///
/// The switch that enables the hook lives on the instance page, not here: a hook
/// is something an instance *has*, and the switch is how it is turned off again
/// without deleting the source.
@objc(NSPHookEditorController)
public final class HookEditorController: PSViewController, UITextViewDelegate {
    private let instanceID: String
    private let phase: BulletinHookRunner.Phase

    /// Built by ``UITextView/scriptEditor()``, which supplies the text storage
    /// that colours the JavaScript as it is typed.
    private let textView = UITextView.scriptEditor()
    private let outputView = UITextView()
    private let gutter = UIView()
    private let gutterLabel = UILabel()

    private var editorToSafeArea: NSLayoutConstraint!
    private var editorWithinKeyboard: NSLayoutConstraint!
    private var editorAboveOutput: NSLayoutConstraint!
    private var outputToSafeArea: NSLayoutConstraint!
    private var outputWithinKeyboard: NSLayoutConstraint!
    private var outputHeight: NSLayoutConstraint!

    private static let gutterWidth: CGFloat = 34
    private var gutterText = "1"
    private var gutterTextHeight: CGFloat = 0
    private var gutterNeedsRebuild = true
    private var lastLayoutWidth: CGFloat = 0
    private var keyboardHeight: CGFloat = 0

    // MARK: - Construction

    public override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        self.instanceID = ""
        self.phase = .received
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    public override init(forContentSize contentSize: CGSize) {
        self.instanceID = ""
        self.phase = .received
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    init(instanceID: String, phase: BulletinHookRunner.Phase) {
        self.instanceID = instanceID
        self.phase = phase
        super.init(nibName: nil, bundle: nil)
    }

    // MARK: - Layout

    public override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = phase == .received
            ? "On Receiving".localized
            : "After Filtering".localized
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Run".localized, style: .plain,
                            target: self, action: #selector(runHook)),
            UIBarButtonItem(title: "Format".localized, style: .plain,
                            target: self, action: #selector(formatHook)),
            UIBarButtonItem(title: "Guide".localized, style: .plain,
                            target: self, action: #selector(showGuide)),
        ]

        view.backgroundColor = .systemGroupedBackground

        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        textView.keyboardType = .asciiCapable
        textView.delegate = self
        textView.backgroundColor = .secondarySystemGroupedBackground
        textView.layer.cornerRadius = 10
        textView.text = storedScript()
        textView.contentInset = .zero
        textView.contentInsetAdjustmentBehavior = .never
        textView.scrollIndicatorInsets = .zero
        textView.textContainerInset = UIEdgeInsets(
            top: 8, left: Self.gutterWidth + 4, bottom: 24, right: 8
        )
        textView.setContentHuggingPriority(.defaultLow, for: .vertical)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        gutter.clipsToBounds = true
        gutter.isUserInteractionEnabled = false
        gutter.backgroundColor = textView.backgroundColor
        gutter.layer.cornerRadius = 10
        gutter.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        view.addSubview(gutter)

        gutterLabel.font = textView.font
        gutterLabel.textColor = .tertiaryLabel
        gutterLabel.numberOfLines = 0
        gutterLabel.textAlignment = .right
        gutterLabel.frame = CGRect(x: 0, y: 0, width: Self.gutterWidth - 6, height: 0)
        gutter.addSubview(gutterLabel)

        outputView.isEditable = false
        outputView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        outputView.backgroundColor = .secondarySystemGroupedBackground
        outputView.layer.cornerRadius = 10
        outputView.isHidden = true
        outputView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(outputView)

        outputHeight = outputView.heightAnchor.constraint(equalToConstant: 0)
        outputHeight.isActive = true
        outputToSafeArea = outputView.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12
        )
        outputToSafeArea.priority = UILayoutPriority(999)
        outputWithinKeyboard = outputView.bottomAnchor.constraint(
            lessThanOrEqualTo: view.bottomAnchor, constant: -12
        )

        editorToSafeArea = textView.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12
        )
        editorToSafeArea.priority = UILayoutPriority(999)
        editorWithinKeyboard = textView.bottomAnchor.constraint(
            lessThanOrEqualTo: view.bottomAnchor, constant: -12
        )
        editorAboveOutput = textView.bottomAnchor.constraint(
            equalTo: outputView.topAnchor, constant: -12
        )

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8
            ),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            outputView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            outputView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            outputToSafeArea,
            outputWithinKeyboard,
        ])
        editorToSafeArea.isActive = true
        editorWithinKeyboard.isActive = true

        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillShowNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil
        )
    }

    /// Preferences containers do not propagate the keyboard layout guide, so the
    /// keyboard's height is tracked from its notifications and applied to the
    /// constraints directly.
    @objc private func keyboardWillChange(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = note.userInfo?[
                UIResponder.keyboardAnimationDurationUserInfoKey
              ] as? TimeInterval
        else { return }

        var height: CGFloat = 0
        if note.name == UIResponder.keyboardWillShowNotification {
            let bottomInWindow = view.convert(view.bounds, to: nil).maxY
            height = max(0, bottomInWindow - frame.minY)
        }
        keyboardHeight = height
        editorWithinKeyboard.constant = -12 - height
        outputWithinKeyboard.constant = -12 - height
        UIView.animate(withDuration: duration) { self.view.layoutIfNeeded() }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // This page is entered from another one, so the view already has a width
        // when the text is assigned — but the keyboard's arrival resizes it, and
        // a re-wrap is what keeps the content height honest either way.
        if textView.bounds.width > 0, textView.bounds.width != lastLayoutWidth {
            lastLayoutWidth = textView.bounds.width
            let inset = textView.textContainerInset
            textView.textContainer.size = CGSize(
                width: textView.bounds.width - inset.left - inset.right,
                height: .greatestFiniteMagnitude
            )
            textView.layoutManager.ensureLayout(for: textView.textContainer)
            gutterNeedsRebuild = true
        }

        let textHeight = textView.layoutManager.usedRect(for: textView.textContainer).height
        let inset = textView.textContainerInset
        let needed = textHeight + inset.top + inset.bottom
        if textView.contentSize.height < needed {
            textView.contentSize = CGSize(width: textView.bounds.width, height: needed)
        }

        let editor = textView.frame
        gutter.frame = CGRect(x: editor.minX, y: editor.minY,
                              width: Self.gutterWidth, height: textView.bounds.height)
        updateGutter()
    }

    // MARK: - Line numbers

    private func updateGutter() {
        moveGutter()
        guard gutterNeedsRebuild else { return }
        gutterNeedsRebuild = false
        let numbers = lineNumbers()
        guard numbers != gutterText else { return }
        gutterText = numbers
        gutterLabel.text = numbers
        let width = max(Self.gutterWidth - 6, 1)
        gutterTextHeight = gutterLabel.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height
        moveGutter()
    }

    private func moveGutter() {
        guard gutterTextHeight > 0 else { return }
        gutterLabel.frame = CGRect(
            x: 0, y: textView.textContainerInset.top - textView.contentOffset.y,
            width: max(Self.gutterWidth - 6, 1), height: gutterTextHeight
        )
    }

    private func lineNumbers() -> String {
        let text = textView.text ?? ""
        guard !text.isEmpty else { return "1" }
        var lineStarts: [Int] = [0]
        for (offset, unit) in text.utf16.enumerated() where unit == 0x0A {
            lineStarts.append(offset + 1)
        }
        let layoutManager = textView.layoutManager
        layoutManager.ensureLayout(for: textView.textContainer)
        var numbers: [String] = []
        var previous = -1
        var glyph = 0
        while glyph < layoutManager.numberOfGlyphs {
            var range = NSRange()
            layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
            if NSMaxRange(range) <= glyph { break }
            let character = layoutManager.characterIndexForGlyph(at: range.location)
            var line = 0
            for (position, start) in lineStarts.enumerated() where start <= character { line = position }
            numbers.append(line == previous ? "" : String(line + 1))
            previous = line
            glyph = NSMaxRange(range)
        }
        if text.hasSuffix("\n") { numbers.append(String(lineStarts.count)) }
        return numbers.isEmpty ? "1" : numbers.joined(separator: "\n")
    }

    public func textViewDidChange(_ textView: UITextView) {
        gutterNeedsRebuild = true
        updateGutter()
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        moveGutter()
    }

    /// Tidies the hook's whitespace, the same way the script editor does.
    @objc private func formatHook() {
        guard let formatted = ScriptFormatter.format(textView.text ?? "") else { return }
        guard formatted != textView.text else { return }

        textView.text = formatted
        gutterNeedsRebuild = true
        updateGutter()
        save()
    }

    /// The guide, presented over the editor: the API is a thing a user consults
    /// *while* writing, so leaving the page to read it would be the wrong shape.
    @objc private func showGuide() {
        view.endEditing(true)
        HookGuide.present(from: self, phase: phase)
    }

    // MARK: - Running

    /// Runs the hook against a sample notification and reports its decision.
    ///
    /// There is nothing to send, so what the report shows is exactly what a hook
    /// is for: kept or dropped, forced or not, which fields it changed, and
    /// anything it printed.
    @objc private func runHook() {
        save()

        var sample = BulletinContext()
        sample.appID = "me.fin.bark"
        sample.appName = "Bark"
        sample.bulletinID = "test"
        sample.title = "Test Title"
        sample.subtitle = "Test Subtitle"
        sample.message = "Hello from Pusher — 验证码 123456"
        sample.date = Date()
        sample.displayTitle = BulletinAdapter.displayTitle(appName: sample.appName, title: sample.title)
        sample.displayMessage = "\(sample.subtitle ?? "")\n\(sample.message ?? "")"

        let state = BulletinAdapter.currentDeviceState()
        let outcome = BulletinHookRunner.run(
            script: textView.text ?? "",
            phase: phase,
            context: sample,
            deviceState: state,
            storage: HookStorage.values(forService: instanceID, phase: phase)
        )

        let output = NSMutableAttributedString()
        if let failure = outcome.failure {
            output.appendColored("Hook failed: \(failure.message)", .systemRed)
        }
        if outcome.isKept {
            output.appendColored("keep() — the notification continues", .label)
            if outcome.isForced {
                output.appendColored("force: true — the filters are bypassed", .systemOrange)
            }
            var changed: [String] = []
            if let title = outcome.changes.title { changed.append("title → \(title)") }
            if let subtitle = outcome.changes.subtitle { changed.append("subtitle → \(subtitle)") }
            if let message = outcome.changes.message { changed.append("message → \(message)") }
            if changed.isEmpty {
                output.appendColored("No field was changed.", .secondaryLabel)
            } else {
                output.appendColored("Changed:\n" + changed.joined(separator: "\n"), .systemBlue)
            }
        } else {
            output.appendColored("No keep() — this notification would be dropped.", .systemRed)
        }
        let stateLine = "device: \(state.isLocked ? "locked" : "unlocked"), "
            + "\(state.network.rawValue), \(state.isOnline ? "online" : "offline")"
        output.appendColored(stateLine, .secondaryLabel)
        for line in outcome.consoleOutput {
            output.appendColored(line, .label)
        }

        showOutput(output)
    }

    private func showOutput(_ attributed: NSAttributedString) {
        outputView.attributedText = attributed
        if editorToSafeArea.isActive {
            editorToSafeArea.isActive = false
            editorAboveOutput.isActive = true
        }
        outputView.isHidden = false
        outputHeight.constant = min(
            300, max(120, outputView.contentSize.height + 16)
        )
        view.layoutIfNeeded()
        updateGutter()
    }

    // MARK: - Storage

    private var scriptKey: String {
        phase == .received ? PrefKey.hookReceivedScript : PrefKey.hookFilteredScript
    }

    private func storedScript() -> String {
        PrefsStore.instance(instanceID).string(scriptKey) ?? Self.starter
    }

    /// Writes the hook back onto its instance, which is what makes an edit take
    /// effect on the next notification.
    @discardableResult
    private func save() -> Bool {
        let text = textView.text ?? ""
        guard text != storedScript() else { return false }
        let key = scriptKey
        PrefsStore.updateInstance(instanceID) { object in
            object[key] = text
        }
        return true
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        save()
    }

    /// The empty hook: what a user sees before writing anything, and what `keep()`
    /// looks like in context.
    static let starter = """
    // The notification is in `bullet`; the device state in `device`.
    // Call keep() to continue, or return without it to drop this
    // notification for this service.
    //
    //   bullet.title / bullet.subtitle / bullet.message — editable
    //   device.locked / device.wifi / device.cellular / device.online
    //   fetch(url, init), localStorage, console.log(...) — as in a script
    //
    // keep();                        continue unchanged
    // keep({ force: true });         continue, ignoring the filters
    // (no keep)                      drop it

    keep();
    """
}

// MARK: - Output coloring

private extension NSMutableAttributedString {
    func appendColored(_ text: String, _ color: UIColor) {
        if length > 0 { append(NSAttributedString(string: "\n")) }
        append(NSAttributedString(
            string: text,
            attributes: [.font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                         .foregroundColor: color]
        ))
    }
}
