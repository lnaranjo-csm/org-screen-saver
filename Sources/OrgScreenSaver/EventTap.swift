import Foundation
import AppKit
import CoreGraphics
import OrgScreenSaverCore

/// Session-level active event tap. Everything goes through `KeyClassifier`; dropped events never reach any app.
final class EventTap {
    /// Called on the main thread for each classified event.
    var onDecision: ((KeyDecision, KeyInput) -> Void)?
    var isLocked: () -> Bool = { false }
    var testMode: () -> Bool = { false }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
        return me.handle(type: type, event: event)
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = ~CGEventMask(0)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: EventTap.callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log("input", "event tap creation FAILED (Accessibility permission missing?)")
            return false
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        source = src
        log("input", "event tap installed")
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        source = nil
        log("input", "event tap removed")
    }

    var isRunning: Bool { tap != nil }

    func reenableIfNeeded() {
        guard let t = tap else { return }
        if !CGEvent.tapIsEnabled(tap: t) {
            CGEvent.tapEnable(tap: t, enable: true)
            log("input", "event tap was disabled by the system; re-enabled")
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            log("input", "event tap disabled by system (\(type.rawValue)); re-enabled")
            return Unmanaged.passUnretained(event)
        }
        let input = EventTap.makeInput(type: type, event: event)
        let decision = KeyClassifier.classify(input, locked: isLocked(), testMode: testMode())
        if decision.action != .pass {
            // Tap runs on the main run loop, so this is already the main thread.
            onDecision?(decision, input)
        }
        return decision.action == .pass ? Unmanaged.passUnretained(event) : nil
    }

    static func makeInput(type: CGEventType, event: CGEvent) -> KeyInput {
        let flags = event.flags
        let cmd = flags.contains(.maskCommand), ctl = flags.contains(.maskControl), opt = flags.contains(.maskAlternate)
        switch type {
        case .keyDown, .keyUp:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            return KeyInput(kind: type == .keyDown ? .keyDown : .keyUp, keyCode: code,
                            command: cmd, control: ctl, option: opt)
        case .flagsChanged:
            return KeyInput(kind: .flagsChanged, command: cmd, control: ctl, option: opt)
        default:
            if type.rawValue == 14 { // NX_SYSDEFINED
                if let ns = NSEvent(cgEvent: event) {
                    let data1 = ns.data1
                    let keyCode = (data1 & 0xFFFF0000) >> 16
                    let down = ((data1 & 0xFF00) >> 8) == 0xA
                    return KeyInput(kind: .systemDefined, sysSubtype: Int(ns.subtype.rawValue),
                                    sysKeyCode: keyCode, sysKeyDown: down)
                }
                return KeyInput(kind: .systemDefined)
            }
            return KeyInput(kind: .pointer)
        }
    }
}
