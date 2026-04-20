import Foundation

struct ParsedRekordboxTrack: Hashable {
    let trackID: String?
    let trackPath: String
    let title: String?
    let artist: String?
    let album: String?
    let bpm: Double?
    let musicalKey: String?
    let genre: String?
    let comment: String?
    let rating: Int?
    let color: String?
    let playCount: Int?
    let lastPlayed: Date?
    let cuePoints: [ExternalDJCuePoint]
}

struct ParsedRekordboxXML: Hashable {
    let sourceURL: URL
    let tracks: [ParsedRekordboxTrack]
    let playlistMembershipsByTrackPath: [String: [String]]
    let trackPathsByID: [String: String]

    nonisolated func memberships(forTrackPath trackPath: String) -> [String] {
        playlistMembershipsByTrackPath[trackPath] ?? []
    }
}

struct RekordboxXMLCandidate: Hashable {
    enum Origin: String, Hashable {
        case savedPath
        case automaticSearch
    }

    let url: URL
    let modifiedAt: Date?
    let origin: Origin
}

enum RekordboxXMLParserError: LocalizedError {
    case invalidDocument

    var errorDescription: String? {
        switch self {
        case .invalidDocument:
            return "The selected file is not a valid Rekordbox XML export."
        }
    }
}

final class RekordboxXMLParser {
    private let cuePointParser: ExternalCuePointParser

    init(cuePointParser: ExternalCuePointParser = ExternalCuePointParser()) {
        self.cuePointParser = cuePointParser
    }

    func parse(from url: URL, fallbackTrackPathsByID: [String: String] = [:]) throws -> ParsedRekordboxXML {
        let data = try Data(contentsOf: url)
        let document = try XMLDocument(data: data)
        try validate(document: document)

        let tracks = try parseTracks(in: document)
        let trackPathsByID = mergedTrackPathsByID(parsedTracks: tracks, fallbackTrackPathsByID: fallbackTrackPathsByID)
        let playlistMembershipsByTrackPath = try parsePlaylistMemberships(
            in: document,
            trackPathsByID: trackPathsByID
        )

        return ParsedRekordboxXML(
            sourceURL: url,
            tracks: tracks,
            playlistMembershipsByTrackPath: playlistMembershipsByTrackPath,
            trackPathsByID: trackPathsByID
        )
    }

    func isValidDocument(at url: URL) -> Bool {
        (try? parseDocument(at: url)) != nil
    }

    private func parseDocument(at url: URL) throws -> XMLDocument {
        let data = try Data(contentsOf: url)
        let document = try XMLDocument(data: data)
        try validate(document: document)
        return document
    }

    private func validate(document: XMLDocument) throws {
        guard let root = document.rootElement(), root.name == "DJ_PLAYLISTS" else {
            throw RekordboxXMLParserError.invalidDocument
        }

        let collectionNodes = try document.nodes(forXPath: "/DJ_PLAYLISTS/COLLECTION")
        let playlistNodes = try document.nodes(forXPath: "/DJ_PLAYLISTS/PLAYLISTS")
        let hasCollection = !collectionNodes.isEmpty
        let hasPlaylists = !playlistNodes.isEmpty
        guard hasCollection || hasPlaylists else {
            throw RekordboxXMLParserError.invalidDocument
        }
    }

    private func parseTracks(in document: XMLDocument) throws -> [ParsedRekordboxTrack] {
        let nodes = try document.nodes(forXPath: "/DJ_PLAYLISTS/COLLECTION/TRACK")
        return nodes.compactMap { node in
            guard let element = node as? XMLElement else { return nil }
            guard let location = element.attribute(forName: "Location")?.stringValue else { return nil }

            let trackPath = TrackPathNormalizer.normalizedAbsolutePath(location)
            guard !trackPath.isEmpty else { return nil }

            let cuePoints = cuePointParser.parseRekordboxCuePoints(from: element)
            return ParsedRekordboxTrack(
                trackID: trimmed(element.attribute(forName: "TrackID")?.stringValue),
                trackPath: trackPath,
                title: trimmed(element.attribute(forName: "Name")?.stringValue),
                artist: trimmed(element.attribute(forName: "Artist")?.stringValue),
                album: trimmed(element.attribute(forName: "Album")?.stringValue),
                bpm: parseDouble(element.attribute(forName: "AverageBpm")?.stringValue),
                musicalKey: trimmed(element.attribute(forName: "Tonality")?.stringValue),
                genre: trimmed(element.attribute(forName: "Genre")?.stringValue),
                comment: trimmed(
                    element.attribute(forName: "Comments")?.stringValue
                        ?? element.attribute(forName: "Comment")?.stringValue
                ),
                rating: parseInt(element.attribute(forName: "Rating")?.stringValue),
                color: trimmed(
                    element.attribute(forName: "Colour")?.stringValue
                        ?? element.attribute(forName: "Color")?.stringValue
                ),
                playCount: parseInt(element.attribute(forName: "PlayCount")?.stringValue),
                lastPlayed: parseDate(
                    element.attribute(forName: "LastPlayed")?.stringValue
                        ?? element.attribute(forName: "DateAdded")?.stringValue
                        ?? element.attribute(forName: "DateModified")?.stringValue
                ),
                cuePoints: cuePoints
            )
        }
    }

