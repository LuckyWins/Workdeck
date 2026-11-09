import AppKit
import SwiftUI
@testable import Workdeck

/// The Your week tab (landing tour animations spec §3.4, as changed by the user on 2026-11-10: no notch, no card;
/// the Statistics window shows at once and scrolls slowly down). Nothing here moves: the page composes three stills
/// and moves them with CSS (a 60 fps scroll in an APNG would weigh 20+ MB):
/// - `week-frame.png`: the window's top at about the tour block's proportions (title bar, toolbar, edges, shadow);
/// - `week-body.png`: the window's whole body, which the page scrolls under the toolbar at `bodyRect`;
/// - `week-grid-empty.png`: the activity grid with no days, which the page lays over the grid at `gridRect` and
///   uncovers week by week before the scroll.
@MainActor
struct WeekScene {
    /// The Statistics window's width (`WorkdeckApp`) and a height that shows all its content.
    static let windowWidth: CGFloat = 460
    static let tallHeight: CGFloat = 1500
    /// The title bar with its toolbar, measured on `statistics-dark.png`.
    static let headerHeight: CGFloat = 52
    /// The shadow kept above the window: the window sits near the block's top.
    static let shadowAbove: CGFloat = 12
    /// The frame's height for its width: about the tour block's proportions, so it touches its top and bottom.
    static let aspect: CGFloat = 0.95

    let full: CGImage
    let empty: CGImage
    /// The grid's cells in the snapshot (points, the shadow margin included).
    let grid: CGRect
    /// Where the window's content ends in the snapshot (points).
    let contentBottom: CGFloat

    static func make(fixtures: ScreenshotFixtures) throws -> WeekScene {
        let size = CGSize(width: windowWidth, height: tallHeight)
        let full = try ScreenshotRenderer.snapshotWindow(
            StatisticsWindow(controller: fixtures.statistics()), title: "Statistics", size: size, dark: true
        )
        // The same days 52 weeks earlier: outside the grid's half year, so its cells are empty, while the window keeps
        // its layout (with no days at all it drops the agent filter and the grid moves up). Whole weeks, by the
        // calendar: no made-up dates such as a February 29 that a year earlier does not have.
        let calendar = fixtures.calendar
        let yearEarlier = RecapDemoScript.days(now: fixtures.thursday, calendar: calendar).compactMap { day -> RecapDay? in
            guard let date = RecapCalendar.date(ofKey: day.date, calendar: calendar),
                  let earlier = calendar.date(byAdding: .day, value: -364, to: date) else { return nil }
            var day = day
            day.date = RecapCalendar.dayKey(earlier, calendar: calendar)
            return day
        }
        let empty = try ScreenshotRenderer.snapshotWindow(
            StatisticsWindow(controller: fixtures.statistics(days: yearEarlier)), title: "Statistics", size: size, dark: true
        )
        return try WeekScene(full: full, empty: empty)
    }

    private init(full: CGImage, empty: CGImage) throws {
        self.full = full
        self.empty = empty
        let margin = ScreenshotRenderer.windowMargin
        let a = PixelImage(full), b = PixelImage(empty)
        // The grid: where the snapshots differ in the content's first 200 pt (the streak line under it is below).
        guard let differing = a.differingRect(from: b, in: CGRect(x: margin, y: margin + Self.headerHeight, width: Self.windowWidth, height: 200)) else {
            throw ScreenshotRenderer.Failure.noBitmap("week: the grid did not change between the snapshots")
        }
        // The cells only, measured on the empty grid: from the first week's left edge, 27 whole weeks wide (so the
        // page's 27 steps uncover whole weeks), from the first row's top to the last row's bottom (the labels above
        // and the streak line below stay the full snapshot's).
        grid = try Self.cells(in: b, around: differing)
        // Above the window's bottom edge (macOS fits the window to the screen, so it may be shorter than asked): its
        // corners and hairline are not content.
        let windowBottom = CGFloat(full.height) / 2 - margin
        contentBottom = a.lastContentRow(in: CGRect(x: margin + 8, y: margin + Self.headerHeight, width: Self.windowWidth - 16, height: windowBottom - 24 - margin - Self.headerHeight)) + 16
    }

    /// The grid's week columns.
    static let weeks = RecapStore.keptWeeks + 1

    /// The cells' rectangle in `image` (points), found inside `area`: runs of non-background pixels along a row through
    /// the cells give the columns, along a column through a middle week the rows.
    static func cells(in image: PixelImage, around area: CGRect) throws -> CGRect {
        let row = Int((area.midY) * 2)
        let columns = image.runs(alongRow: row, from: Int(area.minX * 2), to: Int(area.maxX * 2))
        guard columns.count >= weeks else { throw ScreenshotRenderer.Failure.noBitmap("week: \(columns.count) grid columns, expected \(weeks)") }
        // The last columns may run together with the current week's outline: the pitch comes from the first ones.
        let pitch = CGFloat(columns[weeks - 2].lowerBound - columns[0].lowerBound) / CGFloat(weeks - 2) / 2
        let firstColumn = columns[0]
        // Rows along a week in the middle: the first week may start after its Monday.
        let middle = columns[weeks / 2]
        // From a little above the area: its top edge is already a cell, which would read as the background.
        let rows = image.runs(alongColumn: (middle.lowerBound + middle.upperBound) / 2, from: Int(area.minY * 2) - 6, to: Int(area.maxY * 2))
        guard let top = rows.first?.lowerBound, let bottom = rows.last?.upperBound else {
            throw ScreenshotRenderer.Failure.noBitmap("week: no grid rows")
        }
        return CGRect(x: CGFloat(firstColumn.lowerBound) / 2, y: CGFloat(top) / 2, width: (pitch * CGFloat(weeks)).rounded(), height: CGFloat(bottom - top) / 2)
    }

