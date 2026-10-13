import Darwin

/// The controlling terminal of a process (exact tab spec §3).
nonisolated enum ProcessTTY {
    /// "/dev/ttys003"; `nil` when there is no such process or it has no terminal.
    static func path(of pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let device = info.kp_eproc.e_tdev
        // NODEV: the process has no controlling terminal.
        guard device != -1 else { return nil }
        // devname_r, not devname: devname shares one static buffer between threads.
        var buffer = [CChar](repeating: 0, count: 128)
        guard let name = devname_r(device, S_IFCHR, &buffer, Int32(buffer.count)) else { return nil }
        let path = "/dev/" + String(cString: name)
        return path == "/dev/??" ? nil : path
    }
}

/// AppleScript that brings forward the Terminal or iTerm2 tab of a TTY and returns whether it found one
/// (exact tab spec §2–§3).
nonisolated enum TerminalTabScript {
    static let terminal = "com.apple.Terminal"
    static let iTerm = "com.googlecode.iterm2"

    /// `nil` for other apps, and for anything but a plain TTY path: the TTY is compiled into the script.
    static func source(forBundleID bundleID: String, tty: String) -> String? {
        guard tty.wholeMatch(of: /\/dev\/ttys[0-9]+/) != nil else { return nil }
        // Windows are held by ID and tabs by index within them: restoring or raising a window reorders the windows, so a
        // reference by position would then name another one. A tab that cannot be read (e.g. closing) is skipped.
        switch bundleID {
        case terminal:
            return """
            with timeout of 5 seconds
                tell application id "com.apple.Terminal"
                    set windowIDs to id of every window
                    repeat with windowID in windowIDs
                        set windowID to contents of windowID
                        repeat with tabIndex from 1 to count of tabs of window id windowID
                            try
                                set found to (tty of tab tabIndex of window id windowID) is "\(tty)"
                            on error
                                set found to false
                            end try
                            if found then
                                set miniaturized of window id windowID to false
                                set selected of tab tabIndex of window id windowID to true
                                set index of window id windowID to 1
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end tell
            end timeout
            return false
            """
        case iTerm:
            return """
            with timeout of 5 seconds
                tell application id "com.googlecode.iterm2"
                    set windowIDs to id of every window
                    repeat with windowID in windowIDs
                        set windowID to contents of windowID
                        repeat with tabIndex from 1 to count of tabs of window id windowID
                            repeat with sessionIndex from 1 to count of sessions of tab tabIndex of window id windowID
                                try
                                    set found to (tty of session sessionIndex of tab tabIndex of window id windowID) is "\(tty)"
                                on error
                                    set found to false
                                end try
                                if found then
                                    try
                                        set miniaturized of window id windowID to false
                                    end try
                                    select window id windowID
                                    select tab tabIndex of window id windowID
                                    select session sessionIndex of tab tabIndex of window id windowID
                                    activate
                                    return true
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
            end timeout
            return false
            """
        default:
            return nil
        }
    }
}
