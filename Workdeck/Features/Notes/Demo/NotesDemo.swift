import Foundation

/// Plays `NotesDemoScript` in the quick notes panel while demo mode runs (quick notes spec §9). Made-up lists stand
/// in for the user's and the controller saves nothing meanwhile; a note the user had typed comes back afterwards.
/// If the user's own panel is open when the script starts, the demo leaves it alone.
final class NotesDemo: DemoParticipant {
    private let controller: NotesController
    private let model: NotesPanelModel
    private let open: () -> Void
    private let close: () -> Void
    private let isOpen: () -> Bool
    private let clock: () -> Date
    /// How often the panel follows the script between the demo's one-second ticks, so the typing looks typed; nil
    /// leaves it to the ticks (tests).
    private let frameInterval: Duration?

    private var startedAt: Date?
    /// The panel shows the script.
    private(set) var isShowing = false
    /// The user's panel was open when the script would have started: this run plays nothing.
    private var isSkipped = false
    /// The note in the panel before the demo took it; kept in memory only, as the panel keeps it.
    private var userDraft: NoteDraft?
    private var animation: Task<Void, Never>?

    init(
        controller: NotesController,
        model: NotesPanelModel,
        open: @escaping () -> Void,
        close: @escaping () -> Void,
        isOpen: @escaping () -> Bool,
        clock: @escaping () -> Date = { Date() },
        frameInterval: Duration? = .milliseconds(40)
    ) {
        self.controller = controller
        self.model = model
        self.open = open
        self.close = close
        self.isOpen = isOpen
        self.clock = clock
        self.frameInterval = frameInterval
    }

    deinit {
        animation?.cancel()
    }

    var demoLength: TimeInterval {
        NotesDemoScript.startsAt + NotesDemoScript.length
    }

    func demoDidStart() {
        startedAt = clock()
        isSkipped = false
    }

    func demoTick(elapsed: TimeInterval, previous: TimeInterval?) {
        // The tick's own time anchors the animation: a demo clock that differs from ours still lines up.
        startedAt = clock().addingTimeInterval(-elapsed)
        show(at: elapsed)
        if isShowing, animation == nil, let frameInterval {
            animation = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: frameInterval)
                    guard !Task.isCancelled, let self, let startedAt = self.startedAt else { return }
                    self.show(at: self.clock().timeIntervalSince(startedAt))
                    guard self.isShowing else { return }
                }
            }
        }
    }

    func demoDidStop() {
        if isShowing {
            finish()
        }
        startedAt = nil
        isSkipped = false
    }

    // MARK: Frames

    private func show(at elapsed: TimeInterval) {
        guard !isSkipped else { return }
        guard let frame = NotesDemoScript.frame(at: elapsed - NotesDemoScript.startsAt) else {
            if isShowing {
                finish()
            }
            return
        }
        if !isShowing {
            guard !isOpen() else {
                isSkipped = true
                return
            }
            takeOver()
        }
        switch frame {
        case let .note(text, committed):
            if committed {
                guard model.draft.project?.listID != NotesDemoScript.workdeckID else { return }
                if model.draft.text != text {
                    model.textChanged(text)
                }
                if let workdeck = NotesDemoScript.lists.first(where: { $0.id == NotesDemoScript.workdeckID }) {
                    model.pickList(workdeck)
                }
            } else if model.draft.text != text || model.draft.project != nil {
                model.textChanged(text)
            }
        case let .confirmation(confirmation):
            if model.mode != .confirmation(confirmation) {
                model.showDemoConfirmation(confirmation)
            }
        }
    }

    private func takeOver() {
        isShowing = true
        userDraft = model.draft
        controller.beginDemo(lists: NotesDemoScript.lists)
        model.draft = NoteDraft(text: "", project: nil)
        open()
    }

    private func finish() {
        animation?.cancel()
        animation = nil
        isShowing = false
        close()
        if let userDraft {
            model.draft = userDraft
        }
        userDraft = nil
        controller.endDemo()
    }
}