    /// The frame's crop of the snapshot (points): from a little shadow above the window, about the block's proportions.
    var frameRect: CGRect {
        let width = CGFloat(full.width) / 2
        return CGRect(x: 0, y: ScreenshotRenderer.windowMargin - Self.shadowAbove, width: width, height: (width * Self.aspect).rounded())
    }

    /// The body in the frame (points): under the toolbar, down to the frame's bottom.
    var bodyRect: CGRect {
        let top = Self.shadowAbove + Self.headerHeight
        return CGRect(x: ScreenshotRenderer.windowMargin, y: top, width: Self.windowWidth, height: frameRect.height - top)
    }

    /// The body's whole height (points): what `week-body.png` holds.
    var bodyHeight: CGFloat {
        contentBottom - ScreenshotRenderer.windowMargin - Self.headerHeight
    }

    /// The grid in the body (points).
    var gridRect: CGRect {
        grid.offsetBy(dx: -ScreenshotRenderer.windowMargin, dy: -(ScreenshotRenderer.windowMargin + Self.headerHeight))
    }

    /// How far the page scrolls the body: the content's end reaches the frame's bottom.
    var scrollDistance: CGFloat {
        max(0, bodyHeight - bodyRect.height)
    }

    func write() throws -> [URL] {
        func crop(_ image: CGImage, _ rect: CGRect, _ name: String) throws -> URL {
            let pixels = CGRect(x: rect.minX * 2, y: rect.minY * 2, width: rect.width * 2, height: rect.height * 2).integral
            guard let cropped = image.cropping(to: pixels) else { throw ScreenshotRenderer.Failure.noBitmap(name) }
            return try ScreenshotRenderer.writeImage(cropped, name: name)
        }
        let margin = ScreenshotRenderer.windowMargin
        return [
            try crop(full, frameRect, "week-frame"),
            try crop(full, CGRect(x: margin, y: margin + Self.headerHeight, width: Self.windowWidth, height: bodyHeight), "week-body"),
            try crop(empty, grid, "week-grid-empty"),
        ]
    }
}

/// An image's RGBA bytes, for measuring the window snapshots.
struct PixelImage {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        self.bytes = bytes
    }

    private func pixel(_ x: Int, _ y: Int) -> ArraySlice<UInt8> {
        let index = (y * width + x) * 4
        return bytes[index ..< index + 4]
    }

    /// The bounding rectangle (points, 2× pixels halved) of the pixels that differ from `other` inside `area` (points).
    func differingRect(from other: PixelImage, in area: CGRect) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in Int(area.minY * 2) ..< min(height, Int(area.maxY * 2)) {
            for x in Int(area.minX * 2) ..< min(width, Int(area.maxX * 2)) where pixel(x, y) != other.pixel(x, y) {
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: CGFloat(minX) / 2, y: CGFloat(minY) / 2, width: CGFloat(maxX - minX + 1) / 2, height: CGFloat(maxY - minY + 1) / 2)
    }

    /// Runs of pixels that differ from the row's first one, between `from` and `to` (2× pixels).
    func runs(alongRow y: Int, from: Int, to: Int) -> [Range<Int>] {
        runs(count: to - from) { pixel(from + $0, y) } .map { ($0.lowerBound + from) ..< ($0.upperBound + from) }
    }

    /// Runs of pixels that differ from the column's first one, between `from` and `to` (2× pixels).
    func runs(alongColumn x: Int, from: Int, to: Int) -> [Range<Int>] {
        runs(count: to - from) { pixel(x, from + $0) } .map { ($0.lowerBound + from) ..< ($0.upperBound + from) }
    }

    private func runs(count: Int, _ at: (Int) -> ArraySlice<UInt8>) -> [Range<Int>] {
        guard count > 0 else { return [] }
        let background = at(0)
        var result: [Range<Int>] = []
        var start: Int?
        for index in 0 ..< count {
            let differs = at(index) != background
            if differs, start == nil { start = index }
            if !differs, let begun = start {
                result.append(begun ..< index)
                start = nil
            }
        }
        if let begun = start { result.append(begun ..< count) }
        return result
    }

    /// The lowest row (points) inside `area` with anything but the background, read at the area's left edge.
    func lastContentRow(in area: CGRect) -> CGFloat {
        let left = Int(area.minX * 2)
        for y in stride(from: min(height, Int(area.maxY * 2)) - 1, through: Int(area.minY * 2), by: -1) {
            let background = pixel(left, y)
            for x in left ..< min(width, Int(area.maxX * 2)) where pixel(x, y) != background {
                return CGFloat(y) / 2
            }
        }
        return area.minY
    }
}