    private func mergedTrackPathsByID(
        parsedTracks: [ParsedRekordboxTrack],
        fallbackTrackPathsByID: [String: String]
    ) -> [String: String] {
        var results: [String: String] = fallbackTrackPathsByID.reduce(into: [:]) { partial, entry in
            partial[entry.key.lowercased()] = entry.value
        }

        for track in parsedTracks {
            guard let trackID = trimmed(track.trackID) else { continue }
            results[trackID.lowercased()] = track.trackPath
        }
        return results
    }

    private func parsePlaylistMemberships(
        in document: XMLDocument,
        trackPathsByID: [String: String]
    ) throws -> [String: [String]] {
        let playlistContainers = try document.nodes(forXPath: "/DJ_PLAYLISTS/PLAYLISTS")
        var results: [String: [String]] = [:]

        for case let container as XMLElement in playlistContainers {
            for child in container.elements(forName: "NODE") {
                collectPlaylistMemberships(
                    from: child,
                    path: [],
                    inheritedKeyType: nil,
                    trackPathsByID: trackPathsByID,
                    results: &results
                )
            }
        }

        return results.mapValues { Array(Set($0)).sorted() }
    }

    private func collectPlaylistMemberships(
        from node: XMLElement,
        path: [String],
        inheritedKeyType: PlaylistTrackReferenceKind?,
        trackPathsByID: [String: String],
        results: inout [String: [String]]
    ) {
        let keyType = PlaylistTrackReferenceKind(rawValue: node.attribute(forName: "KeyType")?.stringValue ?? "")
            ?? inheritedKeyType
        let rawName = trimmed(node.attribute(forName: "Name")?.stringValue)
        let normalizedName = normalizedPlaylistNodeName(rawName)
        let currentPath = normalizedName.map { path + [$0] } ?? path
        let playlistPath = currentPath.joined(separator: " / ")

        for member in node.elements(forName: "TRACK") {
            guard
                let trackPath = resolveTrackPath(
                    from: member,
                    keyType: keyType,
                    trackPathsByID: trackPathsByID
                ),
                !playlistPath.isEmpty
            else {
                continue
            }
            results[trackPath, default: []].append(playlistPath)
        }

        for child in node.elements(forName: "NODE") {
            collectPlaylistMemberships(
                from: child,
                path: currentPath,
                inheritedKeyType: keyType,
                trackPathsByID: trackPathsByID,
                results: &results
            )
        }
    }

    private func resolveTrackPath(
        from member: XMLElement,
        keyType: PlaylistTrackReferenceKind?,
        trackPathsByID: [String: String]
    ) -> String? {
        if let location = normalizedPlaylistLocation(member.attribute(forName: "Location")?.stringValue) {
            return location
        }

        let rawKey = trimmed(member.attribute(forName: "Key")?.stringValue)
            ?? trimmed(member.attribute(forName: "TrackID")?.stringValue)
        guard let rawKey else { return nil }

        switch keyType {
        case .trackID:
            if let path = trackPathsByID[rawKey.lowercased()] {
                return path
            }
        case .location:
            if let path = normalizedPlaylistLocation(rawKey) {
                return path
            }
        case nil:
            break
        }

        if let path = trackPathsByID[rawKey.lowercased()] {
            return path
        }

        return normalizedPlaylistLocation(rawKey)
    }

    private func normalizedPlaylistNodeName(_ rawName: String?) -> String? {
        guard let rawName else { return nil }
        let lowered = rawName.lowercased()
        if lowered == "root" || lowered == "playlists" || lowered.hasSuffix(" root") {
            return nil
        }
        return rawName
    }

    private func normalizedPlaylistLocation(_ rawValue: String?) -> String? {
        guard let trimmed = trimmed(rawValue) else { return nil }

        let looksLikeLocation = trimmed.hasPrefix("file://")
            || trimmed.hasPrefix("/")
            || trimmed.hasPrefix("~")
            || trimmed.contains("/")
        guard looksLikeLocation else { return nil }

        let normalized = TrackPathNormalizer.normalizedAbsolutePath(trimmed)
        return normalized.isEmpty ? nil : normalized
    }

    private func parseDate(_ rawValue: String?) -> Date? {
        guard let rawValue = trimmed(rawValue) else { return nil }
        if let date = LibraryDatabase.iso8601.date(from: rawValue) {
            return date
        }

        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd",
            "MM/dd/yyyy HH:mm:ss",
            "MM/dd/yyyy",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: rawValue) {
                return date
            }
        }
        return nil
    }

    private func parseDouble(_ rawValue: String?) -> Double? {
        guard let rawValue = trimmed(rawValue) else { return nil }
        return Double(rawValue)
    }

    private func parseInt(_ rawValue: String?) -> Int? {
        guard let rawValue = trimmed(rawValue) else { return nil }
        return Int(rawValue)
    }

    private func trimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private enum PlaylistTrackReferenceKind: String {
    case trackID = "0"
    case location = "1"
}
