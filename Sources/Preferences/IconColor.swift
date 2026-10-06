import UIKit

/// Extracts a representative, usable color from a service's icon.
///
/// Each service page tints itself with a color taken from its own artwork. The
/// raw pixel data cannot be used directly: the most common color in an app icon
/// is usually near-white or near-black (backgrounds and outlines), which make
/// for an unreadable tint. The algorithm below quantizes with a 3D histogram and
/// picks the most populated bucket that is not too close to white or black.
enum IconColor {

    /// A color extracted from `image`, or `nil` when the image is empty or every
    /// populated bucket was rejected.
    static func dominantColor(in image: UIImage) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }

        // Downscale first: a 180×180 icon has plenty of color information, and
        // this keeps the histogram loop trivial.
        let dimension = 180
        let bytesPerRow = dimension * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * dimension)
        guard let context = CGContext(
            data: &pixels,
            width: dimension,
            height: dimension,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))

        // Quantize to 4 bits per channel. The key packs the three reduced
        // channels into one integer, which makes the histogram a plain
        // dictionary rather than a 4096-element array.
        var histogram: [Int: (count: Int, red: Int, green: Int, blue: Int)] = [:]
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = pixels[offset + 3]
            // Fully transparent pixels carry no color; including them would let
            // a transparent background dominate the histogram.
            guard alpha > 200 else { continue }

            let red = Int(pixels[offset]) >> 4
            let green = Int(pixels[offset + 1]) >> 4
            let blue = Int(pixels[offset + 2]) >> 4
            let key = (red << 8) | (green << 4) | blue

            var entry = histogram[key] ?? (0, 0, 0, 0)
            entry.count += 1
            entry.red += Int(pixels[offset])
            entry.green += Int(pixels[offset + 1])
            entry.blue += Int(pixels[offset + 2])
            histogram[key] = entry
        }

        // Walk the buckets from most to least populated and take the first
        // usable one.
        for entry in histogram.values.sorted(by: { $0.count > $1.count }) {
            let red = CGFloat(entry.red / entry.count) / 255
            let green = CGFloat(entry.green / entry.count) / 255
            let blue = CGFloat(entry.blue / entry.count) / 255
            let color = UIColor(red: red, green: green, blue: blue, alpha: 1)
            if isUsable(color) { return color }
        }
        return nil
    }

    /// Whether a color is far enough from white and black to be readable.
    ///
    /// A tint that is nearly white disappears against the white Settings
    /// background, and one that is nearly black cannot be distinguished from
    /// ordinary label text.
    private static func isUsable(_ color: UIColor) -> Bool {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return false }

        let brightness = (red * 299 + green * 587 + blue * 114) / 1000
        return brightness > 0.15 && brightness < 0.85
    }
}
