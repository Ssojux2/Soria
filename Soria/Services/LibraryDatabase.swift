import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class LibraryDatabase {
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() throws {
        AppPaths.ensureDirectories()
        if sqlite3_open(AppPaths.databaseURL.path, &db) != SQLITE_OK {
            throw DatabaseError.openFailed
        }
        try createSchema()
    }

    deinit {
        sqlite3_close(db)
    }

    func fetchAllTracks() throws -> [Track] {
        let sql = """
        SELECT id, file_path, file_name, title, artist, album, genre, duration, sample_rate, bpm, musical_key,
               modified_time, content_hash, analyzed_at, has_serato, has_rekordbox
        FROM tracks
        ORDER BY artist COLLATE NOCASE, title COLLATE NOCASE;
        """
        return try withStatement(sql) { statement in
            var tracks: [Track] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard
                    let idText = sqliteString(statement, index: 0),
                    let id = UUID(uuidString: idText),
                    let filePath = sqliteString(statement, index: 1),
                    let fileName = sqliteString(statement, index: 2),
                    let title = sqliteString(statement, index: 3),
                    let artist = sqliteString(statement, index: 4),
                    let album = sqliteString(statement, index: 5),
                    let genre = sqliteString(statement, index: 6),
                    let modifiedTimeText = sqliteString(statement, index: 11),
                    let contentHash = sqliteString(statement, index: 12)
                else {
                    continue
                }

                let modifiedTime = Self.iso8601.date(from: modifiedTimeText) ?? .distantPast
                let analyzedAt = sqliteString(statement, index: 13).flatMap { Self.iso8601.date(from: $0) }
                tracks.append(
                    Track(
                        id: id,
                        filePath: filePath,
                        fileName: fileName,
                        title: title,
                        artist: artist,
                        album: album,
                        genre: genre,
                        duration: sqlite3_column_double(statement, 7),
                        sampleRate: sqlite3_column_double(statement, 8),
                        bpm: sqliteOptionalDouble(statement, index: 9),
                        musicalKey: sqliteString(statement, index: 10),
                        modifiedTime: modifiedTime,
                        contentHash: contentHash,
                        analyzedAt: analyzedAt,
                        hasSeratoMetadata: sqlite3_column_int(statement, 14) == 1,
                        hasRekordboxMetadata: sqlite3_column_int(statement, 15) == 1
                    )
                )
            }
            return tracks
        }
    }

    func upsertTrack(_ track: Track) throws {
        let sql = """
        INSERT INTO tracks (
            id, file_path, file_name, title, artist, album, genre, duration, sample_rate, bpm, musical_key,
            modified_time, content_hash, analyzed_at, has_serato, has_rekordbox
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(file_path) DO UPDATE SET
            file_name = excluded.file_name,
            title = excluded.title,
            artist = excluded.artist,
            album = excluded.album,
            genre = excluded.genre,
            duration = excluded.duration,
            sample_rate = excluded.sample_rate,
            bpm = excluded.bpm,
            musical_key = excluded.musical_key,
            modified_time = excluded.modified_time,
            content_hash = excluded.content_hash,
            analyzed_at = excluded.analyzed_at,
            has_serato = excluded.has_serato,
            has_rekordbox = excluded.has_rekordbox;
        """
        try withStatement(sql) { statement in
            bind(statement, index: 1, text: track.id.uuidString)
            bind(statement, index: 2, text: track.filePath)
            bind(statement, index: 3, text: track.fileName)
            bind(statement, index: 4, text: track.title)
            bind(statement, index: 5, text: track.artist)
            bind(statement, index: 6, text: track.album)
            bind(statement, index: 7, text: track.genre)
            sqlite3_bind_double(statement, 8, track.duration)
            sqlite3_bind_double(statement, 9, track.sampleRate)
            bind(statement, index: 10, double: track.bpm)
            bind(statement, index: 11, text: track.musicalKey)
            bind(statement, index: 12, text: Self.iso8601.string(from: track.modifiedTime))
            bind(statement, index: 13, text: track.contentHash)
            bind(statement, index: 14, text: track.analyzedAt.map { Self.iso8601.string(from: $0) })
            sqlite3_bind_int(statement, 15, track.hasSeratoMetadata ? 1 : 0)
            sqlite3_bind_int(statement, 16, track.hasRekordboxMetadata ? 1 : 0)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.writeFailed
            }
        }
    }

    func lookupTrack(path: String) throws -> Track? {
        let sql = "SELECT id, modified_time, content_hash FROM tracks WHERE file_path = ? LIMIT 1;"
        return try withStatement(sql) { statement in
            bind(statement, index: 1, text: path)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard
                let idText = sqliteString(statement, index: 0),
                let id = UUID(uuidString: idText),
                let modifiedTimeText = sqliteString(statement, index: 1),
                let contentHash = sqliteString(statement, index: 2)
            else {
                return nil
            }
            return Track.empty(
                path: path,
                modifiedTime: Self.iso8601.date(from: modifiedTimeText) ?? .distantPast,
                hash: contentHash
            ).withID(id)
        }
    }

    func replaceSegments(
        trackID: UUID,
        segments: [TrackSegment],
        analysisSummary: TrackAnalysisSummary
    ) throws {
        try withTransaction {
            try withStatement("DELETE FROM segments WHERE track_id = ?;") { statement in
                bind(statement, index: 1, text: trackID.uuidString)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw DatabaseError.writeFailed
                }
            }

            let insertSQL = """
            INSERT INTO segments (
                id, track_id, segment_type, start_sec, end_sec, energy_score, descriptor_text, embedding_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
            try withStatement(insertSQL) { statement in
                for segment in segments {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    bind(statement, index: 1, text: segment.id.uuidString)
                    bind(statement, index: 2, text: segment.trackID.uuidString)
                    bind(statement, index: 3, text: segment.type.rawValue)
                    sqlite3_bind_double(statement, 4, segment.startSec)
                    sqlite3_bind_double(statement, 5, segment.endSec)
                    sqlite3_bind_double(statement, 6, segment.energyScore)
                    bind(statement, index: 7, text: segment.descriptorText)
                    bind(statement, index: 8, text: jsonString(segment.vector ?? []))
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw DatabaseError.writeFailed
                    }
                }
            }

            let updateSQL = """
            UPDATE tracks
            SET analyzed_at = ?, track_embedding_json = ?, analysis_summary_json = ?
            WHERE id = ?;
            """
            try withStatement(updateSQL) { statement in
                bind(statement, index: 1, text: Self.iso8601.string(from: Date()))
                bind(statement, index: 2, text: jsonString(analysisSummary.trackEmbedding ?? []))
                bind(statement, index: 3, text: jsonString(analysisSummary))
                bind(statement, index: 4, text: trackID.uuidString)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw DatabaseError.writeFailed
                }
            }
        }
    }

    func fetchSegments(trackID: UUID) throws -> [TrackSegment] {
        let sql = """
        SELECT id, segment_type, start_sec, end_sec, energy_score, descriptor_text, embedding_json
        FROM segments
        WHERE track_id = ?
        ORDER BY start_sec;
        """
        return try withStatement(sql) { statement in
            bind(statement, index: 1, text: trackID.uuidString)
            var segments: [TrackSegment] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard
                    let idText = sqliteString(statement, index: 0),
                    let id = UUID(uuidString: idText),
                    let typeText = sqliteString(statement, index: 1),
                    let type = TrackSegment.SegmentType(rawValue: typeText),
                    let descriptorText = sqliteString(statement, index: 5)
                else {
                    continue
                }
                segments.append(
                    TrackSegment(
                        id: id,
                        trackID: trackID,
                        type: type,
                        startSec: sqlite3_column_double(statement, 2),
                        endSec: sqlite3_column_double(statement, 3),
                        energyScore: sqlite3_column_double(statement, 4),
                        descriptorText: descriptorText,
                        vector: doubles(from: sqliteString(statement, index: 6) ?? "[]")
                    )
                )
            }
            return segments
        }
    }

    func fetchTrackEmbedding(trackID: UUID) throws -> [Double]? {
        let sql = "SELECT track_embedding_json FROM tracks WHERE id = ? LIMIT 1;"
        return try withStatement(sql) { statement in
            bind(statement, index: 1, text: trackID.uuidString)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard let jsonText = sqliteString(statement, index: 0), !jsonText.isEmpty else { return nil }
            return doubles(from: jsonText)
        }
    }

    func fetchAnalysisSummary(trackID: UUID) throws -> TrackAnalysisSummary? {
        let sql = "SELECT analysis_summary_json FROM tracks WHERE id = ? LIMIT 1;"
        return try withStatement(sql) { statement in
            bind(statement, index: 1, text: trackID.uuidString)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard let jsonText = sqliteString(statement, index: 0), !jsonText.isEmpty else { return nil }
            return try? decode(TrackAnalysisSummary.self, from: jsonText)
        }
    }

    func replaceExternalMetadata(
        trackID: UUID,
        source: ExternalDJMetadata.Source,
        entries: [ExternalDJMetadata]
    ) throws {
        try withTransaction {
            try withStatement("DELETE FROM external_metadata WHERE track_id = ? AND source = ?;") { statement in
                bind(statement, index: 1, text: trackID.uuidString)
                bind(statement, index: 2, text: source.rawValue)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw DatabaseError.writeFailed
                }
            }

            let insertSQL = """
            INSERT INTO external_metadata (
                id, track_id, source, track_path, bpm, musical_key, rating, color, tags_json, play_count,
                last_played, playlist_memberships_json, cue_count, comment
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            try withStatement(insertSQL) { statement in
                for entry in entries {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    bind(statement, index: 1, text: entry.id.uuidString)
                    bind(statement, index: 2, text: trackID.uuidString)
                    bind(statement, index: 3, text: entry.source.rawValue)
                    bind(statement, index: 4, text: entry.trackPath)
                    bind(statement, index: 5, double: entry.bpm)
                    bind(statement, index: 6, text: entry.musicalKey)
                    bind(statement, index: 7, int: entry.rating)
                    bind(statement, index: 8, text: entry.color)
                    bind(statement, index: 9, text: jsonString(entry.tags))
                    bind(statement, index: 10, int: entry.playCount)
                    bind(statement, index: 11, text: entry.lastPlayed.map { Self.iso8601.string(from: $0) })
                    bind(statement, index: 12, text: jsonString(entry.playlistMemberships))
                    bind(statement, index: 13, int: entry.cueCount)
                    bind(statement, index: 14, text: entry.comment)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw DatabaseError.writeFailed
                    }
                }
            }
        }
    }

    func fetchExternalMetadata(trackID: UUID) throws -> [ExternalDJMetadata] {
        let sql = """
        SELECT id, source, track_path, bpm, musical_key, rating, color, tags_json, play_count,
               last_played, playlist_memberships_json, cue_count, comment
        FROM external_metadata
        WHERE track_id = ?
        ORDER BY source;
        """
        return try withStatement(sql) { statement in
            bind(statement, index: 1, text: trackID.uuidString)
            var results: [ExternalDJMetadata] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard
                    let idText = sqliteString(statement, index: 0),
                    let id = UUID(uuidString: idText),
                    let sourceText = sqliteString(statement, index: 1),
                    let source = ExternalDJMetadata.Source(rawValue: sourceText),
                    let trackPath = sqliteString(statement, index: 2)
                else {
                    continue
                }
                let lastPlayed = sqliteString(statement, index: 9).flatMap { Self.iso8601.date(from: $0) }
                results.append(
                    ExternalDJMetadata(
                        id: id,
                        trackPath: trackPath,
                        source: source,
                        bpm: sqliteOptionalDouble(statement, index: 3),
                        musicalKey: sqliteString(statement, index: 4),
                        rating: sqliteOptionalInt(statement, index: 5),
                        color: sqliteString(statement, index: 6),
                        tags: stringArray(from: sqliteString(statement, index: 7) ?? "[]"),
                        playCount: sqliteOptionalInt(statement, index: 8),
                        lastPlayed: lastPlayed,
                        playlistMemberships: stringArray(from: sqliteString(statement, index: 10) ?? "[]"),
                        cueCount: sqliteOptionalInt(statement, index: 11),
                        comment: sqliteString(statement, index: 12)
                    )
                )
            }
            return results
        }
    }

    private func createSchema() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS tracks (
            id TEXT PRIMARY KEY,
            file_path TEXT NOT NULL UNIQUE,
            file_name TEXT NOT NULL,
            title TEXT NOT NULL,
            artist TEXT NOT NULL,
            album TEXT NOT NULL,
            genre TEXT NOT NULL,
            duration REAL NOT NULL,
            sample_rate REAL NOT NULL,
            bpm REAL,
            musical_key TEXT,
            modified_time TEXT NOT NULL,
            content_hash TEXT NOT NULL,
            analyzed_at TEXT,
            has_serato INTEGER NOT NULL DEFAULT 0,
            has_rekordbox INTEGER NOT NULL DEFAULT 0,
            track_embedding_json TEXT,
            analysis_summary_json TEXT
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS segments (
            id TEXT PRIMARY KEY,
            track_id TEXT NOT NULL,
            segment_type TEXT NOT NULL,
            start_sec REAL NOT NULL,
            end_sec REAL NOT NULL,
            energy_score REAL NOT NULL,
            descriptor_text TEXT NOT NULL,
            embedding_json TEXT,
            FOREIGN KEY(track_id) REFERENCES tracks(id)
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS external_metadata (
            id TEXT PRIMARY KEY,
            track_id TEXT NOT NULL,
            source TEXT NOT NULL,
            track_path TEXT NOT NULL,
            bpm REAL,
            musical_key TEXT,
            rating INTEGER,
            color TEXT,
            tags_json TEXT NOT NULL DEFAULT '[]',
            play_count INTEGER,
            last_played TEXT,
            playlist_memberships_json TEXT NOT NULL DEFAULT '[]',
            cue_count INTEGER,
            comment TEXT,
            FOREIGN KEY(track_id) REFERENCES tracks(id)
        );
        """)

        if try !columnExists(table: "tracks", column: "track_embedding_json") {
            try exec("ALTER TABLE tracks ADD COLUMN track_embedding_json TEXT;")
        }
        if try !columnExists(table: "tracks", column: "analysis_summary_json") {
            try exec("ALTER TABLE tracks ADD COLUMN analysis_summary_json TEXT;")
        }

        try exec("CREATE INDEX IF NOT EXISTS idx_tracks_hash ON tracks(content_hash);")
        try exec("CREATE INDEX IF NOT EXISTS idx_segments_track ON segments(track_id);")
        try exec("CREATE INDEX IF NOT EXISTS idx_external_metadata_track ON external_metadata(track_id);")
        try exec("CREATE INDEX IF NOT EXISTS idx_tracks_path ON tracks(file_path);")
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed
        }
    }

    private func withStatement<T>(_ sql: String, body: (OpaquePointer?) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func withTransaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try body()
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func columnExists(table: String, column: String) throws -> Bool {
        let sql = "PRAGMA table_info(\(table));"
        return try withStatement(sql) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                if sqliteString(statement, index: 1) == column {
                    return true
                }
            }
            return false
        }
    }

    private func bind(_ statement: OpaquePointer?, index: Int32, text: String?) {
        if let text {
            sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(_ statement: OpaquePointer?, index: Int32, double: Double?) {
        if let value = double {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(_ statement: OpaquePointer?, index: Int32, int: Int?) {
        if let value = int {
            sqlite3_bind_int64(statement, index, sqlite3_int64(value))
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func sqliteString(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private func sqliteOptionalDouble(_ statement: OpaquePointer?, index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    private func sqliteOptionalInt(_ statement: OpaquePointer?, index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }

    private func jsonString<T: Encodable>(_ value: T) -> String {
        guard let data = try? encoder.encode(value) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        guard let data = text.data(using: .utf8) else {
            throw DatabaseError.decodeFailed
        }
        return try decoder.decode(type, from: data)
    }

    private func doubles(from text: String) -> [Double] {
        (try? decode([Double].self, from: text)) ?? []
    }

    private func stringArray(from text: String) -> [String] {
        (try? decode([String].self, from: text)) ?? []
    }

    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

enum DatabaseError: Error {
    case openFailed
    case queryFailed
    case writeFailed
    case decodeFailed
}

private extension Track {
    func withID(_ id: UUID) -> Track {
        Track(
            id: id,
            filePath: filePath,
            fileName: fileName,
            title: title,
            artist: artist,
            album: album,
            genre: genre,
            duration: duration,
            sampleRate: sampleRate,
            bpm: bpm,
            musicalKey: musicalKey,
            modifiedTime: modifiedTime,
            contentHash: contentHash,
            analyzedAt: analyzedAt,
            hasSeratoMetadata: hasSeratoMetadata,
            hasRekordboxMetadata: hasRekordboxMetadata
        )
    }
}
