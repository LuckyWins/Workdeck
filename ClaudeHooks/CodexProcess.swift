import Darwin
import Foundation

/// Finds the `codex` process a hook runs under: Codex passes no PID, and the hook may run in a shell it started.
nonisolated enum CodexProcess {
    static func ancestorPID(
        start: Int32 = getppid(),
        name: (Int32) -> String? = executableName,
        parent: (Int32) -> Int32? = parentPID
    ) -> Int32? {
        var pid = start
        for _ in 0..<8 {
            guard pid > 1 else { return nil }
            if let name = name(pid), isCodex(name) {
                return pid
            }
            guard let next = parent(pid), next != pid else { return nil }
            pid = next
        }
        return nil
    }

    /// `codex`, or a release archive's `codex-aarch64-apple-darwin`; not Codex's helpers such as `codex-code-mode-host`.
    static func isCodex(_ name: String) -> Bool {
        name == "codex" || (name.hasPrefix("codex-") && name.hasSuffix("-apple-darwin"))
    }

    static func executableName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(filePath: String(cString: buffer)).lastPathComponent
    }

    static func parentPID(_ pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
