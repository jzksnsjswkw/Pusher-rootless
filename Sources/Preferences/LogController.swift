import UIKit
import notify

/// The on-device push log viewer.
///
/// Shows what happened to each bulletin: the URL, headers and body that went
/// out, and the server's response. That makes this the page to open when a push
/// is not arriving, which is why it carries the most affordances of any page
/// here — filters, expandable rows, copy-to-clipboard, and a live refresh when
/// new entries are written.
///
/// Per-service pages show one service's events; the global page merges all of
/// them (or just the global pre-fan-out log, via the "Global Only" switch).
@objc(NSPLogController)
public final class LogController: PlainViewController, UITableViewDataSource, UITableViewDelegate {
    private enum FixedRow {
        /// "Logger Enabled" appears only on a service page.
        static let logEnabled = 0
        static let clearLogs = 1
        static let networkResponse = 0
        static let endResult = 1
        static let appFilter = 2
        static let globalOnly = 3
    }

    private let segmentedControlTag = 673
    private let expandedTextViewTag = 674
    private static let cellIdentifier = "LogCell"

    /// The service this page shows, or `""` for the global page.
    private var service = ""
    private var isGlobal = true
    private var logKey = ""
    private var logEnabledKey = ""

    private var logTable: UITableView!
    private var logEnabled = true
    private var logEnabledRow: Int?
    private var clearLogRow = 0
    private var globalOnlyRow: Int?

    /// Section titles, and one array of rows per title.
    private var sections: [String] = []
    private var rows: [String: [String]] = [:]
    private var firstLogSection = 0

    /// Rows that are too long for one line, and so show the expand button.
    private var truncatedRows: Set<IndexPath> = []
    /// Rows the user has expanded.
    private var expandedRows: Set<IndexPath> = []

    private var filteredAppID: String?
    private var filteredNetworkResponse: String?
    private var filteredEndResult: String?
    private var filteredGlobalOnly = false

    public override func viewDidLoad() {
        super.viewDidLoad()

        service = specifier?.string(SpecifierRouting.PropertyKey.service) ?? ""
        isGlobal = service.isEmpty
        logKey = PrefKey.logKey(forService: service)
        logEnabledKey = PrefKey.logEnabledKey(forService: service)

        let frame = UIDevice.current.userInterfaceIdiom == .pad
            ? root?.view.bounds ?? view.bounds
            : view.bounds
        logTable = UITableView(frame: frame, style: .grouped)
        logTable.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellIdentifier)
        logTable.delegate = self
        logTable.dataSource = self
        view.addSubview(logTable)

        navigationItem.title = specifier?.string("label") ?? "Log".localized
        logEnabled = PrefsStore.prefs().bool(logEnabledKey, default: true)

