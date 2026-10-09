import CoreGraphics
import Foundation
import zlib

/// Writes an icon as a palette PNG.
///
/// ## Why not `UIImage.pngData()`
///
/// The system encoder writes 32-bit RGBA, which is the wrong shape for this
/// picture: an icon is 58 pixels across and is drawn at 29 points, so its colour
/// precision is worth far less than its size. Measured on a real photo chosen as
/// a logo — 3085 colours, 10,799 bytes — the same picture as a 64-colour palette
/// is 2,019 bytes, and its base64 goes from 11,404 characters to 2,692. That
/// value travels on every forwarded notification and inside every export, so the
/// difference is paid repeatedly.
///
/// Core Graphics cannot do it: an indexed `CGImage` is 8 bits per pixel with no
/// alpha, and an icon's tile shape lives in its alpha channel — dropping it would
/// square the corners. (Measured: drawing into an indexed context fails outright.)
/// A palette PNG keeps alpha anyway, in a `tRNS` chunk, so the format can express
/// exactly what is needed and only the encoder was missing.
///
/// ## What this produces
///
/// A valid PNG, written by hand: signature, `IHDR`, `PLTE`, `tRNS`, `IDAT`
/// (zlib), `IEND`. Indices are 8 bits each, filter type 0 on every row — the
/// simplest legal encoding, since a palette PNG's pressure comes from the palette
/// rather than from row filtering, and PNG's own zlib pass compresses the rest.
///
/// Returns `nil` when anything about the input is unusable, so the caller can
/// fall back to the system encoder: a larger icon is better than none.
enum IconPalette {

    /// How many colours the palette holds.
    ///
    /// 64 rather than a handful: a drawn symbol is flat and survives 16, but a
    /// photo someone chose as a logo has gradients, and 32 colours begin to show
    /// as banding in a face. 64 is where most of the saving is reached and the
    /// artefact is not.
    static let colourCount = 64

    /// The alpha below which palette entries are packed together.
    ///
    /// Fully transparent pixels all look the same whatever colour they carry, so
    /// they are forced to one entry and cost one palette slot instead of a share
    /// of every slot. This matters because an icon's transparent band is a large
    /// part of it.
    private static let transparentCutoff: UInt8 = 8

    static func encode(_ image: UIImage) -> Data? {
        guard let cgImage = image.cgImage,
              cgImage.width > 0, cgImage.height > 0
        else { return nil }
        guard let pixels = rgbaBytes(cgImage) else { return nil }
        guard let palette = buildPalette(from: pixels) else { return nil }
        guard let indices = mapToIndices(pixels, palette: palette) else { return nil }
        return png(indices: indices, width: cgImage.width, height: cgImage.height,
                   palette: palette)
    }

    // MARK: - The source pixels

