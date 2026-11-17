import AppKit
import ScreenCaptureKit
import CoreMedia
import OrgScreenSaverCore

// MARK: - Wallpaper

/// Shows the current wallpaper on a layer. Order of preference:
/// 1. live capture of ONLY the desktop-level windows (supports apps like Backdrop), needs Screen Recording
/// 2. the static desktop picture
/// 3. black
/// Screen Recording / ScreenCaptureKit can raise a system prompt on first use (and periodically on newer macOS).
/// That prompt would sit under the cover and be unreachable, so it is triggered once at app launch, while the screen is
/// uncovered. Live wallpaper is only used during a lock after this has completed successfully.
enum LiveWallpaperGate {
    private(set) static var ready = false
    private static var timer: Timer?
    private static var running = false

    /// Runs a real (tiny, short) SCStream capture while the screen is uncovered. Merely listing shareable content does
    /// NOT trigger macOS's "bypass the system window picker" approval; only an actual startCapture does, and that prompt
    /// recurs periodically. So the warm-up repeats while unlocked to keep the approval fresh, and a lock never starts a
    /// capture that could raise a prompt under the cover (where it can't be clicked and blocks Touch ID).
    static func warmUp() {
        guard Settings.shared.liveWallpaper, CGPreflightScreenCaptureAccess() else { ready = false; return }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 20 * 60, repeats: true) { _ in warmUp() }
        }
        guard !running, !LockCoordinator.shared.isLocked else { return }
        running = true
        Task {
            defer { running = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else { return }
                let cfg = SCStreamConfiguration()
                cfg.width = 16
                cfg.height = 16
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: nil)
                try await s.startCapture()
                try? await Task.sleep(nanoseconds: 500_000_000)
                try? await s.stopCapture()
                await MainActor.run { ready = true }
                log("wallpaper", "live wallpaper warm-up ok")
            } catch {
                await MainActor.run { ready = false }
                log("wallpaper", "live wallpaper warm-up failed: \(error.localizedDescription); static wallpaper will be used")
            }
        }
    }
}

final class WallpaperProvider: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private weak var layer: CALayer?
    private let sampleQueue = DispatchQueue(label: "orgscreensaver.wallpaper")

    func start(screen: NSScreen, layer: CALayer, live: Bool) {
        self.layer = layer
        layer.contentsGravity = .resizeAspectFill
        layer.backgroundColor = NSColor.black.cgColor
        applyStatic(screen: screen, layer: layer)
        guard live else { return }
        guard CGPreflightScreenCaptureAccess(), LiveWallpaperGate.ready else {
            log("wallpaper", "live wallpaper skipped: Screen Recording not granted or not warmed up; using static wallpaper")
            return
        }
        Task { await self.startLive(screen: screen) }
    }

    func stop() {
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
    }

    private func applyStatic(screen: NSScreen, layer: CALayer) {
        if let url = NSWorkspace.shared.desktopImageURL(for: screen),
           let img = NSImage(contentsOf: url),
           let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            layer.contents = cg
            log("wallpaper", "static wallpaper applied")
        } else {
            log("wallpaper", "static wallpaper unavailable; using black")
        }
    }

    private func startLive(screen: NSScreen) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else {
                log("wallpaper", "live wallpaper: display not found")
                return
            }
            let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
            let windows = content.windows.filter { $0.windowLayer < iconLevel && $0.frame.intersects(display.frame) }
            guard !windows.isEmpty else {
                log("wallpaper", "live wallpaper: no desktop-level windows found")
                return
            }
            log("wallpaper", "live wallpaper: capturing \(windows.count) desktop-level window(s): " +
                windows.map { $0.owningApplication?.applicationName ?? "?" }.joined(separator: ","))
            let filter = SCContentFilter(display: display, including: windows)
            let cfg = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            cfg.width = Int(screen.frame.width * scale)
            cfg.height = Int(screen.frame.height * scale)
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            cfg.showsCursor = false
            cfg.queueDepth = 3
            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await s.startCapture()
            stream = s
        } catch {
            log("wallpaper", "live wallpaper failed: \(error.localizedDescription); keeping static wallpaper")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, raw == SCFrameStatus.complete.rawValue,
              let pixels = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue() else { return }
        DispatchQueue.main.async { [weak self] in self?.layer?.contents = surface }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("wallpaper", "live wallpaper stream stopped: \(error.localizedDescription)")
    }
}

