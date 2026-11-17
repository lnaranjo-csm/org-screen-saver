import Foundation
import AVFoundation
import CoreImage
import OrgScreenSaverCore

/// Takes a webcam photo when a foreign key is pressed on the cover. On-demand session, throttled.
final class SnapshotService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "orgscreensaver.snapshot")
    private let ciContext = CIContext()
    private var configured = false
    private var wantFrameAfter: Date?
    private var giveUpDarkAt: Date?
    private var pendingTag = ""
    private var stopWork: DispatchWorkItem?
    private var throttle = SnapshotThrottle(minInterval: 5, maxPerSession: 100)
    private var loggedMissingPermission = false

    static var authorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

    func beginLockSession() {
        throttle.reset()
        loggedMissingPermission = false
        purgeOld()
    }

    func endLockSession() {
        queue.async {
            self.wantFrameAfter = nil
            self.giveUpDarkAt = nil
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func capture(trigger: String) {
        guard Settings.shared.snapshotEnabled else { return }
        guard SnapshotService.authorized else {
            if !loggedMissingPermission {
                log("snapshot", "skipped: camera permission not granted")
                loggedMissingPermission = true
            }
            return
        }
        guard throttle.allow(now: Date()) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            guard self.configureIfNeeded() else { return }
            self.pendingTag = trigger
            if !self.session.isRunning {
                self.session.startRunning()
                // A cold camera starts with very dark frames until auto-exposure converges, so wait before
                // taking one, then keep skipping frames that are still near-black (up to a deadline).
                self.wantFrameAfter = Date().addingTimeInterval(1.5)
                self.giveUpDarkAt = Date().addingTimeInterval(4.0)
            } else {
                self.wantFrameAfter = Date()
                self.giveUpDarkAt = Date().addingTimeInterval(2.0)
            }
            self.stopWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if self.session.isRunning { self.session.stopRunning() }
            }
            self.stopWork = work
            self.queue.asyncAfter(deadline: .now() + 6, execute: work)
        }
    }

    private func configureIfNeeded() -> Bool {
        if configured { return true }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            log("snapshot", "no usable camera")
            return false
        }
        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canAddInput(input) { session.addInput(input) }
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        configured = true
        return true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let after = wantFrameAfter, Date() >= after,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixels)
        if let deadline = giveUpDarkAt, Date() < deadline, meanBrightness(of: image) < 0.06 { return } // still too dark
        wantFrameAfter = nil
        giveUpDarkAt = nil
        guard let jpeg = ciContext.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:]) else {
            log("snapshot", "JPEG encoding failed")
            return
        }
        AppPaths.ensureDirectories()
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = AppPaths.snapshots.appendingPathComponent("\(f.string(from: Date()))-\(pendingTag).jpg")
        do {
            try jpeg.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            log("snapshot", "saved \(url.lastPathComponent)")
        } catch {
            log("snapshot", "save failed: \(error.localizedDescription)")
        }
    }

    /// Average brightness 0...1, computed on the GPU/CPU from a 1x1 area average.
    private func meanBrightness(of image: CIImage) -> Double {
        let avg = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var px = [UInt8](repeating: 0, count: 4)
        ciContext.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (0.299 * Double(px[0]) + 0.587 * Double(px[1]) + 0.114 * Double(px[2])) / 255.0
    }

    /// Deletes snapshots older than the retention setting.
    func purgeOld() {
        let days = max(1, Settings.shared.snapshotRetentionDays)
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: AppPaths.snapshots, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        var removed = 0
        for url in files {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if date < cutoff, (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        if removed > 0 { log("snapshot", "purged \(removed) old snapshot(s)") }
    }
}
