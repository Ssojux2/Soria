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
    private static let analysisWorkerBundleMarker = "/Contents/Resources/analysis-worker/"

    private struct WorkerRuntimeResolution {
        let path: String
        let reason: String
    }

    static func loadPythonExecutablePath() -> String {
        if let environmentValue = ProcessInfo.processInfo.environment["SORIA_PYTHON"], !environmentValue.isEmpty {
            return environmentValue
        }
        let bundledPath = bundledPythonExecutablePath()
        let detectedProjectPath = projectPythonExecutableCandidatePath()
        if let storedValue = UserDefaults.standard.string(forKey: pythonExecutableKey), !storedValue.isEmpty {
            let resolution = resolvedWorkerRuntimeSelection(
                storedValue: storedValue,
                bundledPath: bundledPath,
                detectedProjectPath: detectedProjectPath
            )
            let resolved = resolution.path.isEmpty ? (detectedProjectPath ?? bundledPath ?? "/usr/bin/python3") : resolution.path
            if resolved != storedValue {
                persistWorkerRuntimePath(resolved, forKey: pythonExecutableKey)
                logWorkerRuntimePathUpdate(
                    kind: "python",
                    originalPath: storedValue,
                    resolvedPath: resolved,
                    reason: resolution.reason
                )
            }
            return resolved
        }
        if let detected = detectedProjectPath ?? bundledPath {
            return detected
        }
        return "/usr/bin/python3"
    }

    @discardableResult
    static func savePythonExecutablePath(_ path: String) -> String {
        let resolved = resolvedWorkerRuntimePath(
            storedValue: path,
            bundledPath: bundledPythonExecutablePath(),
            detectedProjectPath: projectPythonExecutableCandidatePath()
        )
        persistWorkerRuntimePath(resolved, forKey: pythonExecutableKey)
        return resolved
    }

    static func loadWorkerScriptPath() -> String {
        if let environmentValue = ProcessInfo.processInfo.environment["SORIA_WORKER_SCRIPT"], !environmentValue.isEmpty {
            return environmentValue
        }
        let bundledPath = bundledWorkerScriptPath()
        let detectedProjectPath = projectWorkerScriptCandidatePath()
        if let storedValue = UserDefaults.standard.string(forKey: workerScriptKey), !storedValue.isEmpty {
            let resolution = resolvedWorkerRuntimeSelection(
                storedValue: storedValue,
                bundledPath: bundledPath,
                detectedProjectPath: detectedProjectPath
            )
            let resolved = resolution.path.isEmpty
                ? (detectedProjectPath ?? bundledPath ?? "\(FileManager.default.currentDirectoryPath)/analysis-worker/main.py")
                : resolution.path
            if resolved != storedValue {
                persistWorkerRuntimePath(resolved, forKey: workerScriptKey)
                logWorkerRuntimePathUpdate(
                    kind: "script",
                    originalPath: storedValue,
                    resolvedPath: resolved,
                    reason: resolution.reason
                )
            }
            return resolved
        }
        return detectedProjectPath
            ?? bundledPath
            ?? "\(FileManager.default.currentDirectoryPath)/analysis-worker/main.py"
    }

    @discardableResult
    static func saveWorkerScriptPath(_ path: String) -> String {
        let resolved = resolvedWorkerRuntimePath(
            storedValue: path,
            bundledPath: bundledWorkerScriptPath(),
            detectedProjectPath: projectWorkerScriptCandidatePath()
        )
        persistWorkerRuntimePath(resolved, forKey: workerScriptKey)
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
        detectedProjectPythonExecutablePath() ?? bundledPythonExecutablePath()
    }

    static func detectedWorkerScriptPath() -> String? {
        detectedProjectWorkerScriptPath() ?? bundledWorkerScriptPath()
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
        guard let candidate = projectPythonExecutableCandidatePath() else { return nil }
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    static func detectedProjectWorkerScriptPath() -> String? {
        guard let candidate = projectWorkerScriptCandidatePath() else { return nil }
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    static func resolvedWorkerRuntimePath(
        storedValue: String,
        bundledPath: String?,
        detectedProjectPath: String?
    ) -> String {
        resolvedWorkerRuntimeSelection(
            storedValue: storedValue,
            bundledPath: bundledPath,
            detectedProjectPath: detectedProjectPath
        ).path
    }

    nonisolated static var projectRoot: URL? {
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

    nonisolated static func projectPythonExecutableCandidatePath() -> String? {
        projectRoot?.appendingPathComponent("analysis-worker/.venv/bin/python").path
    }

    nonisolated static func projectWorkerScriptCandidatePath() -> String? {
        projectRoot?.appendingPathComponent("analysis-worker/main.py").path
    }

    private static func resolvedWorkerRuntimeSelection(
        storedValue: String,
        bundledPath: String?,
        detectedProjectPath: String?
    ) -> WorkerRuntimeResolution {
        let trimmed = storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let standardizedStored = standardizedWorkerRuntimePath(trimmed)
        let standardizedBundled = bundledPath.map(standardizedWorkerRuntimePath)
        let standardizedProject = detectedProjectPath.map(standardizedWorkerRuntimePath)

        guard !standardizedStored.isEmpty else {
            if let standardizedProject {
                return WorkerRuntimeResolution(path: standardizedProject, reason: "prefer_detected_project")
            }
            if let standardizedBundled {
                return WorkerRuntimeResolution(path: standardizedBundled, reason: "fallback_to_current_bundle")
            }
            return WorkerRuntimeResolution(path: "", reason: "no_runtime_available")
        }

        if isExistingExternalWorkerRuntimePath(standardizedStored) {
            return WorkerRuntimeResolution(path: standardizedStored, reason: "keep_custom_external_runtime")
        }

        if let standardizedProject {
            return WorkerRuntimeResolution(path: standardizedProject, reason: "prefer_detected_project")
        }

        if let standardizedBundled {
            if isAnalysisWorkerBundlePath(standardizedStored) {
                return WorkerRuntimeResolution(path: standardizedBundled, reason: "fallback_to_current_bundle")
            }
            if !FileManager.default.fileExists(atPath: standardizedStored) {
                return WorkerRuntimeResolution(path: standardizedBundled, reason: "replace_missing_path_with_current_bundle")
            }
        }

        if isAnalysisWorkerBundlePath(standardizedStored) && standardizedBundled == nil {
            return WorkerRuntimeResolution(path: "", reason: "discard_stale_bundle_runtime")
        }

        if FileManager.default.fileExists(atPath: standardizedStored) {
            return WorkerRuntimeResolution(path: standardizedStored, reason: "keep_existing_non_bundle_runtime")
        }

        return WorkerRuntimeResolution(path: standardizedBundled ?? "", reason: "discard_missing_runtime")
    }

    nonisolated private static func standardizedWorkerRuntimePath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func isExistingExternalWorkerRuntimePath(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path) && !isAnalysisWorkerBundlePath(path)
    }

    private static func isAnalysisWorkerBundlePath(_ path: String) -> Bool {
        analysisWorkerBundleRoot(for: path) != nil
    }

    private static func analysisWorkerBundleRoot(for path: String) -> String? {
        let standardizedPath = standardizedWorkerRuntimePath(path)
        guard let markerRange = standardizedPath.range(of: analysisWorkerBundleMarker) else {
            return nil
        }
        let bundleRoot = String(standardizedPath[..<markerRange.lowerBound])
        return bundleRoot.hasSuffix(".app") ? bundleRoot : nil
    }

    private static func logWorkerRuntimePathUpdate(
        kind: String,
        originalPath: String,
        resolvedPath: String,
        reason: String
    ) {
        AppLogger.shared.info(
            "Worker runtime path updated | kind=\(kind) | from=\(originalPath) | to=\(resolvedPath) | reason=\(reason)"
        )
    }

    private static func persistWorkerRuntimePath(_ path: String, forKey key: String) {
        let defaults = UserDefaults.standard
        defaults.set(path, forKey: key)
        defaults.synchronize()
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
