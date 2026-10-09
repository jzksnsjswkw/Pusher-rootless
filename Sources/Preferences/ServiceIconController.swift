import UIKit
import PhotosUI

/// Picks a service's own icon.
///
/// Three sections on one page, because they are three ways to arrive at the same
/// thing and a user may want any of them:
///
/// 1. **Gallery** — a grid of SF Symbols, plus a row of tints. This is the fast
///    path and the one that produces a clean result: a symbol is drawn at the
///    chosen size, so it is crisp and its file is tiny.
/// 2. **From a photo** — the photo library. Scaled to fit a square, not cropped,
///    so the user's composition survives.
/// 3. **Size** — how large the stored icon is. It trades fidelity against
///    payload size, and the payload carries this icon on every notification.
///
/// Edits are cached and written once, on the way out: the picker can be
/// cancelled, and a half-chosen icon should leave nothing behind. Each change
/// also renders immediately so the preview shows the real result rather than a
/// description of it.
public final class ServiceIconController: PSViewController {

    /// Where the chosen icon is written.
    public let storage: Storage
    /// The page's heading. Named to avoid ``UIViewController/title``, which is
    /// `String?` and is what the navigation bar reads.
    private let heading: String

    /// Which store the icon belongs to.
    ///
    /// The picker is used from an instance page and from a script definition
    /// page, and those are two different arrays; which one a cell writes to is
    /// the caller's knowledge, so it is passed in rather than guessed.
    public enum Storage {
        case instance(id: String)
        case definition(id: String)
    }

    /// The section of the page: which part of the icon is being edited.
    private enum Section: Int, CaseIterable {
        case size
        case gallery
        case tints
        case photo
    }

    // The edited state. Held here rather than read back from storage on every
    // change: the page is a draft until it is left.
    private var selectedSymbol: String?
    private var selectedTint: Int = 0
    private var selectedSize: ServiceIcon.Size
    private var photoImage: UIImage?
    /// Whether the icon came from the photo library, which is what decides
    /// whether the tint row means anything.
    private var isPhotoSource = false
    private var renderToken = 0

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private weak var previewCell: UITableViewCell?

    public init(storage: Storage, heading: String) {
        self.storage = storage
        self.heading = heading
        let stored = ServiceIconController.readPrefs(storage)
        let storedSize = ServiceIcon.Size(rawValue: stored.int(PrefKey.customIconSize))
        self.selectedSize = storedSize ?? .standard
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    public override init(nibName: String?, bundle: Bundle?) {
        self.storage = .instance(id: "")
        self.heading = ""
        self.selectedSize = .standard
        super.init(nibName: nibName, bundle: bundle)
    }
    public override init(forContentSize contentSize: CGSize) {
        self.storage = .instance(id: "")
        self.heading = ""
        self.selectedSize = .standard
        super.init(nibName: nil, bundle: nil)
    }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = heading
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Save".localized, style: .done,
            target: self, action: #selector(saveAndClose)
        )

        let stored = ServiceIconController.readPrefs(storage)
        selectedSymbol = stored.nonEmptyString(PrefKey.customIconSymbol)
        isPhotoSource = stored.string(PrefKey.customIconSource) == "photo"
        selectedTint = stored.int(PrefKey.customIconTint)
        if isPhotoSource, let base64 = stored.string(PrefKey.customIcon) {
            photoImage = ServiceIcon.image(fromBase64: base64)
        }
        if selectedSymbol == nil, !isPhotoSource {
            selectedSymbol = ServiceIcon.gallery.first
        }

