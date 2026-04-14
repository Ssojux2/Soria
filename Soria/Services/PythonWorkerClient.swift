import Foundation

struct WorkerSegmentResult: Codable {
    let segmentType: String
    let startSec: Double
    let endSec: Double
    let energyScore: Double
    let descriptorText: String
    let embedding: [Double]?
}

struct WorkerAnalysisResult: Codable {
    let estimatedBPM: Double?
    let estimatedKey: String?
    let trackEmbedding: [Double]?
    let brightness: Double
    let onsetDensity: Double
    let rhythmicDensity: Double
    let lowMidHighBalance: [Double]
    let waveformPreview: [Double]
    let segments: [WorkerSegmentResult]
}

struct WorkerSimilarityResult: Codable {
    let filePath: String
    let vectorSimilarity: Double
}

struct WorkerSimilarityResponse: Codable {
    let results: [WorkerSimilarityResult]
}

struct WorkerDependencyStatus: Codable {
    let librosa: Bool
    let chromadb: Bool
    let requests: Bool
}

struct WorkerHealthcheckResponse: Codable {
    let ok: Bool
    let apiKeyConfigured: Bool
    let pythonExecutable: String
    let workerScriptPath: String
    let embeddingProviderLocked: Bool?
    let embeddingProvider: String?
    let dependencies: WorkerDependencyStatus
}

final class PythonWorkerClient {
    struct WorkerConfig {
        var pythonExecutable: String
        var workerScriptPath: String
        var geminiAPIKey: String?
        var embeddingProvider: EmbeddingProvider
    }

    private let configProvider: () -> WorkerConfig

    init(configProvider: @escaping () -> WorkerConfig = { .current }) {
        self.configProvider = configProvider
    }

    func analyze(
        filePath: String,
        track: Track,
        externalMetadata: [ExternalDJMetadata] = []
    ) async throws -> WorkerAnalysisResult {
        let aggregatedTags = Array(
            Set(
                externalMetadata
                    .flatMap(\.tags)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        ).sorted()
        let rating = externalMetadata.compactMap(\.rating).max()
        let playCount = externalMetadata.compactMap(\.playCount).max()
        let playlistMemberships = Array(Set(externalMetadata.flatMap(\.playlistMemberships))).sorted()
        let cueCount = externalMetadata.compactMap(\.cueCount).max()
        let comment = externalMetadata.compactMap(\.comment).first
        let payload = WorkerPayload(
            command: "analyze",
            filePath: filePath,
            trackMetadata: WorkerPayload.TrackMetadata(
                title: track.title,
                artist: track.artist,
                genre: track.genre,
                bpm: track.bpm,
                musicalKey: track.musicalKey,
                duration: track.duration,
                modifiedTime: LibraryDatabase.iso8601.string(from: track.modifiedTime),
                contentHash: track.contentHash,
                hasSeratoMetadata: track.hasSeratoMetadata,
                hasRekordboxMetadata: track.hasRekordboxMetadata,
                tags: aggregatedTags,
                rating: rating,
                playCount: playCount,
                playlistMemberships: playlistMemberships,
                cueCount: cueCount,
                comment: comment
            ),
            options: WorkerPayload.WorkerOptions(
                geminiAPIKey: configProvider().geminiAPIKey,
                cacheDirectory: AppPaths.pythonCacheDirectory.path,
                embeddingProvider: configProvider().embeddingProvider.rawValue
            )
        )
        return try run(payload: payload)
    }

    func querySimilarTracks(
        queryEmbedding: [Double],
        limit: Int,
        excludeTrackPaths: [String],
        filters: WorkerSimilarityFilters
    ) async throws -> WorkerSimilarityResponse {
        let payload = WorkerSimilarityPayload(
            command: "query_similar",
            queryEmbedding: queryEmbedding,
            limit: limit,
            excludeTrackPaths: excludeTrackPaths,
            filters: filters,
            options: WorkerPayload.WorkerOptions(
                geminiAPIKey: nil,
                cacheDirectory: AppPaths.pythonCacheDirectory.path,
                embeddingProvider: configProvider().embeddingProvider.rawValue
            )
        )
        return try runGeneric(payload: payload)
    }

    func healthcheck() async throws -> WorkerHealthcheckResponse {
        let config = configProvider()
        let payload = WorkerHealthcheckPayload(
            command: "healthcheck",
            options: WorkerPayload.WorkerOptions(
                geminiAPIKey: config.geminiAPIKey,
                cacheDirectory: AppPaths.pythonCacheDirectory.path,
                embeddingProvider: config.embeddingProvider.rawValue
            )
        )
        return try runGeneric(payload: payload)
    }

    private func run(payload: WorkerPayload) throws -> WorkerAnalysisResult {
        try runGeneric(payload: payload)
    }

    private func runGeneric<T: Encodable, U: Decodable>(payload: T) throws -> U {
        // 한국어: 워커 프로세스를 1회 실행해 JSON 기반 IPC로 결과를 수신합니다.
        let config = configProvider()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.pythonExecutable)
        process.arguments = [config.workerScriptPath]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        try process.run()

        let payloadData = try JSONEncoder().encode(payload)
        inputPipe.fileHandleForWriting.write(payloadData)
        try inputPipe.fileHandleForWriting.close()

        process.waitUntilExit()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let stderrData = (process.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            throw WorkerError.executionFailed(stderr)
        }

        if let parsedError = try? JSONDecoder().decode(WorkerErrorResponse.self, from: outputData), !parsedError.error.isEmpty {
            throw WorkerError.executionFailed(parsedError.error)
        }
        do {
            return try JSONDecoder().decode(U.self, from: outputData)
        } catch {
            let text = String(data: outputData, encoding: .utf8) ?? ""
            throw WorkerError.decodeFailed(text)
        }
    }
}

