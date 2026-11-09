import SwiftUI
@testable import Workdeck

/// An abstract macOS Terminal window for the landing tour (landing tour animations spec §4.2): three buttons and a
/// title over a near-black body of monospaced lines. Its lines are made up; nothing is read from a real terminal.
struct DrawnTerminal: View {
    struct Line: Hashable {
        var text: String
        /// The agent's line: starts with Claude Code's `⏺` in its color.
        var isAgent = false
        /// The input line: `>` and a block caret.
        var isPrompt = false
    }

    static let titleBarHeight: CGFloat = 28
    static let cornerRadius: CGFloat = 12

    let title: String
    let lines: [Line]
    var width: CGFloat = 520

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { color in
                        Circle().fill(color).frame(width: 12, height: 12)
                    }
                    Spacer()
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .frame(height: Self.titleBarHeight)
            .background(Color(white: 0.17))

            VStack(alignment: .leading, spacing: 5) {
                // By position: two equal lines (two blank ones) are still two rows.
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    row(line)
                }
            }
            .font(.system(size: 13, design: .monospaced))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width)
        .background(Color(white: 0.118))
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius).stroke(Color.white.opacity(0.2), lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 30, y: 12)
    }

    @ViewBuilder
    private func row(_ line: Line) -> some View {
        if line.isPrompt {
            HStack(spacing: 6) {
                Text(">").foregroundStyle(Color.white.opacity(0.85))
                Rectangle().fill(Color.white.opacity(0.8)).frame(width: 8, height: 15)
            }
            .padding(.top, 6)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(line.isAgent ? "⏺" : " ")
                    .foregroundStyle(AgentKind.claudeCode.color)
                Text(line.text)
                    .foregroundStyle(Color.white.opacity(0.85))
            }
        }
    }
}
