import Foundation
import SQLite3

enum TrackPathNormalizer {
    nonisolated static func normalizedAbsolutePath(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let url = URL(string: trimmed), url.isFileURL {
            return normalizedAbsolutePath(url.path)
        }

        let expanded = NSString(string: trimmed).expandingTildeInPath
        let cleaned = expanded
            .replacingOccurrences(of: "file://localhost", with: "")
            .replacingOccurrences(of: "file://", with: "")
        let decoded = cleaned.removingPercentEncoding ?? cleaned
        let absolute = decoded.hasPrefix("/") ? decoded : "/" + decoded
        return URL(fileURLWithPath: absolute).standardizedFileURL.path
    }

    nonisolated static func normalizedAbsolutePath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}

struct VendorLibraryTrackRecord: Hashable {
    let source: ExternalDJMetadata.Source
    let normalizedPath: String
    let fileName: String
    let title: String
    let artist: String
    let album: String
    let genre: String
    let duration: TimeInterval?
    let bpm: Double?
    let musicalKey: String?
    let metadata: ExternalDJMetadata

    var metadataSource: TrackMetadataSource {
        switch source {
        case .serato:
            return .serato
        case .rekordbox:
            return .rekordbox
        }
    }
}

struct NativeLibrarySyncSummary {
    var matchedTrackCount: Int
    var matchedEntryCount: Int
    var unmatchedEntryCount: Int
    var referenceAttachmentCount: Int
    var importedCounts: [LibrarySourceKind: Int]

    var displayText: String {
        let orderedCounts = [LibrarySourceKind.serato, .rekordbox]
            .compactMap { kind -> String? in
                guard let count = importedCounts[kind], count > 0 else { return nil }
                return "\(kind.displayName): \(count)"
            }
            .joined(separator: " | ")

        if orderedCounts.isEmpty {
            return "No vendor metadata sources were refreshed."
        }
        return "Matched \(matchedTrackCount) local tracks, attached \(referenceAttachmentCount) vendor references, and left \(unmatchedEntryCount) vendor entries unmatched. \(orderedCounts)"
    }
}

final class SeratoLibraryService {
    private let fileManager: FileManager
    private let cuePointParser: ExternalCuePointParser

    init(fileManager: FileManager = .default, cuePointParser: ExternalCuePointParser = ExternalCuePointParser()) {
        self.fileManager = fileManager
        self.cuePointParser = cuePointParser
    }

    func defaultDatabaseURL() -> URL? {
        let url = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Serato/Library/master.sqlite")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func loadTracks(from databaseURL: URL) throws -> [VendorLibraryTrackRecord] {
        let reader = try SQLiteReader(databaseURL: databaseURL)
        let containers = try loadContainers(reader: reader)
        let membershipsByAssetID = try loadMemberships(reader: reader, containers: containers)
        let cuePointsByAssetID = try loadCuePoints(reader: reader)
        let sql = """
        SELECT id, portable_id, file_name, name, artist, album, genre, bpm, key, rating, dj_play_count, comments, length_sec, analysis_flags
        FROM asset
        WHERE portable_id <> '';
        """

        return try reader.query(sql) { statement in
            guard
                let assetID = reader.string(statement, index: 0),
                let portableID = reader.string(statement, index: 1)
            else {
                return nil
            }

            let normalizedPath = TrackPathNormalizer.normalizedAbsolutePath(portableID)
            guard !normalizedPath.isEmpty else { return nil }

            let fileName = reader.string(statement, index: 2) ?? URL(fileURLWithPath: normalizedPath).lastPathComponent
            let title = Self.preferredText(
                reader.string(statement, index: 3),
                URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
            )
            let artist = reader.string(statement, index: 4) ?? ""
            let album = reader.string(statement, index: 5) ?? ""
            let genre = reader.string(statement, index: 6) ?? ""
            let bpm = reader.optionalDouble(statement, index: 7)
            let musicalKey = Self.nilIfEmpty(reader.string(statement, index: 8))
            let rating = reader.optionalInt(statement, index: 9)
            let playCount = reader.optionalInt(statement, index: 10)
            let comment = Self.nilIfEmpty(reader.string(statement, index: 11))
            let duration = reader.optionalDouble(statement, index: 12)
            let analysisFlags = reader.optionalInt(statement, index: 13)
            let memberships = membershipsByAssetID[assetID] ?? []
            let cuePoints = cuePointsByAssetID[assetID] ?? []

            let metadata = ExternalDJMetadata(
                id: UUID(),
                trackPath: normalizedPath,
                source: .serato,
                bpm: bpm,
                musicalKey: musicalKey,
                rating: rating,
                color: nil,
                tags: genre.isEmpty ? [] : [genre],
                playCount: playCount,
                lastPlayed: nil,
                playlistMemberships: memberships,
                cueCount: cuePoints.isEmpty ? nil : cuePoints.count,
                cuePoints: cuePoints,
                comment: comment,
                vendorTrackID: assetID,
                analysisState: analysisFlags.map { "flags=\($0)" },
                analysisCachePath: nil,
                syncVersion: "master.sqlite"
            )

            return VendorLibraryTrackRecord(
                source: .serato,
                normalizedPath: normalizedPath,
                fileName: fileName,
                title: title,
                artist: artist,
                album: album,
                genre: genre,
                duration: duration,
                bpm: bpm,
                musicalKey: musicalKey,
                metadata: metadata
            )
        }
    }

    private func loadCuePoints(reader: SQLiteReader) throws -> [String: [ExternalDJCuePoint]] {
        var groupedPoints: [String: [ExternalDJCuePoint]] = [:]
        for spec in cuePointTableSpecs() {
            guard let parsedPoints = try? loadCuePoints(from: reader, spec: spec) else { continue }
            for point in parsedPoints {
                groupedPoints[point.trackID, default: []].append(point.cuePoint)
            }
        }
        return groupedPoints.mapValues { cuePointParser.normalize($0) }
    }

