import Foundation
import Testing
@testable import Workdeck

struct WorkdeckPathsTests {
    @Test func filesLiveInSupportDirectory() {
        let paths = WorkdeckPaths(supportDirectory: URL(fileURLWithPath: "/tmp/Workdeck"))
        #expect(paths.snapshotURL.path == "/tmp/Workdeck/claude-usage.json")
        #expect(paths.statusLineConfigURL.path == "/tmp/Workdeck/statusline.json")
    }

    @Test func standardLocationIsApplicationSupport() {
        #expect(WorkdeckPaths.standard().supportDirectory.path.hasSuffix("/Library/Application Support/Workdeck"))
    }
}
