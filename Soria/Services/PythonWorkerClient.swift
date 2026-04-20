import Darwin
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
    let embeddingPipelineID: String
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
    let waveformEnvelope: TrackWaveformEnvelope?
    let analysisFocus: AnalysisFocus
    let introLengthSec: Double
    let outroLengthSec: Double
    let energyArc: [Double]
    let mixabilityTags: [String]
    let confidence: Double
    let segments: [WorkerSegmentResult]
    let embeddingProfileID: String
    let embeddingPipelineID: String
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

struct WorkerQueryEmbeddingsResponse: Codable {
    let queryEmbeddings: [String: [Double]]
    let embeddingProfileID: String
}

struct WorkerValidationResponse: Codable {
    let ok: Bool
    let profileID: String
    let modelName: String
}

struct WorkerProfileStatus: Codable {
    let supported: Bool
    let requiresAPIKey: Bool
    let dependencyErrors: [String]
}

struct WorkerVectorIndexState: Codable {
    let trackCount: Int
    let collectionCounts: [String: Int]
    let manifestHash: String
}

struct WorkerHealthcheckResponse: Codable {
    let ok: Bool
    let apiKeyConfigured: Bool
    let pythonExecutable: String
    let workerScriptPath: String
    let embeddingProfileID: String
    let dependencies: [String: Bool]
    let profileStatusByID: [String: WorkerProfileStatus]
    let vectorIndexState: WorkerVectorIndexState?
}

struct WorkerMutationResponse: Codable {
    let ok: Bool
    let indexedTrackCount: Int?
    let embeddingProfileID: String?
    let deletedProfileIDs: [String]?
    let trackID: String?
}

enum WorkerTrackSearchMode: String, Codable, Equatable {
    case text
    case reference
    case hybrid
}

