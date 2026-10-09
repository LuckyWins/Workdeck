import Foundation

/// The logic of `workdeck-statusline`, kept here so it is unit-testable from the app's tests.
nonisolated struct StatusLineRunner: Sendable {
    let paths: WorkdeckPaths
    var runChained: @Sendable (String, Data) -> String? = { ChainedCommand.run($0, input: $1) }
    var environment = ProcessInfo.processInfo.environment
    /// The extra instance this status line belongs to (`--instance <name>`); `nil` for the main one.
    var instance: String?

    /// The value of `--instance` when it is a valid instance name (spec §3.1); otherwise the main instance.
    /// The same rule as `HookRunner.instance(from:)`: the two binaries share no code.
    static func instance(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--instance"), arguments.indices.contains(index + 1) else { return nil }
        let name = arguments[index + 1]
        let allowed = name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
        guard (1...20).contains(name.count), allowed, name.first != "-", name != "main" else { return nil }
        return name
    }

    /// Never throws: Claude Code's status line must keep working whatever happens here.
    func run(stdin: Data, now: Date) -> String {
        var snapshot = StatusLineInputParser.snapshot(from: stdin, capturedAt: now)
        if let incoming = snapshot {
            let existing = try? UsageSnapshotFile.read(from: paths.snapshotURL(for: instance))
            let merged = existing?.merged(with: incoming, now: now) ?? incoming
            try? UsageSnapshotFile.write(merged, to: paths.snapshotURL(for: instance))
            snapshot = merged
        }

        let own = snapshot
            .flatMap { UsageFormatting.mostPressing($0.currentWindows(at: now)) }
            .map(UsageFormatting.compactText)
        let isChainedRun = environment[ChainedCommand.markerVariable] != nil
        let chained = isChainedRun ? nil : StatusLineConfig.read(from: paths.statusLineConfigURL(for: instance))?
            .chainedCommand
            .flatMap { runChained($0, stdin) }

        return [own, chained].compactMap { $0 }.joined(separator: " · ")
    }
}
