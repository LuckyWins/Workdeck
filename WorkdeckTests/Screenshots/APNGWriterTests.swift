import CoreGraphics
import Foundation
import ImageIO
import Testing

/// Writing the notch animations as APNG (notch animations spec §3.3). Runs in every test run; writes to a temp folder.
@Suite
struct APNGWriterTests {
    private func solid(_ gray: CGFloat, size: Int = 4, square: CGRect? = nil, squareGray: CGFloat = 1) -> CGImage {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        if let square {
            context.setFillColor(CGColor(gray: squareGray, alpha: 1))
            context.fill(square)
        }
        return context.makeImage()!
    }

    /// The red channel of the decoded frame at a pixel, counted from the top left.
    private func red(_ source: CGImageSource, frame: Int, x: Int, y: Int) throws -> UInt8 {
        let image = try #require(CGImageSourceCreateImageAtIndex(source, frame, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return pixel[0]
    }

    private func written(_ delays: [TimeInterval]) throws -> CGImageSource {
        let url = makeTemporaryDirectory().appending(path: "animation.png")
        try APNGWriter.write(delays.enumerated().map { (solid(CGFloat($0.offset) / 3), $0.element) }, to: url)
        return try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    }

    private func png(_ properties: CFDictionary?) -> [CFString: Any] {
        (properties as? [CFString: Any])?[kCGImagePropertyPNGDictionary] as? [CFString: Any] ?? [:]
    }

    @Test func delaysAreWrittenAsGiven() throws {
        let source = try written([0.1, 0.5, 1.0])
        #expect(CGImageSourceGetCount(source) == 3)
        for (index, delay) in [0.1, 0.5, 1.0].enumerated() {
            let frame = png(CGImageSourceCopyPropertiesAtIndex(source, index, nil))
            let written = (frame[kCGImagePropertyAPNGUnclampedDelayTime] ?? frame[kCGImagePropertyAPNGDelayTime]) as? Double
            #expect(abs((written ?? -1) - delay) < 0.001, "frame \(index)")
        }
    }

    @Test func itLoopsForever() throws {
        let source = try written([0.1, 0.1])
        #expect(png(CGImageSourceCopyProperties(source, nil))[kCGImagePropertyAPNGLoopCount] as? Int == 0)
    }

    @Test func onlyTheChangedRegionIsStored() throws {
        let folder = makeTemporaryDirectory()
        let base = solid(0, size: 200)
        // CoreGraphics' y grows upward: this square is the image's top-left 10 × 10.
        let changed = solid(0, size: 200, square: CGRect(x: 0, y: 190, width: 10, height: 10))
        let one = folder.appending(path: "one.png"), two = folder.appending(path: "two.png")
        try APNGWriter.write([(base, 1)], to: one)
        try APNGWriter.write([(base, 1), (changed, 1)], to: two)
        let size = { (url: URL) in try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int }
        // The second frame adds about its 10 × 10 square, not another 200 × 200 picture.
        let grown = try size(two) - size(one)
        #expect(grown < 400, "the second frame added \(grown) bytes")
    }

    /// A 200 × 200 picture of opaque noise (which PNG cannot squeeze), with opaque white squares where asked.
    private func noise(squares: [CGRect] = []) -> CGImage {
        var state: UInt32 = 12345
        var bytes = [UInt8](repeating: 255, count: 200 * 200 * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            for channel in 0 ..< 3 {
                state = state &* 1_103_515_245 &+ 12345
                bytes[index + channel] = UInt8(state >> 24)
            }
        }
        let context = bytes.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 800,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        squares.forEach { context.fill($0) }
        return context.makeImage()!
    }

    @Test func unchangedPixelsBetweenTwoChangesCostAlmostNothing() throws {
        let folder = makeTemporaryDirectory()
        // Two small changes in opposite corners: their rectangle is the whole noisy picture.
        let corners = [CGRect(x: 0, y: 190, width: 10, height: 10), CGRect(x: 190, y: 0, width: 10, height: 10)]
        let one = folder.appending(path: "one.png"), two = folder.appending(path: "two.png")
        try APNGWriter.write([(noise(), 1)], to: one)
        try APNGWriter.write([(noise(), 1), (noise(squares: corners), 1)], to: two)
        let size = { (url: URL) in try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int }
        let grown = try size(two) - size(one)
        // The whole rectangle again would be about 120 KB of noise.
        #expect(grown < 2_000, "the second frame added \(grown) bytes")
        // And it still composes: both corners white, the noise between them kept.
        let source = try #require(CGImageSourceCreateWithURL(two as CFURL, nil))
        let first = try #require(CGImageSourceCreateWithURL(one as CFURL, nil))
        #expect(try red(source, frame: 1, x: 2, y: 2) == 255)
        #expect(try red(source, frame: 1, x: 195, y: 195) == 255)
        #expect(try red(source, frame: 1, x: 100, y: 100) == red(first, frame: 0, x: 100, y: 100))
    }

    @Test func aPixelTurningClearIsReplacedNotBlended() throws {
        let url = makeTemporaryDirectory().appending(path: "clear.png")
        let base = solid(1, size: 20)
        let context = CGContext(
            data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(base, in: CGRect(x: 0, y: 0, width: 20, height: 20))
        context.clear(CGRect(x: 0, y: 10, width: 10, height: 10))
        try APNGWriter.write([(base, 1), (context.makeImage()!, 1)], to: url)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        // The cleared corner is clear in the second frame, not the first frame's white showing through.
        #expect(try red(source, frame: 1, x: 2, y: 2) == 0)
        #expect(try red(source, frame: 1, x: 15, y: 15) == 255)
    }

    @Test func framesOfDifferentSizesAreAnError() {
        #expect(throws: APNGWriter.Failure.mismatchedFrames) {
            try APNGWriter.write([(solid(0, size: 4), 1), (solid(0, size: 8), 1)], to: makeTemporaryDirectory().appending(path: "sizes.png"))
        }
    }

    @Test func noFramesIsAnError() {
        #expect(throws: APNGWriter.Failure.noFrames) {
            try APNGWriter.write([], to: makeTemporaryDirectory().appending(path: "none.png"))
        }
    }
}
