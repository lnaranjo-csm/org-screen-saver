import Foundation

public struct Schedule: Codable, Identifiable, Equatable {
    public enum Kind: String, Codable { case once, weekly }

    public var id: UUID
    public var kind: Kind
    /// For `.once`: the exact fire date.
    public var date: Date?
    /// For `.weekly`: time of day and weekdays (1 = Sunday ... 7 = Saturday).
    public var hour: Int
    public var minute: Int
    public var weekdays: [Int]
    public var enabled: Bool
    /// Occurrences at or before this moment have already been handled.
    public var lastHandled: Date

    public init(id: UUID = UUID(), kind: Kind, date: Date? = nil, hour: Int = 0, minute: Int = 0,
                weekdays: [Int] = [], enabled: Bool = true, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.date = date
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
        self.enabled = enabled
        self.lastHandled = createdAt
    }

    public static func once(at date: Date, now: Date = Date()) -> Schedule {
        Schedule(kind: .once, date: date, createdAt: now)
    }

    public static func weekly(hour: Int, minute: Int, weekdays: [Int], now: Date = Date()) -> Schedule {
        Schedule(kind: .weekly, hour: hour, minute: minute, weekdays: weekdays.sorted(), createdAt: now)
    }

    /// The next occurrence strictly after `ref`.
    public func nextOccurrence(after ref: Date, calendar: Calendar = .current) -> Date? {
        switch kind {
        case .once:
            guard let d = date, d > ref else { return nil }
            return d
        case .weekly:
            guard !weekdays.isEmpty else { return nil }
            let startOfRef = calendar.startOfDay(for: ref)
            var best: Date?
            for offset in 0...7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: startOfRef),
                      weekdays.contains(calendar.component(.weekday, from: day)),
                      let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                      candidate > ref else { continue }
                if best == nil || candidate < best! { best = candidate }
            }
            return best
        }
    }

    public var summary: String {
        switch kind {
        case .once:
            return date.map { Self.onceFormatter.string(from: $0) } ?? "Invalid"
        case .weekly:
            let names = Calendar.current.shortWeekdaySymbols
            let days = weekdays.sorted().map { names[($0 - 1) % 7] }.joined(separator: ", ")
            return String(format: "%02d:%02d on %@", hour, minute, days)
        }
    }

    private static let onceFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

public enum ScheduleEvaluator {
    /// If a schedule's occurrence was missed by more than this (for example the Mac was asleep), it is skipped.
    public static let graceSeconds: TimeInterval = 600

    public struct Result: Equatable {
        public var fire: Bool
        public var schedule: Schedule
    }

    /// Checks whether a schedule is due and returns it updated (marked as handled).
    public static func evaluate(_ schedule: Schedule, now: Date, calendar: Calendar = .current) -> Result {
        var s = schedule
        guard s.enabled, let next = s.nextOccurrence(after: s.lastHandled, calendar: calendar), next <= now else {
            return Result(fire: false, schedule: s)
        }
        s.lastHandled = now
        if s.kind == .once { s.enabled = false }
        return Result(fire: now.timeIntervalSince(next) <= graceSeconds, schedule: s)
    }
}
