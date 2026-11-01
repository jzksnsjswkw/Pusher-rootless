import UIKit
import PhotosUI

/// Composes the notification a test push sends.
///
/// The fixed test notification answers one question — does my credential work —
/// and it answers it with the same four strings every time. That is not enough to
/// check a service that treats apps differently, a script that branches on
/// `bullet.appName`, or an SMS payload whose `sim` field only exists for one app.
/// This page builds the notification from fields instead, and sends it through the
/// same pipeline a real one takes.
@objc(NSPNotificationDraftController)
public final class NotificationDraftController: PlainViewController {

    /// The instance to test.
    private let serviceID: String

    /// Called with the composed notification instead of publishing it.
    ///
    /// The hook editor opens this page to choose what its hook runs against, and a
    /// hook has nothing to publish — what it needs is the notification as an input.
    /// When this is set the send button becomes Run and hands the draft over
    /// rather than asking SpringBoard to draw it.
    public var onRun: ((NotificationDraft) -> Void)?

    /// Whether the context is built as a test notification.
    ///
    /// `true` is right for the instance page's "show custom notification": it asks
    /// whether the notification draws correctly, and a rule that would suppress it
    /// has no bearing on that. `false` is right for a hook's Run, where the
    /// filters are half of what the hook is being run against.
    public var isTestDraft = true

    /// The fields to open with, replacing this page's own defaults.
    ///
    /// The hook editor keeps the notification its last Run used and hands it back
    /// here, so changing one keyword does not mean retyping the rest.
    public var initialDraft: NotificationDraft?
    /// The fields as they stand. A value type so "cancel" needs no undo.
    ///
    /// Starts as a message rather than a blank form: an SMS is the one
    /// notification whose payload has more to it than a title and a body — a card,
    /// a number — and it is what most people open this page to try. The fields are
    /// filled with the same text the fixed test notification uses, so the first
    /// Send already produces something recognizable.
    /// Starts from the shared test content, localized. A page that opens on
    /// empty fields makes the user type three lines before the first try.
    private var draft = NotificationDraft(
        title: NotificationDraft.TestContent.title.localized,
        subtitle: NotificationDraft.TestContent.subtitle.localized,
        message: NotificationDraft.TestContent.message.localized
    )

    /// Files written for this page, deleted when it closes.
    ///
    /// The attachment travels to SpringBoard as a path — the two processes share
    /// no memory — so each picked image is written to the app's temporary
    /// directory. Nothing else cleans those up, and a page opened a hundred times
    /// would leave a hundred images behind.
    private var temporaryFiles: [URL] = []

    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let sendButton = UIButton(type: .system)

    private enum Row: Int, CaseIterable {
        case app, title, subtitle, message, attachment, sim
    }

    public init(serviceID: String) {
        self.serviceID = serviceID
        super.init(nibName: nil, bundle: nil)
    }

