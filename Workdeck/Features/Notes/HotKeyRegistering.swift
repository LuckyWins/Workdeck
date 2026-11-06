import Carbon.HIToolbox
import Foundation
import OSLog

/// Registers one system-wide key combination (quick notes spec §2.2). Behind a protocol so the monitor is tested
/// with a fake.
protocol HotKeyRegistering: AnyObject {
    /// `keyCode` is a virtual key code and `modifiers` a Carbon modifier mask (`cmdKey`, `optionKey`, ...). Replaces
    /// a previous registration. Returns false when the combination cannot be registered, for instance because
    /// another app holds it. `action` runs on the main thread.
    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool
    func unregister()
}

/// `RegisterEventHotKey`: needs no permission, and the combination does not reach the app in front.
final class CarbonHotKey: HotKeyRegistering {
    private static let log = WorkdeckLog.notes
    /// 'WDNT'.
    static let signature: OSType = 0x5744_4E54
    private static var nextID: UInt32 = 0

    /// Tells this hot key's presses from those of another `CarbonHotKey`: every handler sees every press.
    let id: UInt32
    private var action: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init() {
        Self.nextID += 1
        id = Self.nextID
    }

    isolated deinit {
        unregister()
    }

    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        unregister()

        // A hot key press is delivered to the application's event target on the main thread, so the handler may
        // assume the main actor. `self` travels as an unretained pointer and outlives the handler: `unregister()`
        // removes the handler before `self` goes away.
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var pressed = EventHotKeyID()
                let result = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed
                )
                guard result == noErr else { return result }
                let pressedKey = pressed
                let hotKey = Unmanaged<CarbonHotKey>.fromOpaque(userData).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    guard pressedKey.signature == CarbonHotKey.signature, pressedKey.id == hotKey.id, let action = hotKey.action else {
                        return OSStatus(eventNotHandledErr)
                    }
                    action()
                    return noErr
                }
            },
            1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )
        guard status == noErr else {
            Self.log.error("Hot key: the event handler could not be installed (status \(status, privacy: .public))")
            handlerRef = nil
            return false
        }

        var ref: EventHotKeyRef?
        let registered = RegisterEventHotKey(
            keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), 0, &ref
        )
        guard registered == noErr, let ref else {
            Self.log.error("Hot key: the combination could not be registered (status \(registered, privacy: .public))")
            unregister()
            return false
        }
        hotKeyRef = ref
        self.action = action
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        action = nil
    }
}
