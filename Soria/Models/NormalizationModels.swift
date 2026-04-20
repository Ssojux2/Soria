import Foundation

enum TrackNormalizationState: String, Codable, Hashable {
    case ready
    case needsNormalize = "needsNormalize"
    case normalizing
    case silent
    case unsupported
    case failed

    var displayName: String {
        switch self {
        case .ready:
            return "Ready"
        case .needsNormalize:
            return "Needs Normalize"
        case .normalizing:
            return "Normalizing"
        case .silent:
            return "Silent"
        case .unsupported:
            return "Unsupported"
        case .failed:
            return "Failed"
        }
    }
}

enum TrackNormalizationNeedTier: String, Codable, Hashable {
    case low
    case medium
    case high

    var displayName: String {
        switch self {
        case .low:
            return "Low Priority"
        case .medium:
            return "Medium Priority"
        case .high:
            return "High Priority"
        }
    }
}

enum TrackNormalizationQueuePolicy {
    nonisolated static let targetPeak = 1.0
    nonisolated static let peakTolerance = 1e-4
    nonisolated static let lowPriorityCeiling = targetPeak
    nonisolated static let autoNormalizeCutoff = 0.9
    nonisolated static let highPriorityCutoff = 0.8

    nonisolated static func requiresNormalization(for peakAmplitude: Double) -> Bool {
        guard peakAmplitude.isFinite, peakAmplitude > 0 else { return false }
        return peakAmplitude + peakTolerance < targetPeak
    }

    nonisolated static func meetsOrExceedsTargetPeak(_ peakAmplitude: Double) -> Bool {
        guard peakAmplitude.isFinite, peakAmplitude >= 0 else { return false }
        return peakAmplitude + peakTolerance >= targetPeak
    }

    nonisolated static func effectiveQueueState(
        for state: TrackNormalizationState,
        peakAmplitude: Double?
    ) -> TrackNormalizationState {
        switch state {
        case .ready, .needsNormalize:
            guard let peakAmplitude, peakAmplitude.isFinite, peakAmplitude >= 0 else {
                return state
            }
            if peakAmplitude == 0 {
                return .silent
            }
            return requiresNormalization(for: peakAmplitude) ? .needsNormalize : .ready
        case .normalizing, .silent, .unsupported, .failed:
            return state
        }
    }

    nonisolated static func needTier(for peakAmplitude: Double) -> TrackNormalizationNeedTier? {
        guard requiresNormalization(for: peakAmplitude) else {
            return nil
        }
        if peakAmplitude <= highPriorityCutoff {
            return .high
        }
        if peakAmplitude <= autoNormalizeCutoff {
            return .medium
        }
        return .low
    }
}

enum TrackNormalizationSignature {
    nonisolated static func make(for track: Track) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "\(track.id.uuidString)|\(track.contentHash)|\(formatter.string(from: track.modifiedTime))"
    }
}

struct TrackNormalizationInspection: Codable, Hashable {
    let trackID: UUID
    let signature: String
    let state: TrackNormalizationState
    let peakAmplitude: Double?
    let formatName: String?
    let subtype: String?
    let endian: String?
    let sampleRate: Double?
    let channelCount: Int?
    let frameCount: Int?
    let hasMetadata: Bool
    let isLossy: Bool
    let detailMessage: String?

    func matches(_ track: Track) -> Bool {
        signature == TrackNormalizationSignature.make(for: track)
    }

    var effectiveQueueState: TrackNormalizationState {
        TrackNormalizationQueuePolicy.effectiveQueueState(for: state, peakAmplitude: peakAmplitude)
    }

    var peakMeasurementLabel: String {
        isLossy ? "Decoded Peak" : "Sample Peak"
    }