    private func loadCuePoints(from reader: SQLiteReader, spec: SQLiteCuePointTableSpec) throws -> [(trackID: String, cuePoint: ExternalDJCuePoint)] {
        guard try reader.tableExists(spec.table) else { return [] }
        let columns = try reader.columns(for: spec.table)
        guard spec.supports(columns: columns) else { return [] }

        let query = """
        SELECT * FROM \(spec.table)
        """
        return try reader.query(query) { statement in
            let row = reader.rowDictionary(statement)
            return cuePointParser.parseSQLiteCuePoint(
                from: row,
                trackIDColumns: spec.trackIDColumns,
                timeColumns: spec.timeColumns,
                endColumns: spec.endColumns,
                nameColumns: spec.nameColumns,
                kindColumns: spec.kindColumns,
                indexColumns: spec.indexColumns,
                colorColumns: spec.colorColumns,
                fallbackKind: spec.fallbackKind,
                sourceName: spec.sourceName
            )
        }
    }

    private func cuePointTableSpecs() -> [SQLiteCuePointTableSpec] {
        [
            SQLiteCuePointTableSpec(
                table: "cues",
                trackIDColumns: ["asset_id", "assetID", "assetid", "asset", "portable_id", "track_id", "trackid"],
                timeColumns: ["position", "time", "start", "cue_time", "time_ms", "time_in_ms", "start_time", "starttime"],
                endColumns: ["end", "end_time", "endposition", "length", "duration", "end_time_ms"],
                nameColumns: ["name", "label", "title"],
                kindColumns: ["type", "kind", "cue_type"],
                indexColumns: ["idx", "index", "num", "number", "order", "position_number"],
                colorColumns: ["color", "colour", "rgb", "cue_color"],
                fallbackKind: .cue,
                sourceName: "serato:cues"
            ),
            SQLiteCuePointTableSpec(
                table: "hotcues",
                trackIDColumns: ["asset_id", "assetID", "assetid", "asset", "portable_id", "track_id", "trackid"],
                timeColumns: ["position", "time", "start", "cue_time", "time_ms", "time_in_ms", "start_time", "starttime"],
                endColumns: ["end", "end_time", "length", "duration", "end_time_ms"],
                nameColumns: ["name", "label", "title"],
                kindColumns: ["type", "kind", "cue_type"],
                indexColumns: ["idx", "index", "num", "number", "order"],
                colorColumns: ["color", "colour", "rgb", "cue_color"],
                fallbackKind: .hotcue,
                sourceName: "serato:hotcues"
            ),
            SQLiteCuePointTableSpec(
                table: "cue",
                trackIDColumns: ["asset_id", "assetID", "assetid", "asset", "portable_id", "track_id", "trackid"],
                timeColumns: ["position", "time", "start", "cue_time", "time_ms", "time_in_ms", "start_time", "starttime"],
                endColumns: ["end", "end_time", "length", "duration", "end_time_ms"],
                nameColumns: ["name", "label", "title"],
                kindColumns: ["type", "kind", "cue_type"],
                indexColumns: ["idx", "index", "num", "number", "order", "position_number"],
                colorColumns: ["color", "colour", "rgb", "cue_color"],
                fallbackKind: .cue,
                sourceName: "serato:cue"
            ),
            SQLiteCuePointTableSpec(
                table: "marks",
                trackIDColumns: ["asset_id", "assetID", "assetid", "asset", "portable_id", "track_id", "trackid"],
                timeColumns: ["position", "time", "start", "cue_time", "time_ms", "time_in_ms", "start_time", "starttime"],
                endColumns: ["end", "end_time", "length", "duration", "end_time_ms"],
                nameColumns: ["name", "label", "title"],
                kindColumns: ["type", "kind", "cue_type"],
                indexColumns: ["idx", "index", "num", "number", "order", "position_number"],
                colorColumns: ["color", "colour", "rgb", "cue_color"],
                fallbackKind: .cue,
                sourceName: "serato:marks"
            )
        ]
    }

    private func loadContainers(reader: SQLiteReader) throws -> [Int: SeratoContainerNode] {
        try reader.query("SELECT id, parent_id, name FROM container;") { statement in
            guard
                let id = reader.optionalInt(statement, index: 0),
                let name = reader.string(statement, index: 2)
            else {
                return nil
            }
            return SeratoContainerNode(
                id: id,
                parentID: reader.optionalInt(statement, index: 1),
                name: name
            )
        }
        .reduce(into: [:]) { result, node in
            result[node.id] = node
        }
    }

    private func loadMemberships(
        reader: SQLiteReader,
        containers: [Int: SeratoContainerNode]
    ) throws -> [String: [String]] {
        let memberships: [(String, String)] = try reader.query("SELECT asset_id, location_container_id FROM container_asset;") { statement in
            guard
                let assetID = reader.string(statement, index: 0),
                let containerID = reader.optionalInt(statement, index: 1)
            else {
                return nil
            }
            let path = buildContainerPath(containerID: containerID, containers: containers)
            return path.isEmpty ? nil : (assetID, path)
        }
        return memberships.reduce(into: [:]) { result, item in
            result[item.0, default: []].append(item.1)
        }
    }

    private func buildContainerPath(containerID: Int, containers: [Int: SeratoContainerNode]) -> String {
        var names: [String] = []
        var currentID: Int? = containerID
        while let id = currentID, let container = containers[id] {
            if !container.name.lowercased().hasSuffix(" root"), container.name.lowercased() != "root" {
                names.insert(container.name, at: 0)
            }
            currentID = container.parentID
        }
        return names.joined(separator: " / ")
    }

    nonisolated private static func preferredText(_ candidates: String?...) -> String {
        candidates.compactMap { value -> String? in
            nilIfEmpty(value)
        }.first ?? ""
    }

