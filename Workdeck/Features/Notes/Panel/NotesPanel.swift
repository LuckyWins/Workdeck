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
        // A right-click does not make a window key: on a note it opens the menu whose Edit types in the line, so the
        // panel opened by hover takes the keyboard here too (polish batch spec §4.2).
        if event.type == .rightMouseDown, acceptsKey, !isKeyWindow {
            makeKey()
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
    private var host: NSHostingView<NotesPanelHost>?
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
    /// Notes opened by hover, until a click gives them the keyboard: they close on the pointer and for alerts like
    /// Sessions (polish batch spec §4.2). The pointer watch keeps it.
    var isGlancing: Bool {
        isOpen && pointerWatch.isGlancing
    }
    /// The tab the panel shows (notch tabs spec §2); Notes on every opening by the key.
    private(set) var tab: NotchTab {
        get { tabState.tab }
        set { tabState.tab = newValue }
    }
    private let tabState = PanelTabState()
    /// The notch's model, for the Sessions and Stats tabs.
    private let notchModel: LimitsNotchModel?
    /// Closes Sessions or Stats after the pointer left, as the notch collapses (notch tabs spec §1).
    private var pointerExitTask: Task<Void, Never>?
    private var pointerWatch = PanelPointerWatch()
    /// The notch's model while tabs show: only where a notch is (not with the menu bar text).
    private var tabsModel: LimitsNotchModel?
    private var isSwitching = false
    /// Whether this opening grows out of the compact notch (not when it takes over from the expanded one).
    private var grows = true
    private var switchTask: Task<Void, Never>?
    /// Orders the window out once the panel has drawn back into the notch (notes polish spec §5).
    private lazy var closing = ClosingSequence(
        delay: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : NotesPanelStyle.closeDuration
    )
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
            guard let self, PanelTabRules.closesForAlert(isOpen: isOpen, tab: tab, holdsKeyboard: !isGlancing) else { return }
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

    /// The key, or the popover's Notes row: opens the panel, or closes it when open (spec §2.1).
    func toggle(opening: PanelTabRules.Opening = .shortcut) {
        switch PanelTabRules.toggle(isOpen: isOpen, tab: tab, holdsKeyboard: !isGlancing) {
        case .open: open(opening: opening)
        case .close: close()
        case .showNotes: select(.notes)
        case .takeKeyboard: takeKeyboard()
        }
    }

    /// `takingKeyboard` false shows the panel without making it key: the demo plays in it while the user keeps typing
    /// where they were.
    /// `opening` decides whether a save closes the panel and whether Notes wait for a click to take the keyboard
    /// (polish batch spec §4).
    func open(tab: NotchTab = .notes, takingKeyboard: Bool = true, grows: Bool = true, opening: PanelTabRules.Opening = .shortcut) {
        // No display at all (Closed-Lid Mode without an external screen): there is nowhere to show the panel.
        guard !isOpen, let screen = Self.screenUnderPointer() else { return }
        // Opened again while drawing back: gone at once, then it grows afresh; the notch stays hidden.
        closing.cutShort()
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
        model.returnsAfterSave = PanelTabRules.returnsAfterSave(opening)
        pointerWatch.opened(on: self.tab, holdsKeyboard: PanelTabRules.takesKeyboard(opening))
        self.grows = grows
        model.willOpen()
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
        if takingKeyboard, !pointerWatch.isGlancing, self.tab == .notes {
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

    private func makeView(on screen: NSScreen) -> NotesPanelHost {
        NotesPanelHost(
            state: tabState, model: model, notchModel: tabsModel, topInset: Self.topInset(of: screen),
            closedSize: NotesPanelStyle.closedShapeSize(notchWidth: Self.notchWidth(of: screen), topInset: Self.topInset(of: screen)),
            opening: openings, grows: grows,
            // A click on a tab is the one choice hover remembers (polish batch spec §4.1).
            onSelectTab: { [weak self] tab in
                self?.notchModel?.pickedTab = tab
                self?.select(tab)
            },
            onHover: { [weak self] inside in self?.pointerInside(inside) },
            onSize: { [weak self] size in self?.fit(size) },
            onMorph: { [weak self] in self?.beginSwitch() }
        )
    }

    /// The Notes icon in the hover notch (notch tabs spec §4): the panel takes the notch's place on the same tab and
    /// size, without growing, then switches to Notes with the usual size animation once that first frame is up.
    func openFromNotch() {
        guard !isOpen else { return }
        open(tab: PanelTabRules.handOverStart(notchTab: notchModel?.tab ?? .sessions), takingKeyboard: false, grows: false, opening: .notchTab)
        guard isOpen else { return }
        guard tab != .notes else {
            // No tabs here (no notch screen): Notes straight away.
            panel?.makeKey()
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            self?.select(.notes)
        }
    }

    /// Notes opened by hover take the keyboard, the note field first (the shortcut, polish batch spec §4.2).
    private func takeKeyboard() {
        guard isOpen, isGlancing, let panel else { return }
        panel.makeKey()
        if let field = Self.noteField(in: panel.contentView) {
            panel.makeFirstResponder(field)
        }
    }

    /// Hover on the notch while Notes is the picked tab: the panel grows out of the notch on Notes, showing the open
    /// notes, but the user's app keeps the keyboard until a click in the panel (polish batch spec §4.2).
    func openFromHover() -> Bool {
        guard !isOpen else { return false }
        open(tab: .notes, takingKeyboard: false, opening: .hover)
        return isOpen
    }

    /// A click on a tab icon. Notes takes the keyboard again with the note as it was; Sessions and Stats give it back
    /// and close when the pointer leaves, and alerts that waited for the note show now (notch tabs spec §4, §6).
    func select(_ tab: NotchTab) {
        guard isOpen, tab != self.tab, tabsModel != nil else { return }
        perform(pointerWatch.selected(tab))
        panel?.acceptsKey = PanelTabRules.acceptsKey(tab)
        beginSwitch()
        // The view animates the shape to the new tab's size (`NotesPanelView`); the content switches at once.
        self.tab = tab
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

    /// While the content animates to its new size the window keeps the taller of both, then fits the content again.
    private func beginSwitch() {
        guard isOpen else { return }
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
                guard let self, !Task.isCancelled, isOpen, !pointerWatch.holdsKeyboard else { return }
                close()
            }
        case .close:
            close()
        }
    }

    /// Closes at once for the rest of the app (the keyboard goes back) while the panel draws back into the notch as it
    /// looked (notes polish spec §5); the window goes, the note's state resets and the notch shows again after that.
    func close() {
        guard isOpen else { return }
        // First, before the resets below change what the view would draw.
        tabState.closingLook = PanelLook(tab: tab, mode: model.mode)
        isOpen = false
        tab = .notes
        pointerWatch.reset()
        pointerExitTask?.cancel()
        pointerExitTask = nil
        switchTask?.cancel()
        switchTask = nil
        isSwitching = false
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
        if let panel {
            panel.ignoresMouseEvents = true
            panel.acceptsKey = false
            if panel.isKeyWindow {
                // Out and in again: the keyboard goes back to the app the user typed in while the panel shrinks.
                isReleasingKey = true
                panel.orderOut(nil)
                panel.orderFrontRegardless()
                isReleasingKey = false
            }
        }
        model.willClose()
        if NSApp.isActive, let previousApp, previousApp != NSRunningApplication.current {
            previousApp.activate()
        }
        previousApp = nil
        closing.start { [weak self] showsNotch in self?.finishClose(showsNotch: showsNotch) }
    }

    /// The window goes and the note's state resets; the notch shows again unless the panel is opening anew.
    private func finishClose(showsNotch: Bool) {
        panel?.orderOut(nil)
        panel?.ignoresMouseEvents = false
        tabState.closingLook = nil
        model.closed()
        if showsNotch {
            composer?.setSuspended(false)
        }
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
        let target = Self.panelFrame(content: size, on: screen.frame, keepingHeight: isSwitching ? panel.frame.height : 0)
        if panel.frame != target {
            panel.setFrame(target, display: true)
        }
    }

    /// The window at the top centre of the screen, as tall as the content (or `keepingHeight` while a spring runs) and
    /// always as wide as Notes: the shape grows and shrinks inside it. A window that changed its width with the content
    /// showed the old layout at its left for a frame, so a morph seemed to start from the left edge; the clear sides
    /// let clicks through.
    nonisolated static func panelFrame(content: CGSize, on screen: CGRect, keepingHeight: CGFloat = 0) -> CGRect {
        let width = max(content.width, NotesPanelStyle.width)
        let height = max(content.height, keepingHeight)
        return CGRect(x: (screen.midX - width / 2).rounded(), y: screen.maxY - height, width: width, height: height)
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
        // Text typed during a save's "Saved" that leads back to the line starts the next note.
        if case .confirmation = model.mode, let text = Self.typedText(event), model.typeDuringConfirmation(text) {
            return true
        }
        // Nothing else is typed outside the field; ⌘⇧↩ is not ⌘↩ (the picker and the prompt ignore it).
        guard let key = NoteKeyCommand.panelKey(keyCode: event.keyCode, modifiers: event.modifierFlags) else { return true }
        if model.handleImmediately(key) == nil {
            Task { [model] in _ = await model.handle(key) }
        }
        return true
    }

    // MARK: NSWindowDelegate

    /// A click in Notes opened by hover: from now on they hold the keyboard as Notes do.
    func windowDidBecomeKey(_ notification: Notification) {
        guard isGlancing else { return }
        perform(pointerWatch.tookKeyboard())
    }

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

    /// What a key types, if it types text: no ⌘, ⌃ or ⌥ chord, no control character, no arrow or function key.
    private static func typedText(_ event: NSEvent) -> String? {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty, let text = event.characters,
              !text.isEmpty else { return nil }
        let isText = text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !(0xF700 ... 0xF8FF).contains($0.value) }
        return isText ? text : nil
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

    /// The camera housing's width, else the virtual notch DynamicNotchKit draws: where the closing panel goes.
    static func notchWidth(of screen: NSScreen) -> CGFloat {
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return screen.frame.width - left.width - right.width
        }
        return NotchPeekZone.virtualNotchWidth
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
