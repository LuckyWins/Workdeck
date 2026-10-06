import Foundation
@testable import Workdeck

/// A fixed point in time for deterministic tests: 2026-10-05 12:00:00 UTC.
let fixedNow = Date(timeIntervalSince1970: 1_791_201_600)

func window(_ kind: UsageWindowKind, _ percent: Double, resetsIn seconds: TimeInterval = 3600) -> UsageWindow {
    UsageWindow(kind: kind, usedPercent: percent, resetsAt: fixedNow.addingTimeInterval(seconds))
}

func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "WorkdeckTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Claude Code status line stdin with the given `rate_limits` windows.
func statusLineInput(fiveHour: (Double, TimeInterval)? = nil, sevenDay: (Double, TimeInterval)? = nil) -> Data {
    var limits: [String: Any] = [:]
    if let fiveHour {
        limits["five_hour"] = ["used_percentage": fiveHour.0, "resets_at": fiveHour.1]
    }
    if let sevenDay {
        limits["seven_day"] = ["used_percentage": sevenDay.0, "resets_at": sevenDay.1]
    }
    var root: [String: Any] = ["model": ["display_name": "Opus"], "session_id": "abc"]
    if !limits.isEmpty {
        root["rate_limits"] = limits
    }
    return try! JSONSerialization.data(withJSONObject: root)
}