nonisolated final class PythonWorkerClient {
    typealias WorkerProgressHandler = @Sendable (WorkerProgressEvent) -> Void

    struct WorkerConfig {
        var pythonExecutable: String
        var workerScriptPath: String
        var googleAIAPIKey: String?
        var embeddingProfile: EmbeddingProfile
    }

    static let workerProgressPrefix = "SORIA_PROGRESS "
    static let defaultWorkerTimeoutSec =
        Double(ProcessInfo.processInfo.environment["SORIA_WORKER_TIMEOUT_SEC"] ?? "") ?? 120
    private static let persistentWaveformWorkerSession = PersistentWaveformWorkerSession()

    private let configProvider: () -> WorkerConfig

    init(configProvider: @escaping () -> WorkerConfig = { .current }) {
        self.configProvider = configProvider
    }

    func analyze(
        filePath: String,
        track: Track,
        analysisFocus: AnalysisFocus,
        externalMetadata: [ExternalDJMetadata] = [],
        progress: WorkerProgressHandler? = nil
    ) async throws -> WorkerAnalysisResult {
        let payload = WorkerAnalyzePayload(
            command: "analyze",
            filePath: filePath,
            trackMetadata: trackMetadata(for: track, externalMetadata: externalMetadata),
            options: workerOptions(analysisFocus: analysisFocus)
        )
        return try await runGeneric(payload: payload, progress: progress, commandName: payload.command)
    }

    func extractWaveformEnvelope(
        filePath: String,
        track: Track,
        externalMetadata: [ExternalDJMetadata] = [],
        progress: WorkerProgressHandler? = nil
    ) async throws -> TrackWaveformEnvelope {
        let payload = WorkerAnalyzePayload(
            command: "extract_waveform_envelope",
            filePath: filePath,
            trackMetadata: trackMetadata(for: track, externalMetadata: externalMetadata),
            options: workerOptions()
        )
        let response: WorkerWaveformEnvelopeResponse
        if progress == nil {
            do {
                response = try await Self.persistentWaveformWorkerSession.run(
                    config: configProvider(),
                    payload: payload,
                    commandName: payload.command
                )
            } catch is CancellationError {
                throw WorkerError.cancelled
            } catch {
                if Task.isCancelled {
                    throw WorkerError.cancelled
                }
                AppLogger.shared.info(
                    "Persistent waveform worker fallback engaged: \(Self.failureSummary(for: payload.command, error: error))"
                )
                response = try await runGeneric(
                    payload: payload,
                    progress: progress,
                    commandName: payload.command
                )
            }
        } else {
            response = try await runGeneric(
                payload: payload,
                progress: progress,
                commandName: payload.command
            )
        }
        return response.waveformEnvelope
    }

    func embedAudioSegments(
        track: Track,
        segments: [TrackSegment],
        externalMetadata: [ExternalDJMetadata] = [],
        progress: WorkerProgressHandler? = nil
    ) async throws -> WorkerEmbeddingResult {
        let payload = WorkerEmbedDescriptorsPayload(
            command: "embed_audio_segments",
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
        return try await runGeneric(payload: payload, progress: progress, commandName: payload.command)
    }

    func embedDescriptors(
        track: Track,
        segments: [TrackSegment],
        externalMetadata: [ExternalDJMetadata] = [],
        progress: WorkerProgressHandler? = nil
    ) async throws -> WorkerEmbeddingResult {
        try await embedAudioSegments(
            track: track,
            segments: segments,
            externalMetadata: externalMetadata,
            progress: progress
        )
    }

    func validateEmbeddingProfile() async throws -> WorkerValidationResponse {
        let payload = WorkerValidatePayload(
            command: "validate_embedding_profile",
            options: workerOptions()
        )
        return try await runGeneric(payload: payload, commandName: payload.command)
    }

    func healthcheck() async throws -> WorkerHealthcheckResponse {
        let payload = WorkerHealthcheckPayload(
            command: "healthcheck",
            options: workerOptions()
        )
        return try await runGeneric(payload: payload, commandName: payload.command)
    }

    func buildQueryEmbeddings(
        mode: WorkerTrackSearchMode,
        queryText: String?,
        trackEmbedding: [Double]?,
        segments: [TrackSegment]
    ) async throws -> WorkerQueryEmbeddingsResponse {
        let payload = WorkerBuildQueryEmbeddingsPayload(
            command: "build_query_embeddings",
            mode: mode,
            queryText: queryText,
            queryTrackEmbedding: trackEmbedding,
            querySegments: segments.compactMap { segment in
                guard let vector = segment.vector, !vector.isEmpty else { return nil }
                return WorkerQuerySegment(
                    segmentType: segment.type.rawValue,
                    embedding: vector
                )
            },
            options: workerOptions()
        )
        return try await runGeneric(payload: payload, commandName: payload.command)
    }

    func searchTracksText(
        query: String,
        limit: Int,
        excludeTrackPaths: [String],
        filters: WorkerSimilarityFilters,
        weights: [String: Double]? = nil
    ) async throws -> WorkerTrackSearchResponse {
        try await searchTracks(
            mode: .text,
            queryText: query,
            trackEmbedding: nil,
            segments: [],
            limit: limit,
            excludeTrackPaths: excludeTrackPaths,
            filters: filters,
            weights: weights ?? Self.textSearchWeights
        )
    }

    func searchTracksReference(
        track: Track,
        segments: [TrackSegment],
        trackEmbedding: [Double],
        limit: Int,
        excludeTrackPaths: [String],
        filters: WorkerSimilarityFilters,
        weights: [String: Double]? = nil
    ) async throws -> WorkerTrackSearchResponse {
        _ = track
        return try await searchTracks(
            mode: .reference,
            queryText: nil,
            trackEmbedding: trackEmbedding,
            segments: segments,
            limit: limit,
            excludeTrackPaths: excludeTrackPaths,
            filters: filters,
            weights: weights ?? Self.referenceSearchWeights
        )
    }

    func searchTracksHybrid(
        query: String,
        segments: [TrackSegment],
        trackEmbedding: [Double],
        limit: Int,
        excludeTrackPaths: [String],
        filters: WorkerSimilarityFilters,
        weights: [String: Double]? = nil
    ) async throws -> WorkerTrackSearchResponse {
        try await searchTracks(
            mode: .hybrid,
            queryText: query,
            trackEmbedding: trackEmbedding,
            segments: segments,
            limit: limit,
            excludeTrackPaths: excludeTrackPaths,
            filters: filters,
            weights: weights ?? Self.hybridSearchWeights
        )
    }

    func upsertTrackVectors(
        track: Track,
        segments: [TrackSegment],
        trackEmbedding: [Double]
    ) async throws {
        let payload = WorkerUpsertTrackVectorsPayload(
            command: "upsert_track_vectors",
            track: vectorTrackPayload(track: track, segments: segments, trackEmbedding: trackEmbedding),
            options: workerOptions()
        )
        let _: WorkerMutationResponse = try await runGeneric(payload: payload, commandName: payload.command)
    }

    func deleteTrackVectors(trackID: UUID, profileIDs: [String]? = nil, deleteAllProfiles: Bool = false) async throws {
        let payload = WorkerDeleteTrackVectorsPayload(
            command: "delete_track_vectors",
            trackID: trackID.uuidString,
            profileIDs: profileIDs,
            deleteAllProfiles: deleteAllProfiles,
            options: workerOptions()
        )
        let _: WorkerMutationResponse = try await runGeneric(payload: payload, commandName: payload.command)
    }

    func rebuildVectorIndex(tracks: [Track], segmentsByTrackID: [UUID: [TrackSegment]], trackEmbeddings: [UUID: [Double]]) async throws {
        let payloadTracks = tracks.compactMap { track -> WorkerIndexedTrackPayload? in
            guard
                let trackEmbedding = trackEmbeddings[track.id],
                !trackEmbedding.isEmpty,
                let segments = segmentsByTrackID[track.id]
            else {
                return nil
            }
            return vectorTrackPayload(track: track, segments: segments, trackEmbedding: trackEmbedding)
        }

        let payload = WorkerRebuildVectorIndexPayload(
            command: "rebuild_vector_index",
            tracks: payloadTracks,
            options: workerOptions()
        )
        let _: WorkerMutationResponse = try await runGeneric(payload: payload, commandName: payload.command)
    }

    private func workerOptions(
        embeddingProfileID overrideProfileID: String? = nil,
        analysisFocus: AnalysisFocus? = nil
    ) -> WorkerOptionsPayload {
        let config = configProvider()
        return WorkerOptionsPayload(
            googleAIAPIKey: config.googleAIAPIKey,
            cacheDirectory: AppPaths.pythonCacheDirectory.path,
            embeddingProfileID: overrideProfileID ?? config.embeddingProfile.id,
            embeddingPipelineID: config.embeddingProfile.pipelineID,
            analysisFocus: analysisFocus
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

    private func vectorTrackPayload(
        track: Track,
        segments: [TrackSegment],
        trackEmbedding: [Double]
    ) -> WorkerIndexedTrackPayload {
        WorkerIndexedTrackPayload(
            trackID: track.id.uuidString,
            filePath: track.filePath,
            scanVersion: "\(EmbeddingPipeline.audioSegmentsV1.id)|\(track.contentHash)|\(LibraryDatabase.iso8601.string(from: track.modifiedTime))",
            bpm: track.bpm,
            musicalKey: track.musicalKey,
            genre: track.genre,
            duration: track.duration,
            trackEmbedding: trackEmbedding,
            segments: segments.compactMap { segment in
                guard let vector = segment.vector, !vector.isEmpty else { return nil }
                return WorkerIndexedSegmentPayload(
                    segmentID: segment.id.uuidString,
                    segmentType: segment.type.rawValue,
                    startSec: segment.startSec,
                    endSec: segment.endSec,
                    energyScore: segment.energyScore,
                    descriptorText: segment.descriptorText,
                    embedding: vector
                )
            }
        )
    }

    private func runGeneric<T: Encodable, U: Decodable>(
        payload: T,
        progress: WorkerProgressHandler? = nil,
        commandName: String
    ) async throws -> U {
        let config = configProvider()
        let payloadData = try JSONEncoder().encode(payload)
        let controller = WorkerProcessController()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let result: U = try PythonWorkerClient.runGenericBlocking(
                            config: config,
                            payloadData: payloadData,
                            controller: controller,
                            progress: progress,
                            commandName: commandName
                        )
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in
                controller.cancel()
            }
        }
    }

    private static func runGenericBlocking<U: Decodable>(
        config: WorkerConfig,
        payloadData: Data,
        controller: WorkerProcessController,
        progress: WorkerProgressHandler?,
        commandName: String
    ) throws -> U {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.pythonExecutable)
        process.arguments = [config.workerScriptPath]
        process.environment = workerEnvironment(from: ProcessInfo.processInfo.environment)

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let terminationSignal = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            terminationSignal.signal()
        }

        let startedAt = Date()
        do {
            try process.run()
        } catch {
            AppLogger.shared.error(
                workerCommandLogLine(
                    level: "launch_failed",
                    commandName: commandName,
                    elapsedMs: elapsedMilliseconds(since: startedAt),
                    processID: nil,
                    payloadBytes: payloadData.count,
                    stdoutBytes: nil,
                    stderrText: error.localizedDescription,
                    extra: [
                        "python": config.pythonExecutable,
                        "script": config.workerScriptPath
                    ]
                )
            )
            throw error
        }
        controller.attach(process)
        let processID = process.processIdentifier
        AppLogger.shared.info(
            workerCommandLogLine(
                level: "started",
                commandName: commandName,
                elapsedMs: 0,
                processID: processID,
                payloadBytes: payloadData.count,
                stdoutBytes: nil,
                stderrText: nil,
                extra: [
                    "timeoutSec": String(format: "%.0f", defaultWorkerTimeoutSec),
                    "python": config.pythonExecutable,
                    "script": config.workerScriptPath
                ]
            )
        )

        let stdoutBuffer = LockedDataBuffer()
        let stderrRouter = WorkerStderrRouter(progress: progress)
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutBuffer.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let handle = errorPipe.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty {
                    break
                }
                stderrRouter.append(data)
            }
            stderrRouter.finish()
            readGroup.leave()
        }

        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: payloadData)
            try inputPipe.fileHandleForWriting.close()
        } catch {
            if controller.wasCancelled {
                AppLogger.shared.info(
                    workerCommandLogLine(
                        level: "cancelled",
                        commandName: commandName,
                        elapsedMs: elapsedMilliseconds(since: startedAt),
                        processID: processID,
                        payloadBytes: payloadData.count,
                        stdoutBytes: nil,
                        stderrText: "Cancelled while writing worker payload."
                    )
                )
                throw WorkerError.cancelled
            }
            AppLogger.shared.error(
                workerCommandLogLine(
                    level: "stdin_write_failed",
                    commandName: commandName,
                    elapsedMs: elapsedMilliseconds(since: startedAt),
                    processID: processID,
                    payloadBytes: payloadData.count,
                    stdoutBytes: nil,
                    stderrText: error.localizedDescription
                )
            )
            throw error
        }

        let timeoutSec = defaultWorkerTimeoutSec
        let didExit = terminationSignal.wait(timeout: .now() + timeoutSec) == .success
        if !didExit {
            controller.cancel()
            _ = terminationSignal.wait(timeout: .now() + 3)
        }
        _ = readGroup.wait(timeout: .now() + 3)

        let outputData = stdoutBuffer.data
        let stderrText = stderrRouter.plainText
        if controller.wasCancelled {
            AppLogger.shared.info(
                workerCommandLogLine(
                    level: "cancelled",
                    commandName: commandName,
                    elapsedMs: elapsedMilliseconds(since: startedAt),
                    processID: processID,
                    payloadBytes: payloadData.count,
                    stdoutBytes: outputData.count,
                    stderrText: stderrText
                )
            )
            throw WorkerError.cancelled
        }
        if !didExit {
            AppLogger.shared.error(
                workerCommandLogLine(
                    level: "timed_out",
                    commandName: commandName,
                    elapsedMs: elapsedMilliseconds(since: startedAt),
                    processID: processID,
                    payloadBytes: payloadData.count,
                    stdoutBytes: outputData.count,
                    stderrText: stderrText
                )
            )
            throw WorkerError.timedOut(timeoutSec, detail: stderrText)
        }
        if process.terminationStatus != 0 {
            AppLogger.shared.error(
                workerCommandLogLine(
                    level: "execution_failed",
                    commandName: commandName,
                    elapsedMs: elapsedMilliseconds(since: startedAt),
                    processID: processID,
                    payloadBytes: payloadData.count,
                    stdoutBytes: outputData.count,
                    stderrText: stderrText,
                    extra: ["terminationStatus": "\(process.terminationStatus)"]
                )
            )
            throw WorkerError.executionFailed(stderrText)
        }

        if let parsedError = try? JSONDecoder().decode(WorkerErrorResponse.self, from: outputData), !parsedError.error.isEmpty {
            AppLogger.shared.error(
                workerCommandLogLine(
                    level: "worker_error_payload",
                    commandName: commandName,
                    elapsedMs: elapsedMilliseconds(since: startedAt),
                    processID: processID,
                    payloadBytes: payloadData.count,
                    stdoutBytes: outputData.count,
                    stderrText: parsedError.error
                )
            )
            throw WorkerError.executionFailed(parsedError.error)
        }

        do {
            let decoded = try JSONDecoder().decode(U.self, from: outputData)
            AppLogger.shared.info(
                workerCommandLogLine(
                    level: "completed",
                    commandName: commandName,
                    elapsedMs: elapsedMilliseconds(since: startedAt),
                    processID: processID,
                    payloadBytes: payloadData.count,
                    stdoutBytes: outputData.count,
                    stderrText: stderrText,
                    extra: ["terminationStatus": "\(process.terminationStatus)"]
                )
            )
            return decoded
        } catch {
            let text = String(data: outputData, encoding: .utf8) ?? ""
            let payloadPreview = diagnosticPreview(text)
            let errorPayload = [
                payloadPreview.isEmpty ? nil : "Payload preview: \(payloadPreview)",
                stderrText.isEmpty ? nil : "Stderr: \(diagnosticPreview(stderrText))"
            ]
                .compactMap { $0 }
                .joined(separator: "\n")
            AppLogger.shared.error(
                workerCommandLogLine(
                    level: "decode_failed",
                    commandName: commandName,
                    elapsedMs: elapsedMilliseconds(since: startedAt),
                    processID: processID,
                    payloadBytes: payloadData.count,
                    stdoutBytes: outputData.count,
                    stderrText: errorPayload
                )
            )
            throw WorkerError.decodeFailed(errorPayload)
        }
    }

    private func searchTracks(
        mode: WorkerTrackSearchMode,
        queryText: String?,
        trackEmbedding: [Double]?,
        segments: [TrackSegment],
        limit: Int,
        excludeTrackPaths: [String],
        filters: WorkerSimilarityFilters,
        weights: [String: Double]
    ) async throws -> WorkerTrackSearchResponse {
        let payload = Self.makeTrackSearchPayload(
            mode: mode,
            queryText: queryText,
            trackEmbedding: trackEmbedding,
            segments: segments,
            limit: limit,
            excludeTrackPaths: excludeTrackPaths,
            filters: filters,
            weights: weights,
            options: workerOptions()
        )
        return try await runGeneric(payload: payload, commandName: payload.command)
    }

    static func makeTrackSearchPayload(
        mode: WorkerTrackSearchMode,
        queryText: String?,
        trackEmbedding: [Double]?,
        segments: [TrackSegment],
        limit: Int,
        excludeTrackPaths: [String],
        filters: WorkerSimilarityFilters,
        weights: [String: Double]? = nil,
        options: WorkerOptionsPayload = WorkerOptionsPayload(
            googleAIAPIKey: nil,
            cacheDirectory: "",
            embeddingProfileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id,
            embeddingPipelineID: EmbeddingPipeline.audioSegmentsV1.id,
            analysisFocus: nil
        )
    ) -> WorkerTrackSearchPayload {
        WorkerTrackSearchPayload(
            command: "search_tracks",
            mode: mode,
            queryText: queryText,
            queryTrackEmbedding: trackEmbedding,
            querySegments: segments.compactMap { segment in
                guard let vector = segment.vector, !vector.isEmpty else { return nil }
                return WorkerQuerySegment(
                    segmentType: segment.type.rawValue,
                    embedding: vector
                )
            },
            limit: limit,
            excludeTrackPaths: excludeTrackPaths,
            filters: filters,
            weights: weights ?? defaultSearchWeights(for: mode),
            options: options
        )
    }

    private static let textSearchWeights: [String: Double] = [
        "tracks": 0.45,
        "intro": 0.15,
        "middle": 0.25,
        "outro": 0.15
    ]

    private static let referenceSearchWeights: [String: Double] = [
        "tracks": 0.70,
        "intro": 0.10,
        "middle": 0.10,
        "outro": 0.10
    ]

    private static let hybridSearchWeights: [String: Double] = [
        "tracks": 0.60,
        "intro": 0.10,
        "middle": 0.20,
        "outro": 0.10
    ]

    static func defaultSearchWeights(for mode: WorkerTrackSearchMode) -> [String: Double] {
        switch mode {
        case .text:
            textSearchWeights
        case .reference:
            referenceSearchWeights
        case .hybrid:
            hybridSearchWeights
        }
    }

    static func diagnosticPreview(_ text: String, maxLength: Int = 240) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maxLength else { return normalized }
        let endIndex = normalized.index(normalized.startIndex, offsetBy: maxLength)
        return String(normalized[..<endIndex]) + "..."
    }

    static func failureSummary(for commandName: String, error: Error) -> String {
        guard let workerError = error as? WorkerError else {
            return "Worker \(commandName) failed: \(error.localizedDescription)"
        }

        switch workerError {
        case .executionFailed(let detail):
            let suffix = diagnosticPreview(detail)
            return suffix.isEmpty
                ? "Worker \(commandName) execution failed."
                : "Worker \(commandName) execution failed: \(suffix)"
        case .decodeFailed(let payload):
            let suffix = diagnosticPreview(payload)
            return suffix.isEmpty
                ? "Worker \(commandName) returned unreadable output."
                : "Worker \(commandName) decode failed: \(suffix)"
        case .cancelled:
            return "Worker \(commandName) was canceled."
        case .timedOut(let seconds, let detail):
            let suffix = diagnosticPreview(detail)
            return suffix.isEmpty
                ? "Worker \(commandName) timed out after \(Int(seconds)) seconds."
                : "Worker \(commandName) timed out after \(Int(seconds)) seconds: \(suffix)"
        }
    }

    fileprivate static func elapsedMilliseconds(since date: Date) -> Int {
        max(Int(Date().timeIntervalSince(date) * 1000), 0)
    }

    fileprivate static func workerCommandLogLine(
        level: String,
        commandName: String,
        elapsedMs: Int,
        processID: Int32?,
        payloadBytes: Int,
        stdoutBytes: Int?,
        stderrText: String?,
        extra: [String: String] = [:]
    ) -> String {
        var parts: [String] = [
            "Worker command \(level)",
            "command=\(commandName)",
            "elapsedMs=\(elapsedMs)",
            "payloadBytes=\(payloadBytes)"
        ]
        if let processID {
            parts.append("pid=\(processID)")
        }
        if let stdoutBytes {
            parts.append("stdoutBytes=\(stdoutBytes)")
        }
        for key in extra.keys.sorted() {
            if let value = extra[key], !value.isEmpty {
                parts.append("\(key)=\(value)")
            }
        }
        let stderrPreview = stderrText.map { diagnosticPreview($0) } ?? ""
        if !stderrPreview.isEmpty {
            parts.append("detail=\(stderrPreview)")
        }
        return parts.joined(separator: " | ")
    }
}

