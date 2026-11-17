import SwiftUI
import Combine
import AVFoundation
import OrgScreenSaverCore

// MARK: - Secret (PIN / recovery) editor

struct SecretEditor: View {
    let kind: SecretKind
    let length: Int
    let title: String
    var onChange: () -> Void

    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var message = ""
    @State private var exists = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if exists { SecureField("Current \(title)", text: $current) }
            SecureField("New \(length)-digit \(title)", text: $new)
            SecureField("Confirm \(title)", text: $confirm)
            HStack {
                Button(exists ? "Change \(title)" : "Set \(title)") { save() }
                if exists { Button("Remove \(title)", role: .destructive) { remove() } }
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { exists = SecretStore.has(kind) }
    }

    private func save() {
        if exists && !SecretStore.verify(current, kind: kind) { message = "Current \(title) is wrong"; return }
        guard new.count == length, new.allSatisfy(\.isNumber) else { message = "Use exactly \(length) digits"; return }
        guard new == confirm else { message = "Entries do not match"; return }
        if SecretStore.save(new, kind: kind) {
            if kind == .pin { Settings.shared.pinEnabled = true } else { Settings.shared.recoveryEnabled = true }
            current = ""; new = ""; confirm = ""
            exists = true
            message = "Saved"
            log("settings", "\(kind.rawValue) \(exists ? "set/changed" : "set")")
            onChange()
        } else {
            message = "Could not save to Keychain"
        }
    }

    private func remove() {
        if !SecretStore.verify(current, kind: kind) { message = "Enter the current \(title) to remove it"; return }
        if kind == .pin && !Settings.shared.touchIDEnabled {
            message = "Enable Touch ID first: at least one unlock method is required"
            return
        }
        SecretStore.delete(kind)
        if kind == .pin { Settings.shared.pinEnabled = false } else { Settings.shared.recoveryEnabled = false }
        current = ""; exists = false; message = "Removed"
        onChange()
    }
}

// MARK: - Tabs

private func pickBackground() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image, .movie]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message = "Choose an image or video to use as the cover background"
    if panel.runModal() == .OK, let url = panel.url, !CustomBackground.set(from: url) {
        let a = NSAlert()
        a.messageText = "Couldn't use that file"
        a.runModal()
    }
}

struct GeneralTab: View {
    @ObservedObject var s = Settings.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    var scrollTo: String? = nil

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section("General") {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { LaunchAtLogin.set($0) }
                    Toggle("Keep the display awake while active", isOn: $s.keepDisplayAwake)
                    HStack {
                        Text("Cover background")
                        Spacer()
                        Text(s.customBackgroundPath.isEmpty ? "Desktop wallpaper" : "Custom image/video")
                            .foregroundStyle(.secondary)
                        if !s.customBackgroundPath.isEmpty {
                            Button("Remove") { CustomBackground.clear() }
                        }
                        Button(s.customBackgroundPath.isEmpty ? "Choose File…" : "Change…") { pickBackground() }
                    }
                    TextField("Message on the cover (leave empty to show nothing)", text: $s.message, axis: .vertical)
                        .lineLimit(1...3)
                }
                Section("Permissions") { PermissionsSection() }.id("permissions")
                Section("Shortcut") { ShortcutSection() }.id("shortcut")
                Section("Updates") { UpdatesSection() }.id("updates")
                Section("Logs") { LogsSection() }.id("logs")
            }
            .formStyle(.grouped)
            .onAppear {
                guard let id = scrollTo else { return }
                DispatchQueue.main.async { withAnimation { proxy.scrollTo(id, anchor: .top) } }
            }
        }
    }
}

struct SecurityTab: View {
    @ObservedObject var s = Settings.shared
    @State private var tick = 0
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        Form {
            Section("Unlock with") {
                Toggle("Touch ID", isOn: Binding(
                    get: { s.touchIDEnabled },
                    set: { new in
                        if !new && !Auth.pinActive { return } // keep at least one method
                        s.touchIDEnabled = new
                    }))
                    .disabled(!Biometrics.available)
                if !Biometrics.available {
                    Text("Touch ID is not available on this Mac. A PIN is required.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("PIN (4 digits)", isOn: Binding(
                    get: { s.pinEnabled && SecretStore.has(.pin) },
                    set: { new in
                        if new { s.pinEnabled = SecretStore.has(.pin) }
                        else if Auth.touchIDActive { s.pinEnabled = false }
                    }))
                SecretEditor(kind: .pin, length: 4, title: "PIN", onChange: { tick += 1 })
            }
            Section("Recovery code (optional, 8 digits)") {
                Text("Typed on the cover if Touch ID fails and you forget the PIN.").font(.caption).foregroundStyle(.secondary)
                SecretEditor(kind: .recovery, length: 8, title: "recovery code", onChange: { tick += 1 })
            }
            Section("Camera snapshot on foreign key presses") {
                Toggle("Take a photo when any key other than F1, F2 or a number is pressed", isOn: $s.snapshotEnabled)
                Stepper("Delete photos after \(s.snapshotRetentionDays) days", value: $s.snapshotRetentionDays, in: 1...365)
                HStack {
                    Text("Camera permission: \(cameraText)").font(.caption)
                    if camera == .notDetermined {
                        Button("Request") { AVCaptureDevice.requestAccess(for: .video) { _ in
                            DispatchQueue.main.async { camera = AVCaptureDevice.authorizationStatus(for: .video) } } }
                    }
                    Button("Open snapshots folder") { NSWorkspace.shared.open(AppPaths.snapshots) }
                }
            }
        }.formStyle(.grouped)
    }

    private var cameraText: String {
        switch camera {
        case .authorized: return "granted"
        case .denied: return "denied (System Settings > Privacy & Security > Camera)"
        case .restricted: return "restricted"
        default: return "not requested yet"
        }
    }
}

