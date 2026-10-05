import Foundation
@testable import Workdeck

/// A usage API body with the given windows; reset times are relative to `fixedNow`.
func usageBody(fiveHour: (Double, TimeInterval)? = nil, sevenDay: (Double, TimeInterval)? = nil) -> String {
    func entry(_ value: (Double, TimeInterval)?) -> String {
        guard let value else { return "null" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return #"{"utilization": \#(value.0), "resets_at": "\#(formatter.string(from: fixedNow.addingTimeInterval(value.1)))"}"#
    }
    return #"{"five_hour": \#(entry(fiveHour)), "seven_day": \#(entry(sevenDay)), "seven_day_opus": null}"#
}
