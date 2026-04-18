import CryptoKit
import Foundation

enum AppSettingsStore {
    private static let pythonExecutableKey = "settings.pythonExecutablePath"
    private static let workerScriptKey = "settings.workerScriptPath"
    private static let lastRekordboxXMLPathKey = "settings.lastRekordboxXMLPath"
    private static let googleAIAPIKeyAccount = "google_ai_api_key"
    private static let legacyGeminiAPIKeyAccount = "gemini_api_key"
    private static let skipInitialSetupArgument = "UITEST_SKIP_INITIAL_SETUP"
    private static let uiTestLibraryStatePrefix = "UITEST_LIBRARY_STATE="
    private static let embeddingProfileIDKey = "settings.embeddingProfileID"
    private static let lastValidatedKeyHashKey = "settings.lastValidatedKeyHash"
    private static let lastValidatedProfileIDKey = "settings.lastValidatedProfileID"
    private static let lastValidatedAtKey = "settings.lastValidatedAt"
    private static let automaticVectorRepairSignaturePrefix = "settings.vectorRepairSignature."
    private static let automaticVectorRepairAtPrefix = "settings.vectorRepairAt."
    private static let analysisConcurrencyProfileKey = "settings.analysisConcurrencyProfile"
    private static let recommendationWeightsKey = "settings.recommendationWeights"
    private static let mixsetVectorWeightsKey = "settings.mixsetVectorWeights"
    private static let recommendationConstraintsKey = "settings.recommendationConstraints"
    private static let protectedUserFolders = ["Documents", "Desktop", "Downloads"]

    static func loadPythonExecutablePath() -> String {
        if let environmentValue = ProcessInfo.processInfo.environment["SORIA_PYTHON"], !environmentValue.isEmpty {
            return environmentValue
        }
        let bundledPath = bundledPythonExecutablePath()
        let detectedProjectPath = detectedProjectPythonExecutablePath()
        if let storedValue = UserDefaults.standard.string(forKey: pythonExecutableKey), !storedValue.isEmpty {
            let resolved = resolvedWorkerRuntimePath(
                storedValue: storedValue,
                bundledPath: bundledPath,
                detectedProjectPath: detectedProjectPath
            )
            if resolved != storedValue {
                UserDefaults.standard.set(resolved, forKey: pythonExecutableKey)
            }
            return resolved
        }
        if let detected = bundledPath ?? detectedProjectPath {
            return detected
        }
        return "/usr/bin/python3"
    }

    @discardableResult
    static func savePythonExecutablePath(_ path: String) -> String {
        let resolved = resolvedWorkerRuntimePath(
            storedValue: path,
            bundledPath: bundledPythonExecutablePath(),
            detectedProjectPath: detectedProjectPythonExecutablePath()
        )
        UserDefaults.standard.set(resolved, forKey: pythonExecutableKey)
        return resolved
    }

    static func loadWorkerScriptPath() -> String {
        if let environmentValue = ProcessInfo.processInfo.environment["SORIA_WORKER_SCRIPT"], !environmentValue.isEmpty {
            return environmentValue
        }
        let bundledPath = bundledWorkerScriptPath()
        let detectedProjectPath = detectedProjectWorkerScriptPath()
        if let storedValue = UserDefaults.standard.string(forKey: workerScriptKey), !storedValue.isEmpty {
            let resolved = resolvedWorkerRuntimePath(
                storedValue: storedValue,
                bundledPath: bundledPath,
                detectedProjectPath: detectedProjectPath
            )
            if resolved != storedValue {
                UserDefaults.standard.set(resolved, forKey: workerScriptKey)
            }
            return resolved
        }
        return bundledPath
            ?? detectedProjectPath
            ?? "\(FileManager.default.currentDirectoryPath)/analysis-worker/main.py"
    }

    @discardableResult
    static func saveWorkerScriptPath(_ path: String) -> String {
        let resolved = resolvedWorkerRuntimePath(
            storedValue: path,
            bundledPath: bundledWorkerScriptPath(),
            detectedProjectPath: detectedProjectWorkerScriptPath()
        )
        UserDefaults.standard.set(resolved, forKey: workerScriptKey)
        return resolved
    }