        view.backgroundColor = .systemGroupedBackground
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(IconCell.self, forCellReuseIdentifier: "icon")
        tableView.register(PreviewCell.self, forCellReuseIdentifier: "preview")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "plain")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Storage

    private static func readPrefs(_ storage: Storage) -> Prefs {
        switch storage {
        case .instance(let id): return PrefsStore.instance(id)
        case .definition(let id): return CustomServiceStore.rawEntry(id: id)
        }
    }

    /// The same, as the plain object the writers mutate.
    private static func readRaw(_ storage: Storage) -> [String: Any] {
        readPrefs(storage).raw
    }

    /// Writes the draft out.
    ///
    /// All five keys together: a size change has to re-render the stored value,
    /// so the recipe and the picture are always written as a set. Choosing "no
    /// icon" removes all of them, which is what makes the notification fall back
    /// to the sending app's icon.
    private func persist(_ object: inout [String: Any]) {
        object.removeValue(forKey: PrefKey.customIcon)
        object.removeValue(forKey: PrefKey.customIconSymbol)
        object.removeValue(forKey: PrefKey.customIconTint)
        object.removeValue(forKey: PrefKey.customIconSource)
        object.removeValue(forKey: PrefKey.customIconSize)

        guard let rendered = renderCurrent() else { return }
        guard let base64 = ServiceIcon.storedValue(rendered) as String?, !base64.isEmpty else {
            return
        }
        object[PrefKey.customIcon] = base64
        object[PrefKey.customIconSize] = selectedSize.rawValue
        object[PrefKey.customIconSource] = isPhotoSource ? "photo" : "symbol"
        if isPhotoSource {
            // Nothing else to remember: the picture is the whole recipe.
            return
        }
        object[PrefKey.customIconSymbol] = selectedSymbol
        object[PrefKey.customIconTint] = selectedTint
    }

    // MARK: - Rendering

    /// The icon the current state describes, at the current size.
    private func renderCurrent() -> UIImage? {
        if isPhotoSource {
            guard let photoImage else { return nil }
            return ServiceIcon.normalize(photoImage, to: selectedSize)
        }
        guard let symbol = selectedSymbol else { return nil }
        let tint = ServiceIcon.tints[
            max(0, min(selectedTint, ServiceIcon.tints.count - 1))
        ].color
        return ServiceIcon.render(
            symbol: symbol, tint: tint == .clear ? nil : tint, size: selectedSize
        )
    }

    /// Re-renders after a change and refreshes what is on screen.
    ///
    /// The work is deferred by one run-loop pass and stamped with a token: a
    /// slider-like sequence of taps (a drag across the size segments, several
    /// tints tapped quickly) would otherwise render for each intermediate state
    /// while the user is still choosing, and the last render to finish would not
    /// necessarily be the last one asked for.
    private func invalidate() {
        renderToken += 1
        let token = renderToken
        DispatchQueue.main.async { [weak self] in
            guard let self, token == self.renderToken else { return }
            if let cell = self.previewCell as? PreviewCell {
                cell.show(self.renderCurrent())
            }
            // The size and tint rows draw their selection from the same state.
            self.tableView.reloadSections(
                IndexSet([Section.size.rawValue, Section.tints.rawValue]), with: .none
            )
        }
    }

    @objc private func saveAndClose() {
        if let id = definitionID {
            CustomServiceStore.update(id: id) { self.persist(&$0) }
        } else if case .instance(let id) = storage, !id.isEmpty {
            PrefsStore.updateInstance(id) { self.persist(&$0) }
        }
        navigationController?.popViewController(animated: true)
    }

    private var definitionID: String? {
        if case .definition(let id) = storage { return id }
        return nil
    }

    @objc private func clearIcon() {
        isPhotoSource = false
        photoImage = nil
        selectedSymbol = nil
        if let id = definitionID {
            CustomServiceStore.update(id: id) { object in
                for key in [PrefKey.customIcon, PrefKey.customIconSymbol,
                            PrefKey.customIconTint, PrefKey.customIconSource,
                            PrefKey.customIconSize] {
                    object.removeValue(forKey: key)
                }
            }
        } else if case .instance(let id) = storage, !id.isEmpty {
            PrefsStore.updateInstance(id) { object in
                for key in [PrefKey.customIcon, PrefKey.customIconSymbol,
                            PrefKey.customIconTint, PrefKey.customIconSource,
                            PrefKey.customIconSize] {
                    object.removeValue(forKey: key)
                }
            }
        }
        navigationController?.popViewController(animated: true)
    }

    @objc private func pickPhoto() {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }
}

// MARK: - Table

