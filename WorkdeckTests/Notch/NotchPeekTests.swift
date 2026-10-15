import CoreGraphics
import Testing
@testable import Workdeck

struct NotchPeekTests {
    let frame = CGRect(x: 0, y: 0, width: 2560, height: 1440)

    @Test func theZoneIsTheNotchWithWings() {
        let zone = NotchPeekZone.rect(screenFrame: frame, notchSize: CGSize(width: 300, height: 25))
        #expect(zone == CGRect(x: 1280 - 150 - 60, y: 1440 - 25, width: 420, height: 25))
        #expect(zone.contains(CGPoint(x: 1280, y: 1430)))
        #expect(zone.contains(CGPoint(x: 1075, y: 1430)))
        #expect(!zone.contains(CGPoint(x: 1060, y: 1430)))
        #expect(!zone.contains(CGPoint(x: 1280, y: 1400)))
    }

    @Test func thePointerPinnedAtTheTopEdgeIsInside() {
        // NSEvent.mouseLocation reports y == frame.maxY for the top row of pixels.
        let zone = NotchPeekZone.rect(screenFrame: frame, notchSize: CGSize(width: 300, height: 25))
        #expect(NotchPeekZone.contains(zone, CGPoint(x: 1280, y: 1440)))
        #expect(!NotchPeekZone.contains(zone, CGPoint(x: 1280, y: 1414)))
    }

    @Test func aScreenWithAnOffsetKeepsItsZone() {
        let right = CGRect(x: 2560, y: 0, width: 1920, height: 1080)
        let zone = NotchPeekZone.rect(screenFrame: right, notchSize: CGSize(width: 300, height: 24))
        #expect(zone.midX == right.midX)
        #expect(zone.maxY == right.maxY)
    }
}
