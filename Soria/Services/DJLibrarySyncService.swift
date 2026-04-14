import Foundation
import SQLite3

enum TrackPathNormalizer {
    static func normalizedAbsolutePath(_ input: String) -> String {
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

    static func normalizedAbsolutePath(_ url: URL) -> String {
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
    var mergedTrackCount: Int
    var importedCounts: [LibrarySourceKind: Int]

    var displayText: String {
        let orderedCounts = [LibrarySourceKind.serato, .rekordbox]
            .compactMap { kind -> String? in
                guard let count = importedCounts[kind], count > 0 else { return nil }
                return "\(kind.displayName): \(count)"
            }
            .joined(separator: " | ")

        if orderedCounts.isEmpty {
            return "No DJ library tracks were synced."
        }
        return "Synced \(mergedTrackCount) canonical tracks. \(orderedCounts)"
    }
}

final class SeratoLibraryService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
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
                cueCount: nil,
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

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func defaultSettingsURL() -> URL? {
        let url = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pioneer/rekordbox6/rekordbox3.settings")
        return fileManager.fileExists(atPath: url.path) ? url : nil
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
                var aggregate = aggregates[row.normalizedPath] ?? RekordboxAggregate(path: row.normalizedPath)
                aggregate.merge(row)
                aggregates[row.normalizedPath] = aggregate
            }
        }

        let playlistsByPath = loadPlaylists(from: databaseDirectory.appendingPathComponent("masterPlaylists6.xml"))
        for (path, playlists) in playlistsByPath {
            aggregates[path, default: RekordboxAggregate(path: path)].playlistMemberships.append(contentsOf: playlists)
        }

