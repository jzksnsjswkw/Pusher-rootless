import UIKit

/// A service's own logo: the picture that identifies it.
///
/// Two services of the same type are otherwise indistinguishable — two rows
/// reading "Bark" with the same red logo — and a service the user wrote has no
/// artwork at all. A logo says which destination a row is, and it is the same
/// picture everywhere the service appears: in the list, on its settings page,
/// and (where the payload has a field for it) in the notification itself.
///
/// It also fixes a second problem for notifications: a service often reaches an
/// *account* rather than an app — a bot, a channel, a webhook — so the sending
/// app's icon is the wrong picture twice over, being the app that happened to
/// raise the notification rather than where the notification is going.
///
/// ## What is stored
///
/// Always the rasterized, compressed result, as base64 PNG — one value, already
/// the size it will be sent at, so nothing has to be re-rendered per
/// notification. The recipe that produced it (which symbol and tint, or that it
/// came from the photo library) is stored beside it only so the picker can show
/// what is selected; the base64 is what the payload uses.
///
/// ## Where it is stored
///
/// On the *type* when the type has a page of its own (a script definition), and
/// on the instance otherwise — because that is where the picker lives. An
/// instance always wins over its definition, so a script's instances can
/// override the icon the script declares.
public enum ServiceIcon {

    /// The sizes a service icon may be stored at.
    ///
    /// A notification icon is drawn small — 58 points is what IFTTT documents —
    /// so 512 is already generous for a source image; the point of the ladder is
    /// to let a user trade fidelity for payload size, which matters because the
    /// icon travels base64-in-JSON on every single notification.
    public enum Size: Int, CaseIterable {
        case small = 58
        case medium = 128
        case large = 256
        case extraLarge = 512

        /// The default: comfortably above the drawn size without being heavy.
        public static let standard: Size = .medium

        public var label: String {
            "\(rawValue) × \(rawValue)"
        }
    }

    /// The built-in gallery, as SF Symbols.
    ///
    /// Symbols rather than bundled bitmaps: they render crisply at whatever size
    /// is chosen, cost nothing in the package, and stay right in both light and
    /// dark appearances. The names are grouped only to keep the picker's grid
    /// readable.
    public static let gallery: [String] = [
        // Notification and messaging
        "bell.fill", "bell.badge.fill", "envelope.fill", "envelope.open.fill",
        "paperplane.fill", "message.fill", "bubble.left.and.bubble.right.fill",
        "phone.fill", "video.fill", "megaphone.fill", "dot.radiowaves.left.and.right",
        // Status
        "checkmark.circle.fill", "exclamationmark.triangle.fill", "exclamationmark.octagon.fill",
        "info.circle.fill", "questionmark.circle.fill", "xmark.circle.fill",
        "heart.fill", "star.fill", "bolt.fill", "flame.fill", "snowflake",
        // Devices and infrastructure
        "server.rack", "cloud.fill", "antenna.radiowaves.left.and.right", "wifi",
        "desktopcomputer", "laptopcomputer", "iphone", "applewatch", "cpu",
        "terminal.fill", "gearshape.fill", "wrench.and.screwdriver.fill", "hammer.fill",
        // Security
        "shield.fill", "shield.lefthalf.filled", "lock.fill", "key.fill",
        "fingerprint", "eye.fill", "touchid",
        // People and places
        "person.fill", "person.2.fill", "house.fill", "building.2.fill", "storefront.fill",
        // Money and commerce
        "cart.fill", "creditcard.fill", "banknote.fill", "dollarsign.circle.fill",
        "tag.fill", "gift.fill", "receipt.fill", "chart.line.uptrend.xyaxis",
        // Documents and media
        "doc.fill", "folder.fill", "newspaper.fill", "book.fill", "graduationcap.fill",
        "briefcase.fill", "camera.fill", "photo.fill", "mic.fill", "headphones",
        "music.note", "play.rectangle.fill", "gamecontroller.fill",
        // Travel
        "map.fill", "location.fill", "car.fill", "airplane", "tram.fill", "bicycle",
        "figure.walk", "fuelpump.fill",
        // Misc and decorative
        "pawprint.fill", "leaf.fill", "drop.fill", "sun.max.fill", "moon.fill",
        "sparkles", "wand.and.stars", "crown.fill", "trophy.fill", "medal.fill",
        "seal.fill", "circle.hexagongrid.fill", "square.grid.2x2.fill", "diamond.fill",
        "hexagon.fill", "suit.heart.fill", "suit.club.fill", "suit.spade.fill",
        "suit.diamond.fill", "puzzlepiece.fill", "cube.fill", "shippingbox.fill",
        "calendar", "clock.fill", "alarm.fill", "hourglass", "timer",
        "battery.100", "power", "lightbulb.fill", "wand.and.rays", "theatermasks.fill",
    ]

