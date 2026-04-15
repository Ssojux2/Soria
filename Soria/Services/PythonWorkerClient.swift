import Foundation

struct WorkerSegmentResult: Codable {
    let segmentType: String
    let startSec: Double
    let endSec: Double
    let energyScore: Double
    let descriptorText: String
    let embedding: [Double]?
}

struct WorkerEmbeddingResult: Codable {
    let trackEmbedding: [Double]?
    let segments: [WorkerSegmentResult]
    let embeddingProfileID: String
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
    let embeddingProfileID: String
}

struct WorkerTrackSearchResult: Codable {
    let trackID: String
    let filePath: String
    let fusedScore: Double
    let trackScore: Double
    let introScore: Double
    let middleScore: Double
    let outroScore: Double
    let bestMatchedCollection: String
}

struct WorkerTrackSearchResponse: Codable {
    let results: [WorkerTrackSearchResult]
}

struct WorkerValidationResponse: Codable {
    let ok: Bool
    let profileID: String
    let modelName: String
}

final class PythonWorkerClient {
    struct WorkerConfig {
        var pythonExecutable: String
        var workerScriptPath: String
        var googleAIAPIKey: String?
        var embeddingProfile: EmbeddingProfile
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
        let payload = WorkerAnalyzePayload(
            command: "analyze",
            filePath: filePath,
            trackMetadata: trackMetadata(for: track, externalMetadata: externalMetadata),
            options: workerOptions()
        )
        return try await runGeneric(payload: payload)
    }

    func embedDescriptors(
        track: Track,
        segments: [TrackSegment],
        externalMetadata: [ExternalDJMetadata] = []
    ) async throws -> WorkerEmbeddingResult {
        let payload = WorkerEmbedDescriptorsPayload(
            command: "embed_descriptors",
            filePath: track.filePath,
            trackMetadata: trackMetadata(for: track, externalMetadata: externalMetadata),
            segments: segments.map {
                WorkerDescriptorSegment(
                    segmentType: $0.type.rawValue,
                    startSec: $0.startSec,
                    endSec: $0.endSec,
                    energyScore: $0.energyScore,
                    descriptorText: $0.descriptorText
                )
            },
            options: workerOptions()
        )
        return try await runGeneric(payload: payload)
    }

    func validateEmbeddingProfile() async throws -> WorkerValidationResponse {
        let payload = WorkerValidatePayload(
            command: "validate_embedding_profile",
            options: workerOptions()
        )
        return try await runGeneric(payload: payload)
    }

    func searchTracksText(
        query: String,
        limit: Int,
        excludeTrackPaths: [String],
        filters: WorkerSimilarityFilters
    ) async throws -> WorkerTrackSearchResponse {
        let payload = WorkerTrackSearchPayload(
            command: "search_tracks",
            mode: "text",
            queryText: query,
            queryTrackEmbedding: nil,
            querySegments: [],
            limit: limit,
            excludeTrackPaths: excludeTrackPaths,
            filters: filters,
            weights: [
                "tracks": 0.45,
                "intro": 0.15,
                "middle": 0.25,
                "outro": 0.15
            ],
            options: workerOptions()
        )
        return try await runGeneric(payload: payload)
    }

    func searchTracksReference(
        track: Track,
        segments: [TrackSegment],
        trackEmbedding: [Double],
        limit: Int,
        excludeTrackPaths: [String],
        filters: WorkerSimilarityFilters
    ) async throws -> WorkerTrackSearchResponse {
        let payload = WorkerTrackSearchPayload(
            command: "search_tracks",
            mode: "reference",
            queryText: nil,
            queryTrackEmbedding: trackEmbedding,
            querySegments: segments.compactMap { segment in
                guard let vector = segment.vector else { return nil }
                return WorkerQuerySegment(
                    segmentType: segment.type.rawValue,
                    embedding: vector
                )
            },
            limit: limit,
            excludeTrackPaths: excludeTrackPaths,
            filters: filters,
            weights: [
                "tracks": 0.70,
                "intro": 0.10,
                "middle": 0.10,
                "outro": 0.10
            ],
            options: workerOptions()
        )
        return try await runGeneric(payload: payload)
    }

    private func workerOptions() -> WorkerOptionsPayload {
        let config = configProvider()
        return WorkerOptionsPayload(
            googleAIAPIKey: config.googleAIAPIKey,
            cacheDirectory: AppPaths.pythonCacheDirectory.path,
            embeddingProfileID: config.embeddingProfile.id
        )
    }

    private func trackMetadata(for track: Track, externalMetadata: [ExternalDJMetadata]) -> WorkerTrackMetadataPayload {
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

        return WorkerTrackMetadataPayload(
            trackID: track.id.uuidString,
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
        )
    }

    private func runGeneric<T: Encodable, U: Decodable>(payload: T) async throws -> U {
        let config = configProvider()
        let payloadData = try JSONEncoder().encode(payload)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let result: U = try PythonWorkerClient.runGenericBlocking(config: config, payloadData: payloadData)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runGenericBlocking<U: Decodable>(config: WorkerConfig, payloadData: Data) throws -> U {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.pythonExecutable)
        process.arguments = [config.workerScriptPath]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        try inputPipe.fileHandleForWriting.write(contentsOf: payloadData)
        try inputPipe.fileHandleForWriting.close()

        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
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
            let errorText = String(data: stderrData, encoding: .utf8) ?? ""
            throw WorkerError.decodeFailed([text, errorText].filter { !$0.isEmpty }.joined(separator: "\n"))
        }
    }
}

struct WorkerSimilarityFilters: Codable {
    var bpmMin: Double?
    var bpmMax: Double?
    var durationMaxSec: Double?
    var musicalKey: String?
    var genre: String?
}

private struct WorkerTrackMetadataPayload: Codable {
    let trackID: String
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

private struct WorkerOptionsPayload: Codable {
    let googleAIAPIKey: String?
    let cacheDirectory: String
    let embeddingProfileID: String
}

private struct WorkerAnalyzePayload: Codable {
    let command: String
    let filePath: String
    let trackMetadata: WorkerTrackMetadataPayload
    let options: WorkerOptionsPayload
}

private struct WorkerDescriptorSegment: Codable {
    let segmentType: String
    let startSec: Double
    let endSec: Double
    let energyScore: Double
    let descriptorText: String
}

private struct WorkerEmbedDescriptorsPayload: Codable {
    let command: String
    let filePath: String
    let trackMetadata: WorkerTrackMetadataPayload
    let segments: [WorkerDescriptorSegment]
    let options: WorkerOptionsPayload
}

private struct WorkerValidatePayload: Codable {
    let command: String
    let options: WorkerOptionsPayload
}

private struct WorkerQuerySegment: Codable {
    let segmentType: String
    let embedding: [Double]
}

private struct WorkerTrackSearchPayload: Codable {
    let command: String
    let mode: String
    let queryText: String?
    let queryTrackEmbedding: [Double]?
    let querySegments: [WorkerQuerySegment]
    let limit: Int
    let excludeTrackPaths: [String]
    let filters: WorkerSimilarityFilters
    let weights: [String: Double]
    let options: WorkerOptionsPayload
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
        .init(
            pythonExecutable: AppSettingsStore.loadPythonExecutablePath(),
            workerScriptPath: AppSettingsStore.loadWorkerScriptPath(),
            googleAIAPIKey: AppSettingsStore.loadGoogleAIAPIKey(),
            embeddingProfile: AppSettingsStore.loadEmbeddingProfile()
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
