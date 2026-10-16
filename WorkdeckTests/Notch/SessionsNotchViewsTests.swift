import Foundation
import Testing
@testable import Workdeck

@MainActor
struct SessionsNotchViewsTests {
    @Test func anAgentIconShowsTheStatusByItsStrength() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        #expect(SessionsList.leadingOpacity(.idle, at: start, isAgentMark: true) == 0.4)
        #expect(SessionsList.leadingOpacity(.waiting, at: start, isAgentMark: true) == 1)
        #expect(SessionsList.leadingOpacity(.working, at: start, isAgentMark: true) == SessionsList.leadingOpacity(.working, at: start, isAgentMark: false))
        // The dot keeps today's behavior: idle full, waiting pulsing.
        #expect(SessionsList.leadingOpacity(.idle, at: start, isAgentMark: false) == 1)
        #expect(SessionsList.leadingOpacity(.waiting, at: start, isAgentMark: false) == TerminalPulse.opacity(at: start, period: 2, minimum: 0.25))
    }

    @Test func aFlashingIconGlowsAtFullStrength() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        // A finished session is idle; its green glow is drawn from the icon, so the icon stays full while it flashes.
        #expect(SessionsList.leadingOpacity(.idle, at: start, isAgentMark: true, isFlashing: true) == 1)
        #expect(SessionsList.leadingOpacity(.idle, at: start, isAgentMark: true, isFlashing: false) == 0.4)
    }
}
