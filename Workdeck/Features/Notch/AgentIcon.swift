import AppKit
import SwiftUI

/// Claude Code's mark: eight even rays (agent marks spec §2). Stroked with round caps by `AgentIcon`.
nonisolated struct ClaudeMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        for step in 0..<4 {
            let angle = Double(step) * .pi / 4
            let dx = cos(angle) * radius
            let dy = sin(angle) * radius
            path.move(to: CGPoint(x: center.x - dx, y: center.y - dy))
            path.addLine(to: CGPoint(x: center.x + dx, y: center.y + dy))
        }
        return path
    }
}

/// The `>_` prompt cut out of Codex's circle, on a 24-point grid.
nonisolated struct CodexPromptShape: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit)
        }
        var path = Path()
        path.move(to: point(7.5, 9))
        path.addLine(to: point(11, 12))
        path.addLine(to: point(7.5, 15))
        path.move(to: point(12.5, 15.5))
        path.addLine(to: point(17, 15.5))
        return path
    }
}

/// An agent's mark in its color, sized to the text beside it (agent marks spec §2).
struct AgentIcon: View {
    let agent: AgentKind
    var size: CGFloat = 13

    var body: some View {
        Self.glyph(agent, size: size)
            .foregroundStyle(agent.color)
            .frame(width: size, height: size)
            .accessibilityLabel(agent.name)
    }

    /// The shape alone in the current foreground style; Codex's prompt is transparent.
    @ViewBuilder
    static func glyph(_ agent: AgentKind, size: CGFloat) -> some View {
        switch agent {
        case .claudeCode:
            ClaudeMarkShape()
                .stroke(style: StrokeStyle(lineWidth: size * 0.13, lineCap: .round))
                .padding(size * 0.07)
        case .codex:
            ZStack {
                Circle()
                CodexPromptShape()
                    .stroke(style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round, lineJoin: .round))
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
        }
    }
}

/// Marks inside a line of text: each agent and size rendered once into a template image.
@MainActor
enum AgentIconImages {
    private static var cache: [String: NSImage] = [:]

    static func image(_ agent: AgentKind, size: CGFloat) -> NSImage {
        let key = "\(agent.rawValue)-\(size)"
        if let image = cache[key] {
            return image
        }
        let renderer = ImageRenderer(content: AgentIcon.glyph(agent, size: size).foregroundStyle(.black).frame(width: size, height: size))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: size, height: size))
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        cache[key] = image
        return image
    }
}

extension AgentKind {
    /// The mark as an image inside a `Text`, in the agent's color, sitting on the text's baseline.
    @MainActor
    func markText(size: CGFloat = 12) -> Text {
        Text(Image(nsImage: AgentIconImages.image(self, size: size)))
            .foregroundStyle(color)
            .baselineOffset(-size * 0.12)
            .accessibilityLabel(name)
    }

    /// "<mark> main": the mark in its color before a name.
    @MainActor
    func marked(_ name: String, size: CGFloat = 12) -> Text {
        markText(size: size) + Text(" \(name)")
    }
}
