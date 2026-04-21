import Foundation

enum AnalysisConcurrencyProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case conservative
    case balancedAuto = "balanced_auto"
    case maxThroughput = "max_throughput"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .conservative:
            return "Conservative"
        case .balancedAuto:
            return "Balanced Auto"
        case .maxThroughput:
            return "Max Throughput"
        }
    }

    var helperText: String {
        switch self {
        case .conservative:
            return "Keep preparation to one worker at a time to minimize heat and memory pressure."
        case .balancedAuto:
            return "Use a safe default based on your CPU and the active embedding backend."
        case .maxThroughput:
            return "Favor faster batch completion with more parallel workers when the backend allows it."
        }
    }

    func resolvedMaxConcurrentJobs(
        processorCount: Int,
        backendKind: EmbeddingBackendKind,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        if let override = Int(environment["SORIA_ANALYSIS_MAX_CONCURRENCY"] ?? ""), override > 0 {
            return override
        }

        let normalizedProcessorCount = max(processorCount, 1)
        switch self {
        case .conservative:
            return 1
        case .balancedAuto:
            switch backendKind {
            case .googleAI:
                return min(max(2, normalizedProcessorCount / 3), 4)
            case .clap:
                return 1
            }
        case .maxThroughput:
            switch backendKind {
            case .googleAI:
                return min(max(2, normalizedProcessorCount / 2), 6)
            case .clap:
                return min(max(1, normalizedProcessorCount / 4), 2)
            }
        }
    }
}

struct AnalysisWorkItem: Identifiable, Hashable, Sendable {
    let track: Track
    let queueIndex: Int
    let totalCount: Int
    let externalMetadata: [ExternalDJMetadata]
    let existingSegments: [TrackSegment]
    let shouldReembed: Bool
    let analysisFocus: AnalysisFocus

    var id: UUID { track.id }
}

struct AnalysisTaskOutput: Sendable {
    enum Payload: Sendable {
        case analyzed(WorkerAnalysisResult)
        case reembedded(WorkerEmbeddingResult)
    }

    let workItem: AnalysisWorkItem
    let payload: Payload
    let elapsedMs: Int
}

struct AnalysisSessionProgress: Equatable, Sendable {
    let totalCount: Int
    let runningCount: Int
    let queuedCount: Int
    let completedCount: Int
    let failedCount: Int
    let canceledCount: Int
    let overallProgress: Double
    let latestTrackTitle: String
    let latestMessage: String

    var finishedCount: Int {
        completedCount + failedCount + canceledCount
    }

    var statusLine: String {
        let runningLabel = runningCount == 1 ? "1 running" : "\(runningCount) running"
        let finishedLabel = "\(finishedCount)/\(totalCount) finished"
        guard !latestTrackTitle.isEmpty else {
            return "\(runningLabel) • \(finishedLabel)"
        }
        return "\(runningLabel) • \(finishedLabel) • latest: \(latestTrackTitle)"
    }

    static func queued(totalCount: Int, latestTrackTitle: String, latestMessage: String = "Queued") -> AnalysisSessionProgress {
        AnalysisSessionProgress(
            totalCount: totalCount,
            runningCount: 0,
            queuedCount: totalCount,
            completedCount: 0,
            failedCount: 0,
            canceledCount: 0,
            overallProgress: 0,
            latestTrackTitle: latestTrackTitle,
            latestMessage: latestMessage
        )
    }
}

extension AnalysisConcurrencyProfile {
    static let `default`: AnalysisConcurrencyProfile = .balancedAuto
}

extension EmbeddingBackendKind: @unchecked Sendable {}
extension EmbeddingPipeline: @unchecked Sendable {}
extension EmbeddingProfile: @unchecked Sendable {}
extension TrackMetadataSource: @unchecked Sendable {}
extension Track: @unchecked Sendable {}
extension TrackSegment.SegmentType: @unchecked Sendable {}
extension TrackSegment: @unchecked Sendable {}
extension AnalysisFocus: @unchecked Sendable {}
extension AnalysisTaskState: @unchecked Sendable {}
extension TrackAnalysisState: @unchecked Sendable {}
extension ExternalDJMetadata.Source: @unchecked Sendable {}
extension ExternalDJCuePoint.Kind: @unchecked Sendable {}
extension ExternalDJCuePoint: @unchecked Sendable {}
extension ExternalDJMetadata: @unchecked Sendable {}
extension WorkerSegmentResult: @unchecked Sendable {}
extension WorkerEmbeddingResult: @unchecked Sendable {}
extension WorkerAnalysisResult: @unchecked Sendable {}
extension PythonWorkerClient.WorkerConfig: @unchecked Sendable {}
