import Foundation

actor AnalysisCommitActor {
    private let database: LibraryDatabase
    private let vectorWorker: PythonWorkerClient
    private let gate = AnalysisCommitGate(value: 1)

    init(databaseURL: URL, workerConfig: PythonWorkerClient.WorkerConfig) throws {
        self.database = try LibraryDatabase(databaseURL: databaseURL)
        self.vectorWorker = PythonWorkerClient(configProvider: { workerConfig })
    }

    func commit(_ output: AnalysisTaskOutput) async throws {
        await gate.wait()
        defer {
            Task {
                await gate.signal()
            }
        }

        switch output.payload {
        case let .analyzed(result):
            try await commitAnalysisResult(result, for: output.workItem)
        case let .reembedded(result):
            try await commitReembeddedResult(result, for: output.workItem)
        }
    }

    private func commitAnalysisResult(
        _ result: WorkerAnalysisResult,
        for workItem: AnalysisWorkItem
    ) async throws {
        let segments = result.segments.compactMap { item -> TrackSegment? in
            guard let type = TrackSegment.SegmentType(rawValue: item.segmentType) else { return nil }
            return TrackSegment(
                id: UUID(),
                trackID: workItem.track.id,
                type: type,
                startSec: item.startSec,
                endSec: item.endSec,
                energyScore: item.energyScore,
                descriptorText: item.descriptorText,
                vector: item.embedding
            )
        }
        guard let trackEmbedding = result.trackEmbedding, !trackEmbedding.isEmpty else {
            throw WorkerError.executionFailed("Worker returned an empty track embedding during analysis.")
        }

        let summary = TrackAnalysisSummary(
            trackID: workItem.track.id,
            segments: segments,
            trackEmbedding: trackEmbedding,
            estimatedBPM: result.estimatedBPM,
            estimatedKey: result.estimatedKey,
            brightness: result.brightness,
            onsetDensity: result.onsetDensity,
            rhythmicDensity: result.rhythmicDensity,
            lowMidHighBalance: result.lowMidHighBalance,
            waveformPreview: result.waveformPreview,
            analysisFocus: result.analysisFocus,
            introLengthSec: result.introLengthSec,
            outroLengthSec: result.outroLengthSec,
            energyArc: result.energyArc,
            mixabilityTags: result.mixabilityTags,
            confidence: result.confidence
        )

        let replaceStartedAt = Date()
        try database.replaceSegments(
            trackID: workItem.track.id,
            segments: segments,
            analysisSummary: summary
        )
        log(
            "database_replace_segments_completed",
            workItem: workItem,
            elapsedMs: max(Int(Date().timeIntervalSince(replaceStartedAt) * 1000), 0),
            extra: ["segmentCount": "\(segments.count)"]
        )

        var updatedTrack = workItem.track
        if shouldAdoptMetadataValue(
            result.estimatedBPM,
            from: .soriaAnalysis,
            over: updatedTrack.bpm,
            currentSource: updatedTrack.bpmSource
        ) {
            updatedTrack.bpm = result.estimatedBPM
            updatedTrack.bpmSource = .soriaAnalysis
        }
        if shouldAdoptMetadataValue(
            result.estimatedKey,
            from: .soriaAnalysis,
            over: updatedTrack.musicalKey,
            currentSource: updatedTrack.keySource
        ) {
            updatedTrack.musicalKey = result.estimatedKey
            updatedTrack.keySource = .soriaAnalysis
        }
        updatedTrack.analyzedAt = Date()
        updatedTrack.embeddingProfileID = nil
        updatedTrack.embeddingPipelineID = nil
        updatedTrack.embeddingUpdatedAt = nil

        let upsertTrackStartedAt = Date()
        try database.upsertTrack(updatedTrack)
        log(
            "database_upsert_track_completed",
            workItem: workItem,
            elapsedMs: max(Int(Date().timeIntervalSince(upsertTrackStartedAt) * 1000), 0)
        )

        let vectorUpsertStartedAt = Date()
        try await vectorWorker.upsertTrackVectors(track: updatedTrack, segments: segments, trackEmbedding: trackEmbedding)
        log(
            "worker_upsert_track_vectors_completed",
            workItem: workItem,
            elapsedMs: max(Int(Date().timeIntervalSince(vectorUpsertStartedAt) * 1000), 0)
        )

        let markIndexedStartedAt = Date()
        try database.markTrackEmbeddingIndexed(
            trackID: updatedTrack.id,
            embeddingProfileID: result.embeddingProfileID,
            embeddingPipelineID: result.embeddingPipelineID
        )
        log(
            "database_mark_track_embedding_indexed_completed",
            workItem: workItem,
            elapsedMs: max(Int(Date().timeIntervalSince(markIndexedStartedAt) * 1000), 0),
            extra: [
                "embeddingProfileID": result.embeddingProfileID,
                "embeddingPipelineID": result.embeddingPipelineID
            ]
        )
    }

    private func commitReembeddedResult(
        _ result: WorkerEmbeddingResult,
        for workItem: AnalysisWorkItem
    ) async throws {
        guard let trackEmbedding = result.trackEmbedding, !trackEmbedding.isEmpty else {
            throw WorkerError.executionFailed("Worker returned an empty track embedding for re-embedding.")
        }
        guard let refreshedSegments = Self.mergedReembeddedSegments(
            trackID: workItem.track.id,
            existingSegments: workItem.existingSegments,
            workerSegments: result.segments
        ) else {
            throw WorkerError.executionFailed("Stored descriptor segments no longer match the re-embedded payload.")
        }

        let replaceStartedAt = Date()
        try database.replaceTrackEmbeddings(
            trackID: workItem.track.id,
            segments: refreshedSegments,
            trackEmbedding: trackEmbedding
        )
        log(
            "database_replace_track_embeddings_completed",
            workItem: workItem,
            elapsedMs: max(Int(Date().timeIntervalSince(replaceStartedAt) * 1000), 0),
            extra: ["segmentCount": "\(refreshedSegments.count)"]
        )

        let vectorUpsertStartedAt = Date()
        try await vectorWorker.upsertTrackVectors(
            track: workItem.track,
            segments: refreshedSegments,
            trackEmbedding: trackEmbedding
        )
        log(
            "worker_upsert_track_vectors_completed",
            workItem: workItem,
            elapsedMs: max(Int(Date().timeIntervalSince(vectorUpsertStartedAt) * 1000), 0)
        )

        let markIndexedStartedAt = Date()
        try database.markTrackEmbeddingIndexed(
            trackID: workItem.track.id,
            embeddingProfileID: result.embeddingProfileID,
            embeddingPipelineID: result.embeddingPipelineID
        )
        log(
            "database_mark_track_embedding_indexed_completed",
            workItem: workItem,
            elapsedMs: max(Int(Date().timeIntervalSince(markIndexedStartedAt) * 1000), 0),
            extra: [
                "embeddingProfileID": result.embeddingProfileID,
                "embeddingPipelineID": result.embeddingPipelineID
            ]
        )
    }

    private func log(
        _ event: String,
        workItem: AnalysisWorkItem,
        elapsedMs: Int? = nil,
        extra: [String: String] = [:]
    ) {
        var parts: [String] = [
            "Analysis \(event)",
            "trackPath=\(workItem.track.filePath)",
            "queue=\(workItem.queueIndex)/\(workItem.totalCount)",
            "focus=\(workItem.analysisFocus.rawValue)"
        ]
        if let elapsedMs {
            parts.append("elapsedMs=\(elapsedMs)")
        }
        for key in extra.keys.sorted() {
            if let value = extra[key], !value.isEmpty {
                parts.append("\(key)=\(value)")
            }
        }
        AppLogger.shared.info(parts.joined(separator: " | "))
    }

    private static func mergedReembeddedSegments(
        trackID: UUID,
        existingSegments: [TrackSegment],
        workerSegments: [WorkerSegmentResult]
    ) -> [TrackSegment]? {
        guard existingSegments.count == workerSegments.count else { return nil }

        var refreshed: [TrackSegment] = []
        for (existing, workerSegment) in zip(existingSegments, workerSegments) {
            guard
                let type = TrackSegment.SegmentType(rawValue: workerSegment.segmentType),
                type == existing.type
            else {
                return nil
            }

            refreshed.append(
                TrackSegment(
                    id: existing.id,
                    trackID: trackID,
                    type: existing.type,
                    startSec: existing.startSec,
                    endSec: existing.endSec,
                    energyScore: existing.energyScore,
                    descriptorText: existing.descriptorText,
                    vector: workerSegment.embedding
                )
            )
        }
        return refreshed
    }
}

private actor AnalysisCommitGate {
    private var availablePermits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.availablePermits = value
    }

    func wait() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
            return
        }
        availablePermits += 1
    }
}
