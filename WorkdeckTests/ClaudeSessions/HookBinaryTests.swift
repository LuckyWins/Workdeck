import Foundation
import Testing

struct HookBinaryTests {
    @Test func embeddedHookExitsZeroSilently() throws {
        let binary = Bundle.main.bundlePath + "/Contents/Helpers/workdeck-hook"
        #expect(FileManager.default.isExecutableFile(atPath: binary))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        // Not a valid event, so nothing is written to the real sessions directory.
        input.fileHandleForWriting.write(Data("{}".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }
}