        // Live updates: the pipeline notifies after every log write, so an open
        // viewer keeps up without a manual refresh.
        observerToken = LogObserver.observe { [weak self] in
            self?.updateLogAndReload()
        }
        updateLogAndReload()
    }

    private var observerToken: LogObserver.Token?

    deinit {
        // Remove the observer before anything else is torn down, so a
        // notification cannot arrive into a half-released controller.
        if let observerToken { LogObserver.remove(observerToken) }
    }

    // MARK: - Log data

    private func updateLogAndReload() {
        updateLog()
        logTable?.reloadData()
    }

    /// Rebuilds the section/row model from the stored log.
    private func updateLog() {
        let prefs = LogStore.snapshot()
        truncatedRows = []
        expandedRows = []
        rows = [:]

        // A service page has an enable switch; the global log is always on.
        // The global page alone gets "Global Only".
        sections = ["Settings", "Filters"]
        rows["Settings"] = isGlobal
            ? ["Clear All Logs"]
            : ["Logger Enabled", "Clear All Logs"]
        rows["Filters"] = isGlobal
            ? ["Network Response", "End Result", "Select an App", "Global Only"]
            : ["Network Response", "End Result", "Select an App"]

        logEnabledRow = isGlobal ? nil : FixedRow.logEnabled
        clearLogRow = isGlobal ? 0 : FixedRow.clearLogs
        globalOnlyRow = isGlobal ? FixedRow.globalOnly : nil
        firstLogSection = sections.count

        for section in logSections(from: prefs) {
            let appID = section.string("appID")
            if let filteredAppID, appID != filteredAppID { continue }

            let logs = section.array("logs").map {
                ($0 as? String) ?? String(describing: $0)
            }
            guard LogFormatter.shouldInclude(
                logs: logs, networkResponse: filteredNetworkResponse, endResult: filteredEndResult
            ) else { continue }

            let title = LogFormatter.sectionTitle(forSection: section)
            sections.append(title)
            rows[title] = logs
        }
    }

    /// The stored log sections this page shows.
    ///
    /// The global page normally merges every service's `<service>Log` array,
    /// tagging each with its service; "Global Only" narrows it to the
    /// pre-fan-out log.
    private func logSections(from prefs: [String: Any]) -> [Prefs] {
        var collected: [Prefs] = []
        if isGlobal, !filteredGlobalOnly {
            for key in prefs.keys where key.hasSuffix("Log") {
                guard let stored = prefs[key] as? [[String: Any]] else { continue }
                let serviceName = String(key.dropLast(3))
                for section in stored {
                    var tagged = section
                    tagged["service"] = serviceName
                    collected.append(Prefs(tagged))
                }
            }
        } else {
            collected = (prefs[logKey] as? [[String: Any]] ?? []).map(Prefs.init)
        }

        // Newest first: the entry just written is the one being looked for.
        return collected.sorted {
            (($0["timestamp"] as? Date) ?? .distantPast) > (($1["timestamp"] as? Date) ?? .distantPast)
        }
    }

    private func row(at indexPath: IndexPath) -> String? {
        guard indexPath.section < sections.count else { return nil }
        let sectionRows = rows[sections[indexPath.section]] ?? []
        guard indexPath.row < sectionRows.count else { return nil }
        return sectionRows[indexPath.row]
    }

    // MARK: - Settings actions

    @objc private func updateLogEnabled(_ sender: UISwitch) {
        logEnabled = sender.isOn
        PrefsStore.setValue(logEnabled, forKey: logEnabledKey)
    }

    @objc private func updateGlobalOnly(_ sender: UISwitch) {
        filteredGlobalOnly = sender.isOn
        updateLogAndReload()
    }

    @objc private func networkResponseFilterUpdated(_ sender: UISegmentedControl) {
        filteredNetworkResponse = LogFilter.networkResponse(at: sender.selectedSegmentIndex)
        updateLogAndReload()
    }

    @objc private func endResultFilterUpdated(_ sender: UISegmentedControl) {
        filteredEndResult = LogFilter.endResult(at: sender.selectedSegmentIndex)
        updateLogAndReload()
    }

    private func clearLogs() {
        if isGlobal {
            LogStore.removeAllLogs()
        } else {
            LogStore.removeLogs(forService: service)
        }
        // The logs were just deleted, so the section model is rebuilt from
        // scratch rather than diffed — a diff would race the deletion.
        updateLog()
        logTable.reloadData()
    }

    private func selectAppFilter() {
        let picker = AppSelectionController()
        picker.selectedAppID = filteredAppID
        picker.callback = { [weak self] appID in
            guard let self else { return }
            self.filteredAppID = appID
            self.updateLogAndReload()
            self.showAppFilterTutorialIfNeeded()
        }
        picker.useSearchBar = true
        navigationController?.pushViewController(picker, animated: true)
    }

    // MARK: - First-run tutorial

    /// Explains the gestures the log viewer supports, which are not
    /// discoverable: swipe to clear the app filter, tap to expand, hold to copy.
    private func showAppFilterTutorialIfNeeded() {
        let key = "LogAppFilterTutorialShown"
        guard !PrefsStore.prefs().bool(key) else { return }
        PrefsStore.setValue(true, forKey: key, notify: false)

        let message = "After using the app filter, you can swipe to delete to unset "
            .localized + "it and show all apps again.\n\nTap on any truncated log to "
            .localized + "expand it.\n\n Tap and hold on a log to copy it to the "
            .localized + "clipboard.\n\nTap anywhere to continue.".localized
        TutorialOverlay.present(message, from: self, in: view.window)
    }

    // MARK: - Table data source

    public func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows[sections[section]]?.count ?? 0
    }

    public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        let title = sections[section]
        guard section < firstLogSection else { return title }
        return title.localized
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellIdentifier, for: indexPath)
        cell.accessoryType = .none
        cell.accessoryView = nil
        cell.imageView?.image = nil
        cell.textLabel?.text = nil
        cell.textLabel?.textColor = nil
        cell.tintColor = Theme.activeTintColor

        // Cells are reused, so anything added for a previous row is removed by
        // tag rather than tracked.
        cell.contentView.viewWithTag(expandedTextViewTag)?.removeFromSuperview()
        cell.contentView.viewWithTag(segmentedControlTag)?.removeFromSuperview()

        if indexPath.section == 1 {
            return filterCell(cell, at: indexPath)
        }

        if let title = row(at: indexPath) {
            cell.textLabel?.text = indexPath.section < firstLogSection ? title.localized : title
        }

        if indexPath.section == 0 {
            settingsCell(cell, at: indexPath)
            return cell
        }

        configureLogCell(cell, at: indexPath)
        return cell
    }

    /// The Settings section: the enable switch and the clear button.
    private func settingsCell(_ cell: UITableViewCell, at indexPath: IndexPath) {
        if indexPath.row == logEnabledRow {
            let toggle = UISwitch()
            toggle.isOn = logEnabled
            toggle.addTarget(self, action: #selector(updateLogEnabled(_:)), for: .valueChanged)
            cell.accessoryView = toggle
        } else if indexPath.row == clearLogRow {
            cell.textLabel?.textColor = Theme.activeTintColor
        }
    }

    /// The Filters section: two segmented controls, the app filter and the
    /// global-only switch.
    private func filterCell(_ cell: UITableViewCell, at indexPath: IndexPath) -> UITableViewCell {
        switch indexPath.row {
        case FixedRow.networkResponse, FixedRow.endResult:
            let isNetworkResponse = indexPath.row == FixedRow.networkResponse
            // The first item in each list is "no filter", so index 0 maps to a
            // nil filter.
            let items = (isNetworkResponse ? LogFilter.networkResponses : LogFilter.endResults)
                .map(\.localized)
            let control = UISegmentedControl(items: items)
            control.selectedSegmentIndex = isNetworkResponse
                ? LogFilter.networkResponses.firstIndex(of: filteredNetworkResponse ?? "Any") ?? 0
                : LogFilter.endResults.firstIndex(of: filteredEndResult ?? "Any") ?? 0
            control.addTarget(
                self,
                action: isNetworkResponse
                    ? #selector(networkResponseFilterUpdated(_:))
                    : #selector(endResultFilterUpdated(_:)),
                for: .valueChanged
            )
            control.tag = segmentedControlTag
            control.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(control)
            NSLayoutConstraint.activate([
                control.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 5),
                control.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -5),
                control.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 5),
                control.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -5),
            ])

        case FixedRow.appFilter:
            cell.accessoryType = .disclosureIndicator
            guard let filteredAppID else { break }
            let appName = LSApplicationProxy.applicationProxy(forIdentifier: filteredAppID)?.localizedName
                ?? "Unknown App".localized
            cell.textLabel?.text = String(format: "App Filter: %@".localized, appName)
            cell.imageView?.image = ApplicationIcon.image(forBundleID: filteredAppID)

        case FixedRow.globalOnly:
            let toggle = UISwitch()
            toggle.isOn = filteredGlobalOnly
            toggle.addTarget(self, action: #selector(updateGlobalOnly(_:)), for: .valueChanged)
            cell.accessoryView = toggle

        default:
            break
        }
        return cell
    }

    /// A log row: one line, or a scrollable text view once expanded.
    private func configureLogCell(_ cell: UITableViewCell, at indexPath: IndexPath) {
        let isExpanded = expandedRows.contains(indexPath)

        if isExpanded, let text = cell.textLabel?.text {
            let textView = UITextView()
            textView.tag = expandedTextViewTag
            textView.isEditable = false
            textView.text = text
            textView.font = cell.textLabel?.font
            // The label is cleared so the text is not drawn twice.
            cell.textLabel?.text = nil
            textView.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(textView)

            // Long entries are capped so one row cannot fill the screen; the
            // text view scrolls instead.
            let textHeight = text.boundingRect(
                with: CGSize(width: cell.contentView.bounds.width, height: .greatestFiniteMagnitude),
                options: .usesLineFragmentOrigin,
                attributes: [.font: textView.font as Any],
                context: nil
            ).height + 30
            let maxHeight = UIScreen.main.bounds.height / 2

            NSLayoutConstraint.activate([
                textView.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 10),
                textView.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -10),
                textView.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 10),
                textView.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -10),
                textView.heightAnchor.constraint(equalToConstant: min(textHeight, maxHeight)),
            ])
            return
        }

        // Truncation is only computed once per row; measuring on every reuse
        // would be wasted work while scrolling.
        if truncatedRows.contains(indexPath) {
            cell.accessoryType = .detailButton
            return
        }

        guard let text = cell.textLabel?.text else { return }
        let size = text.size(withAttributes: [.font: cell.textLabel?.font as Any])
        let isTruncated = size.width > cell.contentView.bounds.width
            || size.height > cell.contentView.bounds.height
            || text.contains("\n")
        if isTruncated {
            truncatedRows.insert(indexPath)
            cell.accessoryType = .detailButton
        }
    }

    // MARK: - Table delegate

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 0, indexPath.row == clearLogRow else {
            if indexPath.section == 1, indexPath.row == FixedRow.appFilter {
                selectAppFilter()
            }
            return
        }
        clearLogs()
    }

    public func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        (indexPath.section == 0 && indexPath.row == clearLogRow)
            || (indexPath.section == 1 && indexPath.row == FixedRow.appFilter)
    }

    /// Only the app filter row can be swiped away, which clears the filter.
    public func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        indexPath.section == 1 && indexPath.row == FixedRow.appFilter
    }

    public func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete, indexPath.section == 1,
              indexPath.row == FixedRow.appFilter else { return }
        filteredAppID = nil
        updateLogAndReload()
    }

    /// Long-press to copy one log line.
    public func tableView(_ tableView: UITableView, shouldShowMenuForRowAt indexPath: IndexPath) -> Bool {
        indexPath.section >= firstLogSection
    }

    public func tableView(
        _ tableView: UITableView,
        canPerformAction action: Selector,
        forRowAt indexPath: IndexPath,
        withSender sender: Any?
    ) -> Bool {
        indexPath.section >= firstLogSection && action == #selector(copy(_:))
    }

    public func tableView(
        _ tableView: UITableView,
        performAction action: Selector,
        forRowAt indexPath: IndexPath,
        withSender sender: Any?
    ) {
        guard indexPath.section >= firstLogSection, action == #selector(copy(_:)) else { return }
        // The row's stored text is copied rather than the cell's label: an
        // expanded row has moved its text into a text view.
        UIPasteboard.general.string = row(at: indexPath)
    }

    /// The expand/collapse button on a truncated row.
    public func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) {
        guard indexPath.section >= firstLogSection else { return }
        // Only rows that are expanded or actually truncated can be toggled.
        guard expandedRows.contains(indexPath) || truncatedRows.contains(indexPath) else { return }
        if expandedRows.contains(indexPath) {
            expandedRows.remove(indexPath)
        } else {
            expandedRows.insert(indexPath)
        }
        tableView.reloadRows(at: [indexPath], with: .automatic)
    }
}