struct WorkerSimilarityFilters: Codable, Equatable {
    var bpmMin: Double? = nil
    var bpmMax: Double? = nil
    var durationMaxSec: Double? = nil
    var musicalKey: String? = nil
    var genre: String? = nil
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

struct WorkerOptionsPayload: Codable, Equatable {
    let googleAIAPIKey: String?
    let cacheDirectory: String
    let embeddingProfileID: String
    let embeddingPipelineID: String
    let analysisFocus: AnalysisFocus?
}

private struct WorkerAnalyzePayload: Codable {
    let command: String
    let filePath: String
    let trackMetadata: WorkerTrackMetadataPayload
    let options: WorkerOptionsPayload
}

private struct WorkerWaveformEnvelopeResponse: Codable {
    let waveformEnvelope: TrackWaveformEnvelope
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

private struct WorkerHealthcheckPayload: Codable {
    let command: String
    let options: WorkerOptionsPayload
}

private struct WorkerBuildQueryEmbeddingsPayload: Codable {
    let command: String
    let mode: WorkerTrackSearchMode
    let queryText: String?
    let queryTrackEmbedding: [Double]?
    let querySegments: [WorkerQuerySegment]
    let options: WorkerOptionsPayload
}

struct WorkerQuerySegment: Codable, Equatable {
    let segmentType: String
    let embedding: [Double]
}

struct WorkerTrackSearchPayload: Codable, Equatable {
    let command: String
    let mode: WorkerTrackSearchMode
    let queryText: String?
    let queryTrackEmbedding: [Double]?
    let querySegments: [WorkerQuerySegment]
    let limit: Int
    let excludeTrackPaths: [String]
    let filters: WorkerSimilarityFilters
    let weights: [String: Double]
    let options: WorkerOptionsPayload
}

private struct WorkerIndexedSegmentPayload: Codable {
    let segmentID: String
    let segmentType: String
    let startSec: Double
    let endSec: Double
    let energyScore: Double
    let descriptorText: String
    let embedding: [Double]
}

private struct WorkerIndexedTrackPayload: Codable {
    let trackID: String
    let filePath: String
    let scanVersion: String
    let bpm: Double?
    let musicalKey: String?
    let genre: String
    let duration: Double
    let trackEmbedding: [Double]
    let segments: [WorkerIndexedSegmentPayload]
}

private struct WorkerUpsertTrackVectorsPayload: Codable {
    let command: String
    let track: WorkerIndexedTrackPayload
    let options: WorkerOptionsPayload
}

private struct WorkerDeleteTrackVectorsPayload: Codable {
    let command: String
    let trackID: String
    let profileIDs: [String]?
    let deleteAllProfiles: Bool
    let options: WorkerOptionsPayload
}

private struct WorkerRebuildVectorIndexPayload: Codable {
    let command: String
    let tracks: [WorkerIndexedTrackPayload]
    let options: WorkerOptionsPayload
}

nonisolated private struct WorkerErrorResponse: Codable {
    let error: String
}

nonisolated final class WorkerStderrRouter {
    private var buffer = Data()
    private let decoder = JSONDecoder()
    private let progress: PythonWorkerClient.WorkerProgressHandler?
    private(set) var plainText = ""

    init(progress: PythonWorkerClient.WorkerProgressHandler?) {
        self.progress = progress
    }

    func append(_ data: Data) {
        buffer.append(data)
        consumeAvailableLines()
    }

    func finish() {
        consumeAvailableLines(flushRemainder: true)
    }

    private func consumeAvailableLines(flushRemainder: Bool = false) {
        while let newlineRange = buffer.range(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: 0..<newlineRange.lowerBound)
            buffer.removeSubrange(0...newlineRange.lowerBound)
            consumeLine(lineData)
        }

        if flushRemainder, !buffer.isEmpty {
            let lineData = buffer
            buffer.removeAll(keepingCapacity: false)
            consumeLine(lineData)
        }
    }

