import UIKit

/// Recolors an image by blending every pixel toward a target color.
///
/// Used to redraw the icon assets in the active tint: the PNGs ship in Pusher's
/// green, and each service page recolors them to match the color extracted from
/// that service's own icon.
public extension UIImage {
    /// Returns a copy of the image with `sourceColor` replaced by `targetColor`.
    ///
    /// Pixels far from `sourceColor` are left alone; pixels near it are blended
    /// proportionally, which keeps antialiased edges smooth instead of leaving a
    /// green halo. Returns the receiver unchanged when either color cannot be
    /// expressed in RGB (a grayscale or pattern color).
    func replacingColor(_ sourceColor: UIColor, with targetColor: UIColor) -> UIImage {
        var sourceRed: CGFloat = 0, sourceGreen: CGFloat = 0, sourceBlue: CGFloat = 0, sourceAlpha: CGFloat = 0
        // `getRed:green:blue:alpha:` reports failure for non-RGB color spaces,
        // unlike CGColorGetComponents, which would read out of bounds.
        guard sourceColor.getRed(&sourceRed, green: &sourceGreen, blue: &sourceBlue, alpha: &sourceAlpha) else {
            return self
        }
        var targetRed: CGFloat = 0, targetGreen: CGFloat = 0, targetBlue: CGFloat = 0, targetAlpha: CGFloat = 0
        guard targetColor.getRed(&targetRed, green: &targetGreen, blue: &targetBlue, alpha: &targetAlpha) else {
            return self
        }

        let source = (
            UInt8((sourceRed * 255).rounded()),
            UInt8((sourceGreen * 255).rounded()),
            UInt8((sourceBlue * 255).rounded())
        )
        let target = (
            UInt8((targetRed * 255).rounded()),
            UInt8((targetGreen * 255).rounded()),
            UInt8((targetBlue * 255).rounded())
        )

        guard let cgImage = cgImage else { return self }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return self }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return self }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // The distance above which a pixel counts as "not the source color" and
        // is left entirely alone.
        let fullReplaceThreshold = 0.1

        for offset in stride(from: 0, to: bytesPerRow * height, by: 4) {
            let red = pixels[offset]
            let green = pixels[offset + 1]
            let blue = pixels[offset + 2]

            // How far this pixel is from the source color, normalised across the
            // three channels.
            let distance = (
                abs(Int(red) - Int(source.0))
                    + abs(Int(green) - Int(source.1))
                    + abs(Int(blue) - Int(source.2))
            )
            var ratio = CGFloat(distance) / (255 * 3)
            if ratio > fullReplaceThreshold { ratio = 1 }
            if ratio < 0 { ratio = 0 }

            // Blend: close pixels become the target, distant ones stay put.
            pixels[offset] = blend(channel: red, ratio: ratio, target: target.0)
            pixels[offset + 1] = blend(channel: green, ratio: ratio, target: target.1)
            pixels[offset + 2] = blend(channel: blue, ratio: ratio, target: target.2)
        }

        guard let recolored = context.makeImage() else { return self }
        return UIImage(cgImage: recolored, scale: UIScreen.main.scale, orientation: .up)
    }

    private func blend(channel: UInt8, ratio: CGFloat, target: UInt8) -> UInt8 {
        let mixed = ratio * CGFloat(channel) + (1 - ratio) * CGFloat(target)
        return UInt8(min(max(mixed.rounded(), 0), 255))
    }
}

/// Loads an image from the Pusher bundle, falling back to a default.
public extension UIImage {
    /// A named image from the tweak's own bundle.
    ///
    /// `UIImage(named:)` searches the main bundle, which is Preferences.app, so
    /// the bundle has to be passed explicitly.
    static func pusher(named name: String) -> UIImage? {
        UIImage(named: name, in: .pusher, compatibleWith: nil)
    }

    /// A service's icon: `<kind>Service_<name>`, falling back to a shared
    /// default so a service without its own artwork still shows an icon.
    static func serviceIcon(named name: String, isCustom: Bool) -> UIImage? {
        let prefix = isCustom ? "CustomService_" : "BuiltInService_"
        return pusher(named: prefix + name) ?? pusher(named: "DefaultService")
    }
}
