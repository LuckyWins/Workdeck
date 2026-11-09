import AppKit
import SwiftUI

/// The borderless, non-activating panel a quick note is typed in: it takes the keyboard while the app that was active
/// stays active, its menu bar included (quick notes spec §3).
final class NotesPanel: NSPanel {
    /// Keys while the note field does not have them (picker, folder prompt, confirmation); true when handled.
    var keyHandler: ((NSEvent) -> Bool)?

    init() {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        // After `isFloatingPanel`, which resets the level to `.floating`: below the menu bar the window server moves
        // the panel down under it instead of letting it grow out of the notch.
        level = Self.panelLevel
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
    }

    /// Only Notes takes the keyboard: a click in Sessions or Stats leaves it where the user typed (notch tabs spec §4).
    var acceptsKey = true

    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }

    /// Above the menu bar and its status items, so the panel covers the menu bar under the notch.
    static let panelLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true {
            return
        }
        super.sendEvent(event)
    }
}

/// Opens and closes the quick notes panel: on the screen with the pointer, its top edge at the screen's top, the
/// notch hidden meanwhile. A click outside (the panel resigns key), Esc or the key closes it, and the app that was
/// active before is active again.
final class NotesPanelPresenter: NSObject, NSWindowDelegate {
    let model: NotesPanelModel
    private weak var composer: NotchComposer?
    private var panel: NotesPanel?
    private var host: NSHostingView<NotesPanelView>?
    private var screen: NSScreen?
    /// The folder chooser is up: the panel resigning key does not close it.
    private var isChoosingFolder = false
    /// The panel gives the keyboard back while a confirmation shows; resigning key then does not close it.
    private var isReleasingKey = false
    /// Counts openings: each one starts the panel's grow animation afresh.
    private var openings = 0
    /// The app that was active when the panel opened; reactivated if Workdeck took over (the folder chooser, the
    /// popover's Notes row).
    private var previousApp: NSRunningApplication?
    /// The last app other than Workdeck that became active: the one the user was in before opening the popover.
    private var lastOtherApp: NSRunningApplication?
    private var activationObserver: (any NSObjectProtocol)?
    private(set) var isOpen = false
    /// The tab the panel shows (notch tabs spec §2); Notes on every opening by the key.
    private(set) var tab: NotchTab = .notes
    /// The notch's model, for the Sessions and Stats tabs.
    private let notchModel: LimitsNotchModel?
    /// Closes Sessions or Stats after the pointer left, as the notch collapses (notch tabs spec §1).
    private var pointerExitTask: Task<Void, Never>?
    private var pointerWatch = PanelPointerWatch()
    /// The notch's model while tabs show: only where a notch is (not with the menu bar text).
    private var tabsModel: LimitsNotchModel?
    private var isSwitching = false
    private var switchTask: Task<Void, Never>?
    /// The content's last reported size, fitted once a tab switch's animation is over.
    private var lastSize = CGSize.zero
    /// Clicks in other apps while the panel is open: Sessions and Stats close on them (the panel is not key there, so
    /// resigning key cannot tell).
    private var clickMonitor: Any?
    /// The notch's hover exit delay.
    static let pointerExitDelay: Duration = .milliseconds(500)

    init(model: NotesPanelModel, composer: NotchComposer?, notchModel: LimitsNotchModel? = nil) {
        self.model = model
        self.composer = composer
        self.notchModel = notchModel
        super.init()
        // While Notes has the keyboard alerts wait; on the other tabs the panel steps aside for them (spec §6).
        composer?.onSuspendedAlert = { [weak self] in
            guard let self, PanelTabRules.closesForAlert(isOpen: isOpen, tab: tab) else { return }
            close()
        }
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            lastOtherApp = front
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { @Sendable [weak self] notification in
            // Only the process identifier crosses over: the notification is not sendable.
            guard let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier else { return }
            MainActor.assumeIsolated {
                guard let app = NSRunningApplication(processIdentifier: pid), app != NSRunningApplication.current else { return }
                self?.lastOtherApp = app
            }
        }
        model.onClose = { [weak self] in
            guard let self, PanelTabRules.noteClosesPanel(tab: tab) else { return }
            close()
        }
        model.chooseFolderWithPanel = { [weak self] in await self?.chooseFolder() }
        model.onConfirm = { [weak self] closesPanel in
            if closesPanel {
                self?.releaseKeyboard()
            }
        }
    }

    /// The key: opens the panel, or closes it when open (spec §2.1).
    func toggle() {
        switch PanelTabRules.toggle(isOpen: isOpen, tab: tab) {
        case .open: open()
        case .close: close()
        case .showNotes: select(.notes)
        }
    }

