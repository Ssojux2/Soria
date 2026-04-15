import Foundation

struct AnalysisStage: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static let queued = AnalysisStage(rawValue: "queued")
    static let launching = AnalysisStage(rawValue: "launching")
    static let loadingAudio = AnalysisStage(rawValue: "loading_audio")
    static let extractingFeatures = AnalysisStage(rawValue: "extracting_features")
    static let buildingSegments = AnalysisStage(rawValue: "building_segments")
    static let embeddingDescriptors = AnalysisStage(rawValue: "embedding_descriptors")
    static let returningResult = AnalysisStage(rawValue: "returning_result")

    nonisolated var displayName: String {
        switch self {
        case .queued:
            return "Queued"
        case .launching:
            return "Launching Worker"
        case .loadingAudio:
            return "Loading Audio"
        case .extractingFeatures:
            return "Extracting Features"
        case .buildingSegments:
            return "Building Segments"
        case .embeddingDescriptors:
            return "Embedding Descriptors"
        case .returningResult:
            return "Returning Result"
        default:
            return rawValue
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { $0.capitalized }
                .joined(separator: " ")
        }
    }
}

struct WorkerProgressEvent: Codable, Hashable, Sendable {
    let stage: AnalysisStage
    let message: String
    let fraction: Double?
    let trackPath: String?
    let timestamp: Date

    private enum CodingKeys: String, CodingKey {
        case stage
        case message
        case fraction
        case trackPath
        case timestamp
    }

    nonisolated init(
        stage: AnalysisStage,
        message: String,
        fraction: Double?,
        trackPath: String?,
        timestamp: Date
    ) {
        self.stage = stage
        self.message = message
        self.fraction = fraction
        self.trackPath = trackPath
        self.timestamp = timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stage = try container.decode(AnalysisStage.self, forKey: .stage)
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? stage.displayName
        fraction = try container.decodeIfPresent(Double.self, forKey: .fraction)
        trackPath = try container.decodeIfPresent(String.self, forKey: .trackPath)

        let rawTimestamp = try container.decodeIfPresent(String.self, forKey: .timestamp) ?? ""
        timestamp = LibraryDatabase.iso8601.date(from: rawTimestamp) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stage, forKey: .stage)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(fraction, forKey: .fraction)
        try container.encodeIfPresent(trackPath, forKey: .trackPath)
        try container.encode(LibraryDatabase.iso8601.string(from: timestamp), forKey: .timestamp)
    }
}

struct AnalysisActivityEvent: Identifiable, Hashable, Sendable {
    let id: UUID
    let stage: AnalysisStage
    let message: String
    let timestamp: Date
    let fraction: Double?

    init(
        id: UUID = UUID(),
        stage: AnalysisStage,
        message: String,
        timestamp: Date,
        fraction: Double?
    ) {
        self.id = id
        self.stage = stage
        self.message = message
        self.timestamp = timestamp
        self.fraction = fraction
    }
}

struct AnalysisActivity: Hashable, Sendable {
    var currentTrackTitle: String
    var currentTrackPath: String
    var queueIndex: Int
    var totalCount: Int
    var stage: AnalysisStage
    var stageFraction: Double?
    var startedAt: Date
    var updatedAt: Date
    var recentEvents: [AnalysisActivityEvent]
    var finalState: AnalysisTaskState?
    var lastErrorMessage: String?
    var timeoutSec: Double

    init(
        currentTrackTitle: String,
        currentTrackPath: String,
        queueIndex: Int,
        totalCount: Int,
        stage: AnalysisStage,
        stageFraction: Double?,
        startedAt: Date,
        updatedAt: Date,
        recentEvents: [AnalysisActivityEvent],
        finalState: AnalysisTaskState?,
        lastErrorMessage: String?,
        timeoutSec: Double
    ) {
        self.currentTrackTitle = currentTrackTitle
        self.currentTrackPath = currentTrackPath
        self.queueIndex = queueIndex
        self.totalCount = totalCount
        self.stage = stage
        self.stageFraction = stageFraction
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.recentEvents = recentEvents
        self.finalState = finalState
        self.lastErrorMessage = lastErrorMessage
        self.timeoutSec = timeoutSec
    }

    static func started(
        trackTitle: String,
        trackPath: String,
        queueIndex: Int,
        totalCount: Int,
        timeoutSec: Double,
        startedAt: Date = Date()
    ) -> AnalysisActivity {
        let initialEvent = AnalysisActivityEvent(
            stage: .queued,
            message: "Queued",
            timestamp: startedAt,
            fraction: 0
        )
        return AnalysisActivity(
            currentTrackTitle: trackTitle,
            currentTrackPath: trackPath,
            queueIndex: queueIndex,
            totalCount: totalCount,
            stage: .queued,
            stageFraction: 0,
            startedAt: startedAt,
            updatedAt: startedAt,
            recentEvents: [initialEvent],
            finalState: nil,
            lastErrorMessage: nil,
            timeoutSec: timeoutSec
        )
    }

    var displayedEvents: [AnalysisActivityEvent] {
        Array(recentEvents.suffix(5).reversed())
    }

    nonisolated var isFinished: Bool {
        guard let finalState else { return false }
        return finalState == .succeeded || finalState == .failed || finalState == .canceled
    }

    var headlineText: String {
        if let finalState {
            switch finalState {
            case .succeeded:
                return "Completed"
            case .failed:
                return "Failed"
            case .canceled:
                return "Canceled"
            default:
                return stage.displayName
            }
        }
        return stage.displayName
    }

    nonisolated var currentMessage: String {
        recentEvents.last?.message ?? stage.displayName
    }

    var overallProgress: Double? {
        guard totalCount > 0 else { return nil }
        if finalState == .succeeded {
            return 1
        }

        let completedCount = max(0, min(totalCount, queueIndex - 1))
        let stageProgress = max(0, min(1, stageFraction ?? 0))
        let total = Double(totalCount)
        return min(1, (Double(completedCount) + stageProgress) / total)
    }

    mutating func recordProgress(
        _ event: WorkerProgressEvent,
        trackTitle: String,
        fallbackTrackPath: String,
        queueIndex: Int,
        totalCount: Int
    ) {
        currentTrackTitle = trackTitle
        currentTrackPath = event.trackPath ?? fallbackTrackPath
        self.queueIndex = queueIndex
        self.totalCount = totalCount
        stage = event.stage
        stageFraction = event.fraction.map { max(0, min(1, $0)) }
        updatedAt = event.timestamp
        finalState = nil
        recentEvents.append(
            AnalysisActivityEvent(
                stage: event.stage,
                message: event.message,
                timestamp: event.timestamp,
                fraction: stageFraction
            )
        )
        if recentEvents.count > 20 {
            recentEvents.removeFirst(recentEvents.count - 20)
        }
    }

    mutating func markFinished(
        state: AnalysisTaskState,
        errorMessage: String? = nil,
        message: String? = nil,
        at timestamp: Date = Date()
    ) {
        finalState = state
        updatedAt = timestamp
        if let errorMessage, !errorMessage.isEmpty {
            lastErrorMessage = errorMessage
        }
        if state == .succeeded {
            stageFraction = 1
            stage = .returningResult
        }
        if let message, !message.isEmpty {
            recentEvents.append(
                AnalysisActivityEvent(
                    stage: stage,
                    message: message,
                    timestamp: timestamp,
                    fraction: stageFraction
                )
            )
            if recentEvents.count > 20 {
                recentEvents.removeFirst(recentEvents.count - 20)
            }
        }
    }
}