private struct WorkerPayload: Codable {
    struct TrackMetadata: Codable {
        let title: String
        let artist: String
        let genre: String
        let bpm: Double?
        let musicalKey: String?
        let duration: Double
        let modifiedTime: String
        let contentHash: String
        let hasSeratoMetadata: Bool
        let hasRekordboxMetadata: Bool
        let tags: [String]
        let rating: Int?
        let playCount: Int?
        let playlistMemberships: [String]
        let cueCount: Int?
        let comment: String?
    }

    struct WorkerOptions: Codable {
        let geminiAPIKey: String?
        let cacheDirectory: String
        let embeddingProvider: String
    }

    let command: String
    let filePath: String
    let trackMetadata: TrackMetadata
    let options: WorkerOptions
}

struct WorkerSimilarityFilters: Codable {
    var bpmMin: Double?
    var bpmMax: Double?
    var durationMaxSec: Double?
    var musicalKey: String?
    var genre: String?
}

private struct WorkerSimilarityPayload: Codable {
    let command: String
    let queryEmbedding: [Double]
    let limit: Int
    let excludeTrackPaths: [String]
    let filters: WorkerSimilarityFilters
    let options: WorkerPayload.WorkerOptions
}

private struct WorkerHealthcheckPayload: Codable {
    let command: String
    let options: WorkerPayload.WorkerOptions
}

private struct WorkerErrorResponse: Codable {
    let error: String
}

enum WorkerError: Error {
    case executionFailed(String)
    case decodeFailed(String)
}

private extension PythonWorkerClient.WorkerConfig {
    static var current: PythonWorkerClient.WorkerConfig {
        return .init(
            pythonExecutable: AppSettingsStore.loadPythonExecutablePath(),
            workerScriptPath: AppSettingsStore.loadWorkerScriptPath(),
            geminiAPIKey: AppSettingsStore.loadGeminiAPIKey(),
            embeddingProvider: AppSettingsStore.loadEmbeddingProvider()
        )
    }
}

extension WorkerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .executionFailed(let detail):
            return detail.isEmpty ? "Worker execution failed." : detail
        case .decodeFailed(let payload):
            return payload.isEmpty ? "Worker returned unreadable output." : payload
        }
    }
}
