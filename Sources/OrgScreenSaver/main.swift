import AppKit

// The same binary doubles as the watchdog: `OrgScreenSaver --guard <parent-pid>`.
if CommandLine.arguments.contains("--guard") {
    GuardProcess.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