    nonisolated private static func nilIfEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

final class RekordboxLibraryService {
    private let fileManager: FileManager
    private let cuePointParser: ExternalCuePointParser
    private let visualizationResolver: ExternalVisualizationResolver
    private let rekordboxXMLParser: RekordboxXMLParser

    init(
        fileManager: FileManager = .default,
        cuePointParser: ExternalCuePointParser = ExternalCuePointParser(),
        visualizationResolver: ExternalVisualizationResolver = ExternalVisualizationResolver(),
        rekordboxXMLParser: RekordboxXMLParser? = nil
    ) {
        self.fileManager = fileManager
        self.cuePointParser = cuePointParser
        self.visualizationResolver = visualizationResolver
        self.rekordboxXMLParser = rekordboxXMLParser ?? RekordboxXMLParser(cuePointParser: cuePointParser)
    }

    func defaultSettingsURL() -> URL? {
        let baseURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pioneer", isDirectory: true)
        let candidates = [
            baseURL.appendingPathComponent("rekordbox6/rekordbox3.settings"),
            baseURL.appendingPathComponent("rekordbox7/rekordbox3.settings"),
            baseURL.appendingPathComponent("rekordbox/rekordbox3.settings"),
        ]
        return candidates.first(where: { fileManager.fileExists(atPath: $0.path) })
    }

    func defaultDatabaseDirectory() throws -> URL? {
        guard let settingsURL = defaultSettingsURL() else { return nil }
        return try resolvedDatabaseDirectory(from: settingsURL)
    }

    func resolvedDatabaseDirectory(from settingsURL: URL) throws -> URL? {
        let data = try Data(contentsOf: settingsURL)
        if let document = try? XMLDocument(data: data),
           let nodes = try? document.nodes(forXPath: "//VALUE[@name='masterDbDirectory']"),
           let element = nodes.first as? XMLElement,
           let rawPath = element.attribute(forName: "val")?.stringValue
        {
            let normalizedPath = TrackPathNormalizer.normalizedAbsolutePath(rawPath)
            return URL(fileURLWithPath: normalizedPath, isDirectory: true)
        }

        let text = String(decoding: data, as: UTF8.self)
        let pattern = #"<VALUE name="masterDbDirectory" val="([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: text.utf16.count)
        guard
            let match = regex.firstMatch(in: text, options: [], range: range),
            let capture = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        let normalizedPath = TrackPathNormalizer.normalizedAbsolutePath(String(text[capture]))
        return URL(fileURLWithPath: normalizedPath, isDirectory: true)
    }

    func loadTracks(from databaseDirectory: URL) throws -> [VendorLibraryTrackRecord] {
        var aggregates: [String: RekordboxAggregate] = [:]
        var cuePointsByPath: [String: [ExternalDJCuePoint]] = [:]
        var pathByTrackID: [String: String] = [:]

        for databaseName in ["networkRecommend.db", "networkAnalyze6.db"] {
            let databaseURL = databaseDirectory.appendingPathComponent(databaseName)
            guard fileManager.fileExists(atPath: databaseURL.path) else { continue }
            let reader = try SQLiteReader(databaseURL: databaseURL)
            let rows: [RekordboxManageRow] = try reader.query(
                """
                SELECT SongFilePath, AnalyzeFilePath, AnalyzeStatus, AnalyzeKey, AnalyzeBPMRange,
                       TrackID, TrackCheckSum, Duration, RekordboxVersion, AnalyzeVersion
                FROM manage_tbl
                WHERE SongFilePath <> '';
                """
            ) { statement in
                let songFilePath = reader.string(statement, index: 0) ?? ""
                let normalizedPath = TrackPathNormalizer.normalizedAbsolutePath(songFilePath)
                guard !normalizedPath.isEmpty else { return nil }
                return RekordboxManageRow(
                    normalizedPath: normalizedPath,
                    analysisCachePath: reader.string(statement, index: 1),
                    analyzeStatus: reader.optionalInt(statement, index: 2),
                    analyzeKey: reader.optionalInt(statement, index: 3),
                    analyzeBPMRange: reader.optionalInt(statement, index: 4),
                    trackID: reader.string(statement, index: 5),
                    trackChecksum: reader.string(statement, index: 6),
                    duration: reader.optionalDouble(statement, index: 7),
                    rekordboxVersion: reader.string(statement, index: 8),
                    analyzeVersion: reader.string(statement, index: 9)
                )
            }

            for row in rows {
                if let trackID = trimToNil(row.trackID) {
                    pathByTrackID[trackID.lowercased()] = row.normalizedPath
                }
            }

            let pathByIdentifier = rows.reduce(into: [String: String]()) { result, row in
                if let trackID = trimToNil(row.trackID) {
                    result[trackID.lowercased()] = row.normalizedPath
                }
                if let trackChecksum = trimToNil(row.trackChecksum) {
                    result[trackChecksum.lowercased()] = row.normalizedPath
                }
            }
            let cuePoints = try loadCuePointsFromDatabase(reader: reader, pathByIdentifier: pathByIdentifier)
            for (path, points) in cuePoints {
                cuePointsByPath[path, default: []].append(contentsOf: points)
            }

            for row in rows {
                var aggregate = aggregates[row.normalizedPath] ?? RekordboxAggregate(path: row.normalizedPath)
                aggregate.merge(row)
                aggregates[row.normalizedPath] = aggregate
            }
        }

        let playlistsByPath = loadPlaylists(from: databaseDirectory, pathByTrackID: pathByTrackID)
        for (path, playlists) in playlistsByPath {
            aggregates[path, default: RekordboxAggregate(path: path)].playlistMemberships.append(contentsOf: playlists)
        }

        return aggregates.values.map { aggregate in
            let normalizedDuration = Self.normalizedDuration(aggregate.duration)
            let cacheCuePoints = loadCuePointsFromAnalysisCache(aggregate.analysisCachePath)
            let trackCuePoints = cuePointsByPath[aggregate.path] ?? []
            let cuePoints = cuePointParser.normalize(trackCuePoints + cacheCuePoints)
            let metadata = ExternalDJMetadata(
                id: UUID(),
                trackPath: aggregate.path,
                source: .rekordbox,
                bpm: nil,
                musicalKey: nil,
                rating: nil,
                color: nil,
                tags: [],
                playCount: nil,
                lastPlayed: nil,
                playlistMemberships: Array(Set(aggregate.playlistMemberships)).sorted(),
                cueCount: cuePoints.isEmpty ? nil : cuePoints.count,
                cuePoints: cuePoints,
                comment: nil,
                vendorTrackID: trimToNil(aggregate.vendorTrackID),
                analysisState: aggregate.analysisStateDescription,
                analysisCachePath: aggregate.analysisCachePath,
                syncVersion: aggregate.syncVersion
            )

            let fileName = URL(fileURLWithPath: aggregate.path).lastPathComponent
            let title = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
            return VendorLibraryTrackRecord(
                source: .rekordbox,
                normalizedPath: aggregate.path,
                fileName: fileName,
                title: title,
                artist: "",
                album: "",
                genre: "",
                duration: normalizedDuration,
                bpm: nil,
                musicalKey: nil,
                metadata: metadata
            )
        }
    }