// MARK: - Log change notifications

/// Fans the pipeline's "a log entry was written" Darwin notification out to the
/// open log viewer.
///
/// The callback arrives on a background thread and the notification carries no
/// user info, so there is nothing to parse — this only has to deliver a
/// "something changed" signal to whichever viewer is currently open, on the main
/// thread.
enum LogObserver {
    /// An opaque handle to one registration.
    final class Token {}

    private static var handlers: [ObjectIdentifier: () -> Void] = [:]
    private static var isInstalled = false
    private static let lock = NSLock()

    /// Registers `handler`, returning a token to pass to ``remove(_:)``.
    static func observe(_ handler: @escaping () -> Void) -> Token {
        let token = Token()
        lock.lock()
        handlers[ObjectIdentifier(token)] = handler
        if !isInstalled {
            isInstalled = true
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                nil,
                { _, _, _, _, _ in
                    LogObserver.notify()
                },
                Pusher.logPrefsNotification as CFString,
                nil,
                .coalesce
            )
        }
        lock.unlock()
        return token
    }

    static func remove(_ token: Token) {
        lock.lock()
        handlers.removeValue(forKey: ObjectIdentifier(token))
        lock.unlock()
    }

    private static func notify() {
        // The Darwin callback runs on a background thread; UITableView may only
        // be touched on the main thread.
        DispatchQueue.main.async {
            lock.lock()
            let current = Array(handlers.values)
            lock.unlock()
            for handler in current { handler() }
        }
    }
}

