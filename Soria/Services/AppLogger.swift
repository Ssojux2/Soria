import Foundation

final class AppLogger {
    static let shared = AppLogger()
    private let queue = DispatchQueue(label: "soria.logger.queue", qos: .utility)
    private let logFileURL: URL

    private init() {
        AppPaths.ensureDirectories()
        logFileURL = AppPaths.logsDirectory.appendingPathComponent("app.log")
    }

    func info(_ message: String) {
        write(level: "INFO", message: message)
    }

    func error(_ message: String) {
        write(level: "ERROR", message: message)
    }

    private func write(level: String, message: String) {
        // 한국어: 로컬 로그 파일에 타임스탬프와 레벨을 기록합니다.
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(level)] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: self.logFileURL.path) {
                if let handle = try? FileHandle(forWritingTo: self.logFileURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: self.logFileURL)
            }
        }
    }
}
