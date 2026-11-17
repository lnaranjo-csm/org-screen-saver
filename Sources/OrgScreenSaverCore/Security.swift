import Foundation
import CommonCrypto
import Security

// MARK: - Hashing

public struct HashedSecret: Codable, Equatable {
    public var salt: Data
    public var hash: Data
    public var iterations: Int
}

/// PBKDF2-SHA256 hashing for the PIN and recovery code. Secrets are never stored in plain text.
public enum SecretHasher {
    public static let defaultIterations = 100_000

    public static func make(_ secret: String, iterations: Int = defaultIterations) -> HashedSecret {
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        precondition(status == errSecSuccess, "Could not generate a random salt")
        return HashedSecret(salt: salt, hash: derive(secret, salt: salt, iterations: iterations), iterations: iterations)
    }

    public static func verify(_ secret: String, against stored: HashedSecret) -> Bool {
        let candidate = derive(secret, salt: stored.salt, iterations: stored.iterations)
        return constantTimeEqual(candidate, stored.hash)
    }

    static func derive(_ secret: String, salt: Data, iterations: Int) -> Data {
        var out = Data(count: 32)
        let secretBytes = Array(secret.utf8)
        _ = out.withUnsafeMutableBytes { outPtr in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    secretBytes.map { Int8(bitPattern: $0) }, secretBytes.count,
                    saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    outPtr.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        return out
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}

// MARK: - Wrong-attempt lockout

/// Escalating delay after wrong PIN attempts: 3 wrong = 30 s, 6 or more wrong = 5 min.
public struct AttemptLimiter: Equatable {
    public private(set) var failures = 0
    public private(set) var lockedUntil: Date?

    public init() {}

    public func remainingLockout(now: Date) -> TimeInterval {
        guard let until = lockedUntil else { return 0 }
        return max(0, until.timeIntervalSince(now))
    }

    public func isLockedOut(now: Date) -> Bool { remainingLockout(now: now) > 0 }

    /// Records a failure and returns the lockout (seconds) it triggered, or 0.
    @discardableResult
    public mutating func recordFailure(now: Date) -> TimeInterval {
        failures += 1
        let delay: TimeInterval
        switch failures {
        case ..<3: delay = 0
        case 3..<6: delay = 30
        default: delay = 300
        }
        // Only apply the lockout when a threshold is hit (3, 6, 7, 8, ...).
        let applies = failures == 3 || failures >= 6
        if applies && delay > 0 { lockedUntil = now.addingTimeInterval(delay); return delay }
        return 0
    }

    public mutating func reset() {
        failures = 0
        lockedUntil = nil
    }
}

// MARK: - Digit-entry evaluation

public enum EntryOutcome: Equatable { case pending, unlock, fail }

/// Evaluates the digits typed on the cover. A 4-digit PIN is checked as soon as 4 digits are typed.
/// If a recovery code is enabled (8 digits), a wrong 4-digit entry stays pending until 8 digits are typed.
public enum DigitEntry {
    public static let pinLength = 4
    public static let recoveryLength = 8

    public static func evaluate(buffer: String, pinEnabled: Bool, recoveryEnabled: Bool,
                                verifyPIN: (String) -> Bool, verifyRecovery: (String) -> Bool) -> EntryOutcome {
        let n = buffer.count
        if pinEnabled && n == pinLength {
            if verifyPIN(buffer) { return .unlock }
            if !recoveryEnabled { return .fail }
        }
        if recoveryEnabled && n == recoveryLength {
            return verifyRecovery(buffer) ? .unlock : .fail
        }
        if n >= (recoveryEnabled ? recoveryLength : pinLength) { return .fail }
        return .pending
    }
}