    private func loadCuePointsFromDatabase(reader: SQLiteReader, pathByIdentifier: [String: String]) throws -> [String: [ExternalDJCuePoint]] {
        var groupedPoints: [String: [ExternalDJCuePoint]] = [:]
        for spec in cuePointTableSpecs() {
            guard try reader.tableExists(spec.table) else { continue }
            let columns = try reader.columns(for: spec.table)
            guard spec.supports(columns: columns) else { continue }
            let rows = try reader.query("SELECT * FROM \(spec.table)") { statement in
                let row = reader.rowDictionary(statement)
                return cuePointParser.parseSQLiteCuePoint(
                    from: row,
                    trackIDColumns: spec.trackIDColumns,
                    timeColumns: spec.timeColumns,
                    endColumns: spec.endColumns,
                    nameColumns: spec.nameColumns,
                    kindColumns: spec.kindColumns,
                    indexColumns: spec.indexColumns,
                    colorColumns: spec.colorColumns,
                    fallbackKind: spec.fallbackKind,
                    sourceName: spec.sourceName
                )
            }
            for point in rows {
                if let path = pathByIdentifier[point.trackID.lowercased()] {
                    groupedPoints[path, default: []].append(point.cuePoint)
                }
            }
        }
        return groupedPoints
    }

    private func loadCuePointsFromAnalysisCache(_ path: String?) -> [ExternalDJCuePoint] {
        guard let path else { return [] }
        let normalized = TrackPathNormalizer.normalizedAbsolutePath(path)
        guard !normalized.isEmpty else { return [] }
        let cacheURL = URL(fileURLWithPath: normalized)
        guard fileManager.fileExists(atPath: cacheURL.path) else { return [] }
        return visualizationResolver.readRekordboxVisualization(analysisURL: cacheURL).cuePoints
    }

    private func cuePointTableSpecs() -> [SQLiteCuePointTableSpec] {
        [
            SQLiteCuePointTableSpec(
                table: "djmdHotCue",
                trackIDColumns: ["TrackID", "track_id", "trackid", "TrackNo", "Path", "track_path"],
                timeColumns: ["StartPos", "Start", "StartTime", "CuePos", "Position", "Time", "time"],
                endColumns: ["Length", "Duration", "EndPos", "EndTime", "End"],
                nameColumns: ["Name", "Label", "CueName", "Tag"],
                kindColumns: ["Kind", "Type", "CueType"],
                indexColumns: ["Index", "Num", "Order", "No"],
                colorColumns: ["Color", "Colour", "CueColor"],
                fallbackKind: .hotcue,
                sourceName: "rekordbox:hotcue"
            ),
            SQLiteCuePointTableSpec(
                table: "trackCue",
                trackIDColumns: ["TrackID", "track_id", "trackid", "TrackNo", "Path", "track_path"],
                timeColumns: ["StartPos", "Start", "StartTime", "CuePos", "Position", "Time", "time"],
                endColumns: ["Length", "Duration", "EndPos", "EndTime", "End"],
                nameColumns: ["Name", "Label", "CueName", "Tag"],
                kindColumns: ["Kind", "Type", "CueType"],
                indexColumns: ["Index", "Num", "Order", "No"],
                colorColumns: ["Color", "Colour", "CueColor"],
                fallbackKind: .cue,
                sourceName: "rekordbox:cue"
            ),
            SQLiteCuePointTableSpec(
                table: "marker",
                trackIDColumns: ["TrackID", "track_id", "trackid", "TrackNo", "Path", "track_path"],
                timeColumns: ["StartPos", "Start", "StartTime", "CuePos", "Position", "Time", "time"],
                endColumns: ["Length", "Duration", "EndPos", "EndTime", "End"],
                nameColumns: ["Name", "Label", "CueName", "Tag"],
                kindColumns: ["Kind", "Type", "CueType"],
                indexColumns: ["Index", "Num", "Order", "No"],
                colorColumns: ["Color", "Colour", "CueColor"],
                fallbackKind: .cue,
                sourceName: "rekordbox:marker"
            ),
            SQLiteCuePointTableSpec(
                table: "markers",
                trackIDColumns: ["TrackID", "track_id", "trackid", "TrackNo", "Path", "track_path"],
                timeColumns: ["StartPos", "Start", "StartTime", "CuePos", "Position", "Time", "time"],
                endColumns: ["Length", "Duration", "EndPos", "EndTime", "End"],
                nameColumns: ["Name", "Label", "CueName", "Tag"],
                kindColumns: ["Kind", "Type", "CueType"],
                indexColumns: ["Index", "Num", "Order", "No"],
                colorColumns: ["Color", "Colour", "CueColor"],
                fallbackKind: .cue,
                sourceName: "rekordbox:markers"
            )
        ]
    }