    static func loadLastRekordboxXMLPath() -> String? {
        guard let storedValue = UserDefaults.standard.string(forKey: lastRekordboxXMLPathKey), !storedValue.isEmpty else {
            return nil
        }
        let normalized = TrackPathNormalizer.normalizedAbsolutePath(storedValue)
        return normalized.isEmpty ? nil : normalized
    }

    static func saveLastRekordboxXMLPath(_ path: String) {
        let normalized = TrackPathNormalizer.normalizedAbsolutePath(path)
        guard !normalized.isEmpty else {
            UserDefaults.standard.removeObject(forKey: lastRekordboxXMLPathKey)
            return
        }
        UserDefaults.standard.set(normalized, forKey: lastRekordboxXMLPathKey)
    }

    static func loadGoogleAIAPIKey(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if shouldBypassSecureLookupsForUITests(arguments: arguments) {
            return googleAIAPIKeyOverride(in: environment) ?? ""
        }

        let saved = AppKeychain.load(account: googleAIAPIKeyAccount)
            ?? AppKeychain.load(account: legacyGeminiAPIKeyAccount)
        if let saved, !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return saved.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let override = googleAIAPIKeyOverride(in: environment) {
            return override
        }
        return AppKeychain.load(account: googleAIAPIKeyAccount)
            ?? AppKeychain.load(account: legacyGeminiAPIKeyAccount)
            ?? ""
    }

    static func shouldBypassSecureLookupsForUITests(arguments: [String]) -> Bool {
        arguments.contains(skipInitialSetupArgument)
            || arguments.contains(where: { $0.hasPrefix(uiTestLibraryStatePrefix) })
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
        let storedID = UserDefaults.standard.string(forKey: embeddingProfileIDKey)
        if storedID == EmbeddingProfile.legacyGoogleTextEmbedding004ID ||
            storedID == EmbeddingProfile.legacyGeminiEmbedding001ID
        {
            UserDefaults.standard.set(EmbeddingProfile.googleGeminiEmbedding2Preview.id, forKey: embeddingProfileIDKey)
            clearValidationMetadata()
            return .googleGeminiEmbedding2Preview
        }
        return EmbeddingProfile.resolve(id: storedID)
    }

    static func saveEmbeddingProfile(_ profile: EmbeddingProfile) {
        UserDefaults.standard.set(profile.id, forKey: embeddingProfileIDKey)
    }

    static func loadAnalysisConcurrencyProfile() -> AnalysisConcurrencyProfile {
        guard
            let rawValue = UserDefaults.standard.string(forKey: analysisConcurrencyProfileKey),
            let profile = AnalysisConcurrencyProfile(rawValue: rawValue)
        else {
            return .default
        }
        return profile
    }

    static func saveAnalysisConcurrencyProfile(_ profile: AnalysisConcurrencyProfile) {
        UserDefaults.standard.set(profile.rawValue, forKey: analysisConcurrencyProfileKey)
    }

    static func loadRecommendationWeights() -> RecommendationWeights {
        loadCodable(RecommendationWeights.self, forKey: recommendationWeightsKey) ?? .defaults
    }

    static func saveRecommendationWeights(_ weights: RecommendationWeights) {
        saveCodable(weights, forKey: recommendationWeightsKey)
    }

    static func loadMixsetVectorWeights() -> MixsetVectorWeights {
        loadCodable(MixsetVectorWeights.self, forKey: mixsetVectorWeightsKey) ?? .defaults
    }

    static func saveMixsetVectorWeights(_ weights: MixsetVectorWeights) {
        saveCodable(weights, forKey: mixsetVectorWeightsKey)
    }

    static func loadRecommendationConstraints() -> RecommendationConstraints {
        loadCodable(RecommendationConstraints.self, forKey: recommendationConstraintsKey) ?? .defaults
    }

