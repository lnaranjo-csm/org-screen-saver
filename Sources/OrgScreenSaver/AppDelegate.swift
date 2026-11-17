import AppKit
import SwiftUI
import OrgScreenSaverCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let scheduler = SchedulerService()
    private let lock = LockCoordinator.shared
    private var settingsWindow: NSWindow?
    private var setupWindow: NSWindow?
    private var updateTimer: Timer?
    private let resumeLock = CommandLine.arguments.contains("--resume-lock")

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPaths.ensureDirectories()
        AppConfig.writeDefaultIfMissing()
        log("app", "started v\(Updater.currentVersion) (pid \(ProcessInfo.processInfo.processIdentifier), resumeLock: \(resumeLock), testMode file: \(AppConfig.load().testMode))")

        if !resumeLock, let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            log("app", "another instance is already running (pid \(other.processIdentifier)); exiting")
            exit(0)
        }

        buildStatusItem()
        lock.onStateChange = { [weak self] in self?.updateIcon() }
        scheduler.start()
        LiveWallpaperGate.warmUp()
        ProximityMonitor.shared.apply()
        HotkeyManager.shared.onTrigger = { [weak self] in self?.startNow(reason: "hotkey") }
        let s = Settings.shared
        HotkeyManager.shared.apply(enabled: s.hotkeyEnabled, keyCode: s.hotkeyKeyCode, carbonModifiers: s.hotkeyModifiers)
        SnapshotService().purgeOld()

        if s.autoCheckUpdates && Updater.shared.configured {
            Updater.shared.check(manual: false)
            updateTimer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { _ in Updater.shared.check(manual: false) }
        }

        if resumeLock {
            // Relaunched by the guard after the app died while locked.
            DispatchQueue.main.async { [weak self] in
                if !self!.lock.lock(reason: "resume after unexpected exit", resume: true) {
                    log("app", "resume-lock failed; removing stale lock state")
                    try? FileManager.default.removeItem(at: AppPaths.lockStateFile)
                }
            }
        } else if !s.onboardingDone {
            showSetup()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if lock.isLocked {
            log("app", "quit refused while locked")
            return .terminateCancel
        }
        log("app", "quitting")
        return .terminateNow
    }

    // MARK: Menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
    }

    private func updateIcon() {
        let name = lock.isLocked ? "lock.fill" : "lock.open"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Org Screen Saver")
        img?.isTemplate = true
        statusItem.button?.image = img
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("Start Screen Saver Now", #selector(startNowAction)))

        let lockIn = NSMenuItem(title: "Lock In...", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for m in [5, 15, 30, 60] {
            let it = item("\(m) minutes", #selector(lockInAction(_:)))
            it.tag = m
            sub.addItem(it)
        }
        lockIn.submenu = sub
        menu.addItem(lockIn)
        menu.addItem(item("Schedule...", #selector(openScheduleAction)))

        if let (date, sc) = scheduler.nextFire {
            let f = DateFormatter()
            f.dateStyle = .none
            f.timeStyle = .short
            let day = Calendar.current.isDateInToday(date) ? "today" : {
                let d = DateFormatter(); d.dateFormat = "EEE d MMM"; return d.string(from: date) }()
            let next = NSMenuItem(title: "Next: \(day) \(f.string(from: date))", action: nil, keyEquivalent: "")
            next.isEnabled = false
            menu.addItem(next)
            let cancel = item("Cancel next schedule", #selector(cancelNextAction))
            cancel.representedObject = sc.id
            menu.addItem(cancel)
        }

        menu.addItem(.separator())
        menu.addItem(item("Settings...", #selector(openSettingsAction), key: ","))
        menu.addItem(item("Open Snapshots Folder", #selector(openSnapshotsAction)))
        menu.addItem(item("Open Log Folder", #selector(openLogsAction)))
        if let rel = Updater.shared.available {
            menu.addItem(item("Update to \(rel.tag)...", #selector(openUpdatesAction)))
        } else {
            menu.addItem(item("Check for Updates...", #selector(checkUpdatesAction)))
        }
        menu.addItem(.separator())
        let quit = item("Quit Org Screen Saver", #selector(quitAction), key: "q")
        quit.isEnabled = !lock.isLocked
        menu.addItem(quit)
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    // MARK: Actions

    @objc private func startNowAction() { startNow(reason: "menu: start now") }

    private func startNow(reason: String) {
        if !lock.lock(reason: reason) {
            // lock() already explained why for the user-facing cases.
            if !AXIsProcessTrusted() { showSettings(tab: 0, scrollTo: "permissions") }
            else if !Auth.hasUnlockMethod { showSettings(tab: 1) }
        }
    }

    @objc private func lockInAction(_ sender: NSMenuItem) { scheduler.lockIn(minutes: sender.tag) }
    @objc private func cancelNextAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        Settings.shared.schedules.removeAll { $0.id == id }
        log("schedule", "next schedule cancelled from menu")
    }
    @objc private func openScheduleAction() { showSettings(tab: 2) }
    @objc private func openSettingsAction() { showSettings(tab: 0) }
    @objc private func openUpdatesAction() { showSettings(tab: 0, scrollTo: "updates") }
    @objc private func openSnapshotsAction() {
        AppPaths.ensureDirectories()
        NSWorkspace.shared.open(AppPaths.snapshots)
    }
    @objc private func openLogsAction() { NSWorkspace.shared.open(AppPaths.logs) }
    @objc private func checkUpdatesAction() { Updater.shared.check(manual: true); showSettings(tab: 0, scrollTo: "updates") }
    @objc private func quitAction() { NSApp.terminate(nil) }

    private func showSettings(tab: Int, scrollTo: String? = nil) {
        settingsWindow?.close()
        let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsRoot(initialTab: tab, scrollTo: scrollTo)))
        w.title = "Org Screen Saver Settings"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        settingsWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func showSetup() {
        setupWindow?.close()
        let w = NSWindow(contentViewController: NSHostingController(rootView: SetupView(onDone: { [weak self] in
            self?.setupWindow?.close()
        })))
        w.title = "Org Screen Saver Setup"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        setupWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