    private func loadPlaylists(from databaseDirectory: URL, pathByTrackID: [String: String]) -> [String: [String]] {
        guard let xmlURL = loadPlaylistXMLCandidate(in: databaseDirectory) else { return [:] }
        let fallbackTrackPathsByID = pathByTrackID.reduce(into: [String: String]()) { partial, entry in
            partial[entry.key.lowercased()] = entry.value
        }
        let parsed = try? rekordboxXMLParser.parse(
            from: xmlURL,
            fallbackTrackPathsByID: fallbackTrackPathsByID
        )
        return parsed?.playlistMembershipsByTrackPath ?? [:]
    }

    private func loadPlaylistXMLCandidate(in databaseDirectory: URL) -> URL? {
        let preferredURLs = [
            databaseDirectory.appendingPathComponent("masterPlaylists7.xml"),
            databaseDirectory.appendingPathComponent("masterPlaylists6.xml"),
        ]
        for url in preferredURLs where fileManager.fileExists(atPath: url.path) {
            return url
        }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: databaseDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return contents
            .filter {
                $0.pathExtension.lowercased() == "xml"
                    && $0.lastPathComponent.lowercased().hasPrefix("masterplaylists")
            }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }
            .first
    }

    private static func normalizedDuration(_ rawValue: Double?) -> Double? {
        guard let rawValue, rawValue > 0 else { return nil }
        return rawValue > 10_000 ? rawValue / 1000.0 : rawValue
    }
}

private func trimToNil(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}

final class DJLibrarySyncService {
    private let database: LibraryDatabase
    private let fileManager: FileManager
    private let seratoService: SeratoLibraryService
    private let rekordboxService: RekordboxLibraryService
    private let invalidateVectorIndex: @Sendable (Track) async -> Void

    init(
        database: LibraryDatabase,
        fileManager: FileManager = .default,
        seratoService: SeratoLibraryService = SeratoLibraryService(),
        rekordboxService: RekordboxLibraryService = RekordboxLibraryService(),
        invalidateVectorIndex: @escaping @Sendable (Track) async -> Void = { _ in }
    ) {
        self.database = database
        self.fileManager = fileManager
        self.seratoService = seratoService
        self.rekordboxService = rekordboxService
        self.invalidateVectorIndex = invalidateVectorIndex
    }

    func detectAvailableSources(
        existing: [LibrarySourceRecord],
        fallbackRoots: [String]
    ) -> [LibrarySourceRecord] {
        var sourcesByKind = Dictionary(uniqueKeysWithValues: existing.map { ($0.kind, $0) })

        var serato = sourcesByKind[.serato] ?? .default(for: .serato)
        serato.resolvedPath = seratoService.defaultDatabaseURL()?.path
        serato.status = serato.resolvedPath == nil ? .missing : (serato.enabled ? .available : .disabled)
        if serato.resolvedPath == nil {
            serato.enabled = false
        }
        serato.lastError = serato.status == .missing ? nil : serato.lastError
        sourcesByKind[.serato] = serato

        var rekordbox = sourcesByKind[.rekordbox] ?? .default(for: .rekordbox)
        rekordbox.resolvedPath = try? rekordboxService.defaultDatabaseDirectory()?.path
        rekordbox.status = rekordbox.resolvedPath == nil ? .missing : (rekordbox.enabled ? .available : .disabled)
        if rekordbox.resolvedPath == nil {
            rekordbox.enabled = false
        }
        rekordbox.lastError = rekordbox.status == .missing ? nil : rekordbox.lastError
        sourcesByKind[.rekordbox] = rekordbox

        var folderFallback = sourcesByKind[.folderFallback] ?? .default(for: .folderFallback)
        folderFallback.resolvedPath = fallbackRoots.first
        folderFallback.enabled = fallbackRoots.first != nil
        folderFallback.status = fallbackRoots.first == nil ? .disabled : .available
        folderFallback.lastError = nil
        sourcesByKind[.folderFallback] = folderFallback

        return LibrarySourceKind.allCases.compactMap { sourcesByKind[$0] }
    }

    func syncEnabledSources(
        _ sources: [LibrarySourceRecord],
        additionalImportedTracks: [VendorLibraryTrackRecord] = [],
        onProgress: @escaping @Sendable (ScanJobProgress) -> Void
    ) async throws -> NativeLibrarySyncSummary {
        await Task.yield()
        var importedCounts: [LibrarySourceKind: Int] = [:]
        var importedTracks: [VendorLibraryTrackRecord] = []

        for source in sources where source.enabled {
            switch source.kind {
            case .serato:
                guard let resolvedPath = source.resolvedPath else { continue }
                let tracks = try seratoService.loadTracks(from: URL(fileURLWithPath: resolvedPath))
                importedTracks.append(contentsOf: tracks)
                importedCounts[.serato] = tracks.count
            case .rekordbox:
                guard let resolvedPath = source.resolvedPath else { continue }
                let tracks = try rekordboxService.loadTracks(from: URL(fileURLWithPath: resolvedPath, isDirectory: true))
                importedTracks.append(contentsOf: tracks)
                importedCounts[.rekordbox] = tracks.count
            case .folderFallback:
                continue
            }
        }

        importedTracks.append(contentsOf: additionalImportedTracks)
        let enrichmentSummary = try await syncImportedTracks(importedTracks, onProgress: onProgress)
        return NativeLibrarySyncSummary(
            matchedTrackCount: enrichmentSummary.matchedTrackCount,
            matchedEntryCount: enrichmentSummary.matchedEntryCount,
            unmatchedEntryCount: enrichmentSummary.unmatchedEntryCount,
            referenceAttachmentCount: enrichmentSummary.referenceAttachmentCount,
            importedCounts: importedCounts
        )
    }

