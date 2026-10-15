import Foundation

/// Finds the `codex` command: an app started from Finder has no shell `PATH` (Codex spec §3.2).
nonisolated struct CodexBinaryLocator: Sendable {
    let home: URL
    let isExecutable: @Sendable (String) -> Bool
    /// A folder's entries; empty when it is missing.
    let contents: @Sendable (URL) -> [URL]

    init(home: URL, isExecutable: @escaping @Sendable (String) -> Bool, contents: @escaping @Sendable (URL) -> [URL]) {
        self.home = home
        self.isExecutable = isExecutable
        self.contents = contents
    }

    static func standard() -> CodexBinaryLocator {
        CodexBinaryLocator(
            home: FileManager.default.homeDirectoryForCurrentUser,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            contents: { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
        )
    }

    func locate() -> URL? {
        let fixed = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            + [".local/bin/codex", ".npm-global/bin/codex", ".volta/bin/codex"].map { home.appending(path: $0).path }
        if let path = fixed.first(where: isExecutable) {
            return URL(filePath: path)
        }
        // npm under nvm: the newest Node version first.
        let nvm = newestFirst(contents(home.appending(path: ".nvm/versions/node")))
            .map { $0.appending(path: "bin/codex").path }
        if let path = nvm.first(where: isExecutable) {
            return URL(filePath: path)
        }
        // The binary the ChatGPT extension carries, in VS Code and its forks.
        let editors = [".vscode", ".vscode-insiders", ".cursor", ".windsurf"]
        let extensions = editors.flatMap { editor in
            newestFirst(contents(home.appending(path: "\(editor)/extensions")).filter { $0.lastPathComponent.hasPrefix("openai.chatgpt-") })
        }
        for folder in extensions {
            for arch in ["macos-aarch64", "macos-x86_64"] {
                let path = folder.appending(path: "bin/\(arch)/codex").path
                if isExecutable(path) {
                    return URL(filePath: path)
                }
            }
        }
        return nil
    }

    /// Version-like folder names, the highest first ("v20.19.2" before "v9.1").
    private func newestFirst(_ folders: [URL]) -> [URL] {
        folders.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
    }
}
