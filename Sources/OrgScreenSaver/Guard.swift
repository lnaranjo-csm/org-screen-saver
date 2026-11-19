import Foundation
import OrgScreenSaverCore

/// Tiny watchdog. If the main app dies or hangs while the lock-state file exists, relaunch it into locked state.
/// A hang is detected through the lock-state file's modification time, which the app's main-thread timer refreshes
/// every second. A clean unlock deletes the lock-state file, which makes the guard exit.
enum Heartbeat {
    static let staleAfter: TimeInterval = 15

    /// Called from the app's main thread; stops being called if the main thread hangs.
    static func beat() {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: AppPaths.lockStateFile.path)
    }

    static func age() -> TimeInterval? {
        guard let d = (try? FileManager.default.attributesOfItem(atPath: AppPaths.lockStateFile.path))?[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(d)
    }
}

enum GuardProcess {
    static func run() -> Never {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--guard"), idx + 1 < args.count, let parent = Int32(args[idx + 1]) else { exit(2) }
        let appPath = Bundle.main.bundleURL.path
        var lastTick = Date()
        while true {
            Thread.sleep(forTimeInterval: 1)
            // If this loop itself stalled (system sleep), the app was frozen too; give it time to beat again.
            let slept = Date().timeIntervalSince(lastTick) > 5
            lastTick = Date()
            guard FileManager.default.fileExists(atPath: AppPaths.lockStateFile.path) else { exit(0) } // clean unlock
            if !slept, kill(parent, 0) == 0, let age = Heartbeat.age(), age > Heartbeat.staleAfter {
                NSLog("OrgScreenSaver guard: main app unresponsive for \(Int(age))s; killing it")
                // Logged by the guard since the hung app cannot. The next iteration sees the death and relaunches.
                if let h = try? FileHandle(forWritingTo: AppPaths.logFile) {
                    h.seekToEndOfFile()
                    h.write(Data("\(ISO8601DateFormatter().string(from: Date())) [guard] app unresponsive for \(Int(age))s; killing and resuming lock\n".utf8))
                    try? h.close()
                }
                kill(parent, SIGKILL)
                continue
            }
            if kill(parent, 0) != 0 && errno == ESRCH {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = ["-n", appPath, "--args", "--resume-lock"]
                try? p.run()
                exit(0) // the relaunched app starts its own guard
            }
        }
    }
}