    /// The tints the gallery may be drawn in.
    ///
    /// A fixed set rather than a color picker: an icon is a small shape at a
    /// small size, so it has to be one of a few saturated colors to read at all,
    /// and letting a user pick any color mostly produces muddy ones.
    public static let tints: [(name: String, color: UIColor)] = [
        ("Default", .clear),          // the symbol's own multicolor/template rendering
        ("Red", .systemRed),
        ("Orange", .systemOrange),
        ("Yellow", .systemYellow),
        ("Green", .systemGreen),
        ("Mint", .systemMint),
        ("Teal", .systemTeal),
        ("Blue", .systemBlue),
        ("Indigo", .systemIndigo),
        ("Purple", .systemPurple),
        ("Pink", .systemPink),
        ("Brown", .systemBrown),
        ("Gray", .systemGray),
    ]

    // MARK: - Stored form

    /// The logo of one instance, or `nil` when it has none.
    ///
    /// A definition's logo is the fallback, so a script's instances show the
    /// logo the script declares until one of them chooses its own.
    public static func logo(forInstanceID id: String) -> UIImage? {
        let stored = PrefsStore.instance(id)
        if let own = image(from: stored) { return own }
        guard let type = stored.nonEmptyString(PrefKey.instanceType),
              let definition = CustomServiceStore.definition(id: type)
        else { return nil }
        return image(from: CustomServiceStore.rawEntry(id: definition.id))
    }

    /// The logo of one definition, or `nil` when it has none.
    public static func logo(forDefinitionID id: String) -> UIImage? {
        image(from: CustomServiceStore.rawEntry(id: id))
    }

    /// The icon of one instance or definition, or `nil` when it has none and the
    /// notification's own app icon should be used.
    public static func image(from prefs: Prefs) -> UIImage? {
        guard let base64 = prefs.string(PrefKey.customIcon), !base64.isEmpty else {
            return nil
        }
        return image(fromBase64: base64)
    }

    /// Whether the icon is the one picked for this service rather than the app's.
    public static func isCustomized(_ prefs: Prefs) -> Bool {
        !(prefs.string(PrefKey.customIcon) ?? "").isEmpty
    }

    /// Decodes a stored icon.
    ///
    /// The base64 may be a PNG data URL as well as bare base64, because the
    /// value can arrive from the photo picker's own copy path.
    public static func image(fromBase64 base64: String) -> UIImage? {
        var text = base64
        if let comma = text.range(of: ","), text.hasPrefix("data:") {
            text = String(text[comma.upperBound...])
        }
        // `.ignoreUnknownCharacters` because a base64 string may be wrapped
        // (the stored form is, to keep the preference readable).
        guard let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters)
        else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Rendering

    /// Draws a gallery symbol at `size`, optionally tinted.
    ///
    /// A symbol is rendered inside a rounded square of its tint when a tint is
    /// chosen, and as a plain glyph otherwise — the two shapes a notification
    /// icon takes in practice, and picking between them is the difference
    /// between a glyph that disappears against a light background and one that
    /// reads.
    public static func render(
        symbol: String,
        tint: UIColor?,
        size: Size
    ) -> UIImage? {
        let side = CGFloat(size.rawValue)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1     // the point size *is* the pixel size
        format.opaque = tint != nil

        let configuration = UIImage.SymbolConfiguration(
            pointSize: side * (tint == nil ? 0.92 : 0.52), weight: .medium
        )
        guard let glyph = UIImage(systemName: symbol, withConfiguration: configuration) else {
            return nil
        }

        return UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side), format: format
        ).image { context in
            if let tint {
                tint.setFill()
                context.fill(CGRect(x: 0, y: 0, width: side, height: side))
                // A white glyph on a colored field: the pairing that stays legible
                // whatever the color and whatever the wallpaper behind it.
                let rendered = glyph.withTintColor(.white, renderingMode: .alwaysOriginal)
                let origin = CGPoint(
                    x: (side - rendered.size.width) / 2,
                    y: (side - rendered.size.height) / 2
                )
                rendered.draw(at: origin)
            } else {
                let rendered = glyph.withTintColor(.label, renderingMode: .alwaysOriginal)
                let origin = CGPoint(
                    x: (side - rendered.size.width) / 2,
                    y: (side - rendered.size.height) / 2
                )
                rendered.draw(at: origin)
            }
        }
    }

    /// Scales an arbitrary image into a square icon of `size`.
    ///
    /// Fitted rather than cropped, and centred on transparency: a user's picture
    /// has its own aspect ratio and its own subject position, and cropping to a
    /// square would cut off whichever one the picture was composed around.
    public static func normalize(_ image: UIImage, to size: Size) -> UIImage? {
        let side = CGFloat(size.rawValue)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false

        let scale = min(side / image.size.width, side / image.size.height)
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        return UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side), format: format
        ).image { _ in
            image.draw(in: CGRect(
                x: (side - drawn.width) / 2, y: (side - drawn.height) / 2,
                width: drawn.width, height: drawn.height
            ))
        }
    }

    /// The value stored for an icon: bare base64 PNG, wrapped for legibility.
    ///
    /// Wrapped at 76 columns, the width the base64 line length was chosen for
    /// decades ago; a preference file a person may open is worth keeping
    /// readable, and the newlines cost nothing at decode time.
    public static func storedValue(_ image: UIImage) -> String {
        image.pngData()?.base64EncodedString(options: .lineLength76Characters) ?? ""
    }
}
