import Foundation

enum TrackMetadataSource: String, Codable, CaseIterable {
    case soriaAnalysis = "soria_analysis"
    case serato
    case rekordbox
    case audioTags = "audio_tags"
    case unknown

    var displayName: String {
        switch self {
        case .soriaAnalysis:
            return "Soria Analysis"
        case .serato:
            return "Serato"
        case .rekordbox:
            return "rekordbox"
        case .audioTags:
            return "Audio Tags"
        case .unknown:
            return "Unknown"
        }
    }

    var priority: Int {
        switch self {
        case .soriaAnalysis:
            return 4
        case .serato, .rekordbox:
            return 3
        case .audioTags:
            return 2
        case .unknown:
            return 1
        }
    }
}

struct Track: Identifiable, Codable, Hashable {
    let id: UUID
    var filePath: String
    var fileName: String
    var title: String
    var artist: String
    var album: String
    var genre: String
    var duration: TimeInterval
    var sampleRate: Double
    var bpm: Double?
    var musicalKey: String?
    var modifiedTime: Date
    var contentHash: String
    var analyzedAt: Date?
    var embeddingProfileID: String?
    var embeddingPipelineID: String? = nil
    var embeddingUpdatedAt: Date?
    var hasSeratoMetadata: Bool
    var hasRekordboxMetadata: Bool
    var bpmSource: TrackMetadataSource?
    var keySource: TrackMetadataSource?
    var lastSeenInLocalScanAt: Date? = nil
    var bpmSortValue: Double { bpm ?? 0 }

    func hasCurrentEmbedding(profileID: String, pipelineID: String) -> Bool {
        embeddingProfileID == profileID
            && embeddingPipelineID == pipelineID
            && embeddingUpdatedAt != nil
    }

    func hasCurrentEmbedding(profileID: String) -> Bool {
        hasCurrentEmbedding(profileID: profileID, pipelineID: EmbeddingPipeline.audioSegmentsV1.id)
    }

    static func empty(path: String, modifiedTime: Date, hash: String) -> Track {
        Track(
            id: UUID(),
            filePath: path,
            fileName: URL(fileURLWithPath: path).lastPathComponent,
            title: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
            artist: "",
            album: "",
            genre: "",
            duration: 0,
            sampleRate: 0,
            bpm: nil,
            musicalKey: nil,
            modifiedTime: modifiedTime,
            contentHash: hash,
            analyzedAt: nil,
            embeddingProfileID: nil,
            embeddingPipelineID: nil,
            embeddingUpdatedAt: nil,
            hasSeratoMetadata: false,
            hasRekordboxMetadata: false,
            bpmSource: nil,
            keySource: nil,
            lastSeenInLocalScanAt: nil
        )
    }
}

struct TrackSegment: Identifiable, Codable, Hashable {
    enum SegmentType: String, Codable, CaseIterable {
        case intro
        case middle
        case outro
    }

    let id: UUID
    let trackID: UUID
    let type: SegmentType
    let startSec: Double
    let endSec: Double
    let energyScore: Double
    let descriptorText: String
    let vector: [Double]?
}

struct TrackWaveformEnvelope: Codable, Hashable {
    static let denseBinCount = 2048
    static let canonicalSourceVersion = "soria.waveform.envelope.v2"
    static let vendorFallbackSourceVersion = "vendor.preview.envelope.v1"
    static let legacyPreviewSourceVersion = "legacy.preview.envelope.v1"

    let durationSec: Double
    let upperPeaks: [Double]
    let lowerPeaks: [Double]
    let binCount: Int
    let sourceVersion: String

    init(
        durationSec: Double,
        upperPeaks: [Double],
        lowerPeaks: [Double],
        binCount: Int? = nil,
        sourceVersion: String = Self.canonicalSourceVersion
    ) {
        self.durationSec = durationSec.isFinite ? max(durationSec, 0) : 0
        self.upperPeaks = upperPeaks.map { min(max($0, 0), 1) }
        self.lowerPeaks = lowerPeaks.map { min(max($0, -1), 0) }
        self.binCount = max(binCount ?? upperPeaks.count, 0)
        self.sourceVersion = sourceVersion
    }

    var isDenseCanonical: Bool {
        sourceVersion == Self.canonicalSourceVersion && binCount >= Self.denseBinCount
    }

    var hasRenderableData: Bool {
        binCount > 0 && !upperPeaks.isEmpty && upperPeaks.count == lowerPeaks.count
    }

    static func fromPreview(
        _ preview: [Double],
        durationSec: Double,
        sourceVersion: String = Self.legacyPreviewSourceVersion
    ) -> TrackWaveformEnvelope? {
        let normalized = preview.map { min(max($0, 0), 1) }
        guard !normalized.isEmpty else { return nil }
        return TrackWaveformEnvelope(
            durationSec: durationSec,
            upperPeaks: normalized,
            lowerPeaks: normalized.map { -$0 },
            binCount: normalized.count,
            sourceVersion: sourceVersion
        )
    }
}

