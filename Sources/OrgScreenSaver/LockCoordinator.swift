import AppKit
import ApplicationServices
import OrgScreenSaverCore

/// Owns the locked state and everything that happens when entering and leaving it.
final class LockCoordinator {
    static let shared = LockCoordinator()

    private(set) var isLocked = false
    var onStateChange: (() -> Void)?

    private let settings = Settings.shared
    private let tap = EventTap()
    private let keepAwake = KeepAwake()
    private let snapshots = SnapshotService()
    private var covers: [CoverWindow] = []
    private var buffer = ""
    private var limiter = AttemptLimiter()
    private var testMode = false
    private var bioInFlight = false
    private var cursorHidden = false
    private var bufferTimer: Timer?
    private var statusTimer: Timer?
    private var testTimer: Timer?
    private var guardProcess: Process?
    private var lockedAt = Date()
    private var screenObserver: NSObjectProtocol?

    private init() {
        tap.isLocked = { [weak self] in self?.isLocked ?? false }
        tap.testMode = { [weak self] in self?.testMode ?? false }
        tap.onDecision = { [weak self] decision, input in self?.handle(decision, input) }
    }

    // MARK: Lock

    @discardableResult
    func lock(reason: String, resume: Bool = false) -> Bool {
        guard !isLocked else { return true }
        log("lock", "lock requested (reason: \(reason))")

        guard AXIsProcessTrusted() else {
            log("lock", "refused: Accessibility permission missing")
            if !resume { alert("Accessibility permission needed",
                               "Org Screen Saver needs Accessibility access to block keys while active. Open Settings > General > Permissions from the menu.") }
            return false
        }
        guard Auth.hasUnlockMethod else {
            log("lock", "refused: no unlock method (enable Touch ID or set a PIN)")
            if !resume { alert("No way to unlock yet",
                               "Enable Touch ID or set a PIN in Settings > Security before starting.") }
            return false
        }

        let config = AppConfig.load()
        testMode = config.testMode
        limiter.reset()
        buffer = ""
        lockedAt = Date()
        isLocked = true

        NSApp.activate(ignoringOtherApps: true)
        buildCovers()
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit,
                                     .disableSessionTermination, .disableHideApplication, .disableAppleMenu]
        hideCursor()

        guard tap.start() else {
            log("lock", "aborting: could not install event tap")
            teardown(reason: "event tap failure")
            if !resume { alert("Could not block input", "The keyboard tap failed to start. Check Accessibility permission, then try again.") }
            return false
        }

