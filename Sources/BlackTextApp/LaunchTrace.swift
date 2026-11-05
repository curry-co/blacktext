import AppKit

/// Launch timing for `make bench`. Silent unless BLACKTEXT_LAUNCH_TRACE is set.
/// With BLACKTEXT_EXIT_AFTER_LAUNCH, the app quits as soon as it's ready, so the quit is timed too.
enum LaunchTrace {
    private static let environment = ProcessInfo.processInfo.environment
    static let isEnabled = environment["BLACKTEXT_LAUNCH_TRACE"] != nil
    private static let exitsAfterLaunch = environment["BLACKTEXT_EXIT_AFTER_LAUNCH"] != nil

    /// When the kernel started this process.
    private static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    static func mark(_ event: String) {
        guard isEnabled else { return }
        log("trace \(event) \(milliseconds())ms")
    }

    private static func milliseconds() -> String {
        String(format: "%.1f", Date().timeIntervalSince(processStart) * 1000)
    }

    /// The window is on screen with the cursor in the canvas. Measured after the first frame is drawn.
    static func windowShown() {
        guard isEnabled else { return }
        NSApp.windows.first?.displayIfNeeded()
        CATransaction.flush()
        log("launch_ms=\(milliseconds()) ready_at=\(String(format: "%.4f", Date().timeIntervalSince1970))")
    }

    static func finished() {
        guard isEnabled else { return }
        mark("deferred-work-done")
        if exitsAfterLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        }
    }

    static func quit(seconds: TimeInterval) {
        guard isEnabled else { return }
        log("quit_ms=\(String(format: "%.1f", seconds * 1000))")
    }
}
