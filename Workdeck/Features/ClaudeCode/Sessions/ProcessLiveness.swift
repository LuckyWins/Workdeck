import Darwin
import Foundation

protocol ProcessLiveness {
    /// When the process started, or `nil` if no such process is running.
    func startTime(of pid: Int32) -> Date?
}

struct SystemProcessLiveness: ProcessLiveness {
    func startTime(of pid: Int32) -> Date? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }
}