        keepAwake.start(displayToo: settings.keepDisplayAwake)
        snapshots.beginLockSession()
        writeLockState()
        startGuard()
        startTimers(config: config)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        }
        refreshCovers()
        promptBiometrics()
        log("lock", "LOCKED (testMode: \(testMode), touchID: \(Auth.touchIDActive), pin: \(Auth.pinActive), displays: \(covers.count))")
        onStateChange?()
        return true
    }

    // MARK: Unlock

    func unlock(reason: String) {
        guard isLocked else { return }
        log("lock", "UNLOCKED (reason: \(reason), duration: \(Int(Date().timeIntervalSince(lockedAt)))s)")
        teardown(reason: reason)
        onStateChange?()
    }

    private func teardown(reason: String) {
        isLocked = false
        tap.stop()
        bufferTimer?.invalidate(); bufferTimer = nil
        statusTimer?.invalidate(); statusTimer = nil
        testTimer?.invalidate(); testTimer = nil
        if let o = screenObserver { NotificationCenter.default.removeObserver(o); screenObserver = nil }
        showCursor()
        NSApp.presentationOptions = []
        covers.forEach { $0.coverView.tearDown(); $0.orderOut(nil); $0.close() }
        covers.removeAll()
        keepAwake.stop()
        snapshots.endLockSession()
        try? FileManager.default.removeItem(at: AppPaths.lockStateFile) // tells the guard this was a clean unlock
        guardProcess?.terminate()
        guardProcess = nil
        buffer = ""
    }

    // MARK: Covers

    private func buildCovers() {
        covers.forEach { $0.coverView.tearDown(); $0.orderOut(nil); $0.close() }
        covers = NSScreen.screens.map { screen in
            let w = CoverWindow(screen: screen, message: settings.message, testMode: testMode)
            w.onFallbackKey = { [weak self] event in self?.handleFallback(event) }
            w.orderFrontRegardless()
            return w
        }
        covers.first?.makeKeyAndOrderFront(nil)
    }

    private func screensChanged() {
        guard isLocked else { return }
        log("lock", "display configuration changed; rebuilding covers (\(NSScreen.screens.count))")
        buildCovers()
        refreshCovers()
    }

    private func refreshCovers() {
        let remaining = limiter.remainingLockout(now: Date())
        var text = ""
        if remaining > 0 {
            text = "Too many attempts. Try again in \(Int(remaining.rounded(.up)))s"
        } else if Auth.touchIDActive && Auth.pinActive {
            text = "Touch ID or enter your PIN"
        } else if Auth.touchIDActive {
            text = "Touch ID to unlock"
        } else if Auth.pinActive {
            text = "Enter your PIN"
        }
        let dotsToShow = Auth.recoveryActive ? 4 : DigitEntry.pinLength
        covers.forEach { $0.coverView.update(digitCount: buffer.count, dotsToShow: dotsToShow, statusText: text) }
    }

    // MARK: Cursor

    private func hideCursor() {
        guard !cursorHidden else { return }
        CGAssociateMouseAndMouseCursorPosition(0)
        CGDisplayHideCursor(CGMainDisplayID())
        NSCursor.hide()
        cursorHidden = true
    }

    private func showCursor() {
        guard cursorHidden else { return }
        CGAssociateMouseAndMouseCursorPosition(1)
        CGDisplayShowCursor(CGMainDisplayID())
        NSCursor.unhide()
        cursorHidden = false
    }

    // MARK: Input

    private func handle(_ decision: KeyDecision, _ input: KeyInput) {
        guard isLocked else { return }
        if decision.snapshot {
            snapshots.capture(trigger: input.kind == .systemDefined ? "media\(input.sysKeyCode)" : "key\(input.keyCode)")
            log("input", "foreign key pressed (code \(input.kind == .systemDefined ? input.sysKeyCode : input.keyCode))")
        }
        switch decision.action {
        case .digit(let d): appendDigit(d)
        case .backspace: clearBuffer(countAsAttempt: true)
        case .escapeUnlock: unlock(reason: "ESC (test mode)")
        case .pass, .drop: break
        }
        if decision.snapshot { promptBiometrics() }
    }

    private func handleFallback(_ event: NSEvent) {
        guard isLocked else { return }
        let input = KeyInput(kind: .keyDown, keyCode: Int(event.keyCode),
                             command: event.modifierFlags.contains(.command),
                             control: event.modifierFlags.contains(.control),
                             option: event.modifierFlags.contains(.option))
        let decision = KeyClassifier.classify(input, locked: true, testMode: testMode)
        log("input", "fallback key path used (event tap not swallowing)")
        handle(decision, input)
    }

    private func appendDigit(_ d: Int) {
        guard Auth.pinActive || Auth.recoveryActive else { return }
        let now = Date()
        if limiter.isLockedOut(now: now) { refreshCovers(); return }
        buffer.append(String(d))
        restartBufferTimer()
        let outcome = DigitEntry.evaluate(
            buffer: buffer,
            pinEnabled: Auth.pinActive, recoveryEnabled: Auth.recoveryActive,
            verifyPIN: { SecretStore.verify($0, kind: .pin) },
            verifyRecovery: { SecretStore.verify($0, kind: .recovery) })
        switch outcome {
        case .pending: refreshCovers()
        case .unlock:
            let usedRecovery = buffer.count == DigitEntry.recoveryLength
            buffer = ""
            unlock(reason: usedRecovery ? "recovery code" : "PIN")
        case .fail: registerFailure()
        }
    }

    private func registerFailure() {
        let delay = limiter.recordFailure(now: Date())
        log("security", "wrong code entered (failure #\(limiter.failures)\(delay > 0 ? ", locked out \(Int(delay))s" : ""))")
        buffer = ""
        covers.forEach { $0.coverView.shake() }
        refreshCovers()
    }

    private func clearBuffer(countAsAttempt: Bool) {
        // Abandoning a >=4 digit entry counts as an attempt so pacing cannot dodge the limiter.
        if countAsAttempt && buffer.count >= DigitEntry.pinLength && Auth.recoveryActive {
            registerFailure()
            return
        }
        buffer = ""
        refreshCovers()
    }

    private func restartBufferTimer() {
        bufferTimer?.invalidate()
        bufferTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            self?.clearBuffer(countAsAttempt: true)
        }
    }

    // MARK: Touch ID

    private func promptBiometrics() {
        guard isLocked, Auth.touchIDActive, !bioInFlight else { return }
        bioInFlight = true
        Biometrics.evaluate(reason: "Unlock Org Screen Saver") { [weak self] ok, error in
            guard let self else { return }
            self.bioInFlight = false
            guard self.isLocked else { return }
            if ok {
                self.unlock(reason: "Touch ID")
            } else {
                log("security", "Touch ID not accepted: \(error ?? "unknown")")
            }
        }
    }

    // MARK: Timers, guard, state

    private func startTimers(config: AppConfig) {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.isLocked else { return }
            self.tap.reenableIfNeeded()
            self.ensureGuardAlive()
            self.refreshCovers()
        }
        if testMode {
            let secs = TimeInterval(config.testAutoUnlockMinutes * 60)
            testTimer = Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { [weak self] _ in
                self?.unlock(reason: "test-mode auto unlock")
            }
        }
    }

    private func writeLockState() {
        AppPaths.ensureDirectories()
        try? Data("\(ProcessInfo.processInfo.processIdentifier)".utf8).write(to: AppPaths.lockStateFile, options: .atomic)
    }

    private func startGuard() {
        guard let exe = Bundle.main.executableURL else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--guard", "\(ProcessInfo.processInfo.processIdentifier)"]
        do {
            try p.run()
            guardProcess = p
            log("guard", "guard process started (pid \(p.processIdentifier))")
        } catch {
            log("guard", "could not start guard: \(error.localizedDescription)")
        }
    }

    private func ensureGuardAlive() {
        if let g = guardProcess, g.isRunning { return }
        log("guard", "guard process not running; restarting")
        startGuard()
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