    func syncImportedTracks(
        _ importedTracks: [VendorLibraryTrackRecord],
        onProgress: @escaping @Sendable (ScanJobProgress) -> Void = { _ in }
    ) async throws -> VendorEnrichmentSyncSummary {
        await Task.yield()
        var progress = ScanJobProgress()
        progress.totalFiles = importedTracks.count
        progress.isRunning = true
        onProgress(progress)

        let localTracks = try database.fetchScannedTracks()
        let localTracksByPath = Dictionary(uniqueKeysWithValues: localTracks.map { ($0.filePath, $0) })
        var localTracksByID = Dictionary(uniqueKeysWithValues: localTracks.map { ($0.id, $0) })
        let localTracksByHash = Dictionary(
            grouping: localTracks,
            by: \.contentHash
        ).compactMapValues { matches in
            matches.sorted { lhs, rhs in
                let lhsDate = lhs.lastSeenInLocalScanAt ?? .distantPast
                let rhsDate = rhs.lastSeenInLocalScanAt ?? .distantPast
                if lhsDate == rhsDate {
                    return lhs.filePath.localizedStandardCompare(rhs.filePath) == .orderedAscending
                }
                return lhsDate > rhsDate
            }.first
        }

        var importedHashCache: [String: String?] = [:]
        var groupedRecordsByTrackID: [UUID: [VendorLibraryTrackRecord]] = [:]
        var groupedMetadataByTarget: [VendorEnrichmentTarget: [ExternalDJMetadata]] = [:]
        var matchedTrackIDs = Set<UUID>()
        var matchedEntryCount = 0
        var unmatchedEntryCount = 0
        var referenceAttachmentCount = 0

        for importedTrack in importedTracks {
            progress.scannedFiles += 1
            progress.currentFile = importedTrack.fileName
            onProgress(progress)

            if let target = resolveEnrichmentTarget(
                for: importedTrack,
                localTracksByPath: localTracksByPath,
                localTracksByHash: localTracksByHash,
                importedHashCache: &importedHashCache
            ) {
                groupedRecordsByTrackID[target.trackID, default: []].append(importedTrack)
                groupedMetadataByTarget[target, default: []].append(importedTrack.metadata)
                matchedTrackIDs.insert(target.trackID)
                matchedEntryCount += 1
                referenceAttachmentCount += importedTrack.metadata.playlistMemberships.count
                progress.indexedFiles += 1
            } else {
                unmatchedEntryCount += 1
                progress.skippedFiles += 1
            }
            onProgress(progress)
        }

        for trackID in matchedTrackIDs {
            guard let localTrack = localTracksByID[trackID] else { continue }
            let records = groupedRecordsByTrackID[trackID] ?? []
            let existingMetadata = try database.fetchExternalMetadata(trackID: trackID)
            let updatedTrack = enrich(track: localTrack, with: records)
            try database.upsertTrack(updatedTrack)
            localTracksByID[trackID] = updatedTrack

            for source in ExternalDJMetadata.Source.allCases {
                let target = VendorEnrichmentTarget(trackID: trackID, source: source)
                guard let incomingMetadata = groupedMetadataByTarget[target], !incomingMetadata.isEmpty else {
                    continue
                }
                let mergedMetadata = mergeExternalMetadata(
                    existing: existingMetadata.filter { $0.source == source },
                    incoming: incomingMetadata,
                    source: source
                )
                try database.replaceExternalMetadata(
                    trackID: updatedTrack.id,
                    source: source,
                    entries: mergedMetadata.map { [$0] } ?? []
                )
            }
        }

        progress.isRunning = false
        onProgress(progress)
        return VendorEnrichmentSyncSummary(
            matchedTrackCount: matchedTrackIDs.count,
            matchedEntryCount: matchedEntryCount,
            unmatchedEntryCount: unmatchedEntryCount,
            referenceAttachmentCount: referenceAttachmentCount
        )
    }

    private func resolveEnrichmentTarget(
        for importedTrack: VendorLibraryTrackRecord,
        localTracksByPath: [String: Track],
        localTracksByHash: [String: Track],
        importedHashCache: inout [String: String?]
    ) -> VendorEnrichmentTarget? {
        if let exactTrack = localTracksByPath[importedTrack.normalizedPath] {
            return VendorEnrichmentTarget(trackID: exactTrack.id, source: importedTrack.source)
        }

        let hash = importedHashCache[importedTrack.normalizedPath] ?? {
            let path = importedTrack.normalizedPath
            let pathHash: String?
            if fileManager.fileExists(atPath: path) {
                pathHash = FileHashingService.contentHash(for: URL(fileURLWithPath: path))
            } else {
                pathHash = nil
            }
            importedHashCache[path] = pathHash
            return pathHash
        }()

        guard let hash, let hashedTrack = localTracksByHash[hash] else {
            return nil
        }
        return VendorEnrichmentTarget(trackID: hashedTrack.id, source: importedTrack.source)
    }

