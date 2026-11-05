import AppKit
import Observation

/// What sending feedback needs from the system (feedback spec §2.1), behind a protocol so it is tested with a fake.
/// Nothing here sends: it opens a mail app, shows a file or fills the clipboard; the user presses Send.
@MainActor
protocol FeedbackSystem {
    /// The bundle identifier of the app that opens `mailto:` links, or nil when none does.
    func defaultMailApp() -> String?
    func mailCanCompose(items: [Any]) -> Bool
    func composeMail(recipients: [String], subject: String, items: [Any])
    func open(_ url: URL)
    func reveal(_ file: URL)
    func copy(_ text: String)
}

/// Opens a feedback email to the developer with the diagnostics, by the user's mail app (feedback spec §2.1).
@Observable
@MainActor
final class FeedbackSender {
    private(set) var isPreparing = false
    /// A line under the button after the mailto or clipboard routes; it clears after a while.
    private(set) var status: String?
    /// Clears `status`; exposed so tests can await it.
    @ObservationIgnored private(set) var statusTask: Task<Void, Never>?

    @ObservationIgnored private let system: any FeedbackSystem
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private let report: @Sendable () async -> String
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private let macOS: String
    @ObservationIgnored private let model: String
    @ObservationIgnored private let clearAfter: Duration

    static let mailStatus = "If Mail asks for an account, the address and the diagnostics are on the clipboard."
    static let otherAppStatus = "Attach \(FeedbackMail.fileName) from Finder, or paste the diagnostics into the email."
    static let clipboardOnlyStatus = "Paste the diagnostics from the clipboard into the email."
    static let noAppStatus = "No mail app is set up. The address and the diagnostics are on the clipboard."

    init(
        system: any FeedbackSystem,
        folder: URL,
        report: @escaping @Sendable () async -> String,
        appVersion: String,
        macOS: String,
        model: String,
        clearAfter: Duration = .seconds(8)
    ) {
        self.system = system
        self.folder = folder
        self.report = report
        self.appVersion = appVersion
        self.macOS = macOS
        self.model = model
        self.clearAfter = clearAfter
    }

    func send() async {
        guard !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        let text = await report()
        let body = FeedbackMail.body(appVersion: appVersion, macOS: macOS, model: model)
        let file = write(text)
        let items: [Any] = file.map { [body, $0] } ?? [body]
        switch FeedbackMail.route(defaultMailApp: system.defaultMailApp(), mailCanCompose: file != nil && system.mailCanCompose(items: items)) {
        case .mailWithAttachment:
            system.composeMail(recipients: [FeedbackMail.address], subject: FeedbackMail.subject, items: items)
            // Mail stays the default on a Mac where it was never set up, and then asks for an account instead.
            system.copy("\(FeedbackMail.address)\n\n\(text)")
            show(Self.mailStatus)
        case .otherMailApp:
            system.open(FeedbackMail.mailtoURL(body: body))
            system.copy(text)
            if let file {
                system.reveal(file)
                show(Self.otherAppStatus)
            } else {
                show(Self.clipboardOnlyStatus)
            }
        case .noMailApp:
            system.copy("\(FeedbackMail.address)\n\n\(text)")
            show(Self.noAppStatus)
        }
    }

    /// The report as a file only the user can read; nil when it cannot be written.
    private func write(_ text: String) -> URL? {
        let file = folder.appending(path: FeedbackMail.fileName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Created with its permissions, never readable by others even for a moment; an earlier copy is replaced.
            try? FileManager.default.removeItem(at: file)
            guard FileManager.default.createFile(atPath: file.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
                return nil
            }
            return file
        } catch {
            return nil
        }
    }

    private func show(_ text: String) {
        status = text
        statusTask?.cancel()
        statusTask = Task { [clearAfter] in
            try? await Task.sleep(for: clearAfter)
            guard !Task.isCancelled else { return }
            status = nil
        }
    }
}

/// The real system: Launch Services for the `mailto:` handler, Mail's sharing service, Finder and the clipboard.
@MainActor
struct SystemFeedbackSystem: FeedbackSystem {
    func defaultMailApp() -> String? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "mailto:\(FeedbackMail.address)")!) else { return nil }
        return Bundle(url: app)?.bundleIdentifier
    }

    func mailCanCompose(items: [Any]) -> Bool {
        NSSharingService(named: .composeEmail)?.canPerform(withItems: items) ?? false
    }

    func composeMail(recipients: [String], subject: String, items: [Any]) {
        guard let service = NSSharingService(named: .composeEmail) else { return }
        service.recipients = recipients
        service.subject = subject
        service.perform(withItems: items)
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func reveal(_ file: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
