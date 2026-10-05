import Foundation

protocol ThermalMonitoring: AnyObject {
    var current: ProcessInfo.ThermalState { get }
    var onChange: ((ProcessInfo.ThermalState) -> Void)? { get set }
}

final class ThermalMonitor: ThermalMonitoring {
    var onChange: ((ProcessInfo.ThermalState) -> Void)?
    private var observer: (any NSObjectProtocol)?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onChange?(self.current)
            }
        }
    }

    var current: ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }
}