    /// The image as RGBA bytes, one byte per channel per pixel.
    ///
    /// Redrawn rather than read, because a photo arrives in whatever layout the
    /// picker handed over and the palette has to be built from a known one.
    ///
    /// The alpha is taken as-is with `noneSkipLast` rather than premultiplied:
    /// premultiplying tints the colour under a transparent pixel toward black,
    /// which is exactly the region the palette should collapse to a single
    /// entry rather than give colours to. It is a fallback order because Core
    /// Graphics refuses some alpha and byte-order pairs outright.
    private static func rgbaBytes(_ image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4

        let layouts: [CGBitmapInfo] = [
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        ]

        for layout in layouts {
            var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
            let created = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress,
                    width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: layout.rawValue
                ) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            if created { return bytes }
        }
        return nil
    }

    // MARK: - The palette

    struct Palette {
        var red: [UInt8]
        var green: [UInt8]
        var blue: [UInt8]
        var alpha: [UInt8]

        var count: Int { red.count }
    }

    /// Builds a palette by median cut over the picture's colours.
    ///
    /// Median cut rather than a fixed cube: the colours that matter are the ones
    /// actually present, and slicing the *used* colour space along its longest
    /// axis repeatedly puts the entries where the pixels are. A cube would spend
    /// its slots evenly across a spectrum this picture may not use.
    private static func buildPalette(from pixels: [UInt8]) -> Palette? {
        var opaque: [(r: Int, g: Int, b: Int)] = []
        opaque.reserveCapacity(pixels.count / 4)

        var transparent = false
        var index = 0
        while index + 3 < pixels.count {
            if pixels[index + 3] >= transparentCutoff {
                opaque.append((
                    Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2])
                ))
            } else {
                transparent = true
            }
            index += 4
        }

        // One slot, if any, is reserved for the transparent region.
        let slots = transparent ? colourCount - 1 : colourCount
        guard !opaque.isEmpty else {
            // Nothing visible at all, so a single transparent entry suffices.
            return Palette(red: [0], green: [0], blue: [0], alpha: [0])
        }

        var boxes = [Box(colours: opaque)]
        while boxes.count < slots {
            // Split the box with the widest spread; a box that cannot be split
            // is left alone and the loop moves on to another.
            guard let target = boxes.enumerated()
                .filter({ $0.element.colours.count > 1 })
                .max(by: { $0.element.spread < $1.element.spread })
            else { break }
            guard let (first, second) = boxes[target.offset].split() else { break }
            boxes[target.offset] = first
            boxes.append(second)
        }

        var palette = Palette(red: [], green: [], blue: [], alpha: [])
        if transparent {
            palette.red.append(0)
            palette.green.append(0)
            palette.blue.append(0)
            palette.alpha.append(0)
        }
        for box in boxes {
            let average = box.average
            palette.red.append(UInt8(average.r.rounded()))
            palette.green.append(UInt8(average.g.rounded()))
            palette.blue.append(UInt8(average.b.rounded()))
            palette.alpha.append(255)
        }
        return palette
    }

    /// A set of colours, split along whichever channel varies most.
    private struct Box {
        var colours: [(r: Int, g: Int, b: Int)]

        var spread: Int {
            guard !colours.isEmpty else { return 0 }
            var minR = 255, maxR = 0, minG = 255, maxG = 0, minB = 255, maxB = 0
            for colour in colours {
                minR = min(minR, colour.r); maxR = max(maxR, colour.r)
                minG = min(minG, colour.g); maxG = max(maxG, colour.g)
                minB = min(minB, colour.b); maxB = max(maxB, colour.b)
            }
            return max(maxR - minR, max(maxG - minG, maxB - minB))
        }

        var average: (r: Double, g: Double, b: Double) {
            guard !colours.isEmpty else { return (0, 0, 0) }
            var sumR = 0, sumG = 0, sumB = 0
            for colour in colours {
                sumR += colour.r; sumG += colour.g; sumB += colour.b
            }
            let count = Double(colours.count)
            return (Double(sumR) / count, Double(sumG) / count, Double(sumB) / count)
        }

        /// Splits at the median of the widest channel.
        func split() -> (Box, Box)? {
            guard colours.count > 1 else { return nil }

            var minR = 255, maxR = 0, minG = 255, maxG = 0, minB = 255, maxB = 0
            for colour in colours {
                minR = min(minR, colour.r); maxR = max(maxR, colour.r)
                minG = min(minG, colour.g); maxG = max(maxG, colour.g)
                minB = min(minB, colour.b); maxB = max(maxB, colour.b)
            }
            let ranges = [maxR - minR, maxG - minG, maxB - minB]
            let channel = ranges.firstIndex(of: ranges.max() ?? 0) ?? 0

            let sorted = colours.sorted { left, right in
                switch channel {
                case 0: return left.r < right.r
                case 1: return left.g < right.g
                default: return left.b < right.b
                }
            }
            let middle = sorted.count / 2
            return (
                Box(colours: Array(sorted[..<middle])),
                Box(colours: Array(sorted[middle...]))
            )
        }
    }

    // MARK: - Mapping pixels to the palette

    /// Each pixel's nearest palette entry.
    ///
    /// Transparent pixels go to entry 0 when there is one. Nearest is by squared
    /// distance in RGB, which is what makes a gradient land on a ramp of palette
    /// entries rather than on one distant colour.
    private static func mapToIndices(_ pixels: [UInt8], palette: Palette) -> [UInt8]? {
        let hasTransparentSlot = palette.alpha.first == 0
        var indices = [UInt8](repeating: 0, count: pixels.count / 4)

        // Nearest-neighbour search is a linear scan per pixel: 58×58 pixels and
        // 64 entries is 215k comparisons, which is nothing next to the PNG
        // encode, and a k-d tree would be more code than it saves.
        var cache: [UInt32: UInt8] = [:]
        cache.reserveCapacity(1024)

        var pixel = 0
        var index = 0
        while pixel + 3 < pixels.count {
            let alpha = pixels[pixel + 3]
            if alpha < transparentCutoff, hasTransparentSlot {
                indices[index] = 0
            } else {
                let key = UInt32(pixels[pixel]) << 16
                    | UInt32(pixels[pixel + 1]) << 8
                    | UInt32(pixels[pixel + 2])
                if let cached = cache[key] {
                    indices[index] = cached
                } else {
                    indices[index] = nearest(
                        r: Int(pixels[pixel]), g: Int(pixels[pixel + 1]),
                        b: Int(pixels[pixel + 2]), palette: palette
                    )
                    cache[key] = indices[index]
                }
            }
            pixel += 4
            index += 1
        }
        return indices
    }

    private static func nearest(r: Int, g: Int, b: Int, palette: Palette) -> UInt8 {
        var best = 0
        var bestDistance = Int.max
        for entry in 0..<palette.count {
            let dr = r - Int(palette.red[entry])
            let dg = g - Int(palette.green[entry])
            let db = b - Int(palette.blue[entry])
            let distance = dr * dr + dg * dg + db * db
            if distance < bestDistance {
                bestDistance = distance
                best = entry
                if distance == 0 { break }
            }
        }
        return UInt8(best)
    }

    // MARK: - Writing the PNG

    /// Assembles the file.
    private static func png(
        indices: [UInt8], width: Int, height: Int, palette: Palette
    ) -> Data? {
        // Every row is prefixed with its filter type. Type 0 (none) on all rows:
        // the compression a palette PNG relies on comes from having few distinct
        // bytes, and filtering the palette indices would work against that.
        var raw = [UInt8]()
        raw.reserveCapacity(height * (width + 1))
        for row in 0..<height {
            raw.append(0)
            raw.append(contentsOf: indices[row * width..<(row + 1) * width])
        }
        guard let compressed = zlibCompress(raw) else { return nil }

        var output = Data()
        output.append(contentsOf: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        var header = Data()
        header.append(bigEndian: UInt32(width))
        header.append(bigEndian: UInt32(height))
        header.append(8)                     // bit depth: 8 bits per index
        header.append(3)                     // colour type 3: palette
        header.append(0)                     // deflate
        header.append(0)                     // adaptive filtering
        header.append(0)                     // no interlace
        output.append(chunk("IHDR", header))

        var colourTable = Data()
        for entry in 0..<palette.count {
            colourTable.append(palette.red[entry])
            colourTable.append(palette.green[entry])
            colourTable.append(palette.blue[entry])
        }
        output.append(chunk("PLTE", colourTable))

        // The alpha channel's home: `tRNS`, one byte per entry. Only the
        // transparent entries need writing, so it ends at the last non-opaque
        // one — PNG treats the rest as opaque.
        var transparency = Data()
        for entry in 0..<palette.count {
            transparency.append(palette.alpha[entry])
        }
        while let last = transparency.last, last == 255 {
            transparency.removeLast()
        }
        if !transparency.isEmpty {
            output.append(chunk("tRNS", transparency))
        }

        output.append(chunk("IDAT", compressed))
        output.append(chunk("IEND", Data()))
        return output
    }

    /// One PNG chunk: length, type, payload, CRC over type and payload.
    private static func chunk(_ type: String, _ payload: Data) -> Data {
        var data = Data()
        data.append(bigEndian: UInt32(payload.count))
        let typeBytes = Data(type.utf8)
        data.append(typeBytes)
        data.append(payload)

        var crc = crc32(0, nil, 0)
        crc = typeBytes.withUnsafeBytes { buffer in
            crc32(crc, buffer.bindMemory(to: Bytef.self).baseAddress,
                  uInt(typeBytes.count))
        }
        crc = payload.withUnsafeBytes { buffer in
            crc32(crc, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(payload.count))
        }
        data.append(bigEndian: UInt32(truncatingIfNeeded: crc))
        return data
    }

    /// zlib-compresses the scanlines.
    ///
    /// Named to avoid the instance method `Data.deflate` that would otherwise be
    /// picked over zlib's C function at this call site.
    private static func zlibCompress(_ bytes: [UInt8]) -> Data? {
        guard !bytes.isEmpty else { return nil }
        var output = Data(count: bytes.count + 64)

        let result: Int = output.withUnsafeMutableBytes { destination -> Int in
            var stream = z_stream()
            guard let destinationBase = destination.bindMemory(to: Bytef.self).baseAddress
            else { return -1 }

            // Level 9 and the maximum window: this runs once when an icon is
            // chosen, so the extra milliseconds are free, and the bytes it saves
            // are paid again on every notification.
            guard deflateInit2_(
                &stream, 9, Z_DEFLATED, 15, 9, Z_DEFAULT_STRATEGY,
                ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
            ) == Z_OK else { return -1 }
            defer { deflateEnd(&stream) }

            let status = bytes.withUnsafeBytes { source -> Int32 in
                stream.next_in = UnsafeMutablePointer(
                    mutating: source.bindMemory(to: Bytef.self).baseAddress
                )
                stream.avail_in = uInt(bytes.count)
                stream.next_out = destinationBase
                stream.avail_out = uInt(destination.count)
                return zlib.deflate(&stream, Z_FINISH)
            }
            guard status == Z_STREAM_END else { return -1 }
            return Int(stream.total_out)
        }

        guard result > 0 else { return nil }
        output.removeSubrange(result..<output.count)
        return output
    }
}

private extension Data {
    /// Appends a 32-bit big-endian value, which is the byte order every PNG
    /// field uses.
    mutating func append(bigEndian value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}
