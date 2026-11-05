import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes frames as one animated PNG that loops forever (notch animations spec §3.3): full color and soft
/// transparency, which GIF lacks. Each frame shows for its own delay. ImageIO encodes the pixels, but it writes every
/// frame whole; this writer assembles the APNG chunks itself so a frame after the first stores only the rectangle that
/// changed (a live notch frame differs from the previous one in a spinner or a row, not in 800 × 1000 pixels). When
/// every changed pixel is opaque, the pixels inside that rectangle that did not change are stored clear and the frame
/// is blended over the previous one, so two small changes far apart cost little more than one. A frame identical to the
/// one before lengthens that one's delay.
nonisolated enum APNGWriter {
    enum Failure: Error, Equatable {
        case noFrames
        case notWritten
        /// The frames differ in size, or ImageIO chose different pixel formats for them.
        case mismatchedFrames
    }

    static func write(_ frames: [(image: CGImage, delay: TimeInterval)], to url: URL) throws {
        guard let first = frames.first else { throw Failure.noFrames }
        let width = first.image.width, height = first.image.height

        // One frame at a time against the one before: only two frames' pixels are held, the rest as encoded PNG data.
        var parts: [(chunks: [(type: String, data: Data)], rect: CGRect, delay: TimeInterval, blendsOver: Bool)] = []
        var previous: [UInt32]?
        for frame in frames {
            guard frame.image.width == width, frame.image.height == height else { throw Failure.mismatchedFrames }
            let pixels = try rgba(frame.image)
            let rect: CGRect
            if let previous {
                guard let changed = changedRect(previous, pixels, width: width, height: height) else {
                    parts[parts.count - 1].delay += frame.delay
                    continue
                }
                rect = changed
            } else {
                rect = CGRect(x: 0, y: 0, width: width, height: height)
            }
            let (region, blendsOver) = try regionImage(pixels, previous: previous, rect: rect, width: width)
            parts.append((try pngChunks(of: region), rect, frame.delay, blendsOver))
            previous = pixels
        }

        var output = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var sequence: UInt32 = 0
        var header: Data?
        for (number, part) in parts.enumerated() {
            guard let ihdr = part.chunks.first(where: { $0.type == "IHDR" })?.data else { throw Failure.notWritten }
            // Bit depth, color type, compression, filter and interlace must match the first frame's.
            if let header, header.suffix(5) != ihdr.suffix(5) { throw Failure.mismatchedFrames }
            if number == 0 {
                header = ihdr
                output.append(chunk("IHDR", ihdr))
                output.append(chunk("acTL", be32(UInt32(parts.count)) + be32(0)))
                for ancillary in part.chunks where !["IHDR", "IDAT", "IEND", "acTL", "fcTL", "fdAT"].contains(ancillary.type) {
                    output.append(chunk(ancillary.type, ancillary.data))
                }
            }
            output.append(chunk("fcTL", frameControl(sequence: sequence, rect: part.rect, delay: part.delay, blendsOver: part.blendsOver)))
            sequence += 1
            for data in part.chunks.filter({ $0.type == "IDAT" }).map(\.data) {
                if number == 0 {
                    output.append(chunk("IDAT", data))
                } else {
                    output.append(chunk("fdAT", be32(sequence) + data))
                    sequence += 1
                }
            }
        }
        output.append(chunk("IEND", Data()))
        do {
            try output.write(to: url)
        } catch {
            throw Failure.notWritten
        }
    }

    // MARK: Pixels

    /// The image as premultiplied sRGB RGBA, one 32-bit word a pixel, top row first.
    private static func rgba(_ image: CGImage) throws -> [UInt32] {
        var words = [UInt32](repeating: 0, count: image.width * image.height)
        let drawn = words.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw Failure.notWritten }
        return words
    }

    /// Whether a pixel word is fully opaque (alpha is the last byte in memory, the high byte of a little-endian word).
    private static func isOpaque(_ word: UInt32) -> Bool {
        withUnsafeBytes(of: word) { $0[3] == 255 }
    }

    /// `rect` of `pixels` as an image; with every changed pixel opaque, the unchanged ones clear, to be blended over.
    private static func regionImage(_ pixels: [UInt32], previous: [UInt32]?, rect: CGRect, width: Int) throws -> (CGImage, blendsOver: Bool) {
        let x0 = Int(rect.minX), y0 = Int(rect.minY), w = Int(rect.width), h = Int(rect.height)
        var region = [UInt32](repeating: 0, count: w * h)
        var blendsOver = previous != nil
        pixels.withUnsafeBufferPointer { new in
            region.withUnsafeMutableBufferPointer { out in
                for y in 0 ..< h {
                    for x in 0 ..< w {
                        out[y * w + x] = new[(y0 + y) * width + x0 + x]
                    }
                }
            }
            guard let previous else { return }
            previous.withUnsafeBufferPointer { old in
                // A changed pixel that is not opaque cannot be blended over the old one: replace the whole rectangle.
                outer: for y in 0 ..< h {
                    for x in 0 ..< w {
                        let at = (y0 + y) * width + x0 + x
                        if new[at] != old[at], !isOpaque(new[at]) {
                            blendsOver = false
                            break outer
                        }
                    }
                }
                guard blendsOver else { return }
                region.withUnsafeMutableBufferPointer { out in
                    for y in 0 ..< h {
                        for x in 0 ..< w where new[(y0 + y) * width + x0 + x] == old[(y0 + y) * width + x0 + x] {
                            out[y * w + x] = 0
                        }
                    }
                }
            }
        }
        let image = try region.withUnsafeMutableBytes { buffer -> CGImage in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let image = context.makeImage() else { throw Failure.notWritten }
            return image
        }
        return (image, blendsOver)
    }

    /// The smallest rectangle (top-left origin, as `CGImage.cropping`) holding every pixel that differs, or nil.
    private static func changedRect(_ old: [UInt32], _ new: [UInt32], width: Int, height: Int) -> CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        old.withUnsafeBufferPointer { old in
            new.withUnsafeBufferPointer { new in
                for y in 0 ..< height {
                    let row = y * width
                    for x in 0 ..< width where old[row + x] != new[row + x] {
                        minX = min(minX, x); maxX = max(maxX, x)
                        minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    // MARK: PNG chunks

    private static func pngChunks(of image: CGImage) throws -> [(type: String, data: Data)] {
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else { throw Failure.notWritten }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.notWritten }
        let bytes = encoded as Data
        var chunks: [(String, Data)] = []
        var at = 8
        while at + 8 <= bytes.count {
            let length = Int(bytes[at ..< at + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            let type = String(decoding: bytes[at + 4 ..< at + 8], as: UTF8.self)
            guard at + 12 + length <= bytes.count else { throw Failure.notWritten }
            chunks.append((type, Data(bytes[at + 8 ..< at + 8 + length])))
            at += 12 + length
        }
        return chunks
    }

    /// `fcTL`: where the frame goes and how long it shows; the canvas is kept after it (dispose none), and it either
    /// replaces the pixels under it alpha and all (blend source) or is drawn over them (blend over).
    private static func frameControl(sequence: UInt32, rect: CGRect, delay: TimeInterval, blendsOver: Bool) -> Data {
        be32(sequence) + be32(UInt32(rect.width)) + be32(UInt32(rect.height)) + be32(UInt32(rect.minX)) + be32(UInt32(rect.minY))
            + be16(UInt16(min(65535, max(0, (delay * 1000).rounded())))) + be16(1000) + Data([0, blendsOver ? 1 : 0])
    }

    private static func chunk(_ type: String, _ data: Data) -> Data {
        let body = Data(type.utf8) + data
        return be32(UInt32(data.count)) + body + be32(crc32(body))
    }

    private static func be32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    private static func be16(_ value: UInt16) -> Data {
        Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    private static let crcTable: [UInt32] = (0 ..< 256).map { n in
        (0 ..< 8).reduce(UInt32(n)) { c, _ in c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        ~data.reduce(UInt32.max) { crcTable[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }
}
