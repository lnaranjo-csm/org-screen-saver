import Foundation
import AppKit
import ServiceManagement
import LocalAuthentication
import Security
import IOKit.pwr_mgt
import OrgScreenSaverCore

// MARK: - Logging

/// Detailed, rotating file log. Never logs secrets (PIN digits, recovery codes) or typed characters.
final class Log {
    static let shared = Log()
    private let queue = DispatchQueue(label: "orgscreensaver.log")
    private let maxBytes = 5 * 1024 * 1024
    private let keep = 5
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    func write(_ category: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(category)] \(message)\n"
        queue.async {
            AppPaths.ensureDirectories()
            self.rotateIfNeeded()
            let url = AppPaths.logFile
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: url, options: .atomic)
            }
        }
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        let url = AppPaths.logFile
        guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes else { return }
        for i in stride(from: keep - 1, through: 1, by: -1) {
            let src = url.appendingPathExtension("\(i)")
            let dst = url.appendingPathExtension("\(i + 1)")
            try? fm.removeItem(at: dst)
            try? fm.moveItem(at: src, to: dst)
        }
        try? fm.moveItem(at: url, to: url.appendingPathExtension("1"))
    }

    func tail(lines: Int = 40) -> String {
        guard let text = try? String(contentsOf: AppPaths.logFile, encoding: .utf8) else { return "(no log yet)" }
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }
}

func log(_ category: String, _ message: String) { Log.shared.write(category, message) }

// MARK: - Settings

/// User-facing settings. Every change is logged. Test mode is deliberately NOT here (see AppConfig).
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var touchIDEnabled: Bool { didSet { changed("touchIDEnabled", touchIDEnabled, oldValue) } }
    @Published var pinEnabled: Bool { didSet { changed("pinEnabled", pinEnabled, oldValue) } }
    @Published var recoveryEnabled: Bool { didSet { changed("recoveryEnabled", recoveryEnabled, oldValue) } }
    @Published var message: String { didSet { changed("message", message, oldValue) } }
    @Published var snapshotEnabled: Bool { didSet { changed("snapshotEnabled", snapshotEnabled, oldValue) } }
    @Published var snapshotRetentionDays: Int { didSet { changed("snapshotRetentionDays", snapshotRetentionDays, oldValue) } }
    @Published var keepDisplayAwake: Bool { didSet { changed("keepDisplayAwake", keepDisplayAwake, oldValue) } }
    @Published var customBackgroundPath: String { didSet { changed("customBackgroundPath", customBackgroundPath, oldValue) } }
    @Published var hotkeyEnabled: Bool { didSet { changed("hotkeyEnabled", hotkeyEnabled, oldValue) } }
    @Published var hotkeyKeyCode: Int { didSet { changed("hotkeyKeyCode", hotkeyKeyCode, oldValue) } }
    @Published var hotkeyModifiers: Int { didSet { changed("hotkeyModifiers", hotkeyModifiers, oldValue) } }
    @Published var proximityEnabled: Bool { didSet { changed("proximityEnabled", proximityEnabled, oldValue) } }
    @Published var proximityDevices: [String] { didSet { changed("proximityDevices", proximityDevices, oldValue) } }
    @Published var proximityAwaySeconds: Int { didSet { changed("proximityAwaySeconds", proximityAwaySeconds, oldValue) } }
    @Published var autoCheckUpdates: Bool { didSet { changed("autoCheckUpdates", autoCheckUpdates, oldValue) } }
    @Published var onboardingDone: Bool { didSet { changed("onboardingDone", onboardingDone, oldValue) } }
    @Published var schedules: [Schedule] { didSet { saveSchedules(old: oldValue) } }

    private init() {
        func b(_ k: String, _ def: Bool) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? def }
        func i(_ k: String, _ def: Int) -> Int { UserDefaults.standard.object(forKey: k) as? Int ?? def }
        touchIDEnabled = b("touchIDEnabled", true)
        pinEnabled = b("pinEnabled", false)
        recoveryEnabled = b("recoveryEnabled", false)
        message = UserDefaults.standard.string(forKey: "message") ?? ""
        snapshotEnabled = b("snapshotEnabled", true)
        snapshotRetentionDays = i("snapshotRetentionDays", 30)
        keepDisplayAwake = b("keepDisplayAwake", true)
        customBackgroundPath = UserDefaults.standard.string(forKey: "customBackgroundPath") ?? ""
        hotkeyEnabled = b("hotkeyEnabled", false)
        hotkeyKeyCode = i("hotkeyKeyCode", 37) // L
        hotkeyModifiers = i("hotkeyModifiers", 4096 | 2048 | 256) // control + option + command (Carbon)
        proximityEnabled = b("proximityEnabled", false)
        proximityDevices = UserDefaults.standard.stringArray(forKey: "proximityDevices") ?? []
        proximityAwaySeconds = i("proximityAwaySeconds", 30)
        autoCheckUpdates = b("autoCheckUpdates", true)
        onboardingDone = b("onboardingDone", false)
        if let data = UserDefaults.standard.data(forKey: "schedules"),
           let s = try? JSONDecoder().decode([Schedule].self, from: data) {
            schedules = s
        } else {
            schedules = []
        }
    }

    private func changed<T>(_ key: String, _ new: T, _ old: T) {
        d.set(new, forKey: key)
        let shown = key == "message" ? "(\((new as? String)?.count ?? 0) chars)" : "\(new)"
        log("settings", "\(key) changed to \(shown)")
    }

    private func saveSchedules(old: [Schedule]) {
        if let data = try? JSONEncoder().encode(schedules) { d.set(data, forKey: "schedules") }
        if old.count != schedules.count {
            log("settings", "schedules changed: \(old.count) -> \(schedules.count)")
        }
    }
}