    private func consumeLine(_ data: Data) {
        guard var line = String(data: data, encoding: .utf8) else { return }
        if line.hasSuffix("\r") {
            line.removeLast()
        }
        guard !line.isEmpty else { return }

        if let event = Self.parseProgressEvent(from: line, decoder: decoder) {
            progress?(event)
            return
        }

        if !plainText.isEmpty {
            plainText.append("\n")
        }
        plainText.append(line)
    }

    static func parseProgressEvent(from line: String) -> WorkerProgressEvent? {
        parseProgressEvent(from: line, decoder: JSONDecoder())
    }

    private static func parseProgressEvent(
        from line: String,
        decoder: JSONDecoder
    ) -> WorkerProgressEvent? {
        guard line.hasPrefix(PythonWorkerClient.workerProgressPrefix) else { return nil }
        let payload = String(line.dropFirst(PythonWorkerClient.workerProgressPrefix.count))
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? decoder.decode(WorkerProgressEvent.self, from: data)
    }
}

enum WorkerError: Error {
    case executionFailed(String)
    case decodeFailed(String)
    case cancelled
    case timedOut(Double, detail: String)
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
        case .cancelled:
            return "Worker request was canceled."
        case .timedOut(let seconds, let detail):
            let summary = "Worker timed out after \(Int(seconds)) seconds."
            let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedDetail.isEmpty ? summary : "\(summary)\n\(trimmedDetail)"
        }
    }
}