struct ScheduleTab: View {
    @ObservedObject var s = Settings.shared
    @State private var onceDate = Date().addingTimeInterval(3600)
    @State private var time = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var days: Set<Int> = [2, 3, 4, 5, 6]

    var body: some View {
        Form {
            Section("Scheduled") {
                if s.schedules.filter(\.enabled).isEmpty { Text("Nothing scheduled").foregroundStyle(.secondary) }
                ForEach(s.schedules.filter(\.enabled)) { sc in
                    HStack {
                        Text(sc.summary)
                        Spacer()
                        Button("Delete", role: .destructive) { s.schedules.removeAll { $0.id == sc.id } }
                    }
                }
            }
            Section("Once") {
                DatePicker("Date and time", selection: $onceDate, in: Date()...)
                Button("Add one-time schedule") { s.schedules.append(.once(at: onceDate)) }
            }
            Section("Repeating") {
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                HStack {
                    ForEach(1...7, id: \.self) { d in
                        Toggle(Calendar.current.shortWeekdaySymbols[d - 1], isOn: Binding(
                            get: { days.contains(d) },
                            set: { on in if on { days.insert(d) } else { days.remove(d) } }))
                            .toggleStyle(.button)
                    }
                }
                Button("Add repeating schedule") {
                    let c = Calendar.current.dateComponents([.hour, .minute], from: time)
                    s.schedules.append(.weekly(hour: c.hour ?? 0, minute: c.minute ?? 0, weekdays: Array(days)))
                }.disabled(days.isEmpty)
            }
            Text("Schedules only run while the app is running. Turn on Launch at login.").font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}

struct ShortcutSection: View {
    @ObservedObject var s = Settings.shared
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Group {
            Toggle("Enable a global shortcut to start the screen saver", isOn: $s.hotkeyEnabled)
                .onChange(of: s.hotkeyEnabled) { _ in apply() }
            HStack {
                Text("Shortcut: \(HotkeyManager.describe(keyCode: s.hotkeyKeyCode, carbonModifiers: s.hotkeyModifiers))")
                Button(recording ? "Press the new shortcut..." : "Record") { record() }.disabled(!s.hotkeyEnabled)
            }
            Text("Off by default. Must include at least one of Control, Option or Command.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func apply() {
        HotkeyManager.shared.apply(enabled: s.hotkeyEnabled, keyCode: s.hotkeyKeyCode, carbonModifiers: s.hotkeyModifiers)
    }

    private func record() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let mods = HotkeyManager.carbonModifiers(from: e.modifierFlags)
            let needed = (e.modifierFlags.intersection([.command, .option, .control])).isEmpty
            if needed { return nil }
            s.hotkeyKeyCode = Int(e.keyCode)
            s.hotkeyModifiers = mods
            recording = false
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            apply()
            return nil
        }
    }
}

struct ProximityTab: View {
    @ObservedObject var s = Settings.shared
    @State private var devices: [PairedDevice] = []

    var body: some View {
        Form {
            Text("EXPERIMENTAL").font(.caption.bold()).foregroundStyle(.orange)
            Text("Start the screen saver automatically when a selected Bluetooth device disconnects (goes out of range). Works with devices macOS reports as connected, such as headphones. Phones and watches often do not appear as connected, so results vary.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Auto-lock when my devices leave range", isOn: $s.proximityEnabled)
                .onChange(of: s.proximityEnabled) { _ in ProximityMonitor.shared.apply() }
            Stepper("Lock after \(s.proximityAwaySeconds) seconds away", value: $s.proximityAwaySeconds, in: 10...600, step: 10)
            Section("Devices to monitor") {
                if devices.isEmpty { Text("No paired Bluetooth devices found").foregroundStyle(.secondary) }
                ForEach(devices) { d in
                    Toggle("\(d.name)", isOn: Binding(
                        get: { s.proximityDevices.contains(d.address) },
                        set: { on in
                            if on { s.proximityDevices.append(d.address) } else { s.proximityDevices.removeAll { $0 == d.address } }
                            ProximityMonitor.shared.apply()
                        }))
                }
                Button("Refresh list") { devices = ProximityMonitor.pairedDevices() }
            }
        }
        .formStyle(.grouped)
        .onAppear { devices = ProximityMonitor.pairedDevices() }
    }
}

struct UpdatesSection: View {
    @ObservedObject var s = Settings.shared
    @ObservedObject var u = Updater.shared

