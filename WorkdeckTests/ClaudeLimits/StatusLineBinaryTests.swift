import Foundation
import Testing

struct StatusLineBinaryTests {
    @Test func embeddedBinaryExitsZeroOnEmptyInput() throws {
        let binary = Bundle.main.bundlePath + "/Contents/Helpers/workdeck-statusline"
        #expect(FileManager.default.isExecutableFile(atPath: binary))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data("{}".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