private final class WorkerProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private(set) var wasCancelled = false

    func attach(_ process: Process) {
        lock.lock()
        let shouldCancel = wasCancelled
        self.process = process
        lock.unlock()

        if shouldCancel {
            cancel()
        }
    }

    func cancel() {
        lock.lock()
        wasCancelled = true
        let runningProcess = process
        lock.unlock()

        guard let runningProcess, runningProcess.isRunning else { return }
        runningProcess.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.75) {
            if runningProcess.isRunning {
                kill(runningProcess.processIdentifier, SIGKILL)
            }
        }
    }
}

nonisolated private final class PersistentWaveformWorkerSession: @unchecked Sendable {
    private struct ConfigSignature: Equatable {
        let pythonExecutable: String
        let workerScriptPath: String
    }

    private let lock = NSLock()
    private let stderrLock = NSLock()
    private let requestQueue = DispatchQueue(label: "soria.worker.persistent-waveform.queue", qos: .utility)
    private let stdoutLineSemaphore = DispatchSemaphore(value: 0)

    private var configSignature: ConfigSignature?
    private var process: Process?
    private var inputHandle: FileHandle?
    private var generation: UInt64 = 0
    private var stdoutBuffer = Data()
    private var stdoutReachedEOF = false
    private var stderrRouter = WorkerStderrRouter(progress: nil)

    func run<T: Encodable, U: Decodable>(
        config: PythonWorkerClient.WorkerConfig,
        payload: T,
        commandName: String
    ) async throws -> U {
        let payloadData = try JSONEncoder().encode(payload)
        try Task.checkCancellation()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                requestQueue.async {
                    do {
                        let result: U = try self.runBlocking(
                            config: config,
                            payloadData: payloadData,
                            commandName: commandName
                        )
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            self.cancelInFlightRequest()
        }
    }

    private func runBlocking<U: Decodable>(
        config: PythonWorkerClient.WorkerConfig,
        payloadData: Data,
        commandName: String
    ) throws -> U {
        let startedAt = Date()
        let processID = try ensureProcess(config: config, payloadBytes: payloadData.count, commandName: commandName)

        do {
            try writePayload(payloadData)
            let outputData = try readResponseLine(timeoutSec: PythonWorkerClient.defaultWorkerTimeoutSec)
            let stderrText = currentStderrText()

            if let parsedError = try? JSONDecoder().decode(WorkerErrorResponse.self, from: outputData), !parsedError.error.isEmpty {
                AppLogger.shared.error(
                    PythonWorkerClient.workerCommandLogLine(
                        level: "worker_error_payload",
                        commandName: commandName,
                        elapsedMs: PythonWorkerClient.elapsedMilliseconds(since: startedAt),
                        processID: processID,
                        payloadBytes: payloadData.count,
                        stdoutBytes: outputData.count,
                        stderrText: parsedError.error,
                        extra: ["mode": "persistent"]
                    )
                )
                throw WorkerError.executionFailed(parsedError.error)
            }

            do {
                let decoded = try JSONDecoder().decode(U.self, from: outputData)
                AppLogger.shared.info(
                    PythonWorkerClient.workerCommandLogLine(
                        level: "completed",
                        commandName: commandName,
                        elapsedMs: PythonWorkerClient.elapsedMilliseconds(since: startedAt),
                        processID: processID,
                        payloadBytes: payloadData.count,
                        stdoutBytes: outputData.count,
                        stderrText: stderrText,
                        extra: ["mode": "persistent"]
                    )
                )
                return decoded
            } catch {
                let text = String(data: outputData, encoding: .utf8) ?? ""
                let payloadPreview = PythonWorkerClient.diagnosticPreview(text)
                let errorPayload = [
                    payloadPreview.isEmpty ? nil : "Payload preview: \(payloadPreview)",
                    stderrText.isEmpty ? nil : "Stderr: \(PythonWorkerClient.diagnosticPreview(stderrText))"
                ]
                    .compactMap { $0 }
                    .joined(separator: "\n")
                AppLogger.shared.error(
                    PythonWorkerClient.workerCommandLogLine(
                        level: "decode_failed",
                        commandName: commandName,
                        elapsedMs: PythonWorkerClient.elapsedMilliseconds(since: startedAt),
                        processID: processID,
                        payloadBytes: payloadData.count,
                        stdoutBytes: outputData.count,
                        stderrText: errorPayload,
                        extra: ["mode": "persistent"]
                    )
                )
                throw WorkerError.decodeFailed(errorPayload)
            }
        } catch let workerError as WorkerError {
            throw workerError
        } catch {
            let stderrText = currentStderrText()
            AppLogger.shared.error(
                PythonWorkerClient.workerCommandLogLine(
                    level: "execution_failed",
                    commandName: commandName,
                    elapsedMs: PythonWorkerClient.elapsedMilliseconds(since: startedAt),
                    processID: processID,
                    payloadBytes: payloadData.count,
                    stdoutBytes: nil,
                    stderrText: stderrText.isEmpty ? error.localizedDescription : stderrText,
                    extra: ["mode": "persistent"]
                )
            )
            throw WorkerError.executionFailed(stderrText.isEmpty ? error.localizedDescription : stderrText)
        }
    }

    private func ensureProcess(
        config: PythonWorkerClient.WorkerConfig,
        payloadBytes: Int,
        commandName: String
    ) throws -> Int32 {
        let signature = ConfigSignature(
            pythonExecutable: config.pythonExecutable,
            workerScriptPath: config.workerScriptPath
        )

        lock.lock()
        let existingProcess = process
        let isUsable = configSignature == signature && existingProcess?.isRunning == true && inputHandle != nil
        let existingProcessID = existingProcess?.processIdentifier
        lock.unlock()

        if isUsable, let existingProcessID {
            return existingProcessID
        }

        return try startProcess(config: config, signature: signature, payloadBytes: payloadBytes, commandName: commandName)
    }

    private func startProcess(
        config: PythonWorkerClient.WorkerConfig,
        signature: ConfigSignature,
        payloadBytes: Int,
        commandName: String
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.pythonExecutable)
        process.arguments = [config.workerScriptPath, "--persistent"]

        var environment = PythonWorkerClient.workerEnvironment(from: ProcessInfo.processInfo.environment)
        environment["SORIA_WORKER_PERSISTENT"] = "1"
        process.environment = environment

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let oldProcess = replaceStateForNewProcess()
        terminate(process: oldProcess)

        let startedAt = Date()
        do {
            try process.run()
        } catch {
            AppLogger.shared.error(
                PythonWorkerClient.workerCommandLogLine(
                    level: "launch_failed",
                    commandName: commandName,
                    elapsedMs: PythonWorkerClient.elapsedMilliseconds(since: startedAt),
                    processID: nil,
                    payloadBytes: payloadBytes,
                    stdoutBytes: nil,
                    stderrText: error.localizedDescription,
                    extra: [
                        "mode": "persistent",
                        "python": config.pythonExecutable,
                        "script": config.workerScriptPath
                    ]
                )
            )
            throw error
        }

        lock.lock()
        let currentGeneration = generation
        configSignature = signature
        self.process = process
        inputHandle = inputPipe.fileHandleForWriting
        stdoutBuffer.removeAll(keepingCapacity: false)
        stdoutReachedEOF = false
        lock.unlock()

        stderrLock.lock()
        stderrRouter = WorkerStderrRouter(progress: nil)
        stderrLock.unlock()

        let processID = process.processIdentifier
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.drainStdout(from: outputPipe.fileHandleForReading, generation: currentGeneration)
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.drainStderr(from: errorPipe.fileHandleForReading, generation: currentGeneration)
        }

        AppLogger.shared.info(
            PythonWorkerClient.workerCommandLogLine(
                level: "started",
                commandName: commandName,
                elapsedMs: 0,
                processID: processID,
                payloadBytes: payloadBytes,
                stdoutBytes: nil,
                stderrText: nil,
                extra: [
                    "mode": "persistent",
                    "timeoutSec": String(format: "%.0f", PythonWorkerClient.defaultWorkerTimeoutSec),
                    "python": config.pythonExecutable,
                    "script": config.workerScriptPath
                ]
            )
        )

        return processID
    }

    private func writePayload(_ payloadData: Data) throws {
        lock.lock()
        let handle = inputHandle
        let generation = generation
        let isRunning = process?.isRunning == true
        lock.unlock()

        guard isRunning, let handle else {
            throw WorkerError.executionFailed("Persistent waveform worker is not running.")
        }

        do {
            try handle.write(contentsOf: payloadData)
            try handle.write(contentsOf: Data([0x0A]))
        } catch {
            markStdoutEOF(for: generation)
            throw error
        }
    }

    private func readResponseLine(timeoutSec: Double) throws -> Data {
        let deadline = DispatchTime.now() + timeoutSec

        while true {
            if let line = popBufferedResponseLine() {
                if line.isEmpty {
                    continue
                }
                return line
            }

            if stdoutLineSemaphore.wait(timeout: deadline) == .timedOut {
                cancelInFlightRequest()
                throw WorkerError.timedOut(timeoutSec, detail: currentStderrText())
            }

            lock.lock()
            let reachedEOF = stdoutReachedEOF
            let hasBufferedData = !stdoutBuffer.isEmpty
            lock.unlock()
            if reachedEOF && !hasBufferedData {
                throw WorkerError.executionFailed(currentStderrText())
            }
        }
    }

    private func popBufferedResponseLine() -> Data? {
        lock.lock()
        defer { lock.unlock() }

        guard let newlineRange = stdoutBuffer.range(of: Data([0x0A])) else {
            if stdoutReachedEOF, !stdoutBuffer.isEmpty {
                let remainder = stdoutBuffer
                stdoutBuffer.removeAll(keepingCapacity: false)
                return remainder
            }
            return nil
        }

        let line = stdoutBuffer.subdata(in: 0..<newlineRange.lowerBound)
        stdoutBuffer.removeSubrange(0...newlineRange.lowerBound)
        return line
    }

    private func currentStderrText() -> String {
        stderrLock.lock()
        defer { stderrLock.unlock() }
        return stderrRouter.plainText
    }

    private func replaceStateForNewProcess() -> Process? {
        lock.lock()
        defer { lock.unlock() }

        generation &+= 1
        let oldProcess = process
        configSignature = nil
        process = nil
        inputHandle = nil
        stdoutBuffer.removeAll(keepingCapacity: false)
        stdoutReachedEOF = true
        stdoutLineSemaphore.signal()
        return oldProcess
    }

    private func cancelInFlightRequest() {
        let process = replaceStateForNewProcess()
        terminate(process: process)
    }

    private func terminate(process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.75) {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    private func drainStdout(from handle: FileHandle, generation: UInt64) {
        while true {
            let data = handle.availableData
            if data.isEmpty {
                markStdoutEOF(for: generation)
                break
            }
            appendStdout(data, generation: generation)
        }
    }

    private func drainStderr(from handle: FileHandle, generation: UInt64) {
        while true {
            let data = handle.availableData
            if data.isEmpty {
                finishStderr(generation: generation)
                break
            }
            appendStderr(data, generation: generation)
        }
    }

    private func appendStdout(_ data: Data, generation: UInt64) {
        guard !data.isEmpty else { return }

        lock.lock()
        guard generation == self.generation else {
            lock.unlock()
            return
        }
        stdoutBuffer.append(data)
        lock.unlock()

        let newlineCount = data.reduce(into: 0) { partialResult, byte in
            if byte == 0x0A {
                partialResult += 1
            }
        }
        if newlineCount > 0 {
            for _ in 0..<newlineCount {
                stdoutLineSemaphore.signal()
            }
        }
    }

    private func markStdoutEOF(for generation: UInt64) {
        lock.lock()
        guard generation == self.generation else {
            lock.unlock()
            return
        }
        stdoutReachedEOF = true
        lock.unlock()
        stdoutLineSemaphore.signal()
    }

    private func appendStderr(_ data: Data, generation: UInt64) {
        lock.lock()
        let isCurrentGeneration = generation == self.generation
        lock.unlock()
        guard isCurrentGeneration else { return }

        stderrLock.lock()
        stderrRouter.append(data)
        stderrLock.unlock()
    }

    private func finishStderr(generation: UInt64) {
        lock.lock()
        let isCurrentGeneration = generation == self.generation
        lock.unlock()
        guard isCurrentGeneration else { return }

        stderrLock.lock()
        stderrRouter.finish()
        stderrLock.unlock()
    }
}

private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }
}

private extension PythonWorkerClient {
    static func workerEnvironment(from base: [String: String]) -> [String: String] {
        var environment = base
        environment["ANONYMIZED_TELEMETRY"] = "FALSE"
        environment["POSTHOG_DISABLED"] = "true"
        return environment
    }
}