    var body: some View {
        Group {
            LabeledContent("Version", value: Updater.currentVersion)
            LabeledContent("Update source", value: u.configured ? "github.com/\(u.repo)" : "not configured")
            Toggle("Check for updates automatically", isOn: $s.autoCheckUpdates)
            HStack {
                Button("Check now") { u.check(manual: true) }.disabled(u.busy)
                if let r = u.available { Button("Install \(r.tag)") { u.install() }.disabled(u.busy) }
            }
            Text(u.status).font(.caption).foregroundStyle(.secondary)
            if let r = u.available, !r.notes.isEmpty { Text(r.notes).font(.caption) }
        }
    }
}

struct LogsSection: View {
    @State private var text = Log.shared.tail()
    var body: some View {
        VStack(alignment: .leading) {
            ScrollView { Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 160)
                .background(Color.black.opacity(0.05))
            HStack {
                Button("Refresh") { text = Log.shared.tail() }
                Button("Open log folder") { NSWorkspace.shared.open(AppPaths.logs) }
            }
        }
    }
}

// MARK: - Permissions

struct PermissionRow: View {
    let title: String
    let detail: String
    let ok: Bool
    let required: Bool
    let grant: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.circle.fill" : (required ? "exclamationmark.circle" : "circle"))
                .foregroundStyle(ok ? .green : (required ? .orange : .secondary))
            VStack(alignment: .leading) {
                Text(title + (required ? "" : " (optional)")).bold()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok { Button("Grant") { grant() } }
        }
    }
}

/// Live permission status with Grant buttons. Grant permissions here, never while the cover is up:
/// system prompts cannot be answered behind it.
struct PermissionsSection: View {
    @State private var ax = AXIsProcessTrusted()
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            PermissionRow(title: "Accessibility", detail: "Required. Lets the app block keys and shortcuts while active.", ok: ax, required: true) {
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
            PermissionRow(title: "Camera", detail: "Takes a photo when a foreign key is pressed on the cover.", ok: camera, required: false) {
                AVCaptureDevice.requestAccess(for: .video) { _ in }
            }
            HStack(alignment: .top) {
                Image(systemName: Biometrics.available ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(Biometrics.available ? .green : .orange)
                VStack(alignment: .leading) {
                    Text("Touch ID").bold()
                    Text(Biometrics.available ? "Available." : "Not available on this Mac: a PIN is required.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Grant permissions here before locking. A macOS prompt that appears under the cover cannot be answered.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onReceive(timer) { _ in
            ax = AXIsProcessTrusted()
            camera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        }
    }
}

struct SettingsRoot: View {
    var initialTab = 0
    var scrollTo: String? = nil
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            GeneralTab(scrollTo: scrollTo).tabItem { Label("General", systemImage: "gearshape") }.tag(0)
            SecurityTab().tabItem { Label("Security", systemImage: "lock") }.tag(1)
            ScheduleTab().tabItem { Label("Schedule", systemImage: "clock") }.tag(2)
            ProximityTab().tabItem { Label("Proximity", systemImage: "wave.3.right") }.tag(3)
        }
        .frame(width: 620, height: 560)
        .onAppear { tab = initialTab }
    }
}

// MARK: - Setup checklist (first run)

struct SetupView: View {
    var onDone: () -> Void
    @ObservedObject var s = Settings.shared
    @State private var ax = AXIsProcessTrusted()
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    @State private var hasPin = SecretStore.has(.pin)
    @State private var hasRecovery = SecretStore.has(.recovery)
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up Org Screen Saver").font(.title2.bold())
            row("Accessibility", "Required. Lets the app block keys and shortcuts while active.", ax, required: true) {
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
            row("Camera", "Takes a photo when a foreign key is pressed on the cover.", camera, required: false) {
                AVCaptureDevice.requestAccess(for: .video) { _ in }
            }
            HStack(alignment: .top) {
                Image(systemName: Biometrics.available ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(Biometrics.available ? .green : .orange)
                VStack(alignment: .leading) {
                    Text("Touch ID").bold()
                    Text(Biometrics.available ? "Available and enabled by default." : "Not available on this Mac: you must set a PIN.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            GroupBox("PIN \(Biometrics.available ? "(optional)" : "(required)")") {
                SecretEditor(kind: .pin, length: 4, title: "PIN", onChange: { hasPin = SecretStore.has(.pin) })
            }
            GroupBox("Recovery code (optional)") {
                SecretEditor(kind: .recovery, length: 8, title: "recovery code", onChange: { hasRecovery = SecretStore.has(.recovery) })
            }
            HStack {
                Spacer()
                Button("Done") { s.onboardingDone = true; onDone() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ax || !(Biometrics.available || hasPin))
            }
            Text("You can change all of this later in Settings (General > Permissions, Security).").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 520)
        .onReceive(timer) { _ in
            ax = AXIsProcessTrusted()
            camera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            hasPin = SecretStore.has(.pin)
        }
    }

    private func row(_ title: String, _ detail: String, _ ok: Bool, required: Bool, grant: @escaping () -> Void) -> some View {
        PermissionRow(title: title, detail: detail, ok: ok, required: required, grant: grant)
    }
}
