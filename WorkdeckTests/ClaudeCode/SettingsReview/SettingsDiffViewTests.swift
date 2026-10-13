import SwiftUI
import Testing
@testable import Workdeck

@MainActor
struct SettingsDiffViewTests {
    private let width: CGFloat = 340

    private func height(_ view: some View) -> CGFloat {
        ImageRenderer(content: view.frame(width: width)).nsImage?.size.height ?? 0
    }

    @Test func aShortDiffShowsEveryLineEvenWhenLinesWrap() {
        // Workdeck's command lines wrap at the Settings width; the box must not hide the last lines.
        let command = "\"command\" : \"'/Applications/Workdeck.app/Contents/Helpers/workdeck-statusline' --instance personal\","
        let blocks: [DiffBlock] = [.lines((0..<6).map { DiffLine(kind: .added, text: $0 == 2 ? command : "line \($0)") })]
        #expect(height(SettingsDiffView(blocks: blocks)) >= height(SettingsDiffLines(blocks: blocks)))
    }

    @Test func theTooLargeNoteIsNotCut() {
        #expect(height(SettingsDiffView(blocks: nil)) >= height(SettingsDiffLines(blocks: nil)))
    }

    @Test func aLongDiffScrollsWithinTheMaximumHeight() {
        let blocks: [DiffBlock] = [.lines((0..<100).map { DiffLine(kind: .added, text: "line \($0)") })]
        #expect(height(SettingsDiffView(blocks: blocks)) <= SettingsDiffView.maxHeight + 1)
    }
}
