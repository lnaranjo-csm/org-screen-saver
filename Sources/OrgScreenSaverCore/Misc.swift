import Foundation

/// Limits how often intruder snapshots are taken (typing a long string must not fill the disk).
public struct SnapshotThrottle {
    public var minInterval: TimeInterval
    public var maxPerSession: Int
    private var lastTime: Date?
    private var count = 0

    public init(minInterval: TimeInterval = 5, maxPerSession: Int = 100) {
        self.minInterval = minInterval
        self.maxPerSession = maxPerSession
    }

    public mutating func allow(now: Date) -> Bool {
        guard count < maxPerSession else { return false }
        if let last = lastTime, now.timeIntervalSince(last) < minInterval { return false }
        lastTime = now
        count += 1
        return true
    }

    public mutating func reset() {
        lastTime = nil
        count = 0
    }
}

/// Minimal semantic-version comparison for GitHub release tags such as "v1.2.3".
public enum SemVer {
    public static func parse(_ s: String) -> [Int] {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        let core = t.split(separator: "-").first.map(String.init) ?? t
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parse(candidate), b = parse(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
