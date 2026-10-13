import Testing
@testable import Workdeck

struct TerminalTabTests {
    @Test func terminalScriptSelectsTheTabWithTheTTY() throws {
        let source = try #require(TerminalTabScript.source(forBundleID: "com.apple.Terminal", tty: "/dev/ttys003"))
        #expect(source.contains(#"tell application id "com.apple.Terminal""#))
        // Windows are held by ID: restoring or raising one reorders them, which would move a reference by position.
        #expect(source.contains("set windowIDs to id of every window"))
        #expect(source.contains(#"(tty of tab tabIndex of window id windowID) is "/dev/ttys003""#))
        #expect(source.contains("set miniaturized of window id windowID to false"))
        #expect(source.contains("set selected of tab tabIndex of window id windowID to true"))
        #expect(source.contains("set index of window id windowID to 1"))
        // A tab that cannot be read (e.g. closing) does not end the search.
        #expect(source.contains("on error"))
        #expect(source.contains("with timeout of 5 seconds"))
    }

    @Test func iTermScriptSelectsTheSessionWithTheTTY() throws {
        let source = try #require(TerminalTabScript.source(forBundleID: "com.googlecode.iterm2", tty: "/dev/ttys012"))
        #expect(source.contains(#"tell application id "com.googlecode.iterm2""#))
        #expect(source.contains("set windowIDs to id of every window"))
        #expect(source.contains(#"(tty of session sessionIndex of tab tabIndex of window id windowID) is "/dev/ttys012""#))
        // A minimized iTerm2 window is restored first; if iTerm2 lacks the property, the search goes on.
        #expect(source.contains("set miniaturized of window id windowID to false"))
        #expect(source.contains("select window id windowID"))
        #expect(source.contains("select tab tabIndex of window id windowID"))
        #expect(source.contains("select session sessionIndex of tab tabIndex of window id windowID"))
        #expect(source.contains("on error"))
        #expect(source.contains("with timeout of 5 seconds"))
    }

    @Test(arguments: ["", "ttys003", "/dev/ttys", "/dev/tty003", "/dev/console", #"/dev/ttys003" then do shell script "x"#, "/dev/ttys003\n"])
    func otherTTYsGetNoScript(tty: String) {
        #expect(TerminalTabScript.source(forBundleID: "com.apple.Terminal", tty: tty) == nil)
        #expect(TerminalTabScript.source(forBundleID: "com.googlecode.iterm2", tty: tty) == nil)
    }

    @Test func otherAppsGetNoScript() {
        #expect(TerminalTabScript.source(forBundleID: "com.mitchellh.ghostty", tty: "/dev/ttys003") == nil)
        #expect(TerminalTabScript.source(forBundleID: "com.microsoft.VSCode", tty: "/dev/ttys003") == nil)
    }

    @Test func aMissingProcessHasNoTTY() {
        #expect(ProcessTTY.path(of: 99_999) == nil)
        #expect(ProcessTTY.path(of: -1) == nil)
    }
}
