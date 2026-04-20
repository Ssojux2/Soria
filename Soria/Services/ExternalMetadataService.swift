import Foundation

final class ExternalMetadataService {
    private let fileManager: FileManager
    private let cuePointParser: ExternalCuePointParser
    private let rekordboxXMLParser: RekordboxXMLParser
    private let rekordboxXMLSearchDirectories: [URL]?
    private let lastRekordboxXMLPathProvider: () -> String?

    init(
        fileManager: FileManager = .default,
        cuePointParser: ExternalCuePointParser = ExternalCuePointParser(),
        rekordboxXMLParser: RekordboxXMLParser? = nil,
        rekordboxXMLSearchDirectories: [URL]? = nil,
        lastRekordboxXMLPathProvider: @escaping () -> String? = { AppSettingsStore.loadLastRekordboxXMLPath() }
    ) {
        self.fileManager = fileManager
        self.cuePointParser = cuePointParser
        self.rekordboxXMLParser = rekordboxXMLParser ?? RekordboxXMLParser(cuePointParser: cuePointParser)
        self.rekordboxXMLSearchDirectories = rekordboxXMLSearchDirectories
        self.lastRekordboxXMLPathProvider = lastRekordboxXMLPathProvider
    }

    func importRekordboxXML(from url: URL) throws -> [ExternalDJMetadata] {
        try importRekordboxXMLRecords(from: url).map(\.metadata)
    }

    func importRekordboxXMLRecords(from url: URL) throws -> [VendorLibraryTrackRecord] {
        let parsed = try rekordboxXMLParser.parse(from: url)
        return parsed.tracks.map { track in
            let memberships = parsed.memberships(forTrackPath: track.trackPath)
            let cueCount = cueCount(from: track.cuePoints, legacy: track.cuePoints.count)
            let fileName = URL(fileURLWithPath: track.trackPath).lastPathComponent

            let metadata = ExternalDJMetadata(
                id: UUID(),
                trackPath: track.trackPath,
                source: .rekordbox,
                bpm: track.bpm,
                musicalKey: track.musicalKey,
                rating: track.rating,
                color: track.color,
                tags: track.genre.map { [$0] } ?? [],
                playCount: track.playCount,
                lastPlayed: track.lastPlayed,
                playlistMemberships: memberships,
                cueCount: cueCount,
                cuePoints: track.cuePoints,
                comment: track.comment,
                vendorTrackID: track.trackID,
                analysisState: nil,
                analysisCachePath: nil,
                syncVersion: nil
            )

            return VendorLibraryTrackRecord(
                source: .rekordbox,
                normalizedPath: track.trackPath,
                fileName: fileName,
                title: nilIfEmpty(track.title) ?? URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent,
                artist: track.artist ?? "",
                album: track.album ?? "",
                genre: track.genre ?? "",
                duration: nil,
                bpm: track.bpm,
                musicalKey: track.musicalKey,
                metadata: metadata
            )
        }
    }

    func detectRekordboxXMLCandidate() -> RekordboxXMLCandidate? {
        if let savedPath = lastRekordboxXMLPathProvider() {
            let savedURL = normalizedCandidateURL(URL(fileURLWithPath: savedPath))
            if fileManager.fileExists(atPath: savedURL.path), rekordboxXMLParser.isValidDocument(at: savedURL) {
                return RekordboxXMLCandidate(
                    url: savedURL,
                    modifiedAt: modificationDate(for: savedURL),
                    origin: .savedPath
                )
            }
        }

        let candidateDirectories = rekordboxXMLSearchDirectories ?? [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Music", isDirectory: true),
        ]

        let candidates = candidateDirectories
            .flatMap { rekordboxXMLCandidates(in: $0) }
        return Self.preferredRekordboxXMLCandidate(from: candidates)
    }

    func importSeratoCSV(from url: URL) throws -> [ExternalDJMetadata] {
        try importSeratoCSVRecords(from: url).map(\.metadata)
    }

