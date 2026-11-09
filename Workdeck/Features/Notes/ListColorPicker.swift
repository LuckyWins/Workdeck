import Foundation

/// The color a list created from the quick notes panel gets (notes polish spec §3): the color of Reminders' palette the
/// user's lists use least, so the chips of neighbouring lists differ. Pure.
nonisolated enum ListColorPicker {
    typealias RGB = (red: Double, green: Double, blue: Double)

    /// Reminders' list colors in the app's order: red, orange, yellow, green, blue, purple, brown (sRGB).
    static let palette: [RGB] = [
        (1.0, 0.231, 0.188),
        (1.0, 0.584, 0.0),
        (1.0, 0.8, 0.0),
        (0.204, 0.78, 0.349),
        (0.0, 0.478, 1.0),
        (0.686, 0.322, 0.871),
        (0.635, 0.518, 0.369),
    ]

    /// The palette index of the color the existing lists use least. Each list counts toward its nearest palette color
    /// (Euclidean in sRGB); a tie goes to the lower index.
    static func next(existing: [RGB]) -> Int {
        var counts = Array(repeating: 0, count: palette.count)
        for color in existing {
            counts[nearest(to: color)] += 1
        }
        let fewest = counts.min() ?? 0
        return counts.firstIndex(of: fewest) ?? 0
    }

    private static func nearest(to color: RGB) -> Int {
        let distances = palette.map { entry in
            let red = entry.red - color.red, green = entry.green - color.green, blue = entry.blue - color.blue
            return red * red + green * green + blue * blue
        }
        return distances.indices.min { distances[$0] < distances[$1] } ?? 0
    }
}
