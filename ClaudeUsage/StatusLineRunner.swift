import Foundation

/// The logic of `workdeck-statusline`, kept here so it is unit-testable from the app's tests.
nonisolated struct StatusLineRunner: Sendable {
    let paths: WorkdeckPaths
    var runChained: @Sendable (String, Data) -> String? = { ChainedCommand.run($0, input: $1) }

    /// Never throws: Claude Code's status line must keep working whatever happens here.
    func run(stdin: Data, now: Date) -> String {
        let snapshot = StatusLineInputParser.snapshot(from: stdin, capturedAt: now)
        if let snapshot {
            try? UsageSnapshotFile.write(snapshot, to: paths.snapshotURL)
        }

        let own = snapshot
            .flatMap { UsageFormatting.mostPressing($0.currentWindows(at: now)) }
            .map(UsageFormatting.compactText)
        let chained = StatusLineConfig.read(from: paths.statusLineConfigURL)?
            .chainedCommand
            .flatMap { runChained($0, stdin) }

        return [own, chained].compactMap { $0 }.joined(separator: " · ")
    }
}
