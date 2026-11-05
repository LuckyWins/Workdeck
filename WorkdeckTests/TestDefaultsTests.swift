import Foundation
import Testing

/// Tests keep their `UserDefaults` in a temporary folder, never in `~/Library/Preferences` (a named suite leaves a plist
/// there for good; 54,000 had piled up by 2026-11-05).
@Suite
struct TestDefaultsTests {
    private var preferences: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences")
    }

    @Test func testDefaultsKeepTheirValuesOutOfThePreferencesFolder() throws {
        let defaults = makeTestDefaults()
        defaults.set(42, forKey: "answer")
        defaults.synchronize()
        #expect(defaults.integer(forKey: "answer") == 42)
        let suite = try #require(defaults.dictionaryRepresentation()["answer"] as? Int)
        #expect(suite == 42)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: preferences.path).filter { $0.hasPrefix("WorkdeckTests") }
        #expect(leftovers.isEmpty, "\(leftovers.count) test plists in ~/Library/Preferences")
    }

    @Test func eachCallIsItsOwnSuite() {
        let one = makeTestDefaults(), two = makeTestDefaults()
        one.set(true, forKey: "flag")
        #expect(!two.bool(forKey: "flag"))
    }

    /// New tests use `makeTestDefaults()`: a named suite in a test would start the pile again.
    @Test func noTestNamesASuite() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let enumerator = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" && file.lastPathComponent != "TestDefaults.swift" && file.lastPathComponent != "TestDefaultsTests.swift" {
            if try String(contentsOf: file, encoding: .utf8).contains("UserDefaults(suiteName:") {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty, "use makeTestDefaults() in \(offenders.sorted())")
    }
}