    /// The framework instantiates a `detail`-named controller through these, so
    /// both are written out: a class that adds its own initializer hides the
    /// inherited ones and the framework's call lands on an unimplemented one.
    public override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        self.serviceID = ""
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "Notification".localized
        view.backgroundColor = .systemGroupedBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(close)
        )

        table.dataSource = self
        table.delegate = self
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)

        sendButton.setTitle(
            (onRun == nil ? "Show Notification" : "Run").localized, for: .normal
        )
        sendButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        sendButton.backgroundColor = Theme.activeTintColor
        sendButton.setTitleColor(.white, for: .normal)
        sendButton.layer.cornerRadius = 12
        sendButton.layer.cornerCurve = .continuous
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)
        view.addSubview(sendButton)

        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: sendButton.topAnchor, constant: -12),

            sendButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            sendButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            sendButton.heightAnchor.constraint(equalToConstant: 50),
            sendButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12
            ),
        ])

        // `NotificationDraft` already resolved both: its defaults name Messages
        // and pick that app's installed card. Nothing is re-derived here, so the
        // page and a Run opened from a hook start from the same notification.
        if let initialDraft { draft = initialDraft }
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || isBeingDismissed { cleanUp() }
    }

    private func cleanUp() {
        for file in temporaryFiles { try? FileManager.default.removeItem(at: file) }
        temporaryFiles.removeAll()
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    // MARK: - Sending

    /// Hands the draft to SpringBoard, which owns the pipeline.
    ///
    /// Straight over distributed messaging, exactly as the fixed test push does:
    /// what changes is only that the notification is described rather than
    /// assumed. The reply says whether a request could be built; the delivery
    /// itself lands in the log, where a real one does.
    @objc private func send() {
        view.endEditing(true)
        let fields = draft.normalised()

        // A caller that wants the notification as an input, not on the screen.
        if let onRun {
            onRun(fields)
            return
        }

        guard let json = Self.payload(for: fields) else { return }

        // `display` publishes the notification onto the screen as the app named in
        // it; `service` is left out because nothing is being forwarded. Two
        // separate questions — "does this notification look right", asked here,
        // and "does my credential work", asked by the instance's own button — and
        // only the first needs a draft.
        let reply = Self.deliver(json, to: serviceID)

        // Both were asked for: the notification on the screen and the push to the
        // instance. Reported separately, because one can succeed while the other
        // fails — a banner that appears but never arrives is exactly the case this
        // page has to say out loud.
        let displayed = (reply?["displayed"] as? NSNumber)?.boolValue == true
        let built = (reply?["builtRequest"] as? NSNumber)?.boolValue
            ?? (reply?["built"] as? NSNumber)?.boolValue
        if displayed, built != false { return }

        // Only the failures are reported, and through a real notification so the
        // result looks like every other result Pusher shows.
        let reason = Self.localizedReason(
            reply?["reason"] as? String
                ?? "SpringBoard has not been restarted since installation"
        )
        TestNotification.present(reason, from: self)
    }

    /// Turns a reason from SpringBoard into a sentence in the user's language.
    ///
    /// The tweak cannot call `.localized` — it lives in this bundle — so it sends
    /// an English key with its arguments appended after `||`, and the wording is
    /// chosen here. A string with no `||` is already a finished sentence, which is
    /// what an unexpected exception produces, and is shown as it came.
    static func localizedReason(_ raw: String) -> String {
        guard let separator = raw.range(of: "||") else { return raw.localized }
        let key = String(raw[raw.startIndex..<separator.lowerBound])
        let argument = String(raw[separator.upperBound...])
        return String(format: key.localized, argument)
    }

    /// Shows the notification and sends it to the instance.
    ///
    /// The one call every test page makes. A hook's Run publishes through here
    /// too, so the banner it draws, the forwarding it does and the reply it reads
    /// are the same for all of them — the pages differ only in the context they
    /// build afterwards.
    static func deliver(_ draftJSON: String, to serviceID: String) -> [String: Any]? {
        guard let center = CPDistributedMessagingCenter(named: Pusher.messagingCenterName)
        else { return nil }
        return center.sendMessageAndReceiveReplyName(
            Pusher.testPushMessageName,
            userInfo: ["service": serviceID, "draftJSON": draftJSON, "display": true]
        ) as? [String: Any]
    }

    /// The draft as the JSON the IPC hop carries.
    static func payload(for draft: NotificationDraft) -> String? {
        let fields = draft.normalised()
        var payload: [String: Any] = [
            "appID": fields.appID,
            "appName": fields.appName,
            "title": fields.title,
            "subtitle": fields.subtitle,
            "message": fields.message,
        ]
        if let url = fields.attachmentURL { payload["attachmentPath"] = url.path }
        if let sim = fields.sim {
            payload["sim"] = ["slot": sim.slot,
                              "phoneNumber": sim.phoneNumber,
                              "label": sim.label]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Picking an app

    /// AltList's own picker, so the list is the installed apps with their icons.
    ///
    /// The selection arrives through `callback` when the page is dismissed, which
    /// is where AltList reports it — reading the row the user tapped would miss
    /// the search results and the selection the framework restores on open.
    private func pickApp() {
        let picker = AppSelectionController()
        picker.selectedAppID = draft.appID
        picker.title = "App".localized
        // Without this the list is a plain alphabetical dump of every installed
        // app, which on a phone with a few hundred of them is unusable.
        picker.useSearchBar = true
        picker.callback = { [weak self] appID in
            guard let self, !appID.isEmpty else { return }
            self.draft.appID = appID
            self.draft.appName = NotificationDraft.displayName(forBundleID: appID)
            // A different app cannot carry a SIM slot, and leaving the old one
            // set would send a `sim` field no real notification of that app has.
            self.draft = self.draft.normalised()
            self.table.reloadData()
        }
        navigationController?.pushViewController(picker, animated: true)
    }

    private func pickImage() {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    @objc private func clearImage() {
        draft.attachmentURL = nil
        table.reloadData()
    }
}

// MARK: - Table

extension NotificationDraftController: UITableViewDataSource, UITableViewDelegate {

    public func numberOfSections(in tableView: UITableView) -> Int { 1 }

    public func tableView(_ tableView: UITableView,
                          numberOfRowsInSection section: Int) -> Int {
        // The SIM row only exists for Messages: no other app's notification can
        // arrive on a card, and offering the choice there would produce a payload
        // that describes something impossible.
        Row.allCases.filter { $0 != .sim || draft.canHaveSIM }.count
    }

    /// The row at an index, accounting for the hidden SIM row.
    private func row(at indexPath: IndexPath) -> Row {
        let rows = Row.allCases.filter { $0 != .sim || draft.canHaveSIM }
        return rows[indexPath.row]
    }

    public func tableView(_ tableView: UITableView,
                          cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch row(at: indexPath) {
        case .app:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = "App".localized
            cell.detailTextLabel?.text = draft.appName
            cell.accessoryType = .disclosureIndicator
            return cell

        case .title, .subtitle, .message:
            let field = DraftFieldCell()
            // The label is a placeholder rather than a value: a text row's own
            // text is what the framework centres and lets the user edit, so a
            // static "标题" in it would have to be deleted before typing. The
            // placeholder disappears on the first keystroke and comes back when the
            // field is cleared, which is the affordance a form field should have.
            let configuration: (String, String) = {
                switch row(at: indexPath) {
                case .title: return ("Title".localized, draft.title)
                case .subtitle: return ("Subtitle".localized, draft.subtitle)
                default: return ("Message".localized, draft.message)
                }
            }()
            field.configure(placeholder: configuration.0, text: configuration.1) { [weak self] text in
                guard let self else { return }
                switch self.row(at: indexPath) {
                case .title: self.draft.title = text
                case .subtitle: self.draft.subtitle = text
                default: self.draft.message = text
                }
            }
            return field

        case .attachment:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = "Attachment".localized
            if let url = draft.attachmentURL, let image = UIImage(contentsOfFile: url.path) {
                // The picture replaces the word "Image" on the trailing side, where
                // the value is read. A thumbnail next to the label answers "which
                // file" better than the label can, and the row already has a column
                // for it.
                //
                // Drawn by hand rather than handed to a `UIImageView`: the table
                // sizes the accessory itself, so an image keeps its own dimensions
                // only if it is made the size it should be.
                let side: CGFloat = 40
                let thumbnail = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
                    UIBezierPath(
                        roundedRect: CGRect(x: 0, y: 0, width: side, height: side),
                        cornerRadius: 8
                    ).addClip()
                    let scale = max(side / image.size.width, side / image.size.height)
                    let drawn = CGSize(width: image.size.width * scale,
                                       height: image.size.height * scale)
                    image.draw(in: CGRect(
                        x: (side - drawn.width) / 2,
                        y: (side - drawn.height) / 2,
                        width: drawn.width, height: drawn.height
                    ))
                }
                // Thumbnail and clear button together, in one container: the
                // accessory slot holds a single view, and both are wanted — one
                // shows the pick, the other undoes it.
                let preview = UIImageView(image: thumbnail.withRenderingMode(.alwaysOriginal))
                preview.frame = CGRect(x: 0, y: 0, width: side, height: side)

                let clear = UIButton(type: .system)
                clear.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
                clear.tintColor = .tertiaryLabel
                clear.frame = CGRect(x: side + 8, y: 0, width: 28, height: 28)
                clear.center.y = side / 2
                clear.addTarget(self, action: #selector(clearImage), for: .touchUpInside)

                let accessory = UIView(frame: CGRect(
                    x: 0, y: 0, width: side + 8 + 28, height: side
                ))
                accessory.addSubview(preview)
                accessory.addSubview(clear)
                cell.accessoryView = accessory
            } else {
                cell.detailTextLabel?.text = "None".localized
                cell.accessoryType = .disclosureIndicator
            }
            return cell

        case .sim:
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = "SIM Slot".localized
            // The label as well as the number: a two-SIM phone shows the same
            // digits in both rows otherwise, and the choice is which card, not
            // which ordinal.
            cell.detailTextLabel?.text = draft.sim.map { sim in
                let name = sim.label.isEmpty ? sim.phoneNumber : sim.label
                return name.isEmpty
                    ? String(format: "Slot %d".localized, sim.slot)
                    : String(format: "Slot %d — %@".localized, sim.slot, name)
            } ?? "None".localized
            cell.accessoryType = .disclosureIndicator
            return cell
        }
    }

    public func tableView(_ tableView: UITableView,
                          didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        view.endEditing(true)
        switch row(at: indexPath) {
        case .app: pickApp()
        case .attachment: pickImage()
        case .sim: pickSIM()
        case .title, .subtitle, .message:
            (tableView.cellForRow(at: indexPath) as? DraftFieldCell)?.focus()
        }
    }
}

// MARK: - SIM slot

extension NotificationDraftController {

    /// Which of the two cards the notification claims to have arrived on.
    ///
    /// Two options, because iOS has at most two. The numbers and labels come from
    /// the real SIMs so the payload matches what the pipeline would resolve for a
    /// genuine message; a slot with no card is offered anyway, so the case of a
    /// message arriving on an empty slot can be reproduced.
    private func pickSIM() {
        let sheet = UIAlertController(
            title: "SIM Slot".localized, message: nil, preferredStyle: .actionSheet
        )

        // Read live, and fall back to bare numbers when CoreTelephony answers with
        // nothing — a page whose only job is to name a slot must not be empty just
        // because the numbers could not be fetched. Which is also how a message
        // arriving on a slot with no card can be reproduced.
        let subscriptions = SIMSubscriptions.all()
        for slot in 1...2 {
            let match = subscriptions.first { $0.slot == slot }
            let label = match.map { $0.label.isEmpty ? $0.phoneNumber : $0.label } ?? ""
            let title = label.isEmpty
                ? String(format: "Slot %d".localized, slot)
                : String(format: "Slot %d — %@".localized, slot, label)
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self else { return }
                self.draft.sim = SIMSubscription(
                    slot: slot,
                    phoneNumber: match?.phoneNumber ?? "",
                    label: match?.label ?? ""
                )
                self.table.reloadData()
            })
        }
        sheet.addAction(UIAlertAction(title: "None".localized, style: .cancel) { [weak self] _ in
            self?.draft.sim = nil
            self?.table.reloadData()
        })

        // An action sheet on a regular-width device needs an anchor; without one
        // presenting it throws.
        if let cell = table.cellForRow(at: IndexPath(row: 0, section: 0)) {
            sheet.popoverPresentationController?.sourceView = cell
            sheet.popoverPresentationController?.sourceRect = cell.bounds
        }
        present(sheet, animated: true)
    }
}

// MARK: - Image picking

extension NotificationDraftController: PHPickerViewControllerDelegate {
    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider,
              provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let image = object as? UIImage,
                  let data = image.pngData() else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                // Written to disk because the path, not the image, is what
                // crosses to SpringBoard — and written to a directory both
                // processes can reach. `temporaryDirectory` is this process's own
                // sandbox container, which SpringBoard cannot open; the shared
                // preferences directory is readable by both and is where this
                // tweak already keeps the files the two sides exchange.
                guard let url = NotificationDraft.attachmentScratchURL() else { return }
                do {
                    try data.write(to: url)
                } catch {
                    // Reported rather than swallowed: a silent failure here is
                    // "the attachment does not appear", with nothing to go on.
                    self.presentAlert("Could not save the attachment: \(error.localizedDescription)")
                    return
                }
                self.temporaryFiles.append(url)
                self.draft.attachmentURL = url
                self.table.reloadData()
            }
        }
    }
}

// MARK: - A row that edits a string

/// A text row that reports every keystroke.
///
/// `PSEditTextCell` is not used here: this page has no specifiers and no
/// preference store, so the framework's cell would need a specifier, a target and
/// a selector for each of three fields — three times the machinery for the same
/// one-line edit.
private final class DraftFieldCell: UITableViewCell, UITextFieldDelegate {
    private let field = UITextField()
    private var onChange: ((String) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.addTarget(self, action: #selector(edited), for: .editingChanged)
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .done
        field.delegate = self
        contentView.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            field.topAnchor.constraint(equalTo: contentView.topAnchor),
            field.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        selectionStyle = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(placeholder: String, text: String, onChange: @escaping (String) -> Void) {
        field.placeholder = placeholder
        if field.text != text { field.text = text }
        self.onChange = onChange
    }

    func focus() { field.becomeFirstResponder() }

    @objc private func edited() { onChange?(field.text ?? "") }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
