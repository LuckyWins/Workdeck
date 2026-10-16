import AppKit
import SwiftUI
import Testing
@testable import Workdeck

@MainActor
struct AgentIconTests {
    @Test func claudeIsTerracotta() {
        #expect(AgentKind.claudeCode.color == AgentKind.claudeTerracotta)
        #expect(AgentKind.claudeTerracotta == Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255))
    }

    @Test func codexIsMintAndDarkerOnLight() throws {
        func resolved(_ color: NSColor, _ name: NSAppearance.Name) throws -> NSColor {
            var result: NSColor?
            try #require(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
                result = color.usingColorSpace(.sRGB)
            }
            return try #require(result)
        }
        let codex = NSColor(AgentKind.codex.color)
        // Dark (the notch is always dark): the system mint. Light: darker than the system's light mint, so it stands
        // out on a light popover.
        let dark = try resolved(codex, .darkAqua)
        let systemDark = try resolved(.systemMint, .darkAqua)
        #expect(abs(dark.greenComponent - systemDark.greenComponent) < 0.02)
        let light = try resolved(codex, .aqua)
        let systemLight = try resolved(.systemMint, .aqua)
        #expect(light.greenComponent < systemLight.greenComponent - 0.1)
    }

    @Test func codexMarkHasARealHoleForItsPrompt() {
        let rect = CGRect(x: 0, y: 0, width: 24, height: 24)
        let path = CodexMarkShape().path(in: rect)
        #expect(path.contains(CGPoint(x: 6, y: 6)))
        #expect(!path.contains(CGPoint(x: 11, y: 12)))
        #expect(!path.contains(CGPoint(x: 14.5, y: 15.5)))
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