    func importSeratoCSVRecords(from url: URL) throws -> [VendorLibraryTrackRecord] {
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

            let cuePoints = cuePointParser.parseSeratoCuePoints(from: row)
            let cueCount = cueCount(from: cuePoints, legacy: parseInt(row["cue_count"]))
            let tagText = row["tags"] ?? row["genre"] ?? ""
            let playlistText = row["playlists"] ?? row["playlist_memberships"] ?? ""
            let fileName = URL(fileURLWithPath: trackPath).lastPathComponent

            let metadata = ExternalDJMetadata(
                id: UUID(),
                trackPath: trackPath,
                source: .serato,
                bpm: parseDouble(row["bpm"]),
                musicalKey: nilIfEmpty(row["key"] ?? row["musical_key"]),
                rating: parseInt(row["rating"]),
                color: nilIfEmpty(row["color"] ?? ""),
                tags: splitPipeList(tagText),
                playCount: parseInt(row["play_count"]),
                lastPlayed: parsedDate(row["last_played"]),
                playlistMemberships: splitPipeList(playlistText),
                cueCount: cueCount,
                cuePoints: cuePoints,
                comment: nilIfEmpty(row["comment"] ?? ""),
                vendorTrackID: nilIfEmpty(row["id"] ?? row["track_id"]),
                analysisState: nilIfEmpty(row["analysis_state"]),
                analysisCachePath: nilIfEmpty(row["analysis_cache_path"]),
                syncVersion: nilIfEmpty(row["sync_version"])
            )

            return VendorLibraryTrackRecord(
                source: .serato,
                normalizedPath: trackPath,
                fileName: fileName,
                title: URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent,
                artist: "",
                album: "",
                genre: metadata.tags.first ?? "",
                duration: nil,
                bpm: metadata.bpm,
                musicalKey: metadata.musicalKey,
                metadata: metadata
            )
        }
    }

    func normalizedTrackPath(_ input: String) -> String {
        TrackPathNormalizer.normalizedAbsolutePath(input)
    }

    private func cueCount(from points: [ExternalDJCuePoint], legacy: Int?) -> Int? {
        if !points.isEmpty {
            return max(points.count, legacy ?? 0).takeIfPositive()
        }
        return legacy.flatMap { $0 > 0 ? $0 : nil }
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

    private func parseDouble(_ value: String?) -> Double? {
        guard let trimmed = nilIfEmpty(value) else { return nil }
        return Double(trimmed)
    }

    private func parseInt(_ value: String?) -> Int? {
        guard let trimmed = nilIfEmpty(value) else { return nil }
        return Int(trimmed)
    }

    private func parsedDate(_ rawValue: String?) -> Date? {
        guard let rawValue = nilIfEmpty(rawValue) else { return nil }
        if let date = LibraryDatabase.iso8601.date(from: rawValue) {
            return date
        }
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "MM/dd/yyyy HH:mm:ss", "MM/dd/yyyy"] {
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

    private func rekordboxXMLCandidates(in directory: URL) -> [RekordboxXMLCandidate] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var candidates: [RekordboxXMLCandidate] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "xml" else { continue }
            let candidateURL = normalizedCandidateURL(url)
            guard rekordboxXMLParser.isValidDocument(at: candidateURL) else { continue }
            candidates.append(
                RekordboxXMLCandidate(
                    url: candidateURL,
                    modifiedAt: modificationDate(for: candidateURL),
                    origin: .automaticSearch
                )
            )
        }
        return candidates
    }

    private func modificationDate(for url: URL) -> Date? {
        let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return resourceValues?.contentModificationDate
    }

    private func normalizedCandidateURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func preferredRekordboxXMLCandidate(
        from candidates: [RekordboxXMLCandidate]
    ) -> RekordboxXMLCandidate? {
        candidates.sorted { lhs, rhs in
            switch (lhs.modifiedAt, rhs.modifiedAt) {
            case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                return lhsDate > rhsDate
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return lhs.url.path.localizedCaseInsensitiveCompare(rhs.url.path) == .orderedAscending
            }
        }.first
    }

    private func nilIfEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private extension Int {
    func takeIfPositive() -> Int? {
        self > 0 ? self : nil
    }
}