    private func enrich(
        track: Track,
        with records: [VendorLibraryTrackRecord]
    ) -> Track {
        var updatedTrack = track
        let seratoRecords = records.filter { $0.source == .serato }
        let rekordboxRecords = records.filter { $0.source == .rekordbox }

        updatedTrack.title = fillIfBlank(
            track.title,
            candidates: seratoRecords.map { $0.title as String? } + rekordboxRecords.map { $0.title as String? }
        )
        updatedTrack.artist = fillIfBlank(
            track.artist,
            candidates: seratoRecords.map { $0.artist as String? } + rekordboxRecords.map { $0.artist as String? }
        )
        updatedTrack.album = fillIfBlank(
            track.album,
            candidates: seratoRecords.map { $0.album as String? } + rekordboxRecords.map { $0.album as String? }
        )
        if updatedTrack.duration <= 0, let duration = records.compactMap(\.duration).first(where: { $0 > 0 }) {
            updatedTrack.duration = duration
        }

        if !seratoRecords.isEmpty {
            updatedTrack.hasSeratoMetadata = true
        }
        if !rekordboxRecords.isEmpty {
            updatedTrack.hasRekordboxMetadata = true
        }

        applyPreferredGenre(
            to: &updatedTrack,
            seratoGenre: preferredGenre(from: seratoRecords),
            rekordboxGenre: preferredGenre(from: rekordboxRecords)
        )

        updatedTrack.comment = firstNonEmpty(
            seratoRecords.map(\.metadata.comment)
                + [track.comment as String?]
                + rekordboxRecords.map(\.metadata.comment)
        )

        applyPreferredBPMAndKey(to: &updatedTrack, records: seratoRecords, source: .serato)
        applyPreferredBPMAndKey(to: &updatedTrack, records: rekordboxRecords, source: .rekordbox)

        return updatedTrack
    }

    private func applyPreferredBPMAndKey(
        to track: inout Track,
        records: [VendorLibraryTrackRecord],
        source: ExternalDJMetadata.Source
    ) {
        guard !records.isEmpty else { return }
        let metadataSource: TrackMetadataSource = source == .serato ? .serato : .rekordbox

        if let importedBPM = records.compactMap(\.bpm).first,
           shouldAdoptMetadataValue(importedBPM, from: metadataSource, over: track.bpm, currentSource: track.bpmSource)
        {
            track.bpm = importedBPM
            track.bpmSource = metadataSource
        }

        if let importedKey = records.compactMap(\.musicalKey).first,
           shouldAdoptMetadataValue(importedKey, from: metadataSource, over: track.musicalKey, currentSource: track.keySource)
        {
            track.musicalKey = importedKey
            track.keySource = metadataSource
        }
    }

    private func applyPreferredGenre(
        to track: inout Track,
        seratoGenre: String?,
        rekordboxGenre: String?
    ) {
        let currentGenre = normalizedText(track.genre)
        switch track.genreSource {
        case .audioTags where currentGenre != nil:
            return
        case .serato where currentGenre != nil:
            if let seratoGenre {
                track.genre = seratoGenre
                track.genreSource = .serato
            }
        case .rekordbox where currentGenre != nil:
            if let seratoGenre {
                track.genre = seratoGenre
                track.genreSource = .serato
            } else if let rekordboxGenre {
                track.genre = rekordboxGenre
                track.genreSource = .rekordbox
            }
        default:
            if let seratoGenre {
                track.genre = seratoGenre
                track.genreSource = .serato
            } else if let rekordboxGenre {
                track.genre = rekordboxGenre
                track.genreSource = .rekordbox
            }
        }
    }

    private func preferredGenre(from records: [VendorLibraryTrackRecord]) -> String? {
        firstNonEmptyOptional(
            records.map { $0.genre as String? } + records.flatMap { record in
                [record.metadata.tags.first]
            }
        )
    }

    private func mergeExternalMetadata(
        existing: [ExternalDJMetadata],
        incoming: [ExternalDJMetadata],
        source: ExternalDJMetadata.Source
    ) -> ExternalDJMetadata? {
        let combined = incoming + existing
        guard !combined.isEmpty else { return nil }

        let trackPath = combined
            .map(\.trackPath)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            ?? ""

        let cuePoints = Array(Set(combined.flatMap(\.cuePoints))).sorted {
            if $0.startSec != $1.startSec {
                return $0.startSec < $1.startSec
            }
            let lhsIndex = $0.index ?? .max
            let rhsIndex = $1.index ?? .max
            if lhsIndex != rhsIndex {
                return lhsIndex < rhsIndex
            }
            return ($0.name ?? "") < ($1.name ?? "")
        }

        return ExternalDJMetadata(
            id: incoming.first?.id ?? existing.first?.id ?? UUID(),
            trackPath: trackPath,
            source: source,
            bpm: firstNonNil(incoming.map(\.bpm) + existing.map(\.bpm)),
            musicalKey: firstNonEmptyOptional(incoming.map(\.musicalKey) + existing.map(\.musicalKey)),
            rating: firstNonNil(incoming.map(\.rating) + existing.map(\.rating)),
            color: firstNonEmptyOptional(incoming.map(\.color) + existing.map(\.color)),
            tags: uniqueOrderedStrings(combined.flatMap(\.tags)),
            playCount: firstNonNil(incoming.map(\.playCount) + existing.map(\.playCount)),
            lastPlayed: (incoming + existing).compactMap(\.lastPlayed).max(),
            playlistMemberships: uniqueOrderedStrings(combined.flatMap(\.playlistMemberships)),
            cueCount: cuePoints.isEmpty ? combined.compactMap(\.cueCount).max() : cuePoints.count,
            cuePoints: cuePoints,
            comment: firstNonEmptyOptional(incoming.map(\.comment) + existing.map(\.comment)),
            vendorTrackID: firstNonEmptyOptional(incoming.map(\.vendorTrackID) + existing.map(\.vendorTrackID)),
            analysisState: firstNonEmptyOptional(incoming.map(\.analysisState) + existing.map(\.analysisState)),
            analysisCachePath: firstNonEmptyOptional(incoming.map(\.analysisCachePath) + existing.map(\.analysisCachePath)),
            syncVersion: firstNonEmptyOptional(incoming.map(\.syncVersion) + existing.map(\.syncVersion))
        )
    }

    private func fillIfBlank(_ currentValue: String, candidates: [String?]) -> String {
        normalizedText(currentValue) ?? firstNonEmpty(candidates)
    }

    private func firstNonEmpty(_ values: [String?]) -> String {
        firstNonEmptyOptional(values) ?? ""
    }

    private func firstNonEmptyOptional(_ values: [String?]) -> String? {
        values.compactMap { value -> String? in
            normalizedText(value)
        }.first
    }