    /// `takingKeyboard` false shows the panel without making it key: the demo plays in it while the user keeps typing
    /// where they were.
    func open(tab: NotchTab = .notes, takingKeyboard: Bool = true) {
        // No display at all (Closed-Lid Mode without an external screen): there is nowhere to show the panel.
        guard !isOpen, let screen = Self.screenUnderPointer() else { return }
        self.screen = screen
        let current = NSRunningApplication.current
        previousApp = Self.returnApp(
            frontmost: NSWorkspace.shared.frontmostApplication, workdeck: current, lastOther: lastOtherApp,
            workdeckWindowShown: Self.isWorkdeckWindowShown(besides: panel)
        )
        let panel = panel ?? makePanel()
        openings += 1
        tabsModel = PanelTabRules.tabsModel(notchModel, hasNotchScreen: composer?.hasNotchScreen ?? false)
        self.tab = tabsModel == nil ? .notes : tab
        panel.acceptsKey = PanelTabRules.acceptsKey(self.tab)
        pointerWatch.opened(on: self.tab)
        let view = makeView(on: screen)
        if let host {
            host.rootView = view
        } else {
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []
            panel.contentView = host
            self.host = host
        }
        isOpen = true
        composer?.setSuspended(true)
        fit(host?.fittingSize ?? CGSize(width: NotesPanelStyle.width, height: 120))
        panel.orderFrontRegardless()
        if takingKeyboard, self.tab == .notes {
            panel.makeKey()
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isOpen else { return }
                self.perform(self.pointerWatch.clickOutside())
            }
        }
        Task { await model.opened() }
    }

    private func makeView(on screen: NSScreen) -> NotesPanelView {
        NotesPanelView(
            model: model, notchModel: tabsModel, tab: tab, topInset: Self.topInset(of: screen), opening: openings,
            onSelectTab: { [weak self] tab in self?.select(tab) },
            onHover: { [weak self] inside in self?.pointerInside(inside) }
        ) { [weak self] size in
            self?.fit(size)
        }
    }

    /// A click on a tab icon. Notes takes the keyboard again with the note as it was; Sessions and Stats give it back
    /// and close when the pointer leaves, and alerts that waited for the note show now (notch tabs spec §4, §6).
    func select(_ tab: NotchTab) {
        guard isOpen, tab != self.tab, tabsModel != nil, let screen else { return }
        self.tab = tab
        perform(pointerWatch.selected(tab))
        panel?.acceptsKey = PanelTabRules.acceptsKey(tab)
        beginSwitch()
        host?.rootView = makeView(on: screen)
        if tab == .notes {
            guard let panel else { return }
            panel.makeKey()
            if let field = Self.noteField(in: panel.contentView) {
                panel.makeFirstResponder(field)
            }
        } else {
            releaseKeyboard()
            if PanelTabRules.reactivatesPreviousApp(switchingTo: tab, workdeckIsActive: NSApp.isActive),
               let previousApp, previousApp != NSRunningApplication.current {
                previousApp.activate()
            }
            if composer?.hasWaitingAlerts == true {
                close()
            }
        }
    }

    /// While the content animates to the new tab's size the window keeps the larger of both, so nothing is clipped;
    /// it fits the final size once the animation is over.
    private func beginSwitch() {
        isSwitching = true
        switchTask?.cancel()
        switchTask = Task { [weak self] in
            try? await Task.sleep(for: NotesPanelStyle.tabSwitchDuration + .milliseconds(50))
            guard let self, !Task.isCancelled else { return }
            isSwitching = false
            fit(lastSize)
        }
    }

    /// Away from Notes, the panel closes once the pointer has been off it for the notch's exit delay.
    private func pointerInside(_ inside: Bool) {
        guard isOpen else { return }
        perform(pointerWatch.pointer(inside: inside))
    }

    private func perform(_ action: PanelPointerWatch.Action) {
        switch action {
        case .none:
            break
        case .cancelExit:
            pointerExitTask?.cancel()
            pointerExitTask = nil
        case .armExit:
            pointerExitTask?.cancel()
            pointerExitTask = Task { [weak self] in
                try? await Task.sleep(for: Self.pointerExitDelay)
                guard let self, !Task.isCancelled, isOpen, !tab.waitsForAlerts else { return }
                close()
            }
        case .close:
            close()
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        tab = .notes
        pointerExitTask?.cancel()
        pointerExitTask = nil
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
        panel?.orderOut(nil)
        model.closed()
        composer?.setSuspended(false)
        if NSApp.isActive, let previousApp, previousApp != NSRunningApplication.current {
            previousApp.activate()
        }
        previousApp = nil
    }

    private func makePanel() -> NotesPanel {
        let panel = NotesPanel()
        panel.delegate = self
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        self.panel = panel
        return panel
    }

    /// The window takes the content's size, centered at the top of its screen.
    private func fit(_ size: CGSize) {
        lastSize = size
        guard let panel, let screen, size.width > 0, size.height > 0 else { return }
        var size = size
        if isSwitching {
            size = CGSize(width: max(size.width, panel.frame.width), height: max(size.height, panel.frame.height))
        }
        let frame = screen.frame
        let target = CGRect(x: (frame.midX - size.width / 2).rounded(), y: frame.maxY - size.height, width: size.width, height: size.height)
        if panel.frame != target {
            panel.setFrame(target, display: true)
        }
    }

    /// A confirmation that ends in closing stays on screen, but the keyboard goes back to the app the user typed in:
    /// out and in again without becoming key.
    private func releaseKeyboard() {
        guard isOpen, let panel, panel.isKeyWindow else { return }
        isReleasingKey = true
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        isReleasingKey = false
    }

    /// Outside the note field (picker, folder prompt, confirmation) the arrows, Return and Esc still drive the panel.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard model.mode != .typing else {
            // A click on a row may have taken the first responder: the field gets the keys back.
            if let panel, !(panel.firstResponder is NoteNSTextView), let field = Self.noteField(in: panel.contentView) {
                panel.makeFirstResponder(field)
            }
            return false
        }
        // Nothing else is typed outside the field; ⌘⇧↩ is not ⌘↩ (the picker and the prompt ignore it).
        guard let key = NoteKeyCommand.panelKey(keyCode: event.keyCode, modifiers: event.modifierFlags) else { return true }
        if model.handleImmediately(key) == nil {
            Task { [model] in _ = await model.handle(key) }
        }
        return true
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // A save in flight may have brought up the Reminders access prompt: the panel waits for it. Sessions and Stats
        // do not hold the keyboard: the pointer leaving closes them.
        guard tab == .notes, !isChoosingFolder, !isReleasingKey, !model.isBusy else { return }
        // A confirmation that closes the panel goes on its own when its time is up.
        if case .confirmation = model.mode, model.confirmationClosesPanel {
            return
        }
        close()
    }

    private static func noteField(in view: NSView?) -> NoteNSTextView? {
        guard let view else { return nil }
        if let field = view as? NoteNSTextView {
            return field
        }
        for subview in view.subviews {
            if let field = noteField(in: subview) {
                return field
            }
        }
        return nil
    }

    // MARK: Folder chooser

    private func chooseFolder() async -> String? {
        isChoosingFolder = true
        // Out of the way while the chooser is up: the panel sits above ordinary windows, the chooser among them.
        panel?.orderOut(nil)
        defer {
            isChoosingFolder = false
            if isOpen, let panel {
                panel.orderFrontRegardless()
                panel.makeKey()
            }
        }
        let chooser = NSOpenPanel()
        chooser.canChooseDirectories = true
        chooser.canChooseFiles = false
        chooser.allowsMultipleSelection = false
        chooser.canCreateDirectories = true
        chooser.prompt = "Use Folder"
        chooser.message = "Where should the agent start?"
        chooser.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        NSApp.activate()
        let response = chooser.runModal()
        return response == .OK ? chooser.url?.path : nil
    }

    /// The app to make active again when the panel closes: the one in front when it opened; when that is Workdeck
    /// itself (the popover's Notes row), the app the user was in before, unless one of Workdeck's windows is open
    /// (the user was working there).
    nonisolated static func returnApp<App: Equatable>(
        frontmost: App?, workdeck: App, lastOther: App?, workdeckWindowShown: Bool
    ) -> App? {
        if let frontmost, frontmost != workdeck {
            return frontmost
        }
        return workdeckWindowShown ? nil : lastOther
    }

    /// Settings, Statistics, Chats, Instances or Release Notes is on screen: ordinary titled windows, unlike the
    /// popover, the notch and this panel (panels, or above the normal level).
    private static func isWorkdeckWindowShown(besides panel: NSWindow?) -> Bool {
        NSApp.windows.contains { window in
            window !== panel && window.isVisible && !window.isMiniaturized && window.styleMask.contains(.titled)
                && !(window is NSPanel) && window.level == .normal
        }
    }

    // MARK: Placement

    /// The screen with the pointer (spec §3: where the user is working); nil without any screen.
    static func screenUnderPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// The notch's height on a screen with a camera housing, else the menu bar's: the content starts below it.
    static func topInset(of screen: NSScreen) -> CGFloat {
        if screen.safeAreaInsets.top > 0 {
            return screen.safeAreaInsets.top
        }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return menuBar > 0 ? menuBar : NSStatusBar.system.thickness
    }
}
