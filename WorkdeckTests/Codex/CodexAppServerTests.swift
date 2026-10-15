import Foundation
import Testing
@testable import Workdeck

nonisolated struct FakeCodexRunner: CodexProcessRunning {
    let output: String?
    func exchange(executable: URL, arguments: [String], input: Data, isComplete: @escaping @Sendable (Data) -> Bool, timeout: Duration, maxBytes: Int) async -> Data? {
        output.map { Data($0.utf8) }
    }
}

struct CodexAppServerTests {
    let home = URL(filePath: "/Users/someone")

    @Test func theLocatorPrefersHomebrewThenTheExtension() {
        let present: Set<String> = ["/usr/local/bin/codex", "/Users/someone/.vscode/extensions/openai.chatgpt-26.1-darwin-arm64/bin/macos-aarch64/codex"]
        let locator = CodexBinaryLocator(home: home, isExecutable: { present.contains($0) }, contents: { url in
            url.path.hasSuffix(".vscode/extensions") ? [url.appending(path: "openai.chatgpt-26.1-darwin-arm64")] : []
        })
        #expect(locator.locate()?.path == "/usr/local/bin/codex")
        let onlyExtension = CodexBinaryLocator(home: home, isExecutable: { $0.contains(".vscode") && present.contains($0) }, contents: { url in
            url.path.hasSuffix(".vscode/extensions") ? [url.appending(path: "openai.chatgpt-26.1-darwin-arm64")] : []
        })
        #expect(onlyExtension.locate()?.path.hasSuffix("macos-aarch64/codex") == true)
        #expect(CodexBinaryLocator(home: home, isExecutable: { _ in false }, contents: { _ in [] }).locate() == nil)
    }

    @Test func theLocatorFindsAnNVMInstall() {
        let locator = CodexBinaryLocator(home: home, isExecutable: { $0 == "/Users/someone/.nvm/versions/node/v20.19.2/bin/codex" }, contents: { url in
            url.path.hasSuffix(".nvm/versions/node") ? [url.appending(path: "v18.0.0"), url.appending(path: "v20.19.2")] : []
        })
        #expect(locator.locate()?.path == "/Users/someone/.nvm/versions/node/v20.19.2/bin/codex")
    }

    private func client(_ output: String?, installed: Bool = true) -> CodexAppServerClient {
        CodexAppServerClient(
            locator: CodexBinaryLocator(home: home, isExecutable: { installed && $0 == "/opt/homebrew/bin/codex" }, contents: { _ in [] }),
            runner: FakeCodexRunner(output: output)
        )
    }

    @Test func anAnswerWithLimits() async {
        let output = """
        {"id":1,"result":{"userAgent":"workdeck/0.162.1 (Mac OS 27.0.0; arm64)"}}
        {"method":"account/updated","params":{}}
        {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":3,"windowDurationMins":10080,"resetsAt":1792581359},"secondary":null,"planType":"prolite"},"rateLimitResetCredits":{"availableCount":3}}}
        """
        guard case let .limits(limits, version) = await client(output).fetch(now: fixedNow) else {
            Issue.record("Expected limits")
            return
        }
        #expect(limits.resetCredits == 3)
        #expect(version == "0.162.1")
    }

    @Test func anAPIKeySignInHasNoLimits() async {
        let output = """
        {"id":1,"result":{"userAgent":"workdeck/0.162.1"}}
        {"id":2,"result":{"rateLimits":null}}
        """
        #expect(await client(output).fetch(now: fixedNow) == .noLimits(version: "0.162.1"))
    }

    @Test func failuresAndAMissingBinary() async {
        #expect(await client(nil).fetch(now: fixedNow) == .failed)
        #expect(await client("{\"id\":2,\"error\":{\"message\":\"x\"}}").fetch(now: fixedNow) == .failed)
        #expect(await client("ignored", installed: false).fetch(now: fixedNow) == .notInstalled)
    }

    @Test(.timeLimit(.minutes(1)))
    func theRunnerReturnsWhenTheAnswerArrives() async {
        let data = await SystemCodexProcessRunner().exchange(
            executable: URL(filePath: "/bin/cat"), arguments: [], input: Data("{\"id\":2,\"result\":{}}\n".utf8),
            isComplete: { String(decoding: $0, as: UTF8.self).contains("\"id\":2") }, timeout: .seconds(10), maxBytes: 1 << 20
        )
        #expect(data.map { String(decoding: $0, as: UTF8.self) }?.contains("\"id\":2") == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func aHangingProcessTimesOut() async {
        let start = Date()
        let data = await SystemCodexProcessRunner().exchange(
            executable: URL(filePath: "/bin/sleep"), arguments: ["30"], input: Data(),
            isComplete: { _ in false }, timeout: .milliseconds(300), maxBytes: 1 << 20
        )
        #expect(data == nil)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test(.timeLimit(.minutes(1)))
    func aFloodIsCut() async {
        let data = await SystemCodexProcessRunner().exchange(
            executable: URL(filePath: "/bin/cat"), arguments: [], input: Data(repeating: 0x61, count: 64 * 1024),
            isComplete: { _ in false }, timeout: .seconds(10), maxBytes: 1024
        )
        #expect(data == nil)
    }

    @Test func anAuthErrorMeansNoPlanLimits() async {
        let output = """
        {"id":1,"result":{"userAgent":"workdeck/0.162.1"}}
        {"id":2,"error":{"code":-32600,"message":"chatgpt authentication required to read rate limits"}}
        """
        #expect(await client(output).fetch(now: fixedNow) == .noLimits(version: "0.162.1"))
    }

    @Test(arguments: [".cursor", ".windsurf", ".vscode-insiders"])
    func theLocatorLooksInOtherEditors(folder: String) {
        let path = "/Users/someone/\(folder)/extensions/openai.chatgpt-26.1-darwin-arm64/bin/macos-aarch64/codex"
        let locator = CodexBinaryLocator(home: home, isExecutable: { $0 == path }, contents: { url in
            url.path.hasSuffix("\(folder)/extensions") ? [url.appending(path: "openai.chatgpt-26.1-darwin-arm64")] : []
        })
        #expect(locator.locate()?.path == path)
    }
}
