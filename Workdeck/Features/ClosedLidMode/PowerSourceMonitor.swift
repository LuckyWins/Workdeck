import Foundation
import IOKit.ps

protocol PowerSourceMonitoring: AnyObject {
    var current: PowerSnapshot { get }
    var onChange: ((PowerSnapshot) -> Void)? { get set }
}

/// Publishes battery level and power source changes from IOKit.
final class PowerSourceMonitor: PowerSourceMonitoring {
    var onChange: ((PowerSnapshot) -> Void)?
    private var runLoopSource: CFRunLoopSource?

    init() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                monitor.onChange?(monitor.current)
            }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
    }

    isolated deinit {
        if let runLoopSource {
            CFRunLoopSourceInvalidate(runLoopSource)
        }
    }

    var current: PowerSnapshot {
        Self.readSnapshot()
    }

    static func readSnapshot() -> PowerSnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return PowerSnapshot(isOnBattery: false, batteryPercent: nil)
        }
        let providingType = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let isOnBattery = providingType == kIOPSBatteryPowerValue
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let maxCapacity = description[kIOPSMaxCapacityKey] as? Int,
                  maxCapacity > 0
            else { continue }
            return PowerSnapshot(isOnBattery: isOnBattery, batteryPercent: capacity * 100 / maxCapacity)
        }
        return PowerSnapshot(isOnBattery: isOnBattery, batteryPercent: nil)
    }
}
