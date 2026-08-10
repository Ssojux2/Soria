import Foundation
import Testing

@testable import Soria

/// The batch loaders the similarity map is built on.
///
/// `fetchMapFeatureRows` reads its numbers with SQLite JSON1 path expressions rather
/// than decoding `TrackAnalysisSummary`, which is a large speed win but moves the
/// field names into SQL strings the compiler cannot check. A typo there would leave
/// every axis silently empty, so these run against a real database file.
@Suite(.serialized)
struct TrackMapDatabaseTests {
    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soria-track-map-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func insertAnalyzedTrack(
        into database: LibraryDatabase,
        directory: URL,
        name: String,
        embedding: [Double],
        brightness: Double,
        onsetDensity: Double,
        estimatedBPM: Double?,
        energyArc: [Double]
    ) throws -> Track {
        let track = Track.empty(
            path: TrackPathNormalizer.normalizedAbsolutePath(directory.appendingPathComponent(name).path),
            modifiedTime: Date(),
            hash: UUID().uuidString
        )
        try database.upsertTrack(track)

        let segment = TrackSegment(
            id: UUID(),
            trackID: track.id,
            type: .middle,
            startSec: 0,
            endSec: 30,
            energyScore: 0.5,
            descriptorText: "test",
            vector: embedding
        )
        let summary = TrackAnalysisSummary(
            trackID: track.id,
            segments: [segment],
            trackEmbedding: embedding,
            estimatedBPM: estimatedBPM,
            estimatedKey: "Am",
            brightness: brightness,
            onsetDensity: onsetDensity,
            rhythmicDensity: 1.0,
            lowMidHighBalance: [0.3, 0.4, 0.3],
            waveformPreview: [0.1, 0.2],
            energyArc: energyArc
        )
        try database.replaceSegments(trackID: track.id, segments: [segment], analysisSummary: summary)
        return try #require(try database.fetchTrack(id: track.id))
    }

    // MARK: - Embeddings

    @Test
    func batchEmbeddingLoadReturnsEveryStoredVector() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))

        let first = try insertAnalyzedTrack(
            into: database, directory: directory, name: "a.mp3",
            embedding: [1, 0, 0], brightness: 0.4, onsetDensity: 2, estimatedBPM: 120, energyArc: [0.2, 0.4]
        )
        let second = try insertAnalyzedTrack(
            into: database, directory: directory, name: "b.mp3",
            embedding: [0, 1, 0], brightness: 0.6, onsetDensity: 3, estimatedBPM: 128, energyArc: [0.8]
        )

        let all = try database.fetchTrackEmbeddings()
        #expect(all.count == 2)
        #expect(all[first.id] == [1, 0, 0])
        #expect(all[second.id] == [0, 1, 0])

        // The batch loader must agree with the single-track one it replaces.
        #expect(try database.fetchTrackEmbedding(trackID: first.id) == all[first.id])
    }

    @Test
    func batchEmbeddingLoadHonoursAnIDFilter() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))

        let wanted = try insertAnalyzedTrack(
            into: database, directory: directory, name: "a.mp3",
            embedding: [1, 0], brightness: 0.4, onsetDensity: 2, estimatedBPM: 120, energyArc: [0.5]
        )
        _ = try insertAnalyzedTrack(
            into: database, directory: directory, name: "b.mp3",
            embedding: [0, 1], brightness: 0.6, onsetDensity: 3, estimatedBPM: 128, energyArc: [0.5]
        )

        let filtered = try database.fetchTrackEmbeddings(trackIDs: [wanted.id])
        #expect(filtered.count == 1)
        #expect(filtered[wanted.id] == [1, 0])

        #expect(try database.fetchTrackEmbeddings(trackIDs: []).isEmpty)
    }

    @Test
    func tracksWithoutEmbeddingsAreOmitted() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))

        let bare = Track.empty(
            path: TrackPathNormalizer.normalizedAbsolutePath(directory.appendingPathComponent("bare.mp3").path),
            modifiedTime: Date(),
            hash: UUID().uuidString
        )
        try database.upsertTrack(bare)

        #expect(try database.fetchTrackEmbeddings().isEmpty)
    }

    // MARK: - Feature rows

    @Test
    func featureRowsReadScalarsOutOfTheAnalysisSummary() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))

        let track = try insertAnalyzedTrack(
            into: database, directory: directory, name: "a.mp3",
            embedding: [1, 0, 0],
            brightness: 0.375,
            onsetDensity: 4.25,
            estimatedBPM: 126.5,
            energyArc: [0.2, 0.4, 0.9]
        )

        let rows = try database.fetchMapFeatureRows()
        let row = try #require(rows[track.id])

        #expect(row.brightness == 0.375)
        #expect(row.onsetDensity == 4.25)
        #expect(row.bpm == 126.5)
        // energy is the mean of the arc, averaged by SQLite rather than in Swift.
        let energy = try #require(row.energy)
        #expect(abs(energy - 0.5) < 1e-9)
        #expect(row.analyzedAtEpoch != nil)
    }

    @Test
    func featureRowsFallBackToTheTagTempoWhenAnalysisFoundNone() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))

        var track = Track.empty(
            path: TrackPathNormalizer.normalizedAbsolutePath(directory.appendingPathComponent("a.mp3").path),
            modifiedTime: Date(),
            hash: UUID().uuidString
        )
        track.bpm = 98
        try database.upsertTrack(track)

        let segment = TrackSegment(
            id: UUID(), trackID: track.id, type: .middle,
            startSec: 0, endSec: 10, energyScore: 0.5, descriptorText: "t", vector: [1, 0]
        )
        let summary = TrackAnalysisSummary(
            trackID: track.id,
            segments: [segment],
            trackEmbedding: [1, 0],
            estimatedBPM: nil,
            estimatedKey: nil,
            brightness: 0.2,
            onsetDensity: 1.0,
            rhythmicDensity: 1.0,
            lowMidHighBalance: [0.3, 0.4, 0.3],
            waveformPreview: [],
            energyArc: []
        )
        try database.replaceSegments(trackID: track.id, segments: [segment], analysisSummary: summary)

        let row = try #require(try database.fetchMapFeatureRows()[track.id])
        #expect(row.bpm == 98)
        // An empty arc has no mean, and inventing one would plant a fake cluster.
        #expect(row.energy == nil)
    }

    @Test
    func featureRowsHonourAnIDFilter() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))

        let wanted = try insertAnalyzedTrack(
            into: database, directory: directory, name: "a.mp3",
            embedding: [1, 0], brightness: 0.4, onsetDensity: 2, estimatedBPM: 120, energyArc: [0.5]
        )
        _ = try insertAnalyzedTrack(
            into: database, directory: directory, name: "b.mp3",
            embedding: [0, 1], brightness: 0.6, onsetDensity: 3, estimatedBPM: 128, energyArc: [0.5]
        )

        #expect(try database.fetchMapFeatureRows(trackIDs: [wanted.id]).count == 1)
        #expect(try database.fetchMapFeatureRows(trackIDs: []).isEmpty)
    }
}
