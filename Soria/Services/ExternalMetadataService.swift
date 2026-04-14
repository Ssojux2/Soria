import Foundation

final class ExternalMetadataService {
    func importRekordboxXML(from url: URL) throws -> [ExternalDJMetadata] {
        let data = try Data(contentsOf: url)
        let document = try XMLDocument(data: data)

        var playlistsByTrackID: [String: [String]] = [:]
        let playlistNodes = try document.nodes(forXPath: "//PLAYLISTS//NODE[@Type='1']")
        for node in playlistNodes.compactMap({ $0 as? XMLElement }) {
            let playlistName = node.attribute(forName: "Name")?.stringValue ?? "Playlist"
            for member in node.elements(forName: "TRACK") {
                guard let key = member.attribute(forName: "Key")?.stringValue, !key.isEmpty else { continue }
                playlistsByTrackID[key, default: []].append(playlistName)
            }
        }

        let trackNodes = try document.nodes(forXPath: "//COLLECTION/TRACK")
        return trackNodes.compactMap { node in
            guard let element = node as? XMLElement else { return nil }
            guard let location = element.attribute(forName: "Location")?.stringValue else { return nil }

            let trackID = element.attribute(forName: "TrackID")?.stringValue ?? UUID().uuidString
            let trackPath = normalizedTrackPath(location)
            let cueCount = element.elements(forName: "POSITION_MARK").count
            let genreTag = element.attribute(forName: "Genre")?.stringValue
            let comment = element.attribute(forName: "Comments")?.stringValue

            return ExternalDJMetadata(
                id: UUID(),
                trackPath: trackPath,
                source: .rekordbox,
                bpm: Double(element.attribute(forName: "AverageBpm")?.stringValue ?? ""),
                musicalKey: element.attribute(forName: "Tonality")?.stringValue,
                rating: Int(element.attribute(forName: "Rating")?.stringValue ?? ""),
                color: element.attribute(forName: "Colour")?.stringValue,
                tags: genreTag.map { [$0] } ?? [],
                playCount: Int(element.attribute(forName: "PlayCount")?.stringValue ?? ""),
                lastPlayed: parsedDate(element.attribute(forName: "DateAdded")?.stringValue),
                playlistMemberships: playlistsByTrackID[trackID] ?? [],
                cueCount: cueCount == 0 ? nil : cueCount,
                comment: comment,
                vendorTrackID: trackID,
                analysisState: nil,
                analysisCachePath: nil,
                syncVersion: nil
            )
        }
    }

    func importSeratoCSV(from url: URL) throws -> [ExternalDJMetadata] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let headerLine = lines.first else { return [] }
        let headers = parseCSVLine(headerLine).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        return lines.dropFirst().compactMap { line in
            let values = parseCSVLine(line)
            guard !values.isEmpty else { return nil }
            let row = Dictionary(uniqueKeysWithValues: zip(headers, values))
            let trackPath = normalizedTrackPath(row["path"] ?? row["track_path"] ?? "")
            guard !trackPath.isEmpty else { return nil }

            let tagText = row["tags"] ?? row["genre"] ?? ""
            let playlistText = row["playlists"] ?? row["playlist_memberships"] ?? ""
            return ExternalDJMetadata(
                id: UUID(),
                trackPath: trackPath,
                source: .serato,
                bpm: Double(row["bpm"] ?? ""),
                musicalKey: nilIfEmpty(row["key"] ?? row["musical_key"]),
                rating: Int(row["rating"] ?? ""),
                color: nilIfEmpty(row["color"] ?? ""),
                tags: splitPipeList(tagText),
                playCount: Int(row["play_count"] ?? ""),
                lastPlayed: parsedDate(row["last_played"]),
                playlistMemberships: splitPipeList(playlistText),
                cueCount: Int(row["cue_count"] ?? ""),
                comment: nilIfEmpty(row["comment"] ?? ""),
                vendorTrackID: nilIfEmpty(row["id"] ?? row["track_id"]),
                analysisState: nilIfEmpty(row["analysis_state"]),
                analysisCachePath: nilIfEmpty(row["analysis_cache_path"]),
                syncVersion: nilIfEmpty(row["sync_version"])
            )
        }
    }

    func normalizedTrackPath(_ input: String) -> String {
        TrackPathNormalizer.normalizedAbsolutePath(input)
    }

    private func splitPipeList(_ input: String) -> [String] {
        input
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func parseCSVLine(_ line: String) -> [String] {
        var values: [String] = []
        var current = ""
        var insideQuotes = false
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                let nextIndex = line.index(after: index)
                if insideQuotes, nextIndex < line.endIndex, line[nextIndex] == "\"" {
                    current.append("\"")
                    index = line.index(after: nextIndex)
                    continue
                }
                insideQuotes.toggle()
            } else if character == "," && !insideQuotes {
                values.append(current)
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(character)
            }
            index = line.index(after: index)
        }
        values.append(current)
        return values
    }

    private func parsedDate(_ rawValue: String?) -> Date? {
        guard let rawValue = nilIfEmpty(rawValue) else { return nil }
        if let date = LibraryDatabase.iso8601.date(from: rawValue) {
            return date
        }
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "MM/dd/yyyy HH:mm:ss"] {
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

    private func nilIfEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

enum MetadataImportError: Error {
    case invalidRekordboxXML
}
