import Foundation

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
    var hasSeratoMetadata: Bool
    var hasRekordboxMetadata: Bool

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
            hasSeratoMetadata: false,
            hasRekordboxMetadata: false
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
