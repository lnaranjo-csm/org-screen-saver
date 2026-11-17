import AppKit
import Carbon.HIToolbox
import IOBluetooth
import CryptoKit
import OrgScreenSaverCore

// MARK: - Scheduler

final class SchedulerService {
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            log("schedule", "system woke; checking schedules")
            self?.tick()
        }
        tick()
    }

    func tick() {
        let settings = Settings.shared
        let now = Date()
        var updated = settings.schedules
        var fired = false
        for i in updated.indices {
            let r = ScheduleEvaluator.evaluate(updated[i], now: now)
            if r.schedule != updated[i] { updated[i] = r.schedule }
            if r.fire { fired = true; log("schedule", "schedule due: \(updated[i].summary)") }
            else if r.schedule.lastHandled == now && !r.fire { log("schedule", "schedule missed (outside grace window): \(updated[i].summary)") }
        }
        if updated != settings.schedules { settings.schedules = updated }
        if fired && !LockCoordinator.shared.isLocked {
            LockCoordinator.shared.lock(reason: "schedule")
        }
    }

    var nextFire: (Date, Schedule)? {
        Settings.shared.schedules
            .filter { $0.enabled }
            .compactMap { s in s.nextOccurrence(after: s.lastHandled).map { ($0, s) } }
            .min { $0.0 < $1.0 }
    }

    func lockIn(minutes: Int) {
        let when = Date().addingTimeInterval(Double(minutes) * 60)
        Settings.shared.schedules.append(.once(at: when))
        log("schedule", "countdown set: lock in \(minutes) min")
    }
}

// MARK: - Global hotkey (optional, off by default)

final class HotkeyManager {
    static let shared = HotkeyManager()
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onTrigger: (() -> Void)?

    func apply(enabled: Bool, keyCode: Int, carbonModifiers: Int) {
        unregister()
        guard enabled, carbonModifiers != 0 else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotkeyManager.shared.onTrigger?() }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4F535348), id: 1)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(carbonModifiers), id, GetApplicationEventTarget(), 0, &ref)
        log("hotkey", status == noErr ? "registered (keyCode \(keyCode), modifiers \(carbonModifiers))" : "registration failed (\(status))")
    }

    private func unregister() {
        if let r = ref { UnregisterEventHotKey(r); ref = nil; log("hotkey", "unregistered") }
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.shift) { m |= shiftKey }
        return m
    }

    static func describe(keyCode: Int, carbonModifiers m: Int) -> String {
        var s = ""
        if m & controlKey != 0 { s += "⌃" }
        if m & optionKey != 0 { s += "⌥" }
        if m & shiftKey != 0 { s += "⇧" }
        if m & cmdKey != 0 { s += "⌘" }
        let names: [Int: String] = [0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
                                    12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P",
                                    37: "L", 38: "J", 40: "K", 45: "N", 46: "M", 49: "Space"]
        return s + (names[keyCode] ?? "key \(keyCode)")
    }
}

// MARK: - Bluetooth proximity (experimental)

struct PairedDevice: Identifiable, Hashable {
    var id: String { address }
    let name: String
    let address: String
}

final class ProximityMonitor {
    static let shared = ProximityMonitor()
    private var timer: Timer?
    private var lastSeen: Date?
    private var wasNear = false
    private var seenSinceStart = false

