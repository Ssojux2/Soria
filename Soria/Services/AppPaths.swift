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
    static func makeRecoveryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Soria-recovery-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    static func ensureDirectories() {
        let fm = FileManager.default
        [pythonCacheDirectory, exportsDirectory, logsDirectory].forEach {
            try? fm.createDirectory(at: $0, withIntermediateDirectories: true)
        }
    }
}
