import CryptoKit
import Foundation

enum AppSettingsStore {
    private static let pythonExecutableKey = "settings.pythonExecutablePath"
    private static let workerScriptKey = "settings.workerScriptPath"
    private static let googleAIAPIKeyAccount = "google_ai_api_key"
    private static let legacyGeminiAPIKeyAccount = "gemini_api_key"
    private static let embeddingProfileIDKey = "settings.embeddingProfileID"
    private static let lastValidatedKeyHashKey = "settings.lastValidatedKeyHash"
    private static let lastValidatedProfileIDKey = "settings.lastValidatedProfileID"
    private static let lastValidatedAtKey = "settings.lastValidatedAt"

    static func loadPythonExecutablePath() -> String {
        if let environmentValue = ProcessInfo.processInfo.environment["SORIA_PYTHON"], !environmentValue.isEmpty {
            return environmentValue
        }
        if let storedValue = UserDefaults.standard.string(forKey: pythonExecutableKey), !storedValue.isEmpty {
            return storedValue
        }
        if let detected = detectedPythonExecutablePath() {
            return detected
        }
        return "/usr/bin/python3"
    }

    static func savePythonExecutablePath(_ path: String) {
        UserDefaults.standard.set(path.trimmingCharacters(in: .whitespacesAndNewlines), forKey: pythonExecutableKey)
    }

    static func loadWorkerScriptPath() -> String {
        if let environmentValue = ProcessInfo.processInfo.environment["SORIA_WORKER_SCRIPT"], !environmentValue.isEmpty {
            return environmentValue
        }
        if let storedValue = UserDefaults.standard.string(forKey: workerScriptKey), !storedValue.isEmpty {
            return storedValue
        }
        return detectedWorkerScriptPath() ?? "\(FileManager.default.currentDirectoryPath)/analysis-worker/main.py"
    }

    static func saveWorkerScriptPath(_ path: String) {
        UserDefaults.standard.set(path.trimmingCharacters(in: .whitespacesAndNewlines), forKey: workerScriptKey)
    }

    static func loadGoogleAIAPIKey() -> String {
        let saved = AppKeychain.load(account: googleAIAPIKeyAccount)
            ?? AppKeychain.load(account: legacyGeminiAPIKeyAccount)
        if let saved, !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return saved.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let environment = ProcessInfo.processInfo.environment
        for key in ["GOOGLE_AI_API_KEY", "GOOGLE_API_KEY", "GEMINI_API_KEY"] {
            if let rawValue = environment[key], !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return AppKeychain.load(account: googleAIAPIKeyAccount)
            ?? AppKeychain.load(account: legacyGeminiAPIKeyAccount)
            ?? ""
    }

    static func saveGoogleAIAPIKey(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try AppKeychain.delete(account: googleAIAPIKeyAccount)
            try AppKeychain.delete(account: legacyGeminiAPIKeyAccount)
        } else {
            try AppKeychain.save(trimmed, account: googleAIAPIKeyAccount)
        }
    }

    static func loadEmbeddingProfile() -> EmbeddingProfile {
        EmbeddingProfile.resolve(id: UserDefaults.standard.string(forKey: embeddingProfileIDKey))
    }

    static func saveEmbeddingProfile(_ profile: EmbeddingProfile) {
        UserDefaults.standard.set(profile.id, forKey: embeddingProfileIDKey)
    }

    static func currentValidationStatus(apiKey: String, profile: EmbeddingProfile) -> ValidationStatus {
        computeValidationStatus(
            apiKey: apiKey,
            profile: profile,
            storedKeyHash: UserDefaults.standard.string(forKey: lastValidatedKeyHashKey),
            storedProfileID: UserDefaults.standard.string(forKey: lastValidatedProfileIDKey),
            storedAt: lastValidatedAt()
        )
    }

    static func computeValidationStatus(
        apiKey: String,
        profile: EmbeddingProfile,
        storedKeyHash: String?,
        storedProfileID: String?,
        storedAt: Date?
    ) -> ValidationStatus {
        guard
            let storedKeyHash,
            let storedProfileID,
            let storedAt
        else {
            return .unvalidated
        }

        guard storedProfileID == profile.id else {
            return .unvalidated
        }

        guard storedKeyHash == hashAPIKey(apiKey) else {
            return .unvalidated
        }

        return .validated(storedAt)
    }

    static func markValidationSuccess(apiKey: String, profile: EmbeddingProfile, date: Date = Date()) {
        UserDefaults.standard.set(hashAPIKey(apiKey), forKey: lastValidatedKeyHashKey)
        UserDefaults.standard.set(profile.id, forKey: lastValidatedProfileIDKey)
        UserDefaults.standard.set(LibraryDatabase.iso8601.string(from: date), forKey: lastValidatedAtKey)
    }

    static func clearValidationMetadata() {
        UserDefaults.standard.removeObject(forKey: lastValidatedKeyHashKey)
        UserDefaults.standard.removeObject(forKey: lastValidatedProfileIDKey)
        UserDefaults.standard.removeObject(forKey: lastValidatedAtKey)
    }

    static func hashAPIKey(_ apiKey: String) -> String {
        let digest = SHA256.hash(data: Data(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func detectedPythonExecutablePath() -> String? {
        guard let projectRoot else { return nil }
        let candidate = projectRoot.appendingPathComponent("analysis-worker/.venv/bin/python").path
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    static func detectedWorkerScriptPath() -> String? {
        guard let projectRoot else { return nil }
        let candidate = projectRoot.appendingPathComponent("analysis-worker/main.py").path
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    static var projectRoot: URL? {
        let fileManager = FileManager.default
        let startingPoints = [
            URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true),
            URL(fileURLWithPath: Bundle.main.bundleURL.deletingLastPathComponent().path, isDirectory: true)
        ]

        for start in startingPoints {
            var current = start
            for _ in 0..<8 {
                let workerPath = current.appendingPathComponent("analysis-worker/main.py").path
                if fileManager.fileExists(atPath: workerPath) {
                    return current
                }
                current.deleteLastPathComponent()
            }
        }
        return nil
    }

    private static func lastValidatedAt() -> Date? {
        guard let raw = UserDefaults.standard.string(forKey: lastValidatedAtKey) else {
            return nil
        }
        return LibraryDatabase.iso8601.date(from: raw)
    }
}
