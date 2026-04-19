import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class LibraryDatabase {
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let databaseURL: URL

    var fileURL: URL { databaseURL }

    init(databaseURL: URL = AppPaths.databaseURL) throws {
        self.databaseURL = databaseURL
        let parentDirectory = databaseURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        AppPaths.ensureDirectories()
        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            throw DatabaseError.openFailed
        }
        try configureConnection()
        try createSchema()
    }

    deinit {
        sqlite3_close(db)
    }

    func fetchAllTracks() throws -> [Track] {
        let sql = """
        SELECT \(trackSelectColumns)
        FROM tracks
        ORDER BY artist COLLATE NOCASE, title COLLATE NOCASE;
        """
        return try withStatement(sql) { statement in
            var tracks: [Track] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let track = track(from: statement) {
                    tracks.append(track)
                }
            }
            return tracks
        }
    }

    func fetchScannedTracks() throws -> [Track] {
        let sql = """
        SELECT \(trackSelectColumns)
        FROM tracks
        WHERE last_seen_in_local_scan_at IS NOT NULL
        ORDER BY artist COLLATE NOCASE, title COLLATE NOCASE;
        """
        return try withStatement(sql) { statement in
            var tracks: [Track] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let track = track(from: statement) {
                    tracks.append(track)
                }
            }
            return tracks
        }
    }

    func fetchTrack(path: String) throws -> Track? {
        let sql = """
        SELECT \(trackSelectColumns)
        FROM tracks
        WHERE file_path = ?
        LIMIT 1;
        """
        return try withStatement(sql) { statement in
            bind(statement, index: 1, text: path)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return track(from: statement)
        }
    }

    func fetchTrack(matchingContentHash hash: String, requireLocalScan: Bool = false) throws -> Track? {
        let localPredicate = requireLocalScan ? "AND last_seen_in_local_scan_at IS NOT NULL" : ""
        let sql = """
        SELECT \(trackSelectColumns)
        FROM tracks
        WHERE content_hash = ?
          \(localPredicate)
        ORDER BY last_seen_in_local_scan_at DESC, modified_time DESC
        LIMIT 1;
        """
        return try withStatement(sql) { statement in
            bind(statement, index: 1, text: hash)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return track(from: statement)
        }
    }

    func upsertTrack(_ track: Track) throws {
        let sql = """
        INSERT INTO tracks (
            id, file_path, file_name, title, artist, album, genre, duration, sample_rate, bpm, musical_key,
            modified_time, content_hash, analyzed_at, embedding_profile_id, embedding_pipeline_id, embedding_updated_at,
            has_serato, has_rekordbox, bpm_source, key_source, last_seen_in_local_scan_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            embedding_profile_id = excluded.embedding_profile_id,
            embedding_pipeline_id = excluded.embedding_pipeline_id,
            embedding_updated_at = excluded.embedding_updated_at,
            has_serato = excluded.has_serato,
            has_rekordbox = excluded.has_rekordbox,
            bpm_source = excluded.bpm_source,
            key_source = excluded.key_source,
            last_seen_in_local_scan_at = excluded.last_seen_in_local_scan_at;
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
            bind(statement, index: 15, text: track.embeddingProfileID)
            bind(statement, index: 16, text: track.embeddingPipelineID)
            bind(statement, index: 17, text: track.embeddingUpdatedAt.map { Self.iso8601.string(from: $0) })
            sqlite3_bind_int(statement, 18, track.hasSeratoMetadata ? 1 : 0)
            sqlite3_bind_int(statement, 19, track.hasRekordboxMetadata ? 1 : 0)
            bind(statement, index: 20, text: track.bpmSource?.rawValue)
            bind(statement, index: 21, text: track.keySource?.rawValue)
            bind(statement, index: 22, text: track.lastSeenInLocalScanAt.map { Self.iso8601.string(from: $0) })
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.writeFailed
            }
        }
    }

    func lookupTrack(path: String) throws -> Track? {
        try fetchTrack(path: path)
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
                    bind(statement, index: 8, text: nonEmptyJSONArrayText(segment.vector))
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw DatabaseError.writeFailed
                    }
                }
            }

            let updateSQL = """
            UPDATE tracks
            SET analyzed_at = ?, track_embedding_json = ?, analysis_summary_json = ?,
                waveform_cache_json = ?, waveform_cache_updated_at = ?,
                embedding_profile_id = NULL, embedding_pipeline_id = NULL, embedding_updated_at = NULL
            WHERE id = ?;
            """
            try withStatement(updateSQL) { statement in
                let updatedAt = Self.iso8601.string(from: Date())
                bind(statement, index: 1, text: Self.iso8601.string(from: Date()))
                bind(statement, index: 2, text: nonEmptyJSONArrayText(analysisSummary.trackEmbedding))
                bind(statement, index: 3, text: jsonString(analysisSummary))
                bind(statement, index: 4, text: analysisSummary.waveformEnvelope.map { jsonString($0) })
                bind(statement, index: 5, text: analysisSummary.waveformEnvelope == nil ? nil : updatedAt)
                bind(statement, index: 6, text: trackID.uuidString)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw DatabaseError.writeFailed
                }
            }
        }
    }

    func replaceTrackEmbeddings(
        trackID: UUID,
        segments: [TrackSegment],
        trackEmbedding: [Double]?
    ) throws {
        guard let existingSummary = try fetchAnalysisSummary(trackID: trackID) else {
            throw DatabaseError.writeFailed
        }

        let refreshedSummary = TrackAnalysisSummary(
            trackID: trackID,
            segments: segments,
            trackEmbedding: trackEmbedding,
            estimatedBPM: existingSummary.estimatedBPM,
            estimatedKey: existingSummary.estimatedKey,
            brightness: existingSummary.brightness,
            onsetDensity: existingSummary.onsetDensity,
            rhythmicDensity: existingSummary.rhythmicDensity,
            lowMidHighBalance: existingSummary.lowMidHighBalance,
            waveformPreview: existingSummary.waveformPreview,
            waveformEnvelope: existingSummary.waveformEnvelope,
            analysisFocus: existingSummary.analysisFocus,
            introLengthSec: existingSummary.introLengthSec,
            outroLengthSec: existingSummary.outroLengthSec,
            energyArc: existingSummary.energyArc,
            mixabilityTags: existingSummary.mixabilityTags,
            confidence: existingSummary.confidence
        )

        try withTransaction {
            let updateSegmentSQL = "UPDATE segments SET embedding_json = ? WHERE id = ?;"
            try withStatement(updateSegmentSQL) { statement in
                for segment in segments {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    bind(statement, index: 1, text: nonEmptyJSONArrayText(segment.vector))
                    bind(statement, index: 2, text: segment.id.uuidString)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw DatabaseError.writeFailed
                    }
                }
            }

            let updateTrackSQL = """
            UPDATE tracks
            SET track_embedding_json = ?, analysis_summary_json = ?,
                embedding_profile_id = NULL, embedding_pipeline_id = NULL, embedding_updated_at = NULL
            WHERE id = ?;
            """
            try withStatement(updateTrackSQL) { statement in
                bind(statement, index: 1, text: nonEmptyJSONArrayText(trackEmbedding))
                bind(statement, index: 2, text: jsonString(refreshedSummary))
                bind(statement, index: 3, text: trackID.uuidString)
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
                        vector: optionalDoubles(from: sqliteString(statement, index: 6))
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
            return optionalDoubles(from: jsonText)
        }
    }

    func fetchWaveformCache(trackID: UUID) throws -> TrackWaveformEnvelope? {
        let sql = "SELECT waveform_cache_json FROM tracks WHERE id = ? LIMIT 1;"
        return try withStatement(sql) { statement in
            bind(statement, index: 1, text: trackID.uuidString)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard let jsonText = sqliteString(statement, index: 0), !jsonText.isEmpty else { return nil }
            return try? decode(TrackWaveformEnvelope.self, from: jsonText)
        }
    }

    func replaceWaveformCache(trackID: UUID, waveformEnvelope: TrackWaveformEnvelope?) throws {
        let sql = """
        UPDATE tracks
        SET waveform_cache_json = ?, waveform_cache_updated_at = ?
        WHERE id = ?;
        """
        try withStatement(sql) { statement in
            bind(statement, index: 1, text: waveformEnvelope.map { jsonString($0) })
            bind(
                statement,
                index: 2,
                text: waveformEnvelope == nil ? nil : Self.iso8601.string(from: Date())
            )
            bind(statement, index: 3, text: trackID.uuidString)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.writeFailed
            }
        }
    }

    func fetchReadyTrackIDs(
        profileID: String,
        pipelineID: String,
        requireLocalScan: Bool = false
    ) throws -> Set<UUID> {
        let localPredicate = requireLocalScan ? "AND last_seen_in_local_scan_at IS NOT NULL" : ""
        let sql = """
        SELECT id
        FROM tracks
        WHERE embedding_profile_id = ?
          AND embedding_pipeline_id = ?
          AND embedding_updated_at IS NOT NULL
          AND track_embedding_json IS NOT NULL
          AND track_embedding_json <> ''
          AND track_embedding_json <> '[]'
          AND EXISTS (
            SELECT 1
            FROM segments
            WHERE segments.track_id = tracks.id
              AND embedding_json IS NOT NULL
              AND embedding_json <> ''
              AND embedding_json <> '[]'
          )
          \(localPredicate);
        """
        return try withStatement(sql) { statement in
            bind(statement, index: 1, text: profileID)
            bind(statement, index: 2, text: pipelineID)
            var output: Set<UUID> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idText = sqliteString(statement, index: 0), let id = UUID(uuidString: idText) else {
                    continue
                }
                output.insert(id)
            }
            return output
        }
    }

    func markTrackEmbeddingIndexed(
        trackID: UUID,
        embeddingProfileID: String,
        embeddingPipelineID: String,
        indexedAt: Date = Date()
    ) throws {
        try withStatement(
            """
            UPDATE tracks
            SET embedding_profile_id = ?, embedding_pipeline_id = ?, embedding_updated_at = ?
            WHERE id = ?;
            """
        ) { statement in
            bind(statement, index: 1, text: embeddingProfileID)
            bind(statement, index: 2, text: embeddingPipelineID)
            bind(statement, index: 3, text: Self.iso8601.string(from: indexedAt))
            bind(statement, index: 4, text: trackID.uuidString)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.writeFailed
            }
        }
        _ = try verifyPersistedEmbeddingState(
            trackID: trackID,
            expectedEmbeddingProfileID: embeddingProfileID,
            expectedEmbeddingPipelineID: embeddingPipelineID,
            context: "markTrackEmbeddingIndexed"
        )
    }

    func verifyPersistedEmbeddingState(
        trackID: UUID,
        expectedEmbeddingProfileID: String? = nil,
        expectedEmbeddingPipelineID: String? = nil,
        context: String = "verifyPersistedEmbeddingState"
    ) throws -> PersistedEmbeddingStateSnapshot {
        let trackSQL = """
        SELECT analyzed_at, track_embedding_json, analysis_summary_json, embedding_profile_id, embedding_pipeline_id, embedding_updated_at
        FROM tracks
        WHERE id = ?
        LIMIT 1;
        """
        let trackState = try withStatement(trackSQL) { statement -> PersistedEmbeddingStateSnapshot? in
            bind(statement, index: 1, text: trackID.uuidString)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

            let analyzedAt = sqliteString(statement, index: 0).flatMap { Self.iso8601.date(from: $0) }
            let trackEmbeddingJSON = sqliteString(statement, index: 1)
            let analysisSummaryJSON = sqliteString(statement, index: 2)
            let embeddingProfileID = sqliteString(statement, index: 3)
            let embeddingPipelineID = sqliteString(statement, index: 4)
            let embeddingUpdatedAt = sqliteString(statement, index: 5).flatMap { Self.iso8601.date(from: $0) }

            return PersistedEmbeddingStateSnapshot(
                trackID: trackID,
                analyzedAt: analyzedAt,
                hasTrackEmbedding: Self.hasNonEmptyJSONPayload(trackEmbeddingJSON),
                hasAnalysisSummary: Self.hasNonEmptyJSONPayload(analysisSummaryJSON),
                embeddingProfileID: embeddingProfileID,
                embeddingPipelineID: embeddingPipelineID,
                embeddingUpdatedAt: embeddingUpdatedAt,
                segmentCount: 0,
                embeddedSegmentCount: 0
            )
        }

        guard var snapshot = trackState else {
            throw DatabaseError.writeFailed
        }

        let segmentSQL = """
        SELECT
            COUNT(*),
            SUM(
                CASE
                    WHEN embedding_json IS NOT NULL
                     AND embedding_json <> ''
                     AND embedding_json <> '[]'
                    THEN 1
                    ELSE 0
                END
            )
        FROM segments
        WHERE track_id = ?;
        """
        let segmentState = try withStatement(segmentSQL) { statement -> (Int, Int) in
            bind(statement, index: 1, text: trackID.uuidString)
            guard sqlite3_step(statement) == SQLITE_ROW else { return (0, 0) }
            return (
                Int(sqlite3_column_int64(statement, 0)),
                Int(sqlite3_column_int64(statement, 1))
            )
        }
        snapshot.segmentCount = segmentState.0
        snapshot.embeddedSegmentCount = segmentState.1
        let analyzedAtText = snapshot.analyzedAt.map { Self.iso8601.string(from: $0) } ?? "nil"
        let embeddingUpdatedAtText = snapshot.embeddingUpdatedAt.map { Self.iso8601.string(from: $0) } ?? "nil"

        let isProfileValid = expectedEmbeddingProfileID.map { snapshot.embeddingProfileID == $0 } ?? true
        let isPipelineValid = expectedEmbeddingPipelineID.map { snapshot.embeddingPipelineID == $0 } ?? true
        guard
            snapshot.analyzedAt != nil,
            snapshot.hasTrackEmbedding,
            snapshot.hasAnalysisSummary,
            snapshot.embeddingUpdatedAt != nil,
            isProfileValid,
            isPipelineValid,
            snapshot.segmentCount > 0,
            snapshot.segmentCount == snapshot.embeddedSegmentCount
        else {
            AppLogger.shared.error(
                "Database embedding state verification failed | context=\(context) | trackID=\(trackID.uuidString) | expectedProfile=\(expectedEmbeddingProfileID ?? "nil") | actualProfile=\(snapshot.embeddingProfileID ?? "nil") | expectedPipeline=\(expectedEmbeddingPipelineID ?? "nil") | actualPipeline=\(snapshot.embeddingPipelineID ?? "nil") | analyzedAt=\(analyzedAtText) | embeddingUpdatedAt=\(embeddingUpdatedAtText) | segmentCount=\(snapshot.segmentCount) | embeddedSegmentCount=\(snapshot.embeddedSegmentCount) | hasTrackEmbedding=\(snapshot.hasTrackEmbedding) | hasAnalysisSummary=\(snapshot.hasAnalysisSummary)"
            )
            throw DatabaseError.writeFailed
        }

        AppLogger.shared.info(
            "Database embedding state verified | context=\(context) | trackID=\(trackID.uuidString) | profile=\(snapshot.embeddingProfileID ?? "nil") | pipeline=\(snapshot.embeddingPipelineID ?? "nil") | analyzedAt=\(analyzedAtText) | embeddingUpdatedAt=\(embeddingUpdatedAtText) | segmentCount=\(snapshot.segmentCount) | embeddedSegmentCount=\(snapshot.embeddedSegmentCount)"
        )
        return snapshot
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

    func clearAnalysis(trackID: UUID) throws {
        try withTransaction {
            try withStatement("DELETE FROM segments WHERE track_id = ?;") { statement in
                bind(statement, index: 1, text: trackID.uuidString)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw DatabaseError.writeFailed
                }
            }

            try withStatement(
                """
                UPDATE tracks
                SET analyzed_at = NULL, track_embedding_json = NULL, analysis_summary_json = NULL,
                    waveform_cache_json = NULL, waveform_cache_updated_at = NULL,
                    embedding_profile_id = NULL, embedding_pipeline_id = NULL, embedding_updated_at = NULL
                WHERE id = ?;
                """
            ) { statement in
                bind(statement, index: 1, text: trackID.uuidString)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw DatabaseError.writeFailed
                }
            }
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
                last_played, playlist_memberships_json, cue_count, cue_points_json, comment, vendor_track_id, analysis_state,
                analysis_cache_path, sync_version
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            try withStatement(insertSQL) { statement in
            for entry in entries {
                    let cueCount = resolvedCueCount(stored: entry.cueCount, cuePoints: entry.cuePoints)
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
                    bind(statement, index: 13, int: cueCount)
                    bind(statement, index: 14, text: jsonString(entry.cuePoints))
                    bind(statement, index: 15, text: entry.comment)
                    bind(statement, index: 16, text: entry.vendorTrackID)
                    bind(statement, index: 17, text: entry.analysisState)
                    bind(statement, index: 18, text: entry.analysisCachePath)
                    bind(statement, index: 19, text: entry.syncVersion)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw DatabaseError.writeFailed
                    }
                }
            }

            let membershipPaths = Array(
                Set(
                    entries
                        .flatMap(\.playlistMemberships)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                )
            ).sorted()
            try replaceTrackMemberships(trackID: trackID, source: source, membershipPaths: membershipPaths)
            try rebuildMembershipCatalog()
        }
    }

    func fetchExternalMetadata(trackID: UUID) throws -> [ExternalDJMetadata] {
        let sql = """
        SELECT id, source, track_path, bpm, musical_key, rating, color, tags_json, play_count,
               last_played, playlist_memberships_json, cue_count, cue_points_json, comment, vendor_track_id, analysis_state,
               analysis_cache_path, sync_version
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
                let cuePoints = decodeCuePoints(sqliteString(statement, index: 12) ?? "[]")
                let legacyCueCount = sqliteOptionalInt(statement, index: 11)
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
                        cueCount: resolvedCueCount(stored: legacyCueCount, cuePoints: cuePoints),
                        cuePoints: cuePoints,
                        comment: sqliteString(statement, index: 13),
                        vendorTrackID: sqliteString(statement, index: 14),
                        analysisState: sqliteString(statement, index: 15),
                        analysisCachePath: sqliteString(statement, index: 16),
                        syncVersion: sqliteString(statement, index: 17)
                    )
                )
            }
            return results
        }
    }

    func fetchMembershipFacets(source: ExternalDJMetadata.Source) throws -> [MembershipFacet] {
        let sql = """
        SELECT source, membership_path, display_name, parent_path, depth, track_count
        FROM membership_catalog
        WHERE source = ?
        ORDER BY membership_path COLLATE NOCASE;
        """
        return try withStatement(sql) { statement in
            bind(statement, index: 1, text: source.rawValue)
            var results: [MembershipFacet] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard
                    let sourceText = sqliteString(statement, index: 0),
                    let facetSource = ExternalDJMetadata.Source(rawValue: sourceText),
                    let membershipPath = sqliteString(statement, index: 1),
                    let displayName = sqliteString(statement, index: 2)
                else {
                    continue
                }
                results.append(
                    MembershipFacet(
                        source: facetSource,
                        membershipPath: membershipPath,
                        displayName: displayName,
                        parentPath: sqliteString(statement, index: 3),
                        depth: Int(sqlite3_column_int64(statement, 4)),
                        trackCount: Int(sqlite3_column_int64(statement, 5))
                    )
                )
            }
            return results
        }
    }

    func fetchTrackMembershipSnapshots(trackIDs: [UUID]) throws -> [UUID: TrackMembershipSnapshot] {
        guard !trackIDs.isEmpty else { return [:] }

        let placeholders = Array(repeating: "?", count: trackIDs.count).joined(separator: ", ")
        let sql = """
        SELECT track_id, source, membership_path
        FROM track_memberships
        WHERE track_id IN (\(placeholders))
        ORDER BY membership_path COLLATE NOCASE;
        """

        return try withStatement(sql) { statement in
            for (offset, trackID) in trackIDs.enumerated() {
                bind(statement, index: Int32(offset + 1), text: trackID.uuidString)
            }

            var results: [UUID: TrackMembershipSnapshot] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard
                    let trackIDText = sqliteString(statement, index: 0),
                    let trackID = UUID(uuidString: trackIDText),
                    let sourceText = sqliteString(statement, index: 1),
                    let source = ExternalDJMetadata.Source(rawValue: sourceText),
                    let membershipPath = sqliteString(statement, index: 2)
                else {
                    continue
                }

                var snapshot = results[trackID] ?? TrackMembershipSnapshot()
                switch source {
                case .serato:
                    snapshot.seratoMembershipPaths.append(membershipPath)
                case .rekordbox:
                    snapshot.rekordboxMembershipPaths.append(membershipPath)
                }
                results[trackID] = snapshot
            }

            return results.mapValues { snapshot in
                TrackMembershipSnapshot(
                    seratoMembershipPaths: Array(Set(snapshot.seratoMembershipPaths)).sorted(),
                    rekordboxMembershipPaths: Array(Set(snapshot.rekordboxMembershipPaths)).sorted()
                )
            }
        }
    }

    func fetchTrackIDs(matching scopeFilter: LibraryScopeFilter) throws -> Set<UUID> {
        if scopeFilter.isEmpty {
            let sql = "SELECT id FROM tracks;"
            return try withStatement(sql) { statement in
                var output: Set<UUID> = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let idText = sqliteString(statement, index: 0), let id = UUID(uuidString: idText) else {
                        continue
                    }
                    output.insert(id)
                }
                return output
            }
        }

        let predicate = membershipScopePredicate(for: scopeFilter)
        let sql = """
        SELECT DISTINCT track_id
        FROM track_memberships
        WHERE \(predicate.sql);
        """

        return try withStatement(sql) { statement in
            bindAll(statement, values: predicate.values)
            var output: Set<UUID> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idText = sqliteString(statement, index: 0), let id = UUID(uuidString: idText) else {
                    continue
                }
                output.insert(id)
            }
            return output
        }
    }

    func fetchTracks(matching scopeFilter: LibraryScopeFilter) throws -> [Track] {
        if scopeFilter.isEmpty {
            return try fetchAllTracks()
        }

        let trackIDs = try fetchTrackIDs(matching: scopeFilter)
        guard !trackIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: trackIDs.count).joined(separator: ", ")
        let sql = """
        SELECT \(trackSelectColumns)
        FROM tracks
        WHERE id IN (\(placeholders))
        ORDER BY artist COLLATE NOCASE, title COLLATE NOCASE;
        """

        return try withStatement(sql) { statement in
            bindAll(statement, values: trackIDs.map(\.uuidString))
            var tracks: [Track] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let track = track(from: statement) {
                    tracks.append(track)
                }
            }
            return tracks
        }
    }

    func fetchScopedReadyTrackIDs(
        matching scopeFilter: LibraryScopeFilter,
        profileID: String,
        pipelineID: String
    ) throws -> Set<UUID> {
        if scopeFilter.isEmpty {
            return try fetchReadyTrackIDs(profileID: profileID, pipelineID: pipelineID, requireLocalScan: true)
        }

        let predicate = membershipScopePredicate(for: scopeFilter)
        let sql = """
        SELECT DISTINCT tracks.id
        FROM tracks
        INNER JOIN track_memberships ON track_memberships.track_id = tracks.id
        WHERE tracks.embedding_profile_id = ?
          AND tracks.embedding_pipeline_id = ?
          AND tracks.embedding_updated_at IS NOT NULL
          AND tracks.track_embedding_json IS NOT NULL
          AND tracks.track_embedding_json <> ''
          AND tracks.track_embedding_json <> '[]'
          AND EXISTS (
            SELECT 1
            FROM segments
            WHERE segments.track_id = tracks.id
              AND segments.embedding_json IS NOT NULL
              AND segments.embedding_json <> ''
              AND segments.embedding_json <> '[]'
          )
          AND tracks.last_seen_in_local_scan_at IS NOT NULL
          AND (\(predicate.sql));
        """

        return try withStatement(sql) { statement in
            bind(statement, index: 1, text: profileID)
            bind(statement, index: 2, text: pipelineID)
            bindAll(statement, values: predicate.values, startingAt: 3)
            var output: Set<UUID> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idText = sqliteString(statement, index: 0), let id = UUID(uuidString: idText) else {
                    continue
                }
                output.insert(id)
            }
            return output
        }
    }

    func clearLocalScanMarks(underRoots roots: [String], excludingPaths preservedPaths: [String]) throws {
        let normalizedRoots = Array(
            Set(
                roots
                    .map(TrackPathNormalizer.normalizedAbsolutePath)
                    .filter { !$0.isEmpty }
            )
        ).sorted()
        guard !normalizedRoots.isEmpty else { return }

        let rootClauses = normalizedRoots.map { _ in "file_path = ? OR file_path LIKE ?" }.joined(separator: " OR ")
        let exclusionClause = preservedPaths.isEmpty
            ? ""
            : "AND file_path NOT IN (\(Array(repeating: "?", count: preservedPaths.count).joined(separator: ", ")))"
        let sql = """
        UPDATE tracks
        SET last_seen_in_local_scan_at = NULL
        WHERE last_seen_in_local_scan_at IS NOT NULL
          AND (\(rootClauses))
          \(exclusionClause);
        """

        try withStatement(sql) { statement in
            var bindIndex: Int32 = 1
            for root in normalizedRoots {
                bind(statement, index: bindIndex, text: root)
                bindIndex += 1
                bind(statement, index: bindIndex, text: "\(root)/%")
                bindIndex += 1
            }
            for path in preservedPaths {
                bind(statement, index: bindIndex, text: path)
                bindIndex += 1
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.writeFailed
            }
        }
    }

    func insertScoreSession(
        session: ScoreSession,
        candidates: [ScoreSessionCandidateRecord],
        retentionLimit: Int = 30
    ) throws -> UUID {
        try withTransaction {
            let insertSessionSQL = """
            INSERT INTO score_sessions (
                id, kind, embedding_profile_id, search_mode, query_text, seed_track_id,
                reference_track_ids_json, scope_filter_json, candidate_count_before_scope,
                candidate_count_after_scope, result_limit, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            try withStatement(insertSessionSQL) { statement in
                bind(statement, index: 1, text: session.id.uuidString)
                bind(statement, index: 2, text: session.kind.rawValue)
                bind(statement, index: 3, text: session.embeddingProfileID)
                bind(statement, index: 4, text: session.searchMode)
                bind(statement, index: 5, text: session.queryText)
                bind(statement, index: 6, text: session.seedTrackID?.uuidString)
                bind(statement, index: 7, text: jsonString(session.referenceTrackIDs.map(\.uuidString)))
                bind(statement, index: 8, text: jsonString(session.scopeFilter))
                bind(statement, index: 9, int: session.candidateCountBeforeScope)
                bind(statement, index: 10, int: session.candidateCountAfterScope)
                bind(statement, index: 11, int: session.resultLimit)
                bind(statement, index: 12, text: Self.iso8601.string(from: session.createdAt))
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw DatabaseError.writeFailed
                }
            }

            let insertCandidateSQL = """
            INSERT INTO score_session_candidates (
                session_id, track_id, rank, final_score, vector_fused_score, track_score,
                intro_score, middle_score, outro_score, embedding_similarity,
                bpm_compatibility, harmonic_compatibility, energy_flow,
                transition_region_match, external_metadata_score, best_matched_collection,
                matched_memberships_json, match_reasons_json, score_snapshot_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            try withStatement(insertCandidateSQL) { statement in
                for candidate in candidates {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    bind(statement, index: 1, text: session.id.uuidString)
                    bind(statement, index: 2, text: candidate.trackID.uuidString)
                    bind(statement, index: 3, int: candidate.rank)
                    sqlite3_bind_double(statement, 4, candidate.finalScore)
                    sqlite3_bind_double(statement, 5, candidate.vectorBreakdown.fusedScore)
                    sqlite3_bind_double(statement, 6, candidate.vectorBreakdown.trackScore)
                    sqlite3_bind_double(statement, 7, candidate.vectorBreakdown.introScore)
                    sqlite3_bind_double(statement, 8, candidate.vectorBreakdown.middleScore)
                    sqlite3_bind_double(statement, 9, candidate.vectorBreakdown.outroScore)
                    bind(statement, index: 10, double: candidate.embeddingSimilarity)
                    bind(statement, index: 11, double: candidate.bpmCompatibility)
                    bind(statement, index: 12, double: candidate.harmonicCompatibility)
                    bind(statement, index: 13, double: candidate.energyFlow)
                    bind(statement, index: 14, double: candidate.transitionRegionMatch)
                    bind(statement, index: 15, double: candidate.externalMetadataScore)
                    bind(statement, index: 16, text: candidate.vectorBreakdown.bestMatchedCollection)
                    bind(statement, index: 17, text: jsonString(candidate.matchedMemberships))
                    bind(statement, index: 18, text: jsonString(candidate.matchReasons))
                    bind(statement, index: 19, text: jsonString(candidate.snapshot))
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw DatabaseError.writeFailed
                    }
                }
            }

            try pruneScoreSessions(kind: session.kind, embeddingProfileID: session.embeddingProfileID, retentionLimit: retentionLimit)
        }
        return session.id
    }

    func fetchLibrarySources() throws -> [LibrarySourceRecord] {
        let sql = """
        SELECT id, kind, enabled, resolved_path, last_sync_at, status, last_error
        FROM library_sources
        ORDER BY CASE kind
            WHEN 'serato' THEN 0
            WHEN 'rekordbox' THEN 1
            WHEN 'folderFallback' THEN 2
            ELSE 99
        END;
        """
        var sources = try withStatement(sql) { statement in
            var results: [LibrarySourceRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard
                    let idText = sqliteString(statement, index: 0),
                    let id = UUID(uuidString: idText),
                    let kindText = sqliteString(statement, index: 1),
                    let kind = LibrarySourceKind(rawValue: kindText),
                    let statusText = sqliteString(statement, index: 5),
                    let status = LibrarySourceStatus(rawValue: statusText)
                else {
                    continue
                }
                results.append(
                    LibrarySourceRecord(
                        id: id,
                        kind: kind,
                        enabled: sqlite3_column_int(statement, 2) == 1,
                        resolvedPath: sqliteString(statement, index: 3),
                        lastSyncAt: sqliteString(statement, index: 4).flatMap { Self.iso8601.date(from: $0) },
                        status: status,
                        lastError: sqliteString(statement, index: 6)
                    )
                )
            }
            return results
        }

        var byKind = Dictionary(uniqueKeysWithValues: sources.map { ($0.kind, $0) })
        for kind in LibrarySourceKind.allCases where byKind[kind] == nil {
            let record = LibrarySourceRecord.default(for: kind)
            try upsertLibrarySource(record)
            byKind[kind] = record
        }

        sources = LibrarySourceKind.allCases.compactMap { byKind[$0] }
        return sources
    }

    func upsertLibrarySource(_ source: LibrarySourceRecord) throws {
        let sql = """
        INSERT INTO library_sources (
            id, kind, enabled, resolved_path, last_sync_at, status, last_error
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(kind) DO UPDATE SET
            enabled = excluded.enabled,
            resolved_path = excluded.resolved_path,
            last_sync_at = excluded.last_sync_at,
            status = excluded.status,
            last_error = excluded.last_error;
        """
        try withStatement(sql) { statement in
            bind(statement, index: 1, text: source.id.uuidString)
            bind(statement, index: 2, text: source.kind.rawValue)
            sqlite3_bind_int(statement, 3, source.enabled ? 1 : 0)
            bind(statement, index: 4, text: source.resolvedPath)
            bind(statement, index: 5, text: source.lastSyncAt.map { Self.iso8601.string(from: $0) })
            bind(statement, index: 6, text: source.status.rawValue)
            bind(statement, index: 7, text: source.lastError)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.writeFailed
            }
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
            analysis_summary_json TEXT,
            waveform_cache_json TEXT,
            waveform_cache_updated_at TEXT,
            embedding_profile_id TEXT,
            embedding_pipeline_id TEXT,
            embedding_updated_at TEXT,
            bpm_source TEXT,
            key_source TEXT,
            last_seen_in_local_scan_at TEXT
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
            cue_points_json TEXT NOT NULL DEFAULT '[]',
            comment TEXT,
            vendor_track_id TEXT,
            analysis_state TEXT,
            analysis_cache_path TEXT,
            sync_version TEXT,
            FOREIGN KEY(track_id) REFERENCES tracks(id)
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS library_sources (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL UNIQUE,
            enabled INTEGER NOT NULL DEFAULT 0,
            resolved_path TEXT,
            last_sync_at TEXT,
            status TEXT NOT NULL DEFAULT 'disabled',
            last_error TEXT
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS membership_catalog (
            source TEXT NOT NULL,
            membership_path TEXT NOT NULL,
            display_name TEXT NOT NULL,
            parent_path TEXT,
            depth INTEGER NOT NULL DEFAULT 0,
            track_count INTEGER NOT NULL DEFAULT 0,
            updated_at TEXT NOT NULL,
            PRIMARY KEY (source, membership_path)
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS track_memberships (
            track_id TEXT NOT NULL,
            source TEXT NOT NULL,
            membership_path TEXT NOT NULL,
            PRIMARY KEY (track_id, source, membership_path),
            FOREIGN KEY(track_id) REFERENCES tracks(id)
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS score_sessions (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            embedding_profile_id TEXT NOT NULL,
            search_mode TEXT,
            query_text TEXT,
            seed_track_id TEXT,
            reference_track_ids_json TEXT NOT NULL DEFAULT '[]',
            scope_filter_json TEXT NOT NULL DEFAULT '{}',
            candidate_count_before_scope INTEGER NOT NULL DEFAULT 0,
            candidate_count_after_scope INTEGER NOT NULL DEFAULT 0,
            result_limit INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS score_session_candidates (
            session_id TEXT NOT NULL,
            track_id TEXT NOT NULL,
            rank INTEGER NOT NULL,
            final_score REAL NOT NULL,
            vector_fused_score REAL NOT NULL DEFAULT 0,
            track_score REAL NOT NULL DEFAULT 0,
            intro_score REAL NOT NULL DEFAULT 0,
            middle_score REAL NOT NULL DEFAULT 0,
            outro_score REAL NOT NULL DEFAULT 0,
            embedding_similarity REAL,
            bpm_compatibility REAL,
            harmonic_compatibility REAL,
            energy_flow REAL,
            transition_region_match REAL,
            external_metadata_score REAL,
            best_matched_collection TEXT NOT NULL,
            matched_memberships_json TEXT NOT NULL DEFAULT '[]',
            match_reasons_json TEXT NOT NULL DEFAULT '[]',
            score_snapshot_json TEXT NOT NULL DEFAULT '{}',
            PRIMARY KEY (session_id, track_id, rank),
            FOREIGN KEY(session_id) REFERENCES score_sessions(id)
        );
        """)

        if try !columnExists(table: "tracks", column: "track_embedding_json") {
            try exec("ALTER TABLE tracks ADD COLUMN track_embedding_json TEXT;")
        }
        if try !columnExists(table: "tracks", column: "analysis_summary_json") {
            try exec("ALTER TABLE tracks ADD COLUMN analysis_summary_json TEXT;")
        }
        if try !columnExists(table: "tracks", column: "waveform_cache_json") {
            try exec("ALTER TABLE tracks ADD COLUMN waveform_cache_json TEXT;")
        }
        if try !columnExists(table: "tracks", column: "waveform_cache_updated_at") {
            try exec("ALTER TABLE tracks ADD COLUMN waveform_cache_updated_at TEXT;")
        }
        if try !columnExists(table: "tracks", column: "embedding_profile_id") {
            try exec("ALTER TABLE tracks ADD COLUMN embedding_profile_id TEXT;")
        }
        if try !columnExists(table: "tracks", column: "embedding_pipeline_id") {
            try exec("ALTER TABLE tracks ADD COLUMN embedding_pipeline_id TEXT;")
        }
        if try !columnExists(table: "tracks", column: "embedding_updated_at") {
            try exec("ALTER TABLE tracks ADD COLUMN embedding_updated_at TEXT;")
        }
        if try !columnExists(table: "tracks", column: "bpm_source") {
            try exec("ALTER TABLE tracks ADD COLUMN bpm_source TEXT;")
        }
        if try !columnExists(table: "tracks", column: "key_source") {
            try exec("ALTER TABLE tracks ADD COLUMN key_source TEXT;")
        }
        if try !columnExists(table: "tracks", column: "last_seen_in_local_scan_at") {
            try exec("ALTER TABLE tracks ADD COLUMN last_seen_in_local_scan_at TEXT;")
        }
        if try !columnExists(table: "external_metadata", column: "vendor_track_id") {
            try exec("ALTER TABLE external_metadata ADD COLUMN vendor_track_id TEXT;")
        }
        if try !columnExists(table: "external_metadata", column: "analysis_state") {
            try exec("ALTER TABLE external_metadata ADD COLUMN analysis_state TEXT;")
        }
        if try !columnExists(table: "external_metadata", column: "analysis_cache_path") {
            try exec("ALTER TABLE external_metadata ADD COLUMN analysis_cache_path TEXT;")
        }
        if try !columnExists(table: "external_metadata", column: "sync_version") {
            try exec("ALTER TABLE external_metadata ADD COLUMN sync_version TEXT;")
        }
        if try !columnExists(table: "external_metadata", column: "cue_points_json") {
            try exec("ALTER TABLE external_metadata ADD COLUMN cue_points_json TEXT NOT NULL DEFAULT '[]';")
        }

        try exec("CREATE INDEX IF NOT EXISTS idx_tracks_hash ON tracks(content_hash);")
        try exec("CREATE INDEX IF NOT EXISTS idx_segments_track ON segments(track_id);")
        try exec("CREATE INDEX IF NOT EXISTS idx_external_metadata_track ON external_metadata(track_id);")
        try exec("CREATE INDEX IF NOT EXISTS idx_tracks_path ON tracks(file_path);")
        try exec("CREATE INDEX IF NOT EXISTS idx_tracks_local_scan ON tracks(last_seen_in_local_scan_at);")
        try exec("CREATE INDEX IF NOT EXISTS idx_library_sources_kind ON library_sources(kind);")
        try exec("CREATE INDEX IF NOT EXISTS idx_track_memberships_source_path ON track_memberships(source, membership_path);")
        try exec("CREATE INDEX IF NOT EXISTS idx_track_memberships_track ON track_memberships(track_id);")
        try exec("CREATE INDEX IF NOT EXISTS idx_score_sessions_kind_profile_created ON score_sessions(kind, embedding_profile_id, created_at DESC);")
        try exec("CREATE INDEX IF NOT EXISTS idx_score_session_candidates_session ON score_session_candidates(session_id);")
        try migrateLegacyEmbeddingProfileState()
        try invalidateIncompleteEmbeddingState()
        try rebuildNormalizedMembershipTables()
    }

    private func track(from statement: OpaquePointer?) -> Track? {
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
            return nil
        }

        let modifiedTime = Self.iso8601.date(from: modifiedTimeText) ?? .distantPast
        let analyzedAt = sqliteString(statement, index: 13).flatMap { Self.iso8601.date(from: $0) }
        let embeddingUpdatedAt = sqliteString(statement, index: 16).flatMap { Self.iso8601.date(from: $0) }
        let lastSeenInLocalScanAt = sqliteString(statement, index: 21).flatMap { Self.iso8601.date(from: $0) }
        return Track(
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
            embeddingProfileID: sqliteString(statement, index: 14),
            embeddingPipelineID: sqliteString(statement, index: 15),
            embeddingUpdatedAt: embeddingUpdatedAt,
            hasSeratoMetadata: sqlite3_column_int(statement, 17) == 1,
            hasRekordboxMetadata: sqlite3_column_int(statement, 18) == 1,
            bpmSource: sqliteString(statement, index: 19).flatMap(TrackMetadataSource.init(rawValue:)),
            keySource: sqliteString(statement, index: 20).flatMap(TrackMetadataSource.init(rawValue:)),
            lastSeenInLocalScanAt: lastSeenInLocalScanAt
        )
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed
        }
    }

    private func configureConnection() throws {
        sqlite3_busy_timeout(db, 5_000)
        try exec("PRAGMA foreign_keys = ON;")
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA synchronous = NORMAL;")
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

    private func optionalDoubles(from text: String?) -> [Double]? {
        guard let text, !text.isEmpty else { return nil }
        let decoded = doubles(from: text)
        return decoded.isEmpty ? nil : decoded
    }

    private func nonEmptyJSONArrayText(_ values: [Double]?) -> String? {
        guard let values, !values.isEmpty else { return nil }
        return jsonString(values)
    }

    private func stringArray(from text: String) -> [String] {
        (try? decode([String].self, from: text)) ?? []
    }

    private func decodeCuePoints(_ text: String) -> [ExternalDJCuePoint] {
        (try? decode([ExternalDJCuePoint].self, from: text)) ?? []
    }

    private func resolvedCueCount(stored: Int?, cuePoints: [ExternalDJCuePoint]) -> Int? {
        let storedValue = stored.flatMap { $0 > 0 ? $0 : nil }
        if let storedValue {
            return cuePoints.isEmpty ? storedValue : max(storedValue, cuePoints.count)
        }
        return cuePoints.isEmpty ? nil : cuePoints.count
    }

    private func migrateLegacyEmbeddingProfileState() throws {
        try withTransaction {
            try exec("""
            UPDATE segments
            SET embedding_json = NULL
            WHERE track_id IN (
                SELECT id
                FROM tracks
                WHERE embedding_profile_id IN (
                    '\(EmbeddingProfile.legacyGoogleTextEmbedding004ID)',
                    '\(EmbeddingProfile.legacyGeminiEmbedding001ID)'
                )
            );
            """)
            try exec("""
            UPDATE tracks
            SET track_embedding_json = NULL,
                embedding_profile_id = NULL,
                embedding_pipeline_id = NULL,
                embedding_updated_at = NULL
            WHERE embedding_profile_id IN (
                '\(EmbeddingProfile.legacyGoogleTextEmbedding004ID)',
                '\(EmbeddingProfile.legacyGeminiEmbedding001ID)'
            );
            """)
        }
    }

    private func invalidateIncompleteEmbeddingState() throws {
        try exec("""
        UPDATE tracks
        SET embedding_profile_id = NULL,
            embedding_pipeline_id = NULL,
            embedding_updated_at = NULL
        WHERE embedding_profile_id IS NOT NULL
          AND (
            embedding_pipeline_id IS NULL OR
            track_embedding_json IS NULL OR
            track_embedding_json = '' OR
            track_embedding_json = '[]' OR
            NOT EXISTS (
                SELECT 1
                FROM segments
                WHERE segments.track_id = tracks.id
                  AND embedding_json IS NOT NULL
                  AND embedding_json <> ''
                  AND embedding_json <> '[]'
            )
          );
        """)
    }

    private func replaceTrackMemberships(
        trackID: UUID,
        source: ExternalDJMetadata.Source,
        membershipPaths: [String]
    ) throws {
        try withStatement("DELETE FROM track_memberships WHERE track_id = ? AND source = ?;") { statement in
            bind(statement, index: 1, text: trackID.uuidString)
            bind(statement, index: 2, text: source.rawValue)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.writeFailed
            }
        }

        guard !membershipPaths.isEmpty else { return }

        let insertSQL = """
        INSERT INTO track_memberships (track_id, source, membership_path)
        VALUES (?, ?, ?);
        """
        try withStatement(insertSQL) { statement in
            for membershipPath in membershipPaths {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(statement, index: 1, text: trackID.uuidString)
                bind(statement, index: 2, text: source.rawValue)
                bind(statement, index: 3, text: membershipPath)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw DatabaseError.writeFailed
                }
            }
        }
    }

    private func rebuildNormalizedMembershipTables() throws {
        try withTransaction {
            try exec("DELETE FROM track_memberships;")
            try exec("DELETE FROM membership_catalog;")

            let sql = """
            SELECT track_id, source, playlist_memberships_json
            FROM external_metadata
            ORDER BY track_id, source;
            """

            let rows: [(UUID, ExternalDJMetadata.Source, [String])] = try withStatement(sql) { statement in
                var output: [(UUID, ExternalDJMetadata.Source, [String])] = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard
                        let trackIDText = sqliteString(statement, index: 0),
                        let trackID = UUID(uuidString: trackIDText),
                        let sourceText = sqliteString(statement, index: 1),
                        let source = ExternalDJMetadata.Source(rawValue: sourceText)
                    else {
                        continue
                    }
                    let memberships = Array(
                        Set(
                            stringArray(from: sqliteString(statement, index: 2) ?? "[]")
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                        )
                    ).sorted()
                    output.append((trackID, source, memberships))
                }
                return output
            }

            for row in rows {
                try replaceTrackMemberships(trackID: row.0, source: row.1, membershipPaths: row.2)
            }
            try rebuildMembershipCatalog()
        }
    }

    private func rebuildMembershipCatalog() throws {
        try exec("DELETE FROM membership_catalog;")

        let nowText = Self.iso8601.string(from: Date())
        let sql = """
        SELECT source, membership_path, COUNT(DISTINCT track_id)
        FROM track_memberships
        GROUP BY source, membership_path
        ORDER BY source, membership_path;
        """

        let rows: [(ExternalDJMetadata.Source, String, Int)] = try withStatement(sql) { statement in
            var output: [(ExternalDJMetadata.Source, String, Int)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard
                    let sourceText = sqliteString(statement, index: 0),
                    let source = ExternalDJMetadata.Source(rawValue: sourceText),
                    let membershipPath = sqliteString(statement, index: 1)
                else {
                    continue
                }
                output.append((source, membershipPath, Int(sqlite3_column_int64(statement, 2))))
            }
            return output
        }

        guard !rows.isEmpty else { return }

        let insertSQL = """
        INSERT INTO membership_catalog (
            source, membership_path, display_name, parent_path, depth, track_count, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        try withStatement(insertSQL) { statement in
            for row in rows {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(statement, index: 1, text: row.0.rawValue)
                bind(statement, index: 2, text: row.1)
                bind(statement, index: 3, text: membershipDisplayName(for: row.1))
                bind(statement, index: 4, text: membershipParentPath(for: row.1))
                bind(statement, index: 5, int: membershipDepth(for: row.1))
                bind(statement, index: 6, int: row.2)
                bind(statement, index: 7, text: nowText)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw DatabaseError.writeFailed
                }
            }
        }
    }

    private func pruneScoreSessions(
        kind: ScoreSessionKind,
        embeddingProfileID: String,
        retentionLimit: Int
    ) throws {
        guard retentionLimit > 0 else { return }

        let sql = """
        SELECT id
        FROM score_sessions
        WHERE kind = ?
          AND embedding_profile_id = ?
        ORDER BY created_at DESC
        LIMIT -1 OFFSET ?;
        """
        let doomedSessionIDs = try withStatement(sql) { statement in
            bind(statement, index: 1, text: kind.rawValue)
            bind(statement, index: 2, text: embeddingProfileID)
            bind(statement, index: 3, int: retentionLimit)
            var output: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let sessionID = sqliteString(statement, index: 0) {
                    output.append(sessionID)
                }
            }
            return output
        }

        guard !doomedSessionIDs.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: doomedSessionIDs.count).joined(separator: ", ")

        try withStatement("DELETE FROM score_session_candidates WHERE session_id IN (\(placeholders));") { statement in
            bindAll(statement, values: doomedSessionIDs)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.writeFailed
            }
        }
        try withStatement("DELETE FROM score_sessions WHERE id IN (\(placeholders));") { statement in
            bindAll(statement, values: doomedSessionIDs)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw DatabaseError.writeFailed
            }
        }
    }

    private func membershipDisplayName(for path: String) -> String {
        let parts = path
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.last ?? path
    }

    private func membershipParentPath(for path: String) -> String? {
        let parts = path
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: " / ")
    }

    private func membershipDepth(for path: String) -> Int {
        let parts = path
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return max(parts.count - 1, 0)
    }

    private func membershipScopePredicate(for scopeFilter: LibraryScopeFilter) -> (sql: String, values: [String]) {
        var clauses: [String] = []
        var values: [String] = []

        func appendClause(source: ExternalDJMetadata.Source, paths: [String]) {
            guard !paths.isEmpty else { return }
            let placeholders = Array(repeating: "?", count: paths.count).joined(separator: ", ")
            clauses.append("(source = ? AND membership_path IN (\(placeholders)))")
            values.append(source.rawValue)
            values.append(contentsOf: paths)
        }

        appendClause(source: .serato, paths: scopeFilter.seratoMembershipPaths)
        appendClause(source: .rekordbox, paths: scopeFilter.rekordboxMembershipPaths)

        if clauses.isEmpty {
            return ("1 = 1", [])
        }
        return (clauses.joined(separator: " OR "), values)
    }

    private func bindAll(_ statement: OpaquePointer?, values: [String], startingAt startIndex: Int32 = 1) {
        for (offset, value) in values.enumerated() {
            bind(statement, index: startIndex + Int32(offset), text: value)
        }
    }

    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func hasNonEmptyJSONPayload(_ text: String?) -> Bool {
        guard let text else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "[]" && trimmed != "{}" && trimmed != "null"
    }

    private let trackSelectColumns = """
    id, file_path, file_name, title, artist, album, genre, duration, sample_rate, bpm, musical_key,
    modified_time, content_hash, analyzed_at, embedding_profile_id, embedding_pipeline_id, embedding_updated_at,
    has_serato, has_rekordbox, bpm_source, key_source, last_seen_in_local_scan_at
    """
}

enum DatabaseError: Error {
    case openFailed
    case queryFailed
    case writeFailed
    case decodeFailed
}

extension DatabaseError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .openFailed:
            return "Failed to open the library database."
        case .queryFailed:
            return "A library database query failed."
        case .writeFailed:
            return "A library database write failed."
        case .decodeFailed:
            return "Stored library data could not be decoded."
        }
    }
}

struct PersistedEmbeddingStateSnapshot: Equatable {
    let trackID: UUID
    let analyzedAt: Date?
    let hasTrackEmbedding: Bool
    let hasAnalysisSummary: Bool
    let embeddingProfileID: String?
    let embeddingPipelineID: String?
    let embeddingUpdatedAt: Date?
    var segmentCount: Int
    var embeddedSegmentCount: Int
}
