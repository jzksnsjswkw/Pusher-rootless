import UIKit

/// A service's own logo: the picture that identifies it inside Pusher.
///
/// Two services of the same type are otherwise indistinguishable — two rows
/// reading "Bark" with the same red logo — and a service the user wrote has no
/// artwork at all. A logo says which destination a row is, and it is the same
/// picture everywhere the service appears: in the service list, on its settings
/// page, and in the type list when adding one.
///
/// It is Pusher's own artwork and has nothing to do with the app that raised the
/// notification: the icon a notification carries is its sender's business, and
/// this is not that. Where a payload has an `icon` field, what goes in it is
/// described under ``image(from:)``.
///
/// ## What is stored
///
/// Always the rasterized, compressed result, as base64 PNG — one value, already
/// the size it will be drawn at, so nothing has to be re-rendered per
/// notification. The recipe that produced it (which symbol and tint, or that it
/// came from the photo library) is stored beside it only so the picker can show
/// what is selected.
///
/// ## Where it is stored
///
/// On the *type* when the type has a page of its own (a script definition), and
/// on the instance otherwise — because that is where the picker lives. An
/// instance always wins over its definition, so a script's instances can
/// override the icon the script declares.
public enum ServiceIcon {

    /// The one size an icon is stored at, in **points**.
    ///
    /// 29 points: exactly what the service list and the page titles draw, and
    /// what the bundled artwork is (`BuiltInService_*@3x.png` is 87 px at 3×).
    /// Matching it in points as well as in shape is what makes a chosen logo and
    /// a bundled one the same object on the page — a differently-sized image
    /// sits at a different size in the row, because a table cell sizes its
    /// image view from the image.
    ///
    /// The bitmap is therefore rendered at the screen's own scale, giving 87 px
    /// on a 3× device. That is also ample for the payload's `icon` field, which
    /// a receiver draws small.
    public static let pointSize: CGFloat = 29

    /// The pixel width a stored icon has on this device.
    public static var pixelSize: Int {
        Int((pointSize * UIScreen.main.scale).rounded())
    }

    /// Kept as a type so call sites read the same as they did when the size was
    /// selectable; there is only one now.
    public enum Size {
        case standard
        public var pointSize: CGFloat { ServiceIcon.pointSize }
        public var label: String {
            "\(Int(ServiceIcon.pointSize)) pt"
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

    /// The icon redrawn at the size the app draws icons at.
    ///
    /// A display site must not depend on a bitmap's intrinsic size — a table
    /// cell sizes its image view from the image, so an icon stored at any other
    /// size would draw at that size and push the row's text out of line. An
    /// icon stored before the size was settled is exactly that case, and this
    /// heals it on the way out rather than asking the user to pick the icon
    /// again. It costs one draw on a read that already decoded a PNG, and
    /// returns the image untouched when it is already the right size.
    ///
    /// The redraw goes through ``normalize(_:to:)``, whose clip is the shape the
    /// image already carries, so a conformed icon is identical to one stored at
    /// the right size.
    public static func conformed(_ image: UIImage) -> UIImage {
        guard abs(image.size.width - pointSize) > 0.01
            || abs(image.size.height - pointSize) > 0.01
        else { return image }
        return normalize(image, to: .standard) ?? image
    }

    /// The logo of one instance, or `nil` when it has none.
    ///
    /// A definition's logo is the fallback, so a script's instances show the
    /// logo the script declares until one of them chooses its own.
    public static func logo(forInstanceID id: String) -> UIImage? {
        let stored = PrefsStore.instance(id)
        if let own = image(from: stored) { return conformed(own) }
        guard let type = stored.nonEmptyString(PrefKey.instanceType),
              let definition = CustomServiceStore.definition(id: type)
        else { return nil }
        return logo(forDefinitionID: definition.id)
    }

    /// The logo of one definition, or `nil` when it has none.
    ///
    /// Conformed, so a definition's logo draws at the same size on its row, in
    /// the add-service list and beside its name as an instance's logo does.
    public static func logo(forDefinitionID id: String) -> UIImage? {
        image(from: CustomServiceStore.rawEntry(id: id)).map(conformed)
    }

    /// The logo of one instance or definition, or `nil` when it has none — in
    /// which case a payload's `icon` field falls back to the attachment's image
    /// or is left out, and the display sites fall back to the bundled artwork.
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

    // MARK: - The tile shape

    /// The squircle an app icon is drawn in, at `side` points across.
    ///
    /// A superellipse rather than `UIBezierPath(roundedRect:cornerRadius:)`: a
    /// circular corner is a visibly different shape from the one every icon on
    /// the system uses, and next to a built-in logo (Bark's, WeChat's) a plain
    /// rounded rectangle reads as the odd one out. The exponent is the one
    /// Apple's icons approximate, and the corner radius falls out of it — there
    /// is no separate radius to pick.
    static func tilePath(side: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        let half = side / 2
        let exponent: CGFloat = 5
        let steps = 180
        for step in 0...steps {
            let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
            let cosAngle = cos(angle)
            let sinAngle = sin(angle)
            let x = half * copysign(pow(abs(cosAngle), 2 / exponent), cosAngle)
            let y = half * copysign(pow(abs(sinAngle), 2 / exponent), sinAngle)
            let point = CGPoint(x: half + x, y: half + y)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.close()
        return path
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
        let side = size.pointSize
        let format = UIGraphicsImageRendererFormat.default()
        // The screen's scale, not 1: the image must be 29 *points* at 3× so a
        // table cell draws it at the size the bundled artwork is drawn.
        format.scale = UIScreen.main.scale
        format.opaque = tint != nil

        let configuration = UIImage.SymbolConfiguration(
            pointSize: side * (tint == nil ? 0.92 : 0.52), weight: .medium
        )
        guard let glyph = UIImage(systemName: symbol, withConfiguration: configuration) else {
            return nil
        }

        return UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side), format: format
        ).image { _ in
            let tile = tilePath(side: side)
            // Everything is drawn inside the tile, so the shape is the same
            // whether the field is filled or only the glyph shows.
            tile.addClip()
            if let tint {
                tint.setFill()
                tile.fill()
                // A white glyph on a colored field: the pairing that stays legible
                // whatever the color and whatever the wallpaper behind it.
                let rendered = glyph.withTintColor(.white, renderingMode: .alwaysOriginal)
                rendered.draw(at: CGPoint(
                    x: (side - rendered.size.width) / 2,
                    y: (side - rendered.size.height) / 2
                ))
            } else {
                let rendered = glyph.withTintColor(.label, renderingMode: .alwaysOriginal)
                rendered.draw(at: CGPoint(
                    x: (side - rendered.size.width) / 2,
                    y: (side - rendered.size.height) / 2
                ))
            }
        }
    }

    /// Scales an arbitrary image into an icon tile of `size`.
    ///
    /// Filled rather than fitted: the result has to sit beside the built-in
    /// logos as the same kind of object — a square tile — and a fitted picture
    /// would be a small photo floating in a square with transparent margins,
    /// which is a different shape from every other icon on the page. The
    /// overflow is cropped from the centre, which for a picture chosen as an
    /// identifier (a logo, a face, a mark) is where its subject is.
    public static func normalize(_ image: UIImage, to size: Size) -> UIImage? {
        let side = size.pointSize
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = UIScreen.main.scale
        format.opaque = false

        let scale = max(side / image.size.width, side / image.size.height)
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        return UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side), format: format
        ).image { _ in
            let tile = tilePath(side: side)
            tile.addClip()
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
