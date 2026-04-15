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
    let analysisFocus: AnalysisFocus
    let introLengthSec: Double
    let outroLengthSec: Double
    let energyArc: [Double]
    let mixabilityTags: [String]
    let confidence: Double
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

final class PythonWorkerClient {
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
        return try await runGeneric(payload: payload, progress: progress)
    }

    func embedDescriptors(
        track: Track,
        segments: [TrackSegment],
        externalMetadata: [ExternalDJMetadata] = [],
        progress: WorkerProgressHandler? = nil
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
        return try await runGeneric(payload: payload, progress: progress)
    }

    func validateEmbeddingProfile() async throws -> WorkerValidationResponse {
        let payload = WorkerValidatePayload(
            command: "validate_embedding_profile",
            options: workerOptions()
        )
        return try await runGeneric(payload: payload)
    }

    func healthcheck() async throws -> WorkerHealthcheckResponse {
        let payload = WorkerHealthcheckPayload(
            command: "healthcheck",
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
        try await searchTracks(
            mode: .text,
            queryText: query,
            trackEmbedding: nil,
            segments: [],
            limit: limit,
            excludeTrackPaths: excludeTrackPaths,
            filters: filters,
            weights: Self.textSearchWeights
        )
    }

    func searchTracksReference(
        track: Track,
        segments: [TrackSegment],
        trackEmbedding: [Double],
        limit: Int,
        excludeTrackPaths: [String],
        filters: WorkerSimilarityFilters
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
            weights: Self.referenceSearchWeights
        )
    }

    func searchTracksHybrid(
        query: String,
        segments: [TrackSegment],
        trackEmbedding: [Double],
        limit: Int,
        excludeTrackPaths: [String],
        filters: WorkerSimilarityFilters
    ) async throws -> WorkerTrackSearchResponse {
        try await searchTracks(
            mode: .hybrid,
            queryText: query,
            trackEmbedding: trackEmbedding,
            segments: segments,
            limit: limit,
            excludeTrackPaths: excludeTrackPaths,
            filters: filters,
            weights: Self.hybridSearchWeights
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
        let _: WorkerMutationResponse = try await runGeneric(payload: payload)
    }

    func deleteTrackVectors(trackID: UUID, profileIDs: [String]? = nil, deleteAllProfiles: Bool = false) async throws {
        let payload = WorkerDeleteTrackVectorsPayload(
            command: "delete_track_vectors",
            trackID: trackID.uuidString,
            profileIDs: profileIDs,
            deleteAllProfiles: deleteAllProfiles,
            options: workerOptions()
        )
        let _: WorkerMutationResponse = try await runGeneric(payload: payload)
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
        let _: WorkerMutationResponse = try await runGeneric(payload: payload)
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
            scanVersion: "\(track.contentHash)|\(LibraryDatabase.iso8601.string(from: track.modifiedTime))",
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
        progress: WorkerProgressHandler? = nil
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
                            progress: progress
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
        progress: WorkerProgressHandler?
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

        try process.run()
        controller.attach(process)

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
                throw WorkerError.cancelled
            }
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
            throw WorkerError.cancelled
        }
        if !didExit {
            throw WorkerError.timedOut(timeoutSec, detail: stderrText)
        }
        if process.terminationStatus != 0 {
            throw WorkerError.executionFailed(stderrText)
        }

        if let parsedError = try? JSONDecoder().decode(WorkerErrorResponse.self, from: outputData), !parsedError.error.isEmpty {
            throw WorkerError.executionFailed(parsedError.error)
        }

        do {
            return try JSONDecoder().decode(U.self, from: outputData)
        } catch {
            let text = String(data: outputData, encoding: .utf8) ?? ""
            throw WorkerError.decodeFailed([text, stderrText].filter { !$0.isEmpty }.joined(separator: "\n"))
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
        return try await runGeneric(payload: payload)
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
            embeddingProfileID: EmbeddingProfile.googleGeminiEmbedding001.id,
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
            weights: weights ?? defaultWeights(for: mode),
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

    private static func defaultWeights(for mode: WorkerTrackSearchMode) -> [String: Double] {
        switch mode {
        case .text:
            textSearchWeights
        case .reference:
            referenceSearchWeights
        case .hybrid:
            hybridSearchWeights
        }
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
    let analysisFocus: AnalysisFocus?
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

private struct WorkerHealthcheckPayload: Codable {
    let command: String
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

private struct WorkerErrorResponse: Codable {
    let error: String
}

final class WorkerStderrRouter {
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
