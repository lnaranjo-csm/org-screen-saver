import Foundation

/// Well-known file locations.
public enum AppPaths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    public static var appSupport: URL { home.appendingPathComponent("Library/Application Support/OrgScreenSaver") }
    public static var logs: URL { home.appendingPathComponent("Library/Logs/OrgScreenSaver") }
    public static var configFile: URL { appSupport.appendingPathComponent("config.json") }
    public static var lockStateFile: URL { appSupport.appendingPathComponent("lock.state") }
    public static var snapshots: URL { appSupport.appendingPathComponent("Snapshots") }
    public static var logFile: URL { logs.appendingPathComponent("orgscreensaver.log") }

    public static func ensureDirectories() {
        for dir in [appSupport, logs, snapshots] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
    }
}

/// The hidden developer config file. Test mode lives here, NOT in the app UI, and is off by default.
public struct AppConfig: Codable, Equatable {
    public var testMode: Bool
    public var testAutoUnlockMinutes: Int

    public init(testMode: Bool = false, testAutoUnlockMinutes: Int = 5) {
        self.testMode = testMode
        self.testAutoUnlockMinutes = testAutoUnlockMinutes
    }

    enum CodingKeys: String, CodingKey { case testMode, testAutoUnlockMinutes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        testMode = try c.decodeIfPresent(Bool.self, forKey: .testMode) ?? false
        testAutoUnlockMinutes = try c.decodeIfPresent(Int.self, forKey: .testAutoUnlockMinutes) ?? 5
    }

    /// Reads the config. A missing or unreadable file means defaults (test mode OFF).
    public static func load(from url: URL = AppPaths.configFile) -> AppConfig {
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else { return AppConfig() }
        return AppConfig(testMode: cfg.testMode, testAutoUnlockMinutes: max(1, cfg.testAutoUnlockMinutes))
    }

    /// Creates the file with defaults if it does not exist, so it can be found and edited.
    public static func writeDefaultIfMissing(at url: URL = AppPaths.configFile) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(AppConfig()) { try? data.write(to: url, options: .atomic) }
    }
}