// MARK: - Secrets (PIN / recovery code) in the Keychain

enum SecretKind: String { case pin, recovery }

enum SecretStore {
    private static let service = "com.orgscreensaver.app"

    private static func baseQuery(_ kind: SecretKind) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: kind.rawValue]
    }

    static func has(_ kind: SecretKind) -> Bool { load(kind) != nil }

    static func load(_ kind: SecretKind) -> HashedSecret? {
        var q = baseQuery(kind)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(HashedSecret.self, from: data)
    }

    @discardableResult
    static func save(_ secret: String, kind: SecretKind) -> Bool {
        guard let data = try? JSONEncoder().encode(SecretHasher.make(secret)) else { return false }
        SecItemDelete(baseQuery(kind) as CFDictionary)
        var q = baseQuery(kind)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let ok = SecItemAdd(q as CFDictionary, nil) == errSecSuccess
        log("security", "\(kind.rawValue) \(ok ? "saved" : "SAVE FAILED")")
        return ok
    }

    static func verify(_ secret: String, kind: SecretKind) -> Bool {
        guard let stored = load(kind) else { return false }
        return SecretHasher.verify(secret, against: stored)
    }

    static func delete(_ kind: SecretKind) {
        SecItemDelete(baseQuery(kind) as CFDictionary)
        log("security", "\(kind.rawValue) removed")
    }
}

// MARK: - Authentication helpers

enum Biometrics {
    static var available: Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
    }

    static func evaluate(reason: String, completion: @escaping (Bool, String?) -> Void) {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "" // no password fallback: the cover must not offer one
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else {
            completion(false, err?.localizedDescription ?? "Biometrics unavailable")
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { ok, error in
            DispatchQueue.main.async { completion(ok, error?.localizedDescription) }
        }
    }
}

enum Auth {
    static var pinActive: Bool { Settings.shared.pinEnabled && SecretStore.has(.pin) }
    static var recoveryActive: Bool { Settings.shared.recoveryEnabled && SecretStore.has(.recovery) }
    static var touchIDActive: Bool { Settings.shared.touchIDEnabled && Biometrics.available }
    /// The cover refuses to start unless there is at least one way to get back in.
    static var hasUnlockMethod: Bool { touchIDActive || pinActive }
}

// MARK: - Keep awake

final class KeepAwake {
    private var ids: [IOPMAssertionID] = []

    func start(displayToo: Bool) {
        stop()
        var types = [kIOPMAssertPreventUserIdleSystemSleep as CFString]
        if displayToo { types.append(kIOPMAssertPreventUserIdleDisplaySleep as CFString) }
        for t in types {
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(t, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "Org Screen Saver is active" as CFString, &id)
            if r == kIOReturnSuccess { ids.append(id) }
        }
        log("power", "keep-awake started (display: \(displayToo), assertions: \(ids.count))")
    }

    func stop() {
        guard !ids.isEmpty else { return }
        ids.forEach { IOPMAssertionRelease($0) }
        ids.removeAll()
        log("power", "keep-awake released")
    }
}

// MARK: - Launch at login

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            log("settings", "launchAtLogin set to \(on)")
        } catch {
            log("settings", "launchAtLogin change failed: \(error.localizedDescription)")
        }
    }
}