        return aggregates.values.map { aggregate in
            let normalizedDuration = Self.normalizedDuration(aggregate.duration)
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
                cueCount: nil,
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

    private func loadPlaylists(from xmlURL: URL) -> [String: [String]] {
        guard fileManager.fileExists(atPath: xmlURL.path),
              let data = try? Data(contentsOf: xmlURL),
              let document = try? XMLDocument(data: data),
              let nodes = try? document.nodes(forXPath: "//PLAYLISTS//NODE[@Name]")
        else {
            return [:]
        }

        var results: [String: [String]] = [:]
        for case let element as XMLElement in nodes {
            guard let playlistName = element.attribute(forName: "Name")?.stringValue else { continue }
            for member in element.elements(forName: "TRACK") {
                guard let location = member.attribute(forName: "Location")?.stringValue else { continue }
                let normalizedPath = TrackPathNormalizer.normalizedAbsolutePath(location)
                guard !normalizedPath.isEmpty else { continue }
                results[normalizedPath, default: []].append(playlistName)
            }
        }
        return results
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

    init(
        database: LibraryDatabase,
        fileManager: FileManager = .default,
        seratoService: SeratoLibraryService = SeratoLibraryService(),
        rekordboxService: RekordboxLibraryService = RekordboxLibraryService()
    ) {
        self.database = database
        self.fileManager = fileManager
        self.seratoService = seratoService
        self.rekordboxService = rekordboxService
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
        onProgress: @escaping @Sendable (ScanJobProgress) -> Void
    ) async throws -> NativeLibrarySyncSummary {
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

        let mergedTrackCount = try await syncImportedTracks(importedTracks, onProgress: onProgress)
        return NativeLibrarySyncSummary(mergedTrackCount: mergedTrackCount, importedCounts: importedCounts)
    }

    @discardableResult
    func syncImportedTracks(
        _ importedTracks: [VendorLibraryTrackRecord],
        onProgress: @escaping @Sendable (ScanJobProgress) -> Void = { _ in }
    ) async throws -> Int {
        var progress = ScanJobProgress()
        progress.totalFiles = importedTracks.count
        progress.isRunning = true
        onProgress(progress)

        var mergedPaths = Set<String>()
        for importedTrack in importedTracks {
            progress.scannedFiles += 1
            progress.currentFile = importedTrack.fileName
            onProgress(progress)

            try await upsert(importedTrack)
            mergedPaths.insert(importedTrack.normalizedPath)
            progress.indexedFiles += 1
            onProgress(progress)
        }

        progress.isRunning = false
        onProgress(progress)
        return mergedPaths.count
    }

    private func upsert(_ importedTrack: VendorLibraryTrackRecord) async throws {
        let normalizedPath = importedTrack.normalizedPath
        let existing = try database.fetchTrack(path: normalizedPath)
        let fileURL = URL(fileURLWithPath: normalizedPath)

        var track = existing ?? Track.empty(
            path: normalizedPath,
            modifiedTime: existing?.modifiedTime ?? .distantPast,
            hash: existing?.contentHash ?? "vendor:\(normalizedPath)"
        )

        let fileExists = fileManager.fileExists(atPath: normalizedPath)
        let attributes = fileExists ? try? fileManager.attributesOfItem(atPath: normalizedPath) : nil
        let modifiedTime = (attributes?[.modificationDate] as? Date) ?? existing?.modifiedTime ?? .distantPast

        var contentHash = existing?.contentHash ?? "vendor:\(normalizedPath)"
        var sampleRate = existing?.sampleRate ?? 0
        var audioMetadata: (
            title: String,
            artist: String,
            album: String,
            genre: String,
            duration: TimeInterval,
            sampleRate: Double,
            bpm: Double?,
            musicalKey: String?
        )?

        let fileChanged: Bool
        if fileExists {
            if let existing {
                fileChanged = existing.modifiedTime != modifiedTime
            } else {
                fileChanged = true
            }
            if fileChanged || existing == nil {
                contentHash = FileHashingService.contentHash(for: fileURL)
            }
            let shouldReadAudioMetadata = existing == nil ||
                importedTrack.artist.isEmpty ||
                importedTrack.album.isEmpty ||
                importedTrack.genre.isEmpty ||
                importedTrack.duration == nil ||
                (importedTrack.bpm == nil && track.bpm == nil) ||
                (importedTrack.musicalKey == nil && track.musicalKey == nil) ||
                sampleRate == 0

            if shouldReadAudioMetadata {
                audioMetadata = await AudioMetadataReader.readMetadata(for: fileURL)
                sampleRate = audioMetadata?.sampleRate ?? sampleRate
            }
        } else {
            fileChanged = false
        }

        if fileChanged, let existing, existing.analyzedAt != nil {
            try database.clearAnalysis(trackID: existing.id)
            track.analyzedAt = nil
            if track.bpmSource == .soriaAnalysis {
                track.bpm = nil
                track.bpmSource = nil
            }
            if track.keySource == .soriaAnalysis {
                track.musicalKey = nil
                track.keySource = nil
            }
        } else {
            track.analyzedAt = existing?.analyzedAt
        }

        track.filePath = normalizedPath
        track.fileName = importedTrack.fileName
        track.modifiedTime = modifiedTime
        track.contentHash = contentHash
        track.sampleRate = sampleRate

        track.title = firstNonEmpty(
            importedTrack.title,
            existing?.title,
            audioMetadata?.title,
            URL(fileURLWithPath: importedTrack.fileName).deletingPathExtension().lastPathComponent
        )
        track.artist = firstNonEmpty(importedTrack.artist, existing?.artist, audioMetadata?.artist)
        track.album = firstNonEmpty(importedTrack.album, existing?.album, audioMetadata?.album)
        track.genre = firstNonEmpty(importedTrack.genre, existing?.genre, audioMetadata?.genre)
        track.duration = importedTrack.duration ?? existing?.duration ?? audioMetadata?.duration ?? 0

        if importedTrack.source == .serato {
            track.hasSeratoMetadata = true
        }
        if importedTrack.source == .rekordbox {
            track.hasRekordboxMetadata = true
        }

        if shouldAdoptMetadataValue(
            importedTrack.bpm,
            from: importedTrack.metadataSource,
            over: track.bpm,
            currentSource: track.bpmSource
        ) {
            track.bpm = importedTrack.bpm
            track.bpmSource = importedTrack.metadataSource
        } else if shouldAdoptMetadataValue(
            audioMetadata?.bpm,
            from: .audioTags,
            over: track.bpm,
            currentSource: track.bpmSource
        ) {
            track.bpm = audioMetadata?.bpm
            track.bpmSource = .audioTags
        }

        if shouldAdoptMetadataValue(
            importedTrack.musicalKey,
            from: importedTrack.metadataSource,
            over: track.musicalKey,
            currentSource: track.keySource
        ) {
            track.musicalKey = importedTrack.musicalKey
            track.keySource = importedTrack.metadataSource
        } else if shouldAdoptMetadataValue(
            audioMetadata?.musicalKey,
            from: .audioTags,
            over: track.musicalKey,
            currentSource: track.keySource
        ) {
            track.musicalKey = audioMetadata?.musicalKey
            track.keySource = .audioTags
        }

        try database.upsertTrack(track)
        try database.replaceExternalMetadata(
            trackID: track.id,
            source: importedTrack.source,
            entries: [importedTrack.metadata]
        )
    }

    private func firstNonEmpty(_ values: String?...) -> String {
        values.compactMap { value -> String? in
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }.first ?? ""
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

    func query<T>(_ sql: String, map: (OpaquePointer?) throws -> T?) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }

        var results: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let mapped = try map(statement) {
                results.append(mapped)
            }
        }
        return results
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
}
