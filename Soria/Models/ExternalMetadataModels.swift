import Foundation

struct ExternalDJMetadata: Identifiable, Codable, Hashable {
    let id: UUID
    let trackPath: String
    var source: Source
    var bpm: Double?
    var musicalKey: String?
    var rating: Int?
    var color: String?
    var tags: [String]
    var playCount: Int?
    var lastPlayed: Date?
    var playlistMemberships: [String]
    var cueCount: Int?
    var cuePoints: [ExternalDJCuePoint] = []
    var comment: String?
    var vendorTrackID: String?
    var analysisState: String?
    var analysisCachePath: String?
    var syncVersion: String?

    enum Source: String, Codable, CaseIterable {
        case serato
        case rekordbox

        var displayName: String {
            switch self {
            case .serato:
                return "Serato"
            case .rekordbox:
                return "rekordbox"
            }
        }
    }
}

struct ExternalDJCuePoint: Codable, Hashable {
    enum Kind: String, Codable {
        case cue
        case hotcue
        case loop
        case unknown
    }

    let kind: Kind
    let name: String?
    let index: Int?
    let startSec: Double
    let endSec: Double?
    let color: String?
    let source: String?
}

struct RekordboxTrackEntry: Codable, Hashable {
    let location: String
    let bpm: Double?
    let key: String?
    let genre: String?
}

struct SeratoExportRow: Codable, Hashable {
    let filePath: String
    let bpm: Double?
    let key: String?
    let tags: [String]
    let playCount: Int?
}
