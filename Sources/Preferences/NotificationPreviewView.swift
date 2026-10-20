import UIKit

/// A notification banner, drawn to look like the one the phone shows.
///
/// The three parts a rule can match — title, subtitle, message — are positions on
/// the screen, and "match the message" is a question about the third line. A list
/// of words does not say that; a picture of the thing does.
///
/// Modelled on the system's banner: a card at 19pt continuous corners, a 38pt icon
/// inset 10pt at the left, a semibold 15pt title, a 15pt body under it, and the
/// time at the right. Drawn on a material blur so it reads as something floating
/// over the page rather than as another row of the list.
final class NotificationBannerView: UIView {

    private enum Metrics {
        static let height: CGFloat = 78
        static let cornerRadius: CGFloat = 19
        static let iconSize: CGFloat = 38
        static let iconInset: CGFloat = 10
        static let textLeft: CGFloat = 58
        static let textTop: CGFloat = 11
        static let timeWidth: CGFloat = 44
        static let timeInset: CGFloat = 14
    }

    private let card = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let timeLabel = UILabel()
    private let iconView = UIImageView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear

        card.layer.cornerRadius = Metrics.cornerRadius
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        // The system's own material, which is what a banner is drawn on. A
        // `UIVisualEffectView` would work too, but this is the class SpringBoard
        // uses, so the preview matches whatever this iOS version draws.
        if let materialClass = NSClassFromString("MTMaterialView"),
           let blur = Self.materialView(of: materialClass) {
            blur.frame = card.bounds
            blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            card.addSubview(blur)
        } else {
            // Fallback: a plain surface, so the picture still reads on a system
            // without the material class.
            let surface = UIView()
            surface.backgroundColor = .secondarySystemBackground
            surface.frame = card.bounds
            surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            card.addSubview(surface)
        }

        // A wash over the material. On its own the blur is almost invisible over a
        // white page, and a banner that looks like a gap is worse than no picture.
        let wash = UIView()
        wash.backgroundColor = UIColor.separator.withAlphaComponent(0.12)
        wash.frame = card.bounds
        wash.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        card.addSubview(wash)

        iconView.contentMode = .scaleAspectFit
        iconView.image = Self.appIcon()
        iconView.layer.cornerRadius = 8
        iconView.layer.cornerCurve = .continuous
        iconView.clipsToBounds = true
        iconView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.numberOfLines = 1
        titleLabel.textColor = .label
        titleLabel.text = "Notification title".localized

        subtitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        subtitleLabel.numberOfLines = 1
        subtitleLabel.textColor = .label
        subtitleLabel.text = "Notification subtitle".localized

        bodyLabel.font = .systemFont(ofSize: 15, weight: .regular)
        bodyLabel.numberOfLines = 2
        bodyLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.textColor = .label
        bodyLabel.text = "Notification body".localized

        timeLabel.font = .systemFont(ofSize: 13)
        timeLabel.textColor = UIColor.label.withAlphaComponent(0.5)
        timeLabel.textAlignment = .right
        timeLabel.text = "now".localized
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let text = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, bodyLabel])
        text.axis = .vertical
        text.spacing = 0
        text.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(text)

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(timeLabel)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.heightAnchor.constraint(equalToConstant: Metrics.height),

            iconView.leadingAnchor.constraint(equalTo: card.leadingAnchor,
                                              constant: Metrics.iconInset),
            iconView.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Metrics.iconSize),

            timeLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor,
                                                constant: -Metrics.timeInset),
            timeLabel.topAnchor.constraint(equalTo: card.topAnchor,
                                          constant: Metrics.textTop),
            timeLabel.widthAnchor.constraint(equalToConstant: Metrics.timeWidth),

            text.leadingAnchor.constraint(equalTo: card.leadingAnchor,
                                          constant: Metrics.textLeft),
            text.topAnchor.constraint(equalTo: card.topAnchor,
                                       constant: Metrics.textTop),
            text.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `+[MTMaterialView materialViewWithRecipe:configuration:]`, called through the
    /// runtime because neither the class nor the selector is in a public header.
    private static func materialView(of cls: AnyClass) -> UIView? {
        typealias Make = @convention(c) (
            AnyClass, Selector, Int, Int
        ) -> Unmanaged<AnyObject>?
        let selector = NSSelectorFromString("materialViewWithRecipe:configuration:")
        guard let method = class_getClassMethod(cls, selector) else { return nil }
        let make = unsafeBitCast(method_getImplementation(method), to: Make.self)
        return make(cls, selector, 1, 0)?.takeUnretainedValue() as? UIView
    }

    /// An app icon for the picture. The system's own Settings icon, so the banner
    /// looks like a notification from an app rather than a diagram — and it is
    /// recognisable at 38pt, which Pusher's wordmark is not.
    private static func appIcon() -> UIImage? {
        let settings = UIImage(systemName: "gearshape.fill")?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        let size = CGSize(width: 38, height: 38)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.systemGray.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            settings?.draw(in: CGRect(x: 6, y: 6, width: 26, height: 26))
        }
    }
}

/// The section footer that carries the banner.
///
/// A footer rather than a row: the picture is not something to tap, and a row would
/// have to be made un-tappable — which is what closing the page was. A footer
/// cannot be tapped in the first place.
final class NotificationPreviewFooter: UITableViewHeaderFooterView {

    static let reuseIdentifier = "NotificationPreviewFooter"

    private var banner: NotificationBannerView?

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        backgroundView = UIView()
        backgroundView?.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure() {
        guard banner == nil else { return }

        let banner = NotificationBannerView()
        let caption = UILabel()
        caption.text = "The three parts a rule can match".localized
        caption.font = .systemFont(ofSize: 13)
        caption.textColor = .secondaryLabel
        caption.textAlignment = .center
        caption.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [banner, caption])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
        self.banner = banner
    }
}

/// The row that carries the banner.
///
/// A `PSTableCell` subclass reached through the specifier's `cellClass`, which
/// `PSListController` ignores — so `ListController.cellForRowAt` is what swaps it
/// in. `.staticTextCell` is the row type: it is not a link, so it has no chevron
/// and cannot be tapped, and nothing has to be guarded against a stray tap closing
/// the page.
@objc(NSPushNotificationPreviewCell)
final class NotificationPreviewCell: PSTableCell {
    private var banner: NotificationBannerView?
    private var caption: UILabel?

    override func refreshCellContents(with specifier: PSSpecifier) {
        super.refreshCellContents(with: specifier)
        cellEnabled = true
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        // The framework draws a title label for a static text cell; the picture
        // replaces it.
        titleLabel?.text = nil

        guard banner == nil else { return }

        // The banner is the whole row. No caption: the three lines are already
        // labelled in the picture, and a sentence under it said what the picture
        // says.
        let banner = NotificationBannerView()
        contentView.addSubview(banner)

        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            banner.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            banner.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
        ])
        self.banner = banner
    }
}
