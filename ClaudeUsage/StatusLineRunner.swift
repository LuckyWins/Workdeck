import Foundation

/// The logic of `workdeck-statusline`, kept here so it is unit-testable from the app's tests.
nonisolated struct StatusLineRunner: Sendable {
    let paths: WorkdeckPaths
    var runChained: @Sendable (String, Data) -> String? = { ChainedCommand.run($0, input: $1) }
    var environment = ProcessInfo.processInfo.environment

    /// Never throws: Claude Code's status line must keep working whatever happens here.
    func run(stdin: Data, now: Date) -> String {
        var snapshot = StatusLineInputParser.snapshot(from: stdin, capturedAt: now)
        if let incoming = snapshot {
            let existing = try? UsageSnapshotFile.read(from: paths.snapshotURL)
            let merged = existing?.merged(with: incoming, now: now) ?? incoming
            try? UsageSnapshotFile.write(merged, to: paths.snapshotURL)
            snapshot = merged
        }

        let own = snapshot
            .flatMap { UsageFormatting.mostPressing($0.currentWindows(at: now)) }
            .map(UsageFormatting.compactText)
        let isChainedRun = environment[ChainedCommand.markerVariable] != nil
        let chained = isChainedRun ? nil : StatusLineConfig.read(from: paths.statusLineConfigURL)?
            .chainedCommand
            .flatMap { runChained($0, stdin) }

        return [own, chained].compactMap { $0 }.joined(separator: " · ")
    }
}