extension ServiceIconController: UITableViewDataSource, UITableViewDelegate {

    private var showsTints: Bool { !isPhotoSource }

    public func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int)
        -> Int {
        switch Section(rawValue: section) {
        case .size: return 1
        case .gallery: return 1
        case .tints: return showsTints ? 1 : 0
        case .photo: return 3   // preview, choose, and "use the app icon"
        default: return 0
        }
    }

    public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int)
        -> String? {
        switch Section(rawValue: section) {
        case .size: return "Icon Size".localized
        case .gallery: return "Choose a Symbol".localized
        case .tints: return showsTints ? "Color".localized : nil
        case .photo: return nil
        default: return nil
        }
    }

    public func tableView(_ tableView: UITableView, titleForFooterInSection section: Int)
        -> String? {
        switch Section(rawValue: section) {
        case .size:
            return ("The icon is stored at this size and sent as it is. A larger "
                + "icon costs more on every notification.").localized
        case .gallery:
            return ("Your own icon replaces the sending app's icon in the "
                + "notification.").localized
        default:
            return nil
        }
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath)
        -> UITableViewCell {
        switch Section(rawValue: indexPath.section) {
        case .size:
            let cell = tableView.dequeueReusableCell(withIdentifier: "plain", for: indexPath)
            var configuration = UIListContentConfiguration.valueCell()
            configuration.text = "Size".localized
            configuration.secondaryText = selectedSize.label
            cell.contentConfiguration = configuration
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            return cell

        case .gallery:
            let cell = tableView.dequeueReusableCell(withIdentifier: "icon", for: indexPath)
            (cell as? IconCell)?.configure(
                symbols: ServiceIcon.gallery,
                selected: isPhotoSource ? nil : selectedSymbol,
                tint: selectedTint,
                onSelect: { [weak self] symbol in
                    guard let self else { return }
                    self.selectedSymbol = symbol
                    self.isPhotoSource = false
                    self.invalidate()
                }
            )
            cell.selectionStyle = .none
            return cell

        case .tints:
            let cell = tableView.dequeueReusableCell(withIdentifier: "icon", for: indexPath)
            (cell as? IconCell)?.configureTints(
                selected: selectedTint,
                onSelect: { [weak self] index in
                    guard let self else { return }
                    self.selectedTint = index
                    self.invalidate()
                }
            )
            cell.selectionStyle = .none
            return cell

        case .photo:
            if indexPath.row == 0 {
                let cell = tableView.dequeueReusableCell(withIdentifier: "preview", for: indexPath)
                (cell as? PreviewCell)?.show(renderCurrent())
                previewCell = cell
                cell.selectionStyle = .none
                return cell
            }
            let cell = tableView.dequeueReusableCell(withIdentifier: "plain", for: indexPath)
            var configuration = UIListContentConfiguration.cell()
            if indexPath.row == 1 {
                configuration.text = "Choose from Photos".localized
                configuration.image = UIImage(systemName: "photo.on.rectangle")
                cell.accessoryType = .none
            } else {
                configuration.text = "Use the App's Icon".localized
                configuration.image = UIImage(systemName: "app.dashed")
                cell.accessoryType = .none
            }
            cell.contentConfiguration = configuration
            cell.selectionStyle = .default
            return cell

        default:
            return UITableViewCell()
        }
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section) {
        case .size:
            presentSizePicker()
        case .photo:
            if indexPath.row == 1 {
                pickPhoto()
            } else {
                clearIcon()
            }
        default:
            break
        }
    }

    /// The stored size, as an action sheet. Four options fit without a picker
    /// wheel, and naming them in pixels says more than small/medium/large.
    private func presentSizePicker() {
        let sheet = UIAlertController(
            title: "Icon Size".localized, message: nil, preferredStyle: .actionSheet
        )
        for size in ServiceIcon.Size.allCases {
            let action = UIAlertAction(title: size.label, style: .default) { [weak self] _ in
                guard let self else { return }
                self.selectedSize = size
                self.invalidate()
                self.tableView.reloadRows(
                    at: [IndexPath(row: 0, section: Section.size.rawValue)], with: .none
                )
            }
            action.setValue(size == selectedSize, forKey: "checked")
            sheet.addAction(action)
        }
        sheet.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel))
        // An action sheet needs an anchor on iPad; on iPhone this is a no-op.
        sheet.popoverPresentationController?.sourceView = tableView
        present(sheet, animated: true)
    }
}

