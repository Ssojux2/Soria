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
    var embeddingUpdatedAt: Date?
    var hasSeratoMetadata: Bool
    var hasRekordboxMetadata: Bool
    var bpmSource: TrackMetadataSource?
    var keySource: TrackMetadataSource?

    func hasCurrentEmbedding(profileID: String) -> Bool {
        embeddingProfileID == profileID && embeddingUpdatedAt != nil
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
            embeddingUpdatedAt: nil,
            hasSeratoMetadata: false,
            hasRekordboxMetadata: false,
            bpmSource: nil,
            keySource: nil
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

struct TrackAnalysisSummary: Codable {
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