    private func normalizedText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func uniqueOrderedStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values {
            guard let normalized = normalizedText(value), seen.insert(normalized).inserted else {
                continue
            }
            output.append(normalized)
        }
        return output
    }

    private func firstNonNil<Value>(_ values: [Value?]) -> Value? {
        values.compactMap { $0 }.first
    }
}

private struct SeratoContainerNode {
    let id: Int
    let parentID: Int?
    let name: String
}

private struct RekordboxManageRow {
    let normalizedPath: String
    let analysisCachePath: String?
    let analyzeStatus: Int?
    let analyzeKey: Int?
    let analyzeBPMRange: Int?
    let trackID: String?
    let trackChecksum: String?
    let duration: Double?
    let rekordboxVersion: String?
    let analyzeVersion: String?
}

private struct RekordboxAggregate {
    let path: String
    var analysisCachePath: String?
    var analyzeStatus: Int?
    var analyzeKey: Int?
    var analyzeBPMRange: Int?
    var vendorTrackID: String?
    var duration: Double?
    var syncVersion: String?
    var playlistMemberships: [String] = []

    mutating func merge(_ row: RekordboxManageRow) {
        if let cachePath = row.analysisCachePath, !cachePath.isEmpty {
            analysisCachePath = cachePath
        }
        if let analyzeStatus = row.analyzeStatus {
            self.analyzeStatus = analyzeStatus
        }
        if let analyzeKey = row.analyzeKey, analyzeKey > 0 {
            self.analyzeKey = analyzeKey
        }
        if let analyzeBPMRange = row.analyzeBPMRange, analyzeBPMRange >= 0 {
            self.analyzeBPMRange = analyzeBPMRange
        }
        if let duration = row.duration, duration > 0 {
            self.duration = duration
        }
        if let trackID = row.trackID, !trackID.isEmpty {
            vendorTrackID = trackID
        } else if let trackChecksum = row.trackChecksum, !trackChecksum.isEmpty {
            vendorTrackID = trackChecksum
        }

        let versions = [row.rekordboxVersion, row.analyzeVersion]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
        if !versions.isEmpty {
            syncVersion = versions.joined(separator: "/")
        }
    }

    var analysisStateDescription: String? {
        var parts: [String] = []
        if let analyzeStatus {
            parts.append("status=\(analyzeStatus)")
        }
        if let analyzeKey {
            parts.append("keyCode=\(analyzeKey)")
        }
        if let analyzeBPMRange {
            parts.append("bpmRange=\(analyzeBPMRange)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

struct VendorEnrichmentSyncSummary {
    let matchedTrackCount: Int
    let matchedEntryCount: Int
    let unmatchedEntryCount: Int
    let referenceAttachmentCount: Int
}

private struct VendorEnrichmentTarget: Hashable {
    let trackID: UUID
    let source: ExternalDJMetadata.Source
}

private struct SQLiteCuePointTableSpec {
    let table: String
    let trackIDColumns: [String]
    let timeColumns: [String]
    let endColumns: [String]
    let nameColumns: [String]
    let kindColumns: [String]
    let indexColumns: [String]
    let colorColumns: [String]
    let fallbackKind: ExternalDJCuePoint.Kind
    let sourceName: String

    func supports(columns: Set<String>) -> Bool {
        guard trackIDColumns.contains(where: { columns.contains($0.lowercased()) }) else { return false }
        guard timeColumns.contains(where: { columns.contains($0.lowercased()) }) else { return false }
        return true
    }
}

private final class SQLiteReader {
    private var db: OpaquePointer?

    init(databaseURL: URL) throws {
        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            throw DatabaseError.openFailed
        }
    }

    deinit {
        sqlite3_close(db)
    }

    func query<T>(_ sql: String, bind: ((OpaquePointer?) throws -> Void)? = nil, map: (OpaquePointer?) throws -> T?) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }

        if let bind {
            try bind(statement)
        }

        var results: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let mapped = try map(statement) {
                results.append(mapped)
            }
        }
        return results
    }

    func tableExists(_ table: String) throws -> Bool {
        let target = table.lowercased()
        return try tableNames().contains(where: { $0 == target })
    }

    func tableNames() throws -> [String] {
        try query("SELECT name FROM sqlite_master WHERE type = 'table';") { statement in
            guard let text = string(statement, index: 0) else { return nil }
            return text.lowercased()
        }
    }

    func columns(for table: String) throws -> Set<String> {
        let lowercasedTable = table.lowercased()
        let sql = "PRAGMA table_info(\(lowercasedTable));"
        let columns: [String] = try query(sql) { statement in
            guard let text = string(statement, index: 1) else { return nil }
            return text.lowercased()
        }
        return Set(columns)
    }

    func rowDictionary(_ statement: OpaquePointer?) -> [String: Any?] {
        let columnCount = sqlite3_column_count(statement)
        var dict: [String: Any?] = [:]
        for index in 0..<columnCount {
            guard let rawName = sqlite3_column_name(statement, Int32(index)) else { continue }
            let name = String(cString: rawName).lowercased()
            dict[name] = rowValue(statement: statement, index: Int32(index))
        }
        return dict
    }

    func string(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    func optionalDouble(_ statement: OpaquePointer?, index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    func optionalInt(_ statement: OpaquePointer?, index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }

    private func rowValue(statement: OpaquePointer?, index: Int32) -> Any? {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return sqlite3_column_int64(statement, index)
        case SQLITE_FLOAT:
            return sqlite3_column_double(statement, index)
        case SQLITE_TEXT:
            return string(statement, index: index)
        case SQLITE_BLOB:
            guard let blob = sqlite3_column_blob(statement, index) else { return nil }
            let size = sqlite3_column_bytes(statement, index)
            guard size > 0 else { return nil }
            return Data(bytes: blob, count: Int(size))
        default:
            return nil
        }
    }
}