    static func saveRecommendationConstraints(_ constraints: RecommendationConstraints) {
        saveCodable(constraints, forKey: recommendationConstraintsKey)
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

    static func automaticVectorRepairSignature(profileID: String) -> String? {
        UserDefaults.standard.string(forKey: automaticVectorRepairSignaturePrefix + sanitizeProfileKey(profileID))
    }

    static func automaticVectorRepairDate(profileID: String) -> Date? {
        guard let raw = UserDefaults.standard.string(forKey: automaticVectorRepairAtPrefix + sanitizeProfileKey(profileID)) else {
            return nil
        }
        return LibraryDatabase.iso8601.date(from: raw)
    }

    static func markAutomaticVectorRepair(profileID: String, signature: String, date: Date = Date()) {
        let suffix = sanitizeProfileKey(profileID)
        UserDefaults.standard.set(signature, forKey: automaticVectorRepairSignaturePrefix + suffix)
        UserDefaults.standard.set(LibraryDatabase.iso8601.string(from: date), forKey: automaticVectorRepairAtPrefix + suffix)
    }

    static func clearAutomaticVectorRepair(profileID: String) {
        let suffix = sanitizeProfileKey(profileID)
        UserDefaults.standard.removeObject(forKey: automaticVectorRepairSignaturePrefix + suffix)
        UserDefaults.standard.removeObject(forKey: automaticVectorRepairAtPrefix + suffix)
    }

    static func detectedPythonExecutablePath() -> String? {
        bundledPythonExecutablePath() ?? detectedProjectPythonExecutablePath()
    }

    static func detectedWorkerScriptPath() -> String? {
        bundledWorkerScriptPath() ?? detectedProjectWorkerScriptPath()
    }

    private static func googleAIAPIKeyOverride(in environment: [String: String]) -> String? {
        for key in ["GOOGLE_AI_API_KEY", "GOOGLE_API_KEY", "GEMINI_API_KEY"] {
            if let rawValue = environment[key] {
                let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    static func bundledPythonExecutablePath(bundle: Bundle = .main) -> String? {
        guard let resourcesURL = bundle.resourceURL else { return nil }
        let candidate = resourcesURL.appendingPathComponent("analysis-worker/.venv/bin/python").path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    static func bundledWorkerScriptPath(bundle: Bundle = .main) -> String? {
        guard let resourcesURL = bundle.resourceURL else { return nil }
        let candidate = resourcesURL.appendingPathComponent("analysis-worker/main.py").path
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    static func detectedProjectPythonExecutablePath() -> String? {
        guard let projectRoot else { return nil }
        let candidate = projectRoot.appendingPathComponent("analysis-worker/.venv/bin/python").path
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    static func detectedProjectWorkerScriptPath() -> String? {
        guard let projectRoot else { return nil }
        let candidate = projectRoot.appendingPathComponent("analysis-worker/main.py").path
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    static func resolvedWorkerRuntimePath(
        storedValue: String,
        bundledPath: String?,
        detectedProjectPath: String?
    ) -> String {
        let trimmed = storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return bundledPath ?? detectedProjectPath ?? "" }
        guard let bundledPath else { return trimmed }
        guard shouldPreferBundledRuntime(
            storedPath: trimmed,
            bundledPath: bundledPath,
            detectedProjectPath: detectedProjectPath
        ) else {
            return trimmed
        }
        return bundledPath
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

    private static func sanitizeProfileKey(_ profileID: String) -> String {
        profileID.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "_"
        }.joined()
    }

    private static func shouldPreferBundledRuntime(
        storedPath: String,
        bundledPath: String,
        detectedProjectPath: String?
    ) -> Bool {
        let standardizedStored = URL(fileURLWithPath: storedPath).standardizedFileURL.path
        let standardizedBundled = URL(fileURLWithPath: bundledPath).standardizedFileURL.path
        if standardizedStored == standardizedBundled {
            return false
        }
        if let detectedProjectPath,
           standardizedStored == URL(fileURLWithPath: detectedProjectPath).standardizedFileURL.path
        {
            return true
        }
        if !FileManager.default.fileExists(atPath: standardizedStored) {
            return true
        }
        return isProtectedAnalysisWorkerPath(standardizedStored)
    }

    private static func isProtectedAnalysisWorkerPath(_ path: String) -> Bool {
        guard path.contains("/analysis-worker/") else { return false }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL.path
        return protectedUserFolders.contains { folder in
            path.hasPrefix(home + "/\(folder)/")
        }
    }

    private static func loadCodable<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func saveCodable<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
