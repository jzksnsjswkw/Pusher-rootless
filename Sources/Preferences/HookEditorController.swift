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

    /// The notification the last Run used, kept so reopening starts from it.
    private var runDraft: NotificationDraft?
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
        // Tinted like every other button in the app. A bar button item takes its
        // colour from the navigation bar's tint, and this page sets its own
        // `activeTintColor` on cells — without this the three buttons render in
        // the system default blue while everything around them is green.
        let tint = Theme.activeTintColor
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Run".localized, style: .plain,
                            target: self, action: #selector(runHook)),
            UIBarButtonItem(title: "Format".localized, style: .plain,
                            target: self, action: #selector(formatHook)),
            UIBarButtonItem(title: "Guide".localized, style: .plain,
                            target: self, action: #selector(showGuide)),
            UIBarButtonItem(title: "Examples".localized, style: .plain,
                            target: self, action: #selector(showExamples)),
        ].map { item in
            item.tintColor = tint
            return item
        }

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

    /// Opens the notification the hook will be run against.
    ///
    /// The sample used to be four fixed strings, which answers "does this hook
    /// compile" and nothing else — a hook that branches on the app, the card or a
    /// keyword in the body could not be tried at all. The page that composes a
    /// notification is the same one the instance page uses, and what it holds is
    /// kept here so reopening it continues from what the user last wrote.
    @objc private func runHook() {
        save()
        view.endEditing(true)

        // Kept across openings: the fields the user filled in are still what they
        // want to run against next time, and retyping four fields to change one
        // keyword is the kind of thing that makes a Run button go unused.
        let composer = NotificationDraftController(serviceID: instanceID)
        // A Run is a test of the hook, so it is a test notification. See
        // `PushEngine.runHook`: a test runs the hook whether or not its switch is
        // on, because "does my hook work" is the question a Run asks.
        // A starting notification the hook's examples can act on: a verification
        // code, which is what two of the three examples are for. Kept after the
        // first Run, so changing one field does not mean retyping the rest.
        composer.initialDraft = runDraft ?? NotificationDraft(
            title: "10086",
            subtitle: "",
            message: "【通知示例】您的验证码是：392511，请在10分钟内完成验证。".localized
        )
        composer.onRun = { [weak self] draft in
            guard let self else { return }
            self.runDraft = draft
            // Dismissed first: the result is drawn under the editor, and a sheet
            // covering it would hide the thing the Run was for.
            self.dismiss(animated: true) {
                self.performRun(with: draft)
            }
        }
        let navigation = UINavigationController(rootViewController: composer)
        navigation.modalPresentationStyle = .pageSheet
        present(navigation, animated: true)
    }

    /// Offers the API as snippets, and inserts the chosen one.
    ///
    /// An action sheet rather than a page: the list is six titles, and the text
    /// lands in the editor behind it — a pushed list would have to be dismissed
    /// before the result could be read.
    @objc private func showExamples() {
        view.endEditing(true)
        let sheet = UIAlertController(
            title: "Examples".localized, message: nil, preferredStyle: .actionSheet
        )
        for example in JavaScriptAPI.hookExamples {
            sheet.addAction(UIAlertAction(
                title: example.title.localized, style: .default
            ) { [weak self] _ in
                self?.insert(example.code)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel))
        sheet.popoverPresentationController?.barButtonItem =
            navigationItem.rightBarButtonItems?.first
        present(sheet, animated: true)
    }

    /// Puts a snippet in the editor.
    ///
    /// Replaces an empty script outright and appends to a non-empty one: a user
    /// who already wrote something is adding to it, and one who has not is
    /// starting from the example.
    private func insert(_ code: String) {
        let existing = (textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        textView.text = existing.isEmpty ? code : existing + "\n\n" + code
        // The gutter is driven by the delegate, which a programmatic change does
        // not call.
        gutterNeedsRebuild = true
        textViewDidChange(textView)
    }

    /// Runs the hook against a composed notification.
    ///
    /// `push()` sends for real: the delivery goes through the same `RequestSender`
    /// a service uses, so a Run produces the same log lines, the same retries and
    /// the same answer the pipeline would.
    private func performRun(with draft: NotificationDraft) {
        // The editor's own copy, for showing what the hook decides. Its `test`
        // origin matters only here: `.hook(phase)` is what lets this one run even
        // when its switch is off, which is what "does my hook work" means.
        //
        // The notification actually sent is a separate call and carries no such
        // marker, so the pipeline runs the hook for real — the hook's edits reach
        // the payload exactly once, and the banner shows what the user typed.
        var sample = draft.makeContext(test: .hook(phase))

        let state = BulletinAdapter.currentDeviceState()
        let outcome = BulletinHookRunner.run(
            script: textView.text ?? "",
            phase: phase,
            context: sample,
            deviceState: state,
            storage: HookStorage.values(forService: instanceID, phase: phase),
            deliver: { request in
                // The same `RequestSender` a service uses, so a `push()` from a
                // hook gets the same retries, the same image shrinking and the
                // same log lines a real push would.
                let done = DispatchSemaphore(value: 0)
                let box = HookResumeBox()
                request.completion = { result in
                    box.result = result
                    done.signal()
                }
                RequestSender.shared.send(
                    request,
                    logString: "[Hook,Run]",
                    service: "Hook",
                    context: sample
                )
                _ = done.wait(timeout: .now() + 60)
                return box.result ?? JavaScriptRunner.FetchResult(
                    status: 0, error: "timed out"
                )
            }
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
        // The requests a `push()` sent, in the order it sent them, then the
        // answers. Same colors as the service editor's Run: purple for what went
        // out, green or red for what came back.
        for entry in outcome.trace {
            switch entry {
            case .console(let line):
                output.appendColored(line, .label)
            case .request(_, let raw):
                output.appendColored(raw, .systemPurple)
            case .response(let text):
                let failed = text.hasPrefix("← failed:")
                output.appendColored(text, failed ? .systemRed : UIColor.successResponse)
            }
        }

        let stateLine = "device: \(state.isLocked ? "locked" : "unlocked"), "
            + "\(state.network.rawValue), \(state.isOnline ? "online" : "offline")"
        output.appendColored(stateLine, .secondaryLabel)
        for line in outcome.consoleOutput {
            output.appendColored(line, .label)
        }

        // The rule outcome and the edits are reported in the output pane, not
        // folded into the sent draft: the pipeline runs the hook itself on the way
        // to the service, so applying the edits here as well would send a payload
        // with them applied twice. `draft` is what goes over the IPC hop, untouched
        // — the banner shows what the user typed, and `sample` below carries the
        // hook's own decision for anything the output needs to report.
        if outcome.isKept {
            _ = outcome.changes.apply(to: &sample)
        }

        // The notification then goes through the real pipeline for this instance:
        // the same filters, the same request builder, the same transport a live
        // notification takes. A Run that only reported what the hook decided would
        // leave out the half of the chain that can reject the notification after
        // the hook has already said yes.
        //
        // A test, so the app lists and the notification conditions do not get to
        // discard it: the question is what this hook does, not whether a rule
        // would have blocked the notification first.
        // Shown and forwarded through the same call the instance page and the
        // compose page use: one notification on screen, one push to the instance.
        // A Run that only printed the outcome left the user guessing whether the
        // hook's edits reached a real payload.
        // The draft, untouched: the banner shows what the user typed and the
        // pipeline runs the hook on its way to the service. Sending the edited
        // version instead made the banner disagree with the fields still on the
        // page, and skipping the hook made the Run claim an edit the payload never
        // received — the output pane showed what the hook decided, not what was
        // sent.
        if let json = NotificationDraftController.payload(for: draft) {
            let reply = NotificationDraftController.deliver(json, to: instanceID)
            let displayed = (reply?["displayed"] as? NSNumber)?.boolValue == true
            let built = (reply?["builtRequest"] as? NSNumber)?.boolValue
                ?? (reply?["built"] as? NSNumber)?.boolValue
            if displayed, built != false {
                output.appendColored(
                    "Forwarded to this instance — the result is in Log".localized,
                    .secondaryLabel
                )
            } else {
                output.appendColored(
                    reply?["reason"] as? String
                        ?? "SpringBoard has not been restarted since installation".localized,
                    .systemRed
                )
            }
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


/// Holds a `RequestSender` result across the semaphore wait.
private final class HookResumeBox: @unchecked Sendable {
    var result: JavaScriptRunner.FetchResult?
}
