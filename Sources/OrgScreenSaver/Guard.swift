import Foundation
import OrgScreenSaverCore

/// Tiny watchdog. If the main app dies while the lock-state file exists (crash or kill), relaunch it into locked state.
/// A clean unlock deletes the lock-state file, which makes the guard exit.
enum GuardProcess {
    static func run() -> Never {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--guard"), idx + 1 < args.count, let parent = Int32(args[idx + 1]) else { exit(2) }
        let appPath = Bundle.main.bundleURL.path
        while true {
            Thread.sleep(forTimeInterval: 1)
            guard FileManager.default.fileExists(atPath: AppPaths.lockStateFile.path) else { exit(0) } // clean unlock
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
