import Foundation

/// The end of the panel's closing animation (notes polish spec §5): `finish` runs once, with `true` after the delay
/// (the notch shows again), or with `false` at once when the panel opens again meanwhile (the notch stays hidden).
/// No delay (Reduce Motion) finishes at once.
final class ClosingSequence {
    private let delay: Duration?
    private var task: Task<Void, Never>?
    private var finish: ((Bool) -> Void)?

    init(delay: Duration?) {
        self.delay = delay
    }

    var isRunning: Bool { finish != nil }

    func start(finish: @escaping (_ showsNotch: Bool) -> Void) {
        cutShort()
        guard let delay else {
            finish(true)
            return
        }
        self.finish = finish
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.end(showsNotch: true)
        }
    }

    /// The panel opens again while closing: the window goes now, the notch stays hidden.
    func cutShort() {
        end(showsNotch: false)
    }

    private func end(showsNotch: Bool) {
        task?.cancel()
        task = nil
        guard let finish else { return }
        self.finish = nil
        finish(showsNotch)
    }
}