    static func pairedDevices() -> [PairedDevice] {
        let list = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return list.compactMap { d in
            guard let addr = d.addressString else { return nil }
            return PairedDevice(name: d.name ?? addr, address: addr)
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    func apply() {
        let s = Settings.shared
        timer?.invalidate()
        timer = nil
        guard s.proximityEnabled, !s.proximityDevices.isEmpty else {
            if s.proximityEnabled { log("proximity", "enabled but no devices selected") }
            return
        }
        lastSeen = nil
        wasNear = false
        seenSinceStart = false
        log("proximity", "monitoring \(s.proximityDevices.count) device(s); auto-lock after \(s.proximityAwaySeconds)s away")
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        let s = Settings.shared
        let near = s.proximityDevices.contains { addr in
            IOBluetoothDevice(addressString: addr)?.isConnected() ?? false
        }
        let now = Date()
        if near {
            lastSeen = now
            seenSinceStart = true
            if !wasNear { log("proximity", "device in range") }
        } else if wasNear {
            log("proximity", "device out of range")
        }
        wasNear = near
        // Only auto-lock after a device was seen at least once, so a phone with Bluetooth off cannot lock you out repeatedly.
        guard !near, seenSinceStart, let seen = lastSeen,
              now.timeIntervalSince(seen) >= Double(s.proximityAwaySeconds),
              !LockCoordinator.shared.isLocked else { return }
        log("proximity", "away for \(s.proximityAwaySeconds)s; locking")
        seenSinceStart = false // require the device to come back before locking again
        LockCoordinator.shared.lock(reason: "proximity")
    }
}

// MARK: - Updates via GitHub Releases

final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release {
        var tag: String
        var notes: String
        var zipURL: URL
        var shaURL: URL?
    }

    @Published var status = "Not checked yet"
    @Published var available: Release?
    @Published var busy = false

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// "owner/repo", set in Info.plist (key OSSUpdateRepo) at build time.
    var repo: String { Bundle.main.object(forInfoDictionaryKey: "OSSUpdateRepo") as? String ?? "" }
    var configured: Bool { !repo.isEmpty && !repo.contains("OWNER") }

    func check(manual: Bool) {
        guard configured else {
            status = "Updates are not configured (no GitHub repo set in this build)"
            return
        }
        guard !busy else { return }
        busy = true
        status = "Checking..."
        log("update", "checking github.com/\(repo) (current \(Self.currentVersion))")
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("OrgScreenSaver/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, response, error in
            DispatchQueue.main.async {
                self.busy = false
                if let error {
                    self.status = "Check failed: \(error.localizedDescription)"
                    log("update", "check failed: \(error.localizedDescription)")
                    return
                }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    self.status = "Check failed (HTTP \(code))"
                    log("update", "check failed: HTTP \(code)")
                    return
                }
                let assets = json["assets"] as? [[String: Any]] ?? []
                func url(_ suffix: String) -> URL? {
                    assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true }
                        .flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init)
                }
                if SemVer.isNewer(tag, than: Self.currentVersion), let zip = url(".zip") {
                    self.available = Release(tag: tag, notes: json["body"] as? String ?? "", zipURL: zip, shaURL: url(".zip.sha256"))
                    self.status = "Update available: \(tag)"
                    log("update", "update available: \(tag)")
                } else {
                    self.available = nil
                    self.status = "You are up to date (\(Self.currentVersion))"
                    log("update", "up to date")
                }
            }
        }.resume()
    }

    /// Downloads, verifies the SHA-256, swaps the app bundle in place, and relaunches.
    func install() {
        guard let rel = available, !busy else { return }
        guard !LockCoordinator.shared.isLocked else { status = "Cannot update while locked"; return }
        guard let shaURL = rel.shaURL else {
            status = "Release has no .sha256 file; refusing to install"
            log("update", "refused: release \(rel.tag) has no checksum asset")
            return
        }
        busy = true
        status = "Downloading \(rel.tag)..."
        log("update", "downloading \(rel.tag)")
        Task {
            do {
                let (zipTmp, _) = try await URLSession.shared.download(from: rel.zipURL)
                let (shaData, _) = try await URLSession.shared.data(from: shaURL)
                let expected = String(decoding: shaData, as: UTF8.self).split(separator: " ").first.map(String.init)?.lowercased() ?? ""
                let actual = SHA256.hash(data: try Data(contentsOf: zipTmp)).map { String(format: "%02x", $0) }.joined()
                guard expected == actual else { throw NSError(domain: "update", code: 1, userInfo: [NSLocalizedDescriptionKey: "Checksum mismatch"]) }

                let work = FileManager.default.temporaryDirectory.appendingPathComponent("oss-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let zip = work.appendingPathComponent("update.zip")
                try FileManager.default.moveItem(at: zipTmp, to: zip)
                try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
                guard let newApp = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                        .first(where: { $0.pathExtension == "app" }) else {
                    throw NSError(domain: "update", code: 2, userInfo: [NSLocalizedDescriptionKey: "No app in archive"])
                }
                try run("/usr/bin/codesign", ["--verify", "--deep", newApp.path])
                let dest = Bundle.main.bundleURL
                guard FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
                    throw NSError(domain: "update", code: 3, userInfo: [NSLocalizedDescriptionKey: "Install folder is not writable"])
                }
                log("update", "verified \(rel.tag); replacing app and relaunching")
                let pid = ProcessInfo.processInfo.processIdentifier
                let script = """
                while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
                rm -rf '\(dest.path)'
                ditto '\(newApp.path)' '\(dest.path)'
                xattr -dr com.apple.quarantine '\(dest.path)' 2>/dev/null
                open '\(dest.path)'
                rm -rf '\(work.path)'
                """
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", script]
                try p.run()
                await MainActor.run { NSApp.terminate(nil) }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.status = "Update failed: \(error.localizedDescription)"
                    log("update", "install failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "update", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\((tool as NSString).lastPathComponent) failed: \(msg)"])
        }
    }
}
