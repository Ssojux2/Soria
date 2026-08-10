import Foundation

enum AppPaths {
    static let appSupportDirectory: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Soria", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static let databaseURL = appSupportDirectory.appendingPathComponent("library.sqlite")
    static let pythonCacheDirectory = appSupportDirectory.appendingPathComponent("worker-cache", isDirectory: true)
    static let exportsDirectory = appSupportDirectory.appendingPathComponent("exports", isDirectory: true)
    static let logsDirectory = appSupportDirectory.appendingPathComponent("logs", isDirectory: true)
    /// Last-resort home for quarantined tracks. The quarantine service prefers a
    /// folder on the track's own volume so the move stays an atomic rename; this
    /// is only used when neither the library root nor the volume root is writable.
    static let quarantineDirectory = appSupportDirectory.appendingPathComponent("quarantine", isDirectory: true)
    /// Folder name Soria creates inside a library root to hold quarantined tracks.
    /// The scanner is told to skip it so quarantined files are not re-indexed.
    static let quarantineFolderName = "Soria Quarantine"
    static func makeRecoveryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Soria-recovery-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    static func ensureDirectories() {
        let fm = FileManager.default
        [pythonCacheDirectory, exportsDirectory, logsDirectory, quarantineDirectory].forEach {
            try? fm.createDirectory(at: $0, withIntermediateDirectories: true)
        }
    }
}
