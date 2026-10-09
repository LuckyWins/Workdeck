import Foundation

// Claude Code hook: records session and agent events for Workdeck. Prints nothing and always exits 0.
let input = BoundedInput.read(from: .standardInput, limit: HookRunner.maxInputSize)
HookRunner(directory: SessionsDirectory.standard(), instance: HookRunner.instance(from: CommandLine.arguments)).run(
    stdin: input,
    environment: ProcessInfo.processInfo.environment,
    now: Date()
)
exit(0)
