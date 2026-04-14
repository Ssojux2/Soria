import Foundation

enum AppSettingsStore {
    private static let pythonExecutableKey = "settings.pythonExecutablePath"
    private static let workerScriptKey = "settings.workerScriptPath"
    private static let geminiAPIKeyAccount = "gemini_api_key"
    private static let embeddingProviderKey = "settings.embeddingProvider"
    private static let embeddingProviderLockedKey = "settings.embeddingProviderLocked"

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

    static func loadGeminiAPIKey() -> String {
        if let environmentValue = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !environmentValue.isEmpty {
            return environmentValue
        }
        return AppKeychain.load(account: geminiAPIKeyAccount) ?? ""
    }

    static func saveGeminiAPIKey(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // 한국어: 민감한 키는 Keychain에 저장해 앱 재실행 후에도 안전하게 유지합니다.
        if trimmed.isEmpty {
            try AppKeychain.delete(account: geminiAPIKeyAccount)
        } else {
            try AppKeychain.save(trimmed, account: geminiAPIKeyAccount)
        }
    }

    static func loadEmbeddingProvider() -> EmbeddingProvider {
        if
            let rawValue = UserDefaults.standard.string(forKey: embeddingProviderKey),
            let provider = EmbeddingProvider(rawValue: rawValue)
        {
            return provider
        }
        return .googleEmbedding2
    }

    static func loadEmbeddingProviderLocked() -> Bool {
        UserDefaults.standard.bool(forKey: embeddingProviderLockedKey)
    }

    static func saveEmbeddingProvider(_ provider: EmbeddingProvider) {
        UserDefaults.standard.set(provider.rawValue, forKey: embeddingProviderKey)
    }

    static func lockEmbeddingProviderIfNeeded(_ provider: EmbeddingProvider) {
        if !loadEmbeddingProviderLocked() {
            saveEmbeddingProvider(provider)
            UserDefaults.standard.set(true, forKey: embeddingProviderLockedKey)
        }
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
}
