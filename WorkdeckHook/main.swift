import Foundation

// Claude Code and Codex hook: records session and agent events for Workdeck. Prints nothing and always exits 0.
let input = BoundedInput.read(from: .standardInput, limit: HookRunner.maxInputSize)
let arguments = CommandLine.arguments
let isCodex = HookRunner.isCodex(arguments)
HookRunner(
    directory: isCodex ? SessionsDirectory.codex() : SessionsDirectory.standard(),
    instance: isCodex ? nil : HookRunner.instance(from: arguments),
    isCodex: isCodex
).run(
    stdin: input,
    environment: ProcessInfo.processInfo.environment,
    now: Date()
)
exit(0)
