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
    var comment: String?

    enum Source: String, Codable {
        case serato
        case rekordbox
    }
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
