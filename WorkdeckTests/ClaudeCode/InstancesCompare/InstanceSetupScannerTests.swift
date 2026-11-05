import Foundation
import Testing
@testable import Workdeck

/// A Claude Code instance built inside a temporary folder.
private final class InstanceFixture {
    let root = makeTemporaryDirectory()
    let instance: ClaudeInstance

    init(name: String = "personal") {
        let directory = root.appending(path: ".claude-\(name)")
        instance = ClaudeInstance(name: name, directory: directory, accountFile: directory.appending(path: ".claude.json"))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes `text` at `relative` inside the instance folder, creating the folders.
    func write(_ text: String, _ relative: String) {
        write(Data(text.utf8), relative)
    }

    func write(_ data: Data, _ relative: String) {
        let url = instance.directory.appending(path: relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    func writeAccountFile(_ json: String) {
        try? Data(json.utf8).write(to: instance.accountFile)
    }

    func scan() -> InstanceSetup {
        InstanceSetupScanner.scan(instance)
    }
}

private extension Readable {
    var value: T? {
        if case .read(let value) = self { value } else { nil }
    }
}

struct InstanceSetupScannerTests {
    @Test func skillsWithFrontMatterAndOffState() throws {
        let fixture = InstanceFixture()
        fixture.write("---\nname: write-tests\ndescription: Writes tests\n---\nBody", "skills/write-tests/SKILL.md")
        fixture.write("Deploy it", "skills/deploy/SKILL.md")
        fixture.write(#"{"skillOverrides":{"deploy":"off"}}"#, "settings.json")
        fixture.write("synced", "skills/synced/x/SKILL.md")
        fixture.write("trashed", "skills/.trash/y/SKILL.md")
        fixture.write("", "skills/.DS_Store")
        fixture.write("no skill file", "skills/notes/readme.md")
        let skills = try #require(fixture.scan().skills.value)
        #expect(skills.map(\.name) == ["deploy", "write-tests"])
        let tests = try #require(skills.first { $0.name == "write-tests" })
        #expect(tests.title == "write-tests")
        #expect(tests.summary == "Writes tests")
        #expect(!tests.isOff)
        #expect(!tests.isPartial)
        #expect(tests.folder.lastPathComponent == "write-tests")
        #expect(tests.modified != nil)
        let deploy = try #require(skills.first { $0.name == "deploy" })
        #expect(deploy.isOff)
        #expect(deploy.title == nil)
        #expect(deploy.summary == nil)
    }

    @Test func frontMatterValuesMayBeQuotedOrSpanLines() throws {
        let fixture = InstanceFixture()
        fixture.write("---\nname: \"quoted\"\ndescription: 'It''s short'\nallowed-tools: Read\n---\nBody", "skills/a/SKILL.md")
        fixture.write("---\nname: folded\ndescription: >\n  first line\n  second line\n---\nBody", "skills/b/SKILL.md")
        fixture.write("---\nname: open\ndescription: never closed\nBody", "skills/c/SKILL.md")
        fixture.write("# No front matter\n---\nname: late\n---", "skills/d/SKILL.md")
        let skills = try #require(fixture.scan().skills.value)
        let a = try #require(skills.first { $0.folder.lastPathComponent == "a" })
        #expect(a.title == "quoted")
        #expect(a.summary == "It's short")
        let b = try #require(skills.first { $0.folder.lastPathComponent == "b" })
        #expect(b.title == "folded")
        #expect(b.summary == "first line second line")
        let c = try #require(skills.first { $0.folder.lastPathComponent == "c" })
        #expect(c.title == nil)
        #expect(c.summary == nil)
        let d = try #require(skills.first { $0.folder.lastPathComponent == "d" })
        #expect(d.title == nil)
    }

    @Test func frontMatterWithWindowsLineEndings() throws {
        let fixture = InstanceFixture()
        fixture.write("---\r\nname: crlf\r\ndescription: Works\r\n---\r\nBody", "skills/a/SKILL.md")
        let skill = try #require(fixture.scan().skills.value?.first)
        #expect(skill.title == "crlf")
        #expect(skill.summary == "Works")
    }

    @Test func sameFilesSameHashOtherFilesOtherHash() throws {
        func hash(of fixture: InstanceFixture) throws -> String {
            try #require(fixture.scan().skills.value?.first).contentHash
        }
        let first = InstanceFixture(name: "first")
        let second = InstanceFixture(name: "second")
        let third = InstanceFixture(name: "third")
        for fixture in [first, second, third] {
            fixture.write("---\nname: s\n---\nBody", "skills/s/SKILL.md")
            fixture.write("reference A", "skills/s/reference/a.md")
        }
        third.write("reference B", "skills/s/reference/a.md")
        #expect(try hash(of: first) == hash(of: second))
        #expect(try hash(of: first) != hash(of: third))
        // A Finder leftover does not make a copy differ.
        second.write("", "skills/s/.DS_Store")
        #expect(try hash(of: first) == hash(of: second))
    }

    @Test func aHugeSkillComparesItsSkillFileOnly() throws {
        let huge = InstanceFixture(name: "huge")
        let plain = InstanceFixture(name: "plain")
        huge.write("Skill body", "skills/big/SKILL.md")
        plain.write("Skill body", "skills/big/SKILL.md")
        for index in 0..<200 {
            huge.write("file \(index)", "skills/big/files/\(index).txt")
        }
        let bigSkill = try #require(huge.scan().skills.value?.first)
        let plainSkill = try #require(plain.scan().skills.value?.first)
        #expect(bigSkill.isPartial)
        #expect(!plainSkill.isPartial)
        #expect(bigSkill.contentHash == plainSkill.contentHash)
    }

    @Test func twoHundredFilesAreStillHashedWhole() throws {
        let fixture = InstanceFixture()
        fixture.write("Skill body", "skills/s/SKILL.md")
        for index in 0..<199 {
            fixture.write("file \(index)", "skills/s/files/\(index).txt")
        }
        #expect(try #require(fixture.scan().skills.value?.first).isPartial == false)
    }

    @Test func aSkillOverFiveMegabytesIsPartial() throws {
        let fixture = InstanceFixture()
        fixture.write("Skill body", "skills/s/SKILL.md")
        fixture.write(Data(count: 5 * 1024 * 1024 + 1), "skills/s/data.bin")
        #expect(try #require(fixture.scan().skills.value?.first).isPartial)
    }

    @Test func hiddenEntriesAreNotCompared() throws {
        let plain = InstanceFixture(name: "plain")
        let cloned = InstanceFixture(name: "cloned")
        for fixture in [plain, cloned] {
            fixture.write("Skill body", "skills/s/SKILL.md")
            fixture.write("reference", "skills/s/reference.md")
        }
        cloned.write("[core]", "skills/s/.git/config")
        cloned.write("local", "skills/s/.env")
        for index in 0..<250 {
            cloned.write("object \(index)", "skills/s/.git/objects/\(index)")
        }
        let plainSkill = try #require(plain.scan().skills.value?.first)
        let clonedSkill = try #require(cloned.scan().skills.value?.first)
        #expect(clonedSkill.contentHash == plainSkill.contentHash)
        #expect(!clonedSkill.isPartial, "a big .git does not fill the file cap")
    }

    @Test func aTemporaryCopyIsNotASkill() throws {
        let fixture = InstanceFixture()
        fixture.write("Skill body", "skills/deploy/SKILL.md")
        let temporary = SetupCopier.temporaryLocation(for: fixture.instance.directory.appending(path: "skills/deploy"))
        #expect(temporary.lastPathComponent.hasPrefix(".deploy.workdeck-"))
        #expect(temporary.deletingLastPathComponent().lastPathComponent == "skills")
        fixture.write("Half copied", "skills/\(temporary.lastPathComponent)/SKILL.md")
        #expect(try #require(fixture.scan().skills.value).map(\.name) == ["deploy"])
    }

    @Test func symlinksAreFollowedOnlyInsideTheSkillFolder() throws {
        let plain = InstanceFixture(name: "plain")
        plain.write("Skill body", "skills/s/SKILL.md")
        plain.write("shared", "skills/s/reference.md")
        let linked = InstanceFixture(name: "linked")
        linked.write("Skill body", "skills/s/SKILL.md")
        linked.write("shared", "skills/s/real.md")
        let skill = linked.instance.directory.appending(path: "skills/s")
        try FileManager.default.createSymbolicLink(at: skill.appending(path: "reference.md"), withDestinationURL: skill.appending(path: "real.md"))
        // Outside the folder: the link is left out of the hash.
        let outside = linked.root.appending(path: "outside.md")
        try Data("private".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: skill.appending(path: "escape.md"), withDestinationURL: outside)
        let reference = InstanceFixture(name: "reference")
        reference.write("Skill body", "skills/s/SKILL.md")
        reference.write("shared", "skills/s/real.md")
        reference.write("shared", "skills/s/reference.md")
        #expect(try #require(linked.scan().skills.value?.first).contentHash == #require(reference.scan().skills.value?.first).contentHash)
        #expect(try #require(linked.scan().skills.value?.first).contentHash != #require(plain.scan().skills.value?.first).contentHash)
    }

    @Test func pluginsByScope() throws {
        let fixture = InstanceFixture()
        fixture.write(
            #"{"version":2,"plugins":{"superpowers@m":[{"scope":"user","version":"7.0.0"},{"scope":"project","projectPath":"/p","version":"7.0.0"}],"swift-lsp@m":[{"scope":"user","version":"1.0.4"}]}}"#,
            "plugins/installed_plugins.json"
        )
        fixture.write(#"{"enabledPlugins":{"superpowers@m":true}}"#, "settings.json")
        let plugins = try #require(fixture.scan().plugins.value)
        #expect(plugins == [
            PluginInfo(id: "superpowers@m", version: "7.0.0", projectPath: nil, isOff: false),
            PluginInfo(id: "superpowers@m", version: "7.0.0", projectPath: "/p", isOff: false),
            PluginInfo(id: "swift-lsp@m", version: "1.0.4", projectPath: nil, isOff: true),
        ])
    }

    @Test func aPluginTurnedOffInSettingsIsOff() throws {
        let fixture = InstanceFixture()
        fixture.write(#"{"version":2,"plugins":{"a@m":[{"scope":"user","version":"1"}]}}"#, "plugins/installed_plugins.json")
        fixture.write(#"{"enabledPlugins":{"a@m":false}}"#, "settings.json")
        #expect(try #require(fixture.scan().plugins.value?.first).isOff)
    }

    @Test func mcpServersOfTheInstanceAndItsProjects() throws {
        let fixture = InstanceFixture()
        fixture.writeAccountFile("""
        {"mcpServers":{
           "dart":{"type":"stdio","command":"dart","args":["mcp-server"]},
           "cloud":{"command":"uvx","args":["x"],"env":{"AWS_PROFILE":"prod-secret"}}},
         "projects":{"/p/zophi":{
           "mcpServers":{"firebase":{"type":"stdio","command":"npx","args":["firebase-tools","mcp"]}},
           "disabledMcpServers":["firebase"]}}}
        """)
        let servers = try #require(fixture.scan().mcp.value)
        #expect(servers.map(\.name) == ["cloud", "dart", "firebase"])
        let dart = try #require(servers.first { $0.name == "dart" })
        #expect(dart.display == "dart mcp-server")
        #expect(dart.kind == "stdio")
        #expect(dart.project == nil)
        #expect(!dart.isOff)
        let cloud = try #require(servers.first { $0.name == "cloud" })
        #expect(cloud.kind == "stdio")
        #expect(cloud.display.contains("AWS_PROFILE=•••"))
        let firebase = try #require(servers.first { $0.name == "firebase" })
        #expect(firebase.project == "/p/zophi")
        #expect(firebase.isOff)
        // The copy source holds the real values.
        let copied = try #require(JSONSerialization.jsonObject(with: cloud.json) as? [String: Any])
        #expect((copied["env"] as? [String: String])?["AWS_PROFILE"] == "prod-secret")
    }

    @Test func mcpSignatureTellsOtherValuesApart() throws {
        func signature(_ profile: String) throws -> String {
            let fixture = InstanceFixture()
            fixture.writeAccountFile(#"{"mcpServers":{"cloud":{"command":"uvx","env":{"AWS_PROFILE":"\#(profile)"}}}}"#)
            return try #require(fixture.scan().mcp.value?.first).signature
        }
        #expect(try signature("prod") == signature("prod"))
        #expect(try signature("prod") != signature("dev"))
    }

    @Test func mcpDisplayHidesEveryValue() throws {
        let fixture = InstanceFixture()
        fixture.writeAccountFile("""
        {"mcpServers":{
           "cloud":{"command":"uvx","args":["x"],"env":{"AWS_PROFILE":"prod-secret"}},
           "remote":{"type":"http","url":"https://example.com/mcp","headers":{"Authorization":"Bearer abc"}}},
         "projects":{"/p":{"mcpServers":{"local":{"command":"x","env":{"TOKEN":"prod-secret"}}}}}}
        """)
        let setup = fixture.scan()
        let servers = try #require(setup.mcp.value)
        #expect(servers.count == 3)
        let remote = try #require(servers.first { $0.name == "remote" })
        #expect(remote.kind == "http")
        #expect(remote.display == "https://example.com/mcp Authorization=•••")
        func dumped(_ value: Any) -> String {
            var text = ""
            dump(value, to: &text)
            return text
        }
        let texts = servers.flatMap { [$0.display, String(describing: $0), String(reflecting: $0), "\($0)", dumped($0)] }
            + [String(describing: setup.mcp), String(reflecting: setup.mcp), String(describing: setup), dumped(setup)]
        for text in texts {
            #expect(!text.contains("prod-secret"))
            #expect(!text.contains("Bearer abc"))
            #expect(!text.contains(" json:"), "the definition's bytes are never printed")
        }
        #expect(dumped(remote).contains("https://example.com/mcp"))
    }

    @Test func secretsInArgumentsAndUrlsAreMasked() throws {
        let fixture = InstanceFixture()
        fixture.writeAccountFile("""
        {"mcpServers":{
           "supabase":{"command":"npx","args":["-y","@supabase/mcp-server","--access-token","sbp-123","--project-ref=abc"]},
           "flag":{"command":"x","args":["--api-key=sk-456","API_TOKEN=tok-789"]},
           "db":{"command":"x","args":["postgres://user:hunter2@host/db"]},
           "sse":{"type":"sse","url":"https://user:hunter2@example.com/sse?api_key=sk-456&mode=fast"},
           "header":{"command":"npx","args":["mcp-remote","https://api.example.com/mcp","--header","Authorization: Bearer abc123"]},
           "headerEq":{"command":"x","args":["--header=Authorization:Bearer def456"]},
           "shortH":{"command":"x","args":["-H","X-Custom: ghi789"]},
           "bare":{"command":"x","args":["Bearer jkl012"]},
           "named":{"command":"x","args":["X-Api-Key: mno345"]},
           "zapier":{"type":"http","url":"https://mcp.zapier.com/api/mcp/s/ZjYxNmY4OTItYTk0Ny00Zm/mcp"},
           "conn":{"command":"x","args":["Server=db.local;User Id=sa;Password=pqr678"]},
           "dsn":{"command":"x","args":["--dsn","host=db&password=stu901"]}}}
        """)
        let servers = try #require(fixture.scan().mcp.value)
        func display(_ name: String) throws -> String {
            try #require(servers.first { $0.name == name }).display
        }
        #expect(try display("supabase") == "npx -y @supabase/mcp-server --access-token ••• --project-ref=abc")
        #expect(try display("flag") == "x --api-key=••• API_TOKEN=•••")
        #expect(try display("db") == "x postgres://•••@host/db")
        #expect(try display("sse") == "https://•••@example.com/sse?api_key=•••&mode=•••")
        #expect(try display("header") == "npx mcp-remote https://api.example.com/mcp --header Authorization: •••")
        #expect(try display("headerEq") == "x --header=Authorization: •••")
        #expect(try display("shortH") == "x -H X-Custom: •••")
        #expect(try display("bare") == "x •••")
        #expect(try display("named") == "x X-Api-Key: •••")
        #expect(try display("zapier") == "https://mcp.zapier.com/api/mcp/s/•••/mcp")
        #expect(try display("conn") == "x Server=db.local;User Id=sa;Password=•••")
        #expect(try display("dsn") == "x --dsn host=db&password=•••")
        let secrets = ["sbp-123", "sk-456", "tok-789", "hunter2", "abc123", "def456", "ghi789", "jkl012", "mno345", "ZjYxNmY4", "pqr678", "stu901"]
        for text in servers.map(\.display) {
            for secret in secrets {
                #expect(!text.contains(secret))
            }
        }
    }

    /// The display of each stdio server `name: args` (command `x`), read through the scanner.
    private func displays(_ arguments: [String: [String]]) throws -> [String: String] {
        let fixture = InstanceFixture()
        let servers = arguments.mapValues { ["command": "x", "args": $0] as [String: Any] }
        let data = try JSONSerialization.data(withJSONObject: ["mcpServers": servers])
        fixture.writeAccountFile(String(decoding: data, as: UTF8.self))
        let scanned = try #require(fixture.scan().mcp.value)
        return Dictionary(uniqueKeysWithValues: scanned.map { ($0.name, $0.display) })
    }

    @Test func secretValuesInsideJSONArgumentsAreMasked() throws {
        let shown = try displays([
            "smithery": ["run", "@smithery-ai/github", "--config", #"{"githubPersonalAccessToken":"jsonval1","debug":true}"#],
            "nested": [#"--config={"server":{"apiKey":"jsonval2","port":3000},"list":[{"password":"jsonval3"}],"note":"ghp_jsonval4"}"#],
            "array": [#"[{"secret":"jsonval5"},"plain"]"#],
            "equalsInside": [#"{"token":"a=jsonval6"}"#],
            "broken": [#"{"token": "jsonval7""#],
            "spaced": [#"  {"auth":{"user":"u","pw":"jsonval8"}}"#],
        ])
        #expect(shown["smithery"] == #"x run @smithery-ai/github --config {"debug":true,"githubPersonalAccessToken":"•••"}"#)
        #expect(shown["nested"] == #"x --config={"list":[{"password":"•••"}],"note":"•••","server":{"apiKey":"•••","port":3000}}"#)
        #expect(shown["array"] == #"x [{"secret":"•••"},"plain"]"#)
        #expect(shown["equalsInside"] == #"x {"token":"•••"}"#)
        #expect(shown["broken"] == "x •••")
        #expect(shown["spaced"] == #"x {"auth":"•••"}"#)
        for text in shown.values {
            #expect(!text.contains("jsonval"))
        }
    }

    @Test func aSecretNamedFlagMasksTheNextArgumentEvenWithBearerInItsName() throws {
        let shown = try displays([
            "oauth": ["--oauth2Bearer", "bearerval1"],
            "bearerToken": ["--bearer-token", "bearerval2", "--verbose"],
        ])
        #expect(shown["oauth"] == "x --oauth2Bearer •••")
        #expect(shown["bearerToken"] == "x --bearer-token ••• --verbose")
    }

    @Test func knownTokenFormatsAreMaskedWherever() throws {
        let prefixes = ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "glpat-", "xoxb-", "xoxp-", "xoxa-", "xoxs-",
                        "sk-", "sk_live_", "sk_test_", "rk_live_", "AKIA", "ASIA", "AIza", "ya29.", "eyJ"]
        var arguments: [String: [String]] = [:]
        for (index, prefix) in prefixes.enumerated() {
            arguments["positional\(index)"] = [prefix + "tokval\(index)"]
            arguments["equals\(index)"] = ["--config-value=\(prefix)tokval\(index)"]
            arguments["pair\(index)"] = ["GITHUB=\(prefix)tokval\(index)"]
            arguments["header\(index)"] = ["X-Custom: \(prefix)tokval\(index)"]
        }
        arguments["lookalikes"] = ["sky-blue", "SK-visible", "eyes", "akia", "skipped"]
        let shown = try displays(arguments)
        for index in prefixes.indices {
            #expect(shown["positional\(index)"] == "x •••", "\(prefixes[index])")
            #expect(shown["equals\(index)"] == "x --config-value=•••", "\(prefixes[index])")
            #expect(shown["pair\(index)"] == "x GITHUB=•••", "\(prefixes[index])")
            #expect(shown["header\(index)"] == "x X-Custom: •••", "\(prefixes[index])")
        }
        #expect(shown["lookalikes"] == "x sky-blue SK-visible eyes akia skipped")
        for text in shown.values {
            #expect(!text.contains("tokval"))
        }
    }

    @Test func shortPasswordFlagsMaskTheirValue() throws {
        let shown = try displays([
            "pat": ["--pat", "flagval1"],
            "patEquals": ["--pat=flagval2"],
            "pass": ["--user", "root", "--pass", "flagval3"],
            "passwd": ["--passwd", "flagval4"],
            "p": ["-u", "root", "-p", "flagval5"],
            "port": ["-p", "8080"],
            "dockerPort": ["run", "-p", "3000:3000", "image"],
            "pThenFlag": ["-p", "--verbose"],
            "lookalikes": ["--path", "/Users/a", "--compat", "v1", "-P", "2222"],
        ])
        #expect(shown["pat"] == "x --pat •••")
        #expect(shown["patEquals"] == "x --pat=•••")
        #expect(shown["pass"] == "x --user root --pass •••")
        #expect(shown["passwd"] == "x --passwd •••")
        #expect(shown["p"] == "x -u root -p •••")
        #expect(shown["port"] == "x -p 8080")
        #expect(shown["dockerPort"] == "x run -p 3000:3000 image")
        #expect(shown["pThenFlag"] == "x -p --verbose")
        #expect(shown["lookalikes"] == "x --path /Users/a --compat v1 -P 2222")
        for text in shown.values {
            #expect(!text.contains("flagval"))
        }
    }

    @Test func anArgumentWithSpacesIsMaskedWordByWord() throws {
        let shown = try displays([
            "shellToken": ["-c", "npx foo --token wsval1"],
            "shellEnv": ["-c", "GITHUB_TOKEN=wsval2 npx foo"],
            "quoted": ["-c", #"npx mcp-remote https://x/mcp --header 'Authorization: Bearer wsval3' --pass "wsval4 b""#],
            "bearerArgs": ["Bearer", "wsval5"],
            "bearerWords": ["run Bearer wsval6"],
            "headerWords": ["npx foo X-Api-Key: wsval7"],
            "mixed": ["-c", "cd /srv && API_KEY=wsval8 npx foo --mode=fast --api-key wsval9 https://u:wsval10@h/x"],
            "spacing": ["npx  foo\t--token wsval11"],
            "plain": ["-c", "npx -y @scope/server --verbose"],
        ])
        #expect(shown["shellToken"] == "x -c npx foo --token •••")
        #expect(shown["shellEnv"] == "x -c GITHUB_TOKEN=•••")
        #expect(shown["quoted"] == "x -c npx mcp-remote https://x/mcp --header Authorization: ••• --pass •••")
        #expect(shown["bearerArgs"] == "x ••• •••")
        #expect(shown["bearerWords"] == "x run ••• •••")
        #expect(shown["headerWords"] == "x npx foo X-Api-Key: •••")
        #expect(shown["mixed"] == "x -c cd /srv && API_KEY=••• npx foo --mode=fast --api-key ••• https://•••@h/x")
        #expect(shown["spacing"] == "x npx foo --token •••")
        #expect(shown["plain"] == "x -c npx -y @scope/server --verbose")
        for text in shown.values {
            #expect(!text.contains("wsval"))
        }
    }

    @Test func theWordAfterAGluedBearerIsMasked() throws {
        let shown = try displays([
            "headerGlued": ["X-Custom:Bearer zzz991"],
            "equalsGlued": ["--h=Bearer zzz992"],
            "json": [#"{"h":"X-Custom:Bearer zzz993"}"#],
            "tokenFlagThenBearer": ["-c", "npx foo --token Bearer zzz994"],
            "escapedSpace": ["-c", #"curl -H X-Custom:Bearer\ zzz995"#],
            "unescapedSpace": ["-c", "curl -H X-Custom:Bearer zzz996"],
            "separateHeader": ["X-Custom:Bearer", "zzz997"],
            "separateEquals": ["--h=Bearer", "zzz998"],
            "lowercase": ["-c", "npx foo --auth bearer zzz999"],
        ])
        #expect(shown["headerGlued"] == "x X-Custom: •••")
        #expect(shown["equalsGlued"] == "x --h=•••")
        #expect(shown["json"] == #"x {"h":"X-Custom: •••"}"#)
        #expect(shown["tokenFlagThenBearer"] == "x -c npx foo --token ••• •••")
        #expect(shown["escapedSpace"] == "x -c curl -H X-Custom: •••")
        #expect(shown["unescapedSpace"] == "x -c curl -H X-Custom: ••• •••")
        #expect(shown["separateHeader"] == "x X-Custom: ••• •••")
        #expect(shown["separateEquals"] == "x --h=••• •••")
        #expect(shown["lowercase"] == "x -c npx foo --auth ••• •••")
        for text in shown.values {
            #expect(!text.contains("zzz99"))
        }
    }

    @Test func aDeeplyNestedJSONArgumentIsMaskedWithoutParsing() throws {
        let deepObject = String(repeating: #"{"a":"#, count: 1000) + "1" + String(repeating: "}", count: 1000)
        let deepArray = String(repeating: "[", count: 1000) + String(repeating: "]", count: 1000)
        let shallow = String(repeating: #"{"a":"#, count: 10) + #""ok""# + String(repeating: "}", count: 10)
        let shown = try displays(["object": [deepObject], "array": [deepArray], "inString": [#"{"a":"\#(deepObject.replacing("\"", with: "\\\""))"}"#], "shallow": [shallow]])
        #expect(shown["object"] == "x •••")
        #expect(shown["array"] == "x •••")
        #expect(shown["inString"] == #"x {"a":"•••"}"#)
        #expect(shown["shallow"] == "x " + shallow)
    }

    @Test func aPasswordBeforeTheHostWithoutASchemeIsMasked() throws {
        let shown = try displays([
            "redis": ["--redis", "default:slval1@redis.local:6379"],
            "withPath": ["user:slval2@host:6379/db"],
            "equals": ["--url=admin:slval3@db.local/x"],
            "atInPassword": ["u:sl@val4@host"],
            "lookalikes": ["git@github.com:org/repo.git", "user@host", "host:5432", "node:20"],
        ])
        #expect(shown["redis"] == "x --redis default:•••@redis.local:6379")
        #expect(shown["withPath"] == "x user:•••@host:6379/db")
        #expect(shown["equals"] == "x --url=admin:•••@db.local/x")
        #expect(shown["atInPassword"] == "x u:•••@host")
        #expect(shown["lookalikes"] == "x git@github.com:org/repo.git user@host host:5432 node:20")
        for text in shown.values {
            #expect(!text.contains("slval") && !text.contains("val4"))
        }
    }

    @Test func urlFragmentValuesAreMasked() throws {
        let fixture = InstanceFixture()
        fixture.writeAccountFile("""
        {"mcpServers":{
           "remote":{"type":"http","url":"https://mcp.example.com/mcp#token=frval1&view=full"},
           "arg":{"command":"x","args":["https://example.com/cb#access_token=frval2"]},
           "anchor":{"type":"http","url":"https://example.com/docs#install"}}}
        """)
        let servers = try #require(fixture.scan().mcp.value)
        func display(_ name: String) throws -> String {
            try #require(servers.first { $0.name == name }).display
        }
        #expect(try display("remote") == "https://mcp.example.com/mcp#token=•••&view=•••")
        #expect(try display("arg") == "x https://example.com/cb#access_token=•••")
        #expect(try display("anchor") == "https://example.com/docs#install")
    }

    @Test func instructionsIncludeRuleSubfolders() throws {
        let fixture = InstanceFixture()
        fixture.write("Global", "CLAUDE.md")
        fixture.write("Flutter", "rules/flutter.md")
        fixture.write("Style", "rules/team/style.md")
        fixture.write("Old", "rules/.trash/old.md")
        fixture.write("Not markdown", "rules/notes.txt")
        let instructions = try #require(fixture.scan().instructions.value)
        #expect(instructions.map(\.path) == ["CLAUDE.md", "rules/flutter.md", "rules/team/style.md"])
        #expect(instructions[0].url.lastPathComponent == "CLAUDE.md")
        #expect(instructions[2].url.path.hasSuffix("rules/team/style.md"))
    }

    /// Dotfile managers often link `rules/` (or a folder in it) to a repository.
    @Test func aLinkedRulesFolderIsRead() throws {
        let fixture = InstanceFixture()
        let dotfiles = fixture.root.appending(path: "dotfiles/rules")
        try FileManager.default.createDirectory(at: dotfiles.appending(path: "team"), withIntermediateDirectories: true)
        try Data("Be terse".utf8).write(to: dotfiles.appending(path: "style.md"))
        try Data("Review".utf8).write(to: dotfiles.appending(path: "team/review.md"))
        try FileManager.default.createDirectory(at: fixture.instance.directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.instance.directory.appending(path: "rules"), withDestinationURL: dotfiles)
        let instructions = try #require(fixture.scan().instructions.value)
        #expect(instructions.map(\.path) == ["rules/style.md", "rules/team/review.md"])
        // The file's place is the instance's own path, so a removal knows which instance it belongs to.
        #expect(instructions[0].url.path == fixture.instance.directory.appending(path: "rules/style.md").path)
    }

    @Test func aLinkedFolderInsideRulesIsRead() throws {
        let fixture = InstanceFixture()
        let shared = fixture.root.appending(path: "dotfiles/team")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try Data("Review".utf8).write(to: shared.appending(path: "review.md"))
        fixture.write("Flutter", "rules/flutter.md")
        try FileManager.default.createSymbolicLink(at: fixture.instance.directory.appending(path: "rules/team"), withDestinationURL: shared)
        let instructions = try #require(fixture.scan().instructions.value)
        #expect(instructions.map(\.path) == ["rules/flutter.md", "rules/team/review.md"])
    }

    @Test func aRulesLinkLoopEnds() throws {
        let fixture = InstanceFixture()
        fixture.write("Flutter", "rules/flutter.md")
        let rules = fixture.instance.directory.appending(path: "rules")
        try FileManager.default.createSymbolicLink(at: rules.appending(path: "again"), withDestinationURL: rules)
        let instructions = try #require(fixture.scan().instructions.value)
        #expect(instructions.map(\.path) == ["rules/flutter.md"])
    }

    @Test func instructionHashFollowsTheBytes() throws {
        let first = InstanceFixture(name: "first")
        let second = InstanceFixture(name: "second")
        first.write("Same", "CLAUDE.md")
        second.write("Same", "CLAUDE.md")
        first.write("One", "rules/a.md")
        second.write("Two", "rules/a.md")
        let one = try #require(first.scan().instructions.value)
        let two = try #require(second.scan().instructions.value)
        #expect(one[0].contentHash == two[0].contentHash)
        #expect(one[1].contentHash != two[1].contentHash)
    }

    @Test func aBrokenFileMarksThatTabUnreadable() throws {
        let fixture = InstanceFixture()
        fixture.writeAccountFile("{not json")
        fixture.write("Body", "skills/a/SKILL.md")
        let setup = fixture.scan()
        #expect(setup.mcp == .unreadable)
        #expect(try #require(setup.skills.value).count == 1)
        #expect(setup.plugins == .read([]))
        #expect(setup.instructions == .read([]))
    }

    @Test func aBrokenSettingsFileMarksSkillsAndPluginsUnreadable() {
        let fixture = InstanceFixture()
        fixture.write("{not json", "settings.json")
        fixture.write("Body", "skills/a/SKILL.md")
        fixture.write("Rules", "CLAUDE.md")
        let setup = fixture.scan()
        #expect(setup.skills == .unreadable)
        #expect(setup.plugins == .unreadable)
        #expect(setup.instructions.value?.count == 1)
    }

    @Test func aBrokenInstalledPluginsFileMarksPluginsUnreadable() {
        let fixture = InstanceFixture()
        fixture.write("[]", "plugins/installed_plugins.json")
        #expect(fixture.scan().plugins == .unreadable)
    }

    @Test func anInstanceWithoutFilesIsEmptyNotUnreadable() {
        let fixture = InstanceFixture()
        let setup = fixture.scan()
        #expect(setup.skills == .read([]))
        #expect(setup.plugins == .read([]))
        #expect(setup.mcp == .read([]))
        #expect(setup.instructions == .read([]))
        #expect(setup.instance == fixture.instance)
    }
}
