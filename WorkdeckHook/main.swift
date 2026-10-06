import Foundation

// Claude Code hook: records session and agent events for Workdeck. Prints nothing and always exits 0.
let input = FileHandle.standardInput.readDataToEndOfFile()
HookRunner(directory: SessionsDirectory.standard()).run(
    stdin: input,
    environment: ProcessInfo.processInfo.environment,
    now: Date()
)
exit(0)
