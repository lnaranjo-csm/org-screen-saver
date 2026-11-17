import AppKit
import AVFoundation
import OrgScreenSaverCore

// MARK: - Wallpaper

/// Shows the custom background (image, or a muted looping video) if one is set, otherwise the current static desktop
/// picture, otherwise black.
final class WallpaperProvider {
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?

    func start(screen: NSScreen, layer: CALayer) {
        layer.contentsGravity = .resizeAspectFill
        layer.backgroundColor = NSColor.black.cgColor
        if let video = CustomBackground.videoURL() {
            let item = AVPlayerItem(url: video)
            let p = AVQueuePlayer()
            p.isMuted = true
            p.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: p, templateItem: item)
            let pl = AVPlayerLayer(player: p)
            pl.frame = layer.bounds
            pl.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            pl.videoGravity = .resizeAspectFill
            layer.addSublayer(pl)
            player = p
            p.play()
            log("wallpaper", "custom video background playing")
        } else if let custom = CustomBackground.loadImage() {
            layer.contents = custom
            log("wallpaper", "custom background applied")
        } else if let url = NSWorkspace.shared.desktopImageURL(for: screen),
                  let img = NSImage(contentsOf: url),
                  let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            layer.contents = cg
            log("wallpaper", "static wallpaper applied")
        } else {
            log("wallpaper", "static wallpaper unavailable; using black")
        }
    }

    func stop() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
    }
}

// MARK: - Custom background

enum CustomBackground {
    static var directory: URL { AppPaths.appSupport }

    private static func isVideo(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .movie) ?? false
    }

    /// Copies the picked image or video into app support (so it survives the original being moved) and stores its path.
    static func set(from url: URL) -> Bool {
        let video = isVideo(url)
        if video {
            guard AVURLAsset(url: url).isPlayable else { return false }
        } else {
            guard NSImage(contentsOf: url) != nil else { return false }
        }
        AppPaths.ensureDirectories()
        clear()
        let dest = directory.appendingPathComponent("background-\(Int(Date().timeIntervalSince1970)).\(url.pathExtension.lowercased())")
        do {
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            log("wallpaper", "custom background copy failed: \(error.localizedDescription)")
            return false
        }
        Settings.shared.customBackgroundPath = dest.path
        return true
    }

    static func clear() {
        let path = Settings.shared.customBackgroundPath
        if !path.isEmpty { try? FileManager.default.removeItem(atPath: path) }
        Settings.shared.customBackgroundPath = ""
    }

    static func videoURL() -> URL? {
        let path = Settings.shared.customBackgroundPath
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        return isVideo(url) ? url : nil
    }

    static func loadImage() -> CGImage? {
        let path = Settings.shared.customBackgroundPath
        guard !path.isEmpty, let img = NSImage(contentsOfFile: path) else { return nil }
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
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

    init(screen: NSScreen, message: String, testMode: Bool) {
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
        wallpaper.start(screen: screen, layer: wallpaperLayer)
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

    init(screen: NSScreen, message: String, testMode: Bool) {
        coverView = CoverView(screen: screen, message: message, testMode: testMode)
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
