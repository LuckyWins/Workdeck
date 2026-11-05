import Foundation
import Testing
@testable import Workdeck

/// Records what sending feedback asked the system to do; it never sends anything itself.
@MainActor
private final class FakeFeedbackSystem: FeedbackSystem {
    var mailApp: String?
    var canCompose = true
    private(set) var composed: (recipients: [String], subject: String, items: [Any])?
    private(set) var opened: [URL] = []
    private(set) var revealed: [URL] = []
    private(set) var copied: [String] = []

    func defaultMailApp() -> String? { mailApp }
    func mailCanCompose(items: [Any]) -> Bool { canCompose }
    func composeMail(recipients: [String], subject: String, items: [Any]) { composed = (recipients, subject, items) }
    func open(_ url: URL) { opened.append(url) }
    func reveal(_ file: URL) { revealed.append(file) }
    func copy(_ text: String) { copied.append(text) }
}

@MainActor
@Suite
struct FeedbackSenderTests {
    private let folder = makeTemporaryDirectory()
    private let report = "Workdeck diagnostics\nsession orbit-app"

    private func sender(_ system: FakeFeedbackSystem, clearAfter: Duration = .seconds(60)) -> FeedbackSender {
        FeedbackSender(
            system: system, folder: folder, report: { [report] in report },
            appVersion: "1.1.5 (7)", macOS: "27.0.1", model: "Mac16,7", clearAfter: clearAfter
        )
    }

    private var file: URL { folder.appending(path: FeedbackMail.fileName) }

    @Test func mailComposesWithTheReportAttached() async throws {
        let system = FakeFeedbackSystem()
        system.mailApp = "com.apple.mail"
        await sender(system).send()
        let composed = try #require(system.composed)
        #expect(composed.recipients == ["andreu.puzikov.21@gmail.com"])
        #expect(composed.subject == "Workdeck feedback")
        #expect(composed.items.first as? String == FeedbackMail.body(appVersion: "1.1.5 (7)", macOS: "27.0.1", model: "Mac16,7"))
        #expect(composed.items.last as? URL == file)
        #expect(try String(contentsOf: file, encoding: .utf8) == report)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(system.opened.isEmpty)
    }

    /// Mail stays the default mail app on a Mac where it was never set up; it then asks for an account instead of
    /// composing, so the address and the diagnostics wait on the clipboard (final review).
    @Test func theMailRouteAlsoLeavesTheAddressAndReportOnTheClipboard() async {
        let system = FakeFeedbackSystem()
        system.mailApp = "com.apple.mail"
        let sender = sender(system)
        await sender.send()
        #expect(system.copied == ["andreu.puzikov.21@gmail.com\n\n\(report)"])
        #expect(sender.status == "If Mail asks for an account, the address and the diagnostics are on the clipboard.")
    }

    @Test func anotherMailAppOpensMailtoAndShowsTheFile() async {
        let system = FakeFeedbackSystem()
        system.mailApp = "com.microsoft.Outlook"
        let sender = sender(system)
        await sender.send()
        #expect(system.composed == nil)
        #expect(system.opened.map(\.scheme) == ["mailto"])
        #expect(system.revealed == [file])
        #expect(system.copied == [report])
        #expect(sender.status == "Attach Workdeck-diagnostics.txt from Finder, or paste the diagnostics into the email.")
    }

    @Test func whenTheFileCannotBeWrittenTheLineSaysClipboard() async throws {
        // A file where the folder should be: the report cannot be written there.
        let blocked = folder.appending(path: "blocked")
        try Data().write(to: blocked)
        let system = FakeFeedbackSystem()
        system.mailApp = "com.microsoft.Outlook"
        let sender = FeedbackSender(
            system: system, folder: blocked, report: { [report] in report },
            appVersion: "1.1.5 (7)", macOS: "27.0.1", model: "Mac16,7", clearAfter: .seconds(60)
        )
        await sender.send()
        #expect(system.revealed.isEmpty)
        #expect(system.copied == [report])
        #expect(sender.status == "Paste the diagnostics from the clipboard into the email.")
    }

    @Test func mailWithoutAnAccountTakesTheMailtoRoute() async {
        let system = FakeFeedbackSystem()
        system.mailApp = "com.apple.mail"
        system.canCompose = false
        await sender(system).send()
        #expect(system.composed == nil)
        #expect(system.opened.count == 1)
    }

    @Test func noMailAppPutsAddressAndReportOnTheClipboard() async {
        let system = FakeFeedbackSystem()
        system.mailApp = nil
        let sender = sender(system)
        await sender.send()
        #expect(system.composed == nil && system.opened.isEmpty)
        #expect(system.copied == ["andreu.puzikov.21@gmail.com\n\n\(report)"])
        #expect(sender.status == "No mail app is set up. The address and the diagnostics are on the clipboard.")
    }

    @Test func theStatusClears() async {
        let system = FakeFeedbackSystem()
        let sender = sender(system, clearAfter: .zero)
        await sender.send()
        await sender.statusTask?.value
        #expect(sender.status == nil)
        #expect(!sender.isPreparing)
    }
}
