import Foundation
import Testing
@testable import Workdeck

/// The feedback email's text, its `mailto:` form and how it is sent (feedback spec §2.1).
@Suite
struct FeedbackMailTests {
    @Test func bodyIsExact() {
        #expect(FeedbackMail.body(appVersion: "1.1.5 (7)", macOS: "27.0.1", model: "Mac16,7") == """
        Hi,

        [Write what happened or what you would like here.]


        —
        Workdeck 1.1.5 (7)
        macOS 27.0.1, Mac16,7
        """)
    }

    @Test func mailtoKeepsEveryCharacter() throws {
        // Non-ASCII letters too: they are percent-encoded, not left raw.
        let body = "a & b ? c # d + e = f % g\nsecond line — café\n\nthird"
        let url = FeedbackMail.mailtoURL(body: body)
        #expect(url.scheme == "mailto")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "andreu.puzikov.21@gmail.com")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["subject"] == "Workdeck feedback")
        #expect(items["body"] == body)
        // `+` must stay a plus for mail apps that decode the body as a form.
        #expect(!url.absoluteString.contains("+"))
        #expect(!url.absoluteString.contains("café"))
    }

    @Test func routesByTheDefaultMailApp() {
        #expect(FeedbackMail.route(defaultMailApp: "com.apple.mail", mailCanCompose: true) == .mailWithAttachment)
        #expect(FeedbackMail.route(defaultMailApp: "com.apple.mail", mailCanCompose: false) == .otherMailApp)
        #expect(FeedbackMail.route(defaultMailApp: "com.microsoft.Outlook", mailCanCompose: true) == .otherMailApp)
        #expect(FeedbackMail.route(defaultMailApp: nil, mailCanCompose: true) == .noMailApp)
    }

    @Test func theModelIsReadFromTheSystem() {
        #expect(!FeedbackMail.modelIdentifier().isEmpty)
    }
}
