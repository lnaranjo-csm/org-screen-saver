import XCTest
@testable import OrgScreenSaverCore

final class KeyClassifierTests: XCTestCase {
    func key(_ code: Int, cmd: Bool = false) -> KeyInput { KeyInput(kind: .keyDown, keyCode: code, command: cmd) }

    func testPassesEverythingWhenNotLocked() {
        XCTAssertEqual(KeyClassifier.classify(key(0), locked: false, testMode: false).action, .pass)
    }

    func testDigitsAreConsumedNotSnapshotted() {
        let d = KeyClassifier.classify(key(18), locked: true, testMode: false)
        XCTAssertEqual(d, KeyDecision(action: .digit(1), snapshot: false))
        let pad = KeyClassifier.classify(key(92), locked: true, testMode: false)
        XCTAssertEqual(pad.action, .digit(9))
        XCTAssertEqual(KeyClassifier.classify(key(29), locked: true, testMode: false).action, .digit(0))
    }

    func testCommandDigitIsNotADigit() {
        let d = KeyClassifier.classify(key(18, cmd: true), locked: true, testMode: false)
        XCTAssertEqual(d, KeyDecision(action: .drop, snapshot: true))
    }

    func testF1F2PassThrough() {
        XCTAssertEqual(KeyClassifier.classify(key(122), locked: true, testMode: false).action, .pass)
        XCTAssertEqual(KeyClassifier.classify(key(120), locked: true, testMode: false).action, .pass)
        let up = KeyInput(kind: .keyUp, keyCode: 122)
        XCTAssertEqual(KeyClassifier.classify(up, locked: true, testMode: false).action, .pass)
    }

    func testBrightnessSystemKeysPassOthersDrop() {
        let bright = KeyInput(kind: .systemDefined, sysSubtype: 8, sysKeyCode: 3, sysKeyDown: true)
        XCTAssertEqual(KeyClassifier.classify(bright, locked: true, testMode: false).action, .pass)
        let volume = KeyInput(kind: .systemDefined, sysSubtype: 8, sysKeyCode: 0, sysKeyDown: true)
        XCTAssertEqual(KeyClassifier.classify(volume, locked: true, testMode: false),
                       KeyDecision(action: .drop, snapshot: true))
    }

    func testOtherKeysDropAndSnapshot() {
        XCTAssertEqual(KeyClassifier.classify(key(0), locked: true, testMode: false),
                       KeyDecision(action: .drop, snapshot: true))
        XCTAssertEqual(KeyClassifier.classify(key(12, cmd: true), locked: true, testMode: false),
                       KeyDecision(action: .drop, snapshot: true))
    }

    func testEscapeOnlyUnlocksInTestMode() {
        XCTAssertEqual(KeyClassifier.classify(key(53), locked: true, testMode: true).action, .escapeUnlock)
        XCTAssertEqual(KeyClassifier.classify(key(53), locked: true, testMode: false),
                       KeyDecision(action: .drop, snapshot: true))
    }

    func testPointerAndModifiersDroppedQuietly() {
        XCTAssertEqual(KeyClassifier.classify(KeyInput(kind: .pointer), locked: true, testMode: false),
                       KeyDecision(action: .drop, snapshot: false))
        XCTAssertEqual(KeyClassifier.classify(KeyInput(kind: .flagsChanged), locked: true, testMode: false),
                       KeyDecision(action: .drop, snapshot: false))
        XCTAssertEqual(KeyClassifier.classify(KeyInput(kind: .keyUp, keyCode: 0), locked: true, testMode: false),
                       KeyDecision(action: .drop, snapshot: false))
    }
}

final class SecurityTests: XCTestCase {
    func testHashVerify() {
        let h = SecretHasher.make("1234", iterations: 1000)
        XCTAssertTrue(SecretHasher.verify("1234", against: h))
        XCTAssertFalse(SecretHasher.verify("1235", against: h))
        XCTAssertNotEqual(h.salt, SecretHasher.make("1234", iterations: 1000).salt)
    }

    func testLimiterEscalation() {
        var l = AttemptLimiter()
        let t = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(l.recordFailure(now: t), 0)
        XCTAssertEqual(l.recordFailure(now: t), 0)
        XCTAssertEqual(l.recordFailure(now: t), 30)
        XCTAssertTrue(l.isLockedOut(now: t.addingTimeInterval(29)))
        XCTAssertFalse(l.isLockedOut(now: t.addingTimeInterval(31)))
        XCTAssertEqual(l.recordFailure(now: t), 0)
        XCTAssertEqual(l.recordFailure(now: t), 0)
        XCTAssertEqual(l.recordFailure(now: t), 300)
        l.reset()
        XCTAssertEqual(l.failures, 0)
    }