enum AnalysisFocus: String, Codable, CaseIterable, Identifiable {
    case balanced = "balanced"
    case transitionSafe = "transition_safe"
    case peakTime = "peak_time"
    case warmUpDeep = "warm_up_deep"
    case outroFriendly = "outro_friendly"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .balanced:
            return "Balanced"
        case .transitionSafe:
            return "Transition-safe"
        case .peakTime:
            return "Peak-time"
        case .warmUpDeep:
            return "Warm-up / Deep"
        case .outroFriendly:
            return "Outro-friendly"
        }
    }

    var helperText: String {
        switch self {
        case .balanced:
            return "Balanced read across groove, energy, and transition utility."
        case .transitionSafe:
            return "Favor smooth handoff points, stable rhythm, and cleaner intro/outro structure."
        case .peakTime:
            return "Favor energetic, brighter tracks that feel ready for bigger moments."
        case .warmUpDeep:
            return "Favor lower-intensity, deeper, and more patient grooves."
        case .outroFriendly:
            return "Favor clean exits and longer blend-friendly endings."
        }
    }
}

enum AnalysisTaskState: String, Codable, Hashable {
    case idle
    case queued
    case running
    case succeeded
    case failed
    case canceled

    var displayName: String {
        switch self {
        case .idle:
            return "Idle"
        case .queued:
            return "Queued"
        case .running:
            return "Analyzing"
        case .succeeded:
            return "Done"
        case .failed:
            return "Failed"
        case .canceled:
            return "Canceled"
        }
    }
}

struct TrackAnalysisState: Hashable {
    var state: AnalysisTaskState
    var message: String?
    var updatedAt: Date

    static func idle(at date: Date = Date()) -> TrackAnalysisState {
        TrackAnalysisState(state: .idle, message: nil, updatedAt: date)
    }
}

struct TrackAnalysisSummary: Codable, Hashable {
    let trackID: UUID
    let segments: [TrackSegment]
    let trackEmbedding: [Double]?
    let estimatedBPM: Double?
    let estimatedKey: String?
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

    init(
        trackID: UUID,
        segments: [TrackSegment],
        trackEmbedding: [Double]?,
        estimatedBPM: Double?,
        estimatedKey: String?,
        brightness: Double,
        onsetDensity: Double,
        rhythmicDensity: Double,
        lowMidHighBalance: [Double],
        waveformPreview: [Double],
        waveformEnvelope: TrackWaveformEnvelope? = nil,
        analysisFocus: AnalysisFocus = .balanced,
        introLengthSec: Double = 0,
        outroLengthSec: Double = 0,
        energyArc: [Double] = [],
        mixabilityTags: [String] = [],
        confidence: Double = 0.5
    ) {
        self.trackID = trackID
        self.segments = segments
        self.trackEmbedding = trackEmbedding
        self.estimatedBPM = estimatedBPM
        self.estimatedKey = estimatedKey
        self.brightness = brightness
        self.onsetDensity = onsetDensity
        self.rhythmicDensity = rhythmicDensity
        self.lowMidHighBalance = lowMidHighBalance
        self.waveformPreview = waveformPreview
        self.waveformEnvelope = waveformEnvelope
        self.analysisFocus = analysisFocus
        self.introLengthSec = introLengthSec
        self.outroLengthSec = outroLengthSec
        self.energyArc = energyArc
        self.mixabilityTags = mixabilityTags
        self.confidence = confidence
    }
}

extension TrackAnalysisSummary {
    private enum CodingKeys: String, CodingKey {
        case trackID
        case segments
        case trackEmbedding
        case estimatedBPM
        case estimatedKey
        case brightness
        case onsetDensity
        case rhythmicDensity
        case lowMidHighBalance
        case waveformPreview
        case waveformEnvelope
        case analysisFocus
        case introLengthSec
        case outroLengthSec
        case energyArc
        case mixabilityTags
        case confidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trackID = try container.decode(UUID.self, forKey: .trackID)
        segments = try container.decode([TrackSegment].self, forKey: .segments)
        trackEmbedding = try container.decodeIfPresent([Double].self, forKey: .trackEmbedding)
        estimatedBPM = try container.decodeIfPresent(Double.self, forKey: .estimatedBPM)
        estimatedKey = try container.decodeIfPresent(String.self, forKey: .estimatedKey)
        brightness = try container.decode(Double.self, forKey: .brightness)
        onsetDensity = try container.decode(Double.self, forKey: .onsetDensity)
        rhythmicDensity = try container.decode(Double.self, forKey: .rhythmicDensity)
        lowMidHighBalance = try container.decode([Double].self, forKey: .lowMidHighBalance)
        waveformPreview = try container.decode([Double].self, forKey: .waveformPreview)
        waveformEnvelope = try container.decodeIfPresent(TrackWaveformEnvelope.self, forKey: .waveformEnvelope)
        analysisFocus = try container.decodeIfPresent(AnalysisFocus.self, forKey: .analysisFocus) ?? .balanced
        introLengthSec = try container.decodeIfPresent(Double.self, forKey: .introLengthSec) ?? 0
        outroLengthSec = try container.decodeIfPresent(Double.self, forKey: .outroLengthSec) ?? 0
        energyArc = try container.decodeIfPresent([Double].self, forKey: .energyArc) ?? []
        mixabilityTags = try container.decodeIfPresent([String].self, forKey: .mixabilityTags) ?? []
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.5
    }
}

func shouldAdoptMetadataValue<Value>(
    _ incomingValue: Value?,
    from incomingSource: TrackMetadataSource,
    over currentValue: Value?,
    currentSource: TrackMetadataSource?
) -> Bool {
    guard incomingValue != nil else { return false }
    guard currentValue != nil else { return true }
    return incomingSource.priority > (currentSource?.priority ?? 0)
}
