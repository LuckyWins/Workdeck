import CoreGraphics
import Testing
@testable import Workdeck

struct FullScreenDetectorTests {
    let display = CGRect(x: 0, y: 0, width: 2560, height: 1440)

    @Test func aWindowAsLargeAsTheDisplayIsFullScreen() {
        #expect(FullScreenRule.isFullScreen(displayBounds: display, windows: [WindowFrame(bounds: display, layer: 0)]))
    }

    @Test func aSmallerWindowIsNot() {
        let zoomed = CGRect(x: 0, y: 25, width: 2560, height: 1415)
        #expect(!FullScreenRule.isFullScreen(displayBounds: display, windows: [WindowFrame(bounds: zoomed, layer: 0)]))
    }

    @Test func onlyANormalWindowCountsAsFullScreen() {
        #expect(!FullScreenRule.isFullScreen(displayBounds: display, windows: [WindowFrame(bounds: display, layer: -2147483624)]))
        #expect(!FullScreenRule.isFullScreen(displayBounds: display, windows: [WindowFrame(bounds: display, layer: 25)]))
    }

    @Test func aFullScreenWindowOnAnotherDisplayDoesNotCount() {
        let other = CGRect(x: 2560, y: 0, width: 1920, height: 1080)
        #expect(!FullScreenRule.isFullScreen(displayBounds: display, windows: [WindowFrame(bounds: other, layer: 0)]))
    }

    @Test func splitViewHalvesAreFullScreen() {
        let left = CGRect(x: 0, y: 0, width: 1276, height: 1440)
        let right = CGRect(x: 1284, y: 0, width: 1276, height: 1440)
        #expect(FullScreenRule.isFullScreen(displayBounds: display, windows: [WindowFrame(bounds: left, layer: 0), WindowFrame(bounds: right, layer: 0)]))
    }

    @Test func aShortWindowAtTheTopIsNot() {
        let strip = CGRect(x: 0, y: 0, width: 2560, height: 100)
        #expect(!FullScreenRule.isFullScreen(displayBounds: display, windows: [WindowFrame(bounds: strip, layer: 0)]))
    }

    @Test func noWindowsIsNotFullScreen() {
        #expect(!FullScreenRule.isFullScreen(displayBounds: display, windows: []))
    }
}
