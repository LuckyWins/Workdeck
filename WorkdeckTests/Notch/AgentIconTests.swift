import AppKit
import SwiftUI
import Testing
@testable import Workdeck

@MainActor
struct AgentIconTests {
    @Test func claudeIsTerracotta() {
        #expect(AgentKind.claudeCode.color == AgentKind.claudeTerracotta)
        #expect(AgentKind.claudeTerracotta == Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255))
        #expect(AgentKind.codex.color == .mint)
    }

    @Test func theMenuBarKeepsItsGlyphs() {
        #expect(AgentKind.claudeCode.menuBarMark == "✳")
        #expect(AgentKind.codex.menuBarMark == "◎")
    }

    @Test(arguments: AgentKind.allCases)
    func eachMarkRendersATemplateImage(agent: AgentKind) throws {
        let image = AgentIconImages.image(agent, size: 13)
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 13, height: 13))
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        var drawn = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                drawn += 1
            }
        }
        #expect(drawn > bitmap.pixelsWide * bitmap.pixelsHigh / 10)
        func alpha(_ x: Double, _ y: Double) -> CGFloat {
            bitmap.colorAt(x: Int(x * Double(bitmap.pixelsWide)), y: Int(y * Double(bitmap.pixelsHigh)))?.alphaComponent ?? 0
        }
        switch agent {
        case .claudeCode:
            // The rays meet in the middle and leave gaps between them.
            #expect(alpha(0.5, 0.5) > 0.5)
            #expect(alpha(0.634, 0.177) < 0.5)
        case .codex:
            // The circle is filled, and the prompt's point is cut out of it.
            #expect(alpha(0.25, 0.25) > 0.5)
            #expect(alpha(11.0 / 24, 0.5) < 0.5)
        }
    }

    @Test func imagesAreCachedPerSize() {
        #expect(AgentIconImages.image(.codex, size: 12) === AgentIconImages.image(.codex, size: 12))
        #expect(AgentIconImages.image(.codex, size: 12) !== AgentIconImages.image(.codex, size: 14))
    }
}
