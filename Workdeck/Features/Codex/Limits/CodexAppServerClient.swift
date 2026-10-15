import Foundation

nonisolated enum CodexAppServerAnswer: Equatable, Sendable {
    case limits(CodexLimits, version: String?)
    /// Signed in without a ChatGPT plan (an API key): there are no plan limits.
    case noLimits(version: String?)
    case notInstalled
    case failed
}

protocol CodexLimitsFetching: Sendable {
    func fetch(now: Date) async -> CodexAppServerAnswer
}

/// Asks `codex app-server` for the plan limits, as Codex's `/status` does; Codex answers with its own sign-in
/// (Codex spec §2.1).
nonisolated struct CodexAppServerClient: CodexLimitsFetching {
    let locator: CodexBinaryLocator
    let runner: any CodexProcessRunning
    var timeout: Duration = .seconds(15)

    init(locator: CodexBinaryLocator, runner: any CodexProcessRunning, timeout: Duration = .seconds(15)) {
        self.locator = locator
        self.runner = runner
        self.timeout = timeout
    }

    static let requests = Data("""
    {"id":1,"method":"initialize","params":{"clientInfo":{"name":"workdeck","version":"1"}}}
    {"method":"initialized"}
    {"id":2,"method":"account/rateLimits/read"}

    """.utf8)

    func fetch(now: Date) async -> CodexAppServerAnswer {
        guard let executable = locator.locate() else { return .notInstalled }
        guard let output = await runner.exchange(
            executable: executable,
            arguments: ["app-server"],
            input: Self.requests,
            isComplete: { Self.answer(in: $0) != nil },
            timeout: timeout,
            maxBytes: 2 * 1024 * 1024
        ) else { return .failed }
        var version: String?
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if object["id"] as? Int == 1, let agent = (object["result"] as? [String: Any])?["userAgent"] as? String {
                version = CodexRateLimits.version(fromUserAgent: agent)
            }
        }
        guard let answer = Self.answer(in: output) else { return .failed }
        guard let result = answer["result"] as? [String: Any] else {
            // Codex refuses the question without a ChatGPT sign-in, e.g. with an API key: no plan limits to show.
            let message = ((answer["error"] as? [String: Any])?["message"] as? String ?? "").lowercased()
            return message.contains("chatgpt") ? .noLimits(version: version) : .failed
        }
        if let limits = CodexRateLimits.fromAppServer(result, now: now) {
            return .limits(limits, version: version)
        }
        return .noLimits(version: version)
    }

    /// The response to request 2, once it has arrived.
    static func answer(in output: Data) -> [String: Any]? {
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n") where line.contains("\"id\":2") {
            if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], object["id"] as? Int == 2 {
                return object
            }
        }
        return nil
    }
}