    func testDigitEntryPinOnly() {
        let ok: (String) -> Bool = { $0 == "1234" }
        let no: (String) -> Bool = { _ in false }
        func eval(_ b: String) -> EntryOutcome {
            DigitEntry.evaluate(buffer: b, pinEnabled: true, recoveryEnabled: false, verifyPIN: ok, verifyRecovery: no)
        }
        XCTAssertEqual(eval("12"), .pending)
        XCTAssertEqual(eval("1234"), .unlock)
        XCTAssertEqual(eval("9999"), .fail)
    }

    func testDigitEntryWithRecovery() {
        let pin: (String) -> Bool = { $0 == "1234" }
        let rec: (String) -> Bool = { $0 == "87654321" }
        func eval(_ b: String) -> EntryOutcome {
            DigitEntry.evaluate(buffer: b, pinEnabled: true, recoveryEnabled: true, verifyPIN: pin, verifyRecovery: rec)
        }
        XCTAssertEqual(eval("1234"), .unlock)
        XCTAssertEqual(eval("8765"), .pending)
        XCTAssertEqual(eval("87654321"), .unlock)
        XCTAssertEqual(eval("87654320"), .fail)
    }
}

final class ConfigTests: XCTestCase {
    func testDefaultsAreSafe() {
        let missing = URL(fileURLWithPath: "/nonexistent/config.json")
        XCTAssertFalse(AppConfig.load(from: missing).testMode)
    }

    func testParsesAndToleratesPartialFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oss-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"testMode": true}"#.utf8).write(to: url)
        let cfg = AppConfig.load(from: url)
        XCTAssertTrue(cfg.testMode)
        XCTAssertEqual(cfg.testAutoUnlockMinutes, 5)
        try Data("not json".utf8).write(to: url)
        XCTAssertFalse(AppConfig.load(from: url).testMode)
    }
}

final class ScheduleTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testWeeklyNextOccurrence() {
        // 2026-11-17 is a Tuesday (weekday 3). Schedule Mon (2) and Wed (4) at 09:30.
        let s = Schedule.weekly(hour: 9, minute: 30, weekdays: [2, 4], now: date(2026, 11, 17, 8, 0))
        XCTAssertEqual(s.nextOccurrence(after: date(2026, 11, 17, 8, 0), calendar: cal), date(2026, 11, 18, 9, 30))
        XCTAssertEqual(s.nextOccurrence(after: date(2026, 11, 18, 9, 30), calendar: cal), date(2026, 11, 23, 9, 30))
    }

    func testOnceFiresWithinGraceThenDisables() {
        let now = date(2026, 11, 17, 10, 0)
        let s = Schedule.once(at: date(2026, 11, 17, 10, 5), now: now)
        XCTAssertFalse(ScheduleEvaluator.evaluate(s, now: date(2026, 11, 17, 10, 4), calendar: cal).fire)
        let r = ScheduleEvaluator.evaluate(s, now: date(2026, 11, 17, 10, 6), calendar: cal)
        XCTAssertTrue(r.fire)
        XCTAssertFalse(r.schedule.enabled)
    }

    func testMissedBeyondGraceIsSkipped() {
        let s = Schedule.once(at: date(2026, 11, 17, 10, 5), now: date(2026, 11, 17, 10, 0))
        let r = ScheduleEvaluator.evaluate(s, now: date(2026, 11, 17, 12, 0), calendar: cal)
        XCTAssertFalse(r.fire)
        XCTAssertFalse(r.schedule.enabled)
    }

    func testWeeklyDoesNotRefireSameOccurrence() {
        let s = Schedule.weekly(hour: 9, minute: 0, weekdays: [3], now: date(2026, 11, 17, 8, 0))
        let r1 = ScheduleEvaluator.evaluate(s, now: date(2026, 11, 17, 9, 1), calendar: cal)
        XCTAssertTrue(r1.fire)
        let r2 = ScheduleEvaluator.evaluate(r1.schedule, now: date(2026, 11, 17, 9, 2), calendar: cal)
        XCTAssertFalse(r2.fire)
    }
}

final class MiscTests: XCTestCase {
    func testThrottle() {
        var t = SnapshotThrottle(minInterval: 5, maxPerSession: 2)
        let n = Date()
        XCTAssertTrue(t.allow(now: n))
        XCTAssertFalse(t.allow(now: n.addingTimeInterval(1)))
        XCTAssertTrue(t.allow(now: n.addingTimeInterval(6)))
        XCTAssertFalse(t.allow(now: n.addingTimeInterval(20)))
    }

    func testSemVer() {
        XCTAssertTrue(SemVer.isNewer("v1.2.0", than: "1.1.9"))
        XCTAssertTrue(SemVer.isNewer("1.10.0", than: "1.9.0"))
        XCTAssertFalse(SemVer.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(SemVer.isNewer("0.9", than: "1.0.0"))
    }
}
