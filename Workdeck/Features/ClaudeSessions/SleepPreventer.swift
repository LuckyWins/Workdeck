import IOKit.pwr_mgt

protocol SleepPreventing {
    func setPreventing(_ preventing: Bool)
}

/// Keeps the Mac from idle-sleeping while held; the display may still sleep. Released by the system when Workdeck exits.
final class PowerAssertionSleepPreventer: SleepPreventing {
    static let reason = "Workdeck: Claude Code is working"

    private(set) var isPreventing = false
    private var assertionID = IOPMAssertionID(0)

    func setPreventing(_ preventing: Bool) {
        guard preventing != isPreventing else { return }
        if preventing {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                Self.reason as CFString,
                &assertionID
            )
            guard result == kIOReturnSuccess else { return }
        } else {
            IOPMAssertionRelease(assertionID)
        }
        isPreventing = preventing
    }
}