// MARK: - Photo library

extension ServiceIconController: PHPickerViewControllerDelegate {
    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider,
              provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let image = object as? UIImage else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.photoImage = image
                self.isPhotoSource = true
                // The tint row and the symbol grid no longer describe what is
                // shown, so the page returns to a consistent state.
                self.tableView.reloadData()
                self.invalidate()
            }
        }
    }
}

// MARK: - The symbol grid

/// A horizontally scrolling row of symbols.
///
/// A row rather than a grid: a grid of a hundred symbols needs its own page and
/// its own scrolling, and the picker's job is to be quick. The gallery is
/// ordered by theme, so a symbol is found by where it sits rather than by
/// searching.
private final class IconCell: UITableViewCell {
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var onSelectSymbol: ((String) -> Void)?
    private var onSelectTint: ((Int) -> Void)?
    private var buttons: [UIButton] = []

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scroll)
        stack.axis = .horizontal
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func reset() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        buttons = []
    }

    func configure(
        symbols: [String], selected: String?, tint: Int,
        onSelect: @escaping (String) -> Void
    ) {
        reset()
        onSelectSymbol = onSelect
        let color = ServiceIcon.tints[max(0, min(tint, ServiceIcon.tints.count - 1))].color
        for symbol in symbols {
            let button = UIButton(type: .system)
            let configuration = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
            button.setImage(UIImage(systemName: symbol, withConfiguration: configuration), for: .normal)
            button.tintColor = color == .clear ? .label : color
            button.backgroundColor = symbol == selected ? .tertiarySystemFill : .clear
            button.layer.cornerRadius = 10
            button.widthAnchor.constraint(equalToConstant: 46).isActive = true
            button.heightAnchor.constraint(equalToConstant: 46).isActive = true
            button.accessibilityLabel = symbol
            button.addAction(UIAction { [weak self] _ in
                self?.onSelectSymbol?(symbol)
            }, for: .touchUpInside)
            stack.addArrangedSubview(button)
            buttons.append(button)
        }
    }

    func configureTints(selected: Int, onSelect: @escaping (Int) -> Void) {
        reset()
        onSelectTint = onSelect
        for (index, tint) in ServiceIcon.tints.enumerated() {
            let button = UIButton(type: .system)
            button.backgroundColor = tint.color == .clear ? .secondarySystemFill : tint.color
            button.layer.cornerRadius = 17
            button.widthAnchor.constraint(equalToConstant: 34).isActive = true
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
            button.layer.borderWidth = index == selected ? 3 : 0
            button.layer.borderColor = UIColor.label.cgColor
            button.accessibilityLabel = tint.name
            if tint.color == .clear {
                button.setImage(UIImage(systemName: "circle.slash"), for: .normal)
                button.tintColor = .secondaryLabel
            }
            button.addAction(UIAction { [weak self] _ in
                self?.onSelectTint?(index)
            }, for: .touchUpInside)
            stack.addArrangedSubview(button)
            buttons.append(button)
        }
    }
}

/// The rendered result, so the page shows the real icon rather than describing
/// it.
private final class PreviewCell: UITableViewCell {
    /// Named `preview` rather than `imageView`: `UITableViewCell` already has one.
    private let preview = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        preview.contentMode = .scaleAspectFit
        preview.layer.cornerRadius = 12
        preview.clipsToBounds = true
        preview.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            preview.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            preview.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            preview.widthAnchor.constraint(equalToConstant: 72),
            preview.heightAnchor.constraint(equalToConstant: 72),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ image: UIImage?) {
        preview.image = image
        if image == nil {
            preview.image = UIImage(systemName: "questionmark")
            preview.tintColor = .tertiaryLabel
        }
    }
}