// MARK: - Cover content

final class CoverView: NSView {
    private let wallpaperLayer = CALayer()
    private let dim = CALayer()
    private let clock = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let dots = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let testLabel = NSTextField(labelWithString: "")
    private var clockTimer: Timer?
    private let wallpaper = WallpaperProvider()
    private let screen: NSScreen

    init(screen: NSScreen, message: String, testMode: Bool, liveWallpaper: Bool) {
        self.screen = screen
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        wallpaperLayer.frame = bounds
        wallpaperLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(wallpaperLayer)
        dim.frame = bounds
        dim.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        dim.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        layer?.addSublayer(dim)

        style(clock, size: 96, weight: .thin, alpha: 0.95)
        style(messageLabel, size: 28, weight: .regular, alpha: 0.9)
        style(dots, size: 30, weight: .regular, alpha: 0.9)
        style(status, size: 15, weight: .regular, alpha: 0.7)
        messageLabel.stringValue = message
        messageLabel.isHidden = message.trimmingCharacters(in: .whitespaces).isEmpty
        messageLabel.maximumNumberOfLines = 3
        messageLabel.preferredMaxLayoutWidth = 700
        messageLabel.alignment = .center

        let stack = NSStackView(views: [clock, messageLabel, dots, status])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 800)
        ])

        if testMode {
            style(testLabel, size: 14, weight: .semibold, alpha: 1)
            testLabel.stringValue = "TEST MODE: press ESC to exit"
            testLabel.textColor = .systemYellow
            testLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(testLabel)
            NSLayoutConstraint.activate([
                testLabel.topAnchor.constraint(equalTo: topAnchor, constant: 24),
                testLabel.centerXAnchor.constraint(equalTo: centerXAnchor)
            ])
        }
        updateClock()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateClock() }
        wallpaper.start(screen: screen, layer: wallpaperLayer, live: liveWallpaper)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func style(_ f: NSTextField, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) {
        f.font = .systemFont(ofSize: size, weight: weight)
        f.textColor = NSColor.white.withAlphaComponent(alpha)
        f.alignment = .center
        f.isBezeled = false
        f.drawsBackground = false
    }

    private func updateClock() {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        clock.stringValue = f.string(from: Date())
    }

    func update(digitCount: Int, dotsToShow: Int, statusText: String) {
        if digitCount == 0 {
            dots.stringValue = ""
        } else {
            dots.stringValue = (0..<max(dotsToShow, digitCount)).map { $0 < digitCount ? "●" : "○" }.joined(separator: " ")
        }
        status.stringValue = statusText
    }

    func shake() {
        guard let l = dots.layer ?? { dots.wantsLayer = true; return dots.layer }() else { return }
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        a.values = [0, -14, 14, -10, 10, -5, 5, 0]
        a.duration = 0.45
        l.add(a, forKey: "shake")
    }

    func tearDown() {
        clockTimer?.invalidate()
        clockTimer = nil
        wallpaper.stop()
    }
}

// MARK: - Window

final class CoverWindow: NSWindow {
    let coverView: CoverView
    var onFallbackKey: ((NSEvent) -> Void)?

    init(screen: NSScreen, message: String, testMode: Bool, liveWallpaper: Bool) {
        coverView = CoverView(screen: screen, message: message, testMode: testMode, liveWallpaper: liveWallpaper)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        canHide = false
        contentView = coverView
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Fallback path: only reached if the event tap is not delivering (it normally swallows keys first).
    override func keyDown(with event: NSEvent) { onFallbackKey?(event) }
    override func performClose(_ sender: Any?) {}
    override func miniaturize(_ sender: Any?) {}
    override func performMiniaturize(_ sender: Any?) {}
}