// MARK: - Tutorial overlay

/// The full-screen explanation shown once per feature on first use.
enum TutorialOverlay {
    /// Presents `message` over `view`, dismissing on the first tap.
    ///
    /// The dismissing tap is armed after a beat so the tap that opened the page
    /// cannot also close the overlay.
    static func present(_ message: String, from controller: UIViewController, in window: UIWindow?) {
        guard let window else { return }

        let overlay = UIView(frame: window.bounds)
        overlay.alpha = 0
        overlay.backgroundColor = UIColor(white: 0, alpha: 0.9)

        let label = UILabel()
        label.font = .systemFont(ofSize: UIFont.systemFontSize * 1.5, weight: .thin)
        label.textColor = .white
        label.text = message
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(label)

        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: 270),
            label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        ])

        window.addSubview(overlay)
        UIView.animate(withDuration: 0.3) { overlay.alpha = 1 }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            overlay.addGestureRecognizer(UITapGestureRecognizer(
                target: Dismisser.shared,
                action: #selector(Dismisser.dismiss(_:))
            ))
        }
    }

    /// The gesture target, kept alive because a gesture recognizer does not
    /// retain its target.
    private final class Dismisser: NSObject {
        static let shared = Dismisser()

        @objc func dismiss(_ gesture: UITapGestureRecognizer) {
            guard let overlay = gesture.view else { return }
            UIView.animate(withDuration: 0.3, animations: { overlay.alpha = 0 }) { _ in
                overlay.removeFromSuperview()
            }
        }
    }
}