    var peakMeasurementExplanation: String? {
        guard let peakAmplitude, peakAmplitude.isFinite else { return nil }
        guard peakAmplitude > TrackNormalizationQueuePolicy.targetPeak + TrackNormalizationQueuePolicy.peakTolerance else {
            return nil
        }

        if isLossy {
            return "Lossy decoding can reconstruct sample peaks above 1.0."
        }
        if usesFloatingPointPCM {
            return "Float PCM can store sample peaks outside +/-1.0."
        }
        return nil
    }

    var needTier: TrackNormalizationNeedTier? {
        guard effectiveQueueState == .needsNormalize, let peakAmplitude else { return nil }
        return TrackNormalizationQueuePolicy.needTier(for: peakAmplitude)
    }

    var shouldNormalizeInQueue: Bool {
        guard effectiveQueueState == .needsNormalize else { return false }
        guard let needTier else { return true }
        return needTier != .low
    }

    var needsExportAttention: Bool {
        switch effectiveQueueState {
        case .needsNormalize:
            return shouldNormalizeInQueue
        case .unsupported, .failed:
            return true
        case .ready, .normalizing, .silent:
            return false
        }
    }

    static func failed(for track: Track, message: String) -> TrackNormalizationInspection {
        TrackNormalizationInspection(
            trackID: track.id,
            signature: TrackNormalizationSignature.make(for: track),
            state: .failed,
            peakAmplitude: nil,
            formatName: nil,
            subtype: nil,
            endian: nil,
            sampleRate: nil,
            channelCount: nil,
            frameCount: nil,
            hasMetadata: false,
            isLossy: false,
            detailMessage: message
        )
    }

    private var usesFloatingPointPCM: Bool {
        guard let subtype else { return false }
        let normalizedSubtype = subtype.uppercased()
        return normalizedSubtype.contains("FLOAT") || normalizedSubtype.contains("DOUBLE")
    }
}

struct WorkerNormalizationInspectionResponse: Codable, Hashable {
    let state: TrackNormalizationState
    let peakAmplitude: Double?
    let formatName: String?
    let subtype: String?
    let endian: String?
    let sampleRate: Double?
    let channelCount: Int?
    let frameCount: Int?
    let hasMetadata: Bool
    let isLossy: Bool
    let detailMessage: String?

    func inspection(for track: Track) -> TrackNormalizationInspection {
        TrackNormalizationInspection(
            trackID: track.id,
            signature: TrackNormalizationSignature.make(for: track),
            state: state,
            peakAmplitude: peakAmplitude,
            formatName: formatName,
            subtype: subtype,
            endian: endian,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            hasMetadata: hasMetadata,
            isLossy: isLossy,
            detailMessage: detailMessage
        )
    }
}

struct WorkerNormalizationResultResponse: Codable, Hashable {
    let state: TrackNormalizationState
    let originalPeakAmplitude: Double?
    let normalizedPeakAmplitude: Double?
    let appliedGain: Double?
    let didNormalize: Bool
    let outputPath: String?
    let formatName: String?
    let subtype: String?
    let endian: String?
    let sampleRate: Double?
    let channelCount: Int?
    let frameCount: Int?
    let hasMetadata: Bool
    let isLossy: Bool
    let detailMessage: String?

    func inspection(for track: Track) -> TrackNormalizationInspection {
        TrackNormalizationInspection(
            trackID: track.id,
            signature: TrackNormalizationSignature.make(for: track),
            state: state,
            peakAmplitude: normalizedPeakAmplitude ?? originalPeakAmplitude,
            formatName: formatName,
            subtype: subtype,
            endian: endian,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            hasMetadata: hasMetadata,
            isLossy: isLossy,
            detailMessage: detailMessage
        )
    }
}

struct AudioNormalizationQueueResult {
    let updatedTracksByID: [UUID: Track]
    let inspectionsByTrackID: [UUID: TrackNormalizationInspection]
    let warnings: [String]
    let normalizedCount: Int
    let skippedLowPriorityCount: Int
}

struct ExportNormalizationConfirmationState: Equatable {
    let playlistName: String
    let outputURL: URL
    let outputDirectory: URL?
    let warnings: [String]
}
