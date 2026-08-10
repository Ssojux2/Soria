import Foundation
import Testing
@testable import Soria

/// Persistence for Soria-authored collections, quarantine records, and organization
/// history, plus the optimistic-concurrency guard on track relocation.
///
/// These run against a real SQLite file in a temp directory, matching how the rest
/// of the database tests work.
@Suite(.serialized)
struct LibraryCollectionStoreTests {
    @Test
    func collectionsSurviveMembershipRebuild() throws {
        // The whole reason soria_collections exists: membership_catalog and
        // track_memberships are DELETEd and re-derived from vendor metadata on
        // every launch, so authored collections cannot live there.
        let directory = try makeCollectionTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("library.sqlite")

        let collectionID = UUID()
        let trackID: UUID
        do {
            let database = try LibraryDatabase(databaseURL: databaseURL)
            let track = try insertTrack(into: database, path: directory.appendingPathComponent("a.mp3").path)
            trackID = track.id
            try database.upsertCollection(
                SoriaCollection(id: collectionID, name: "House", folderPath: "/Music/House")
            )
            try database.replaceCollectionTracks(collectionID: collectionID, trackIDs: [track.id])
        }

        // Reopening runs createSchema() again, which calls
        // rebuildNormalizedMembershipTables().
        let reopened = try LibraryDatabase(databaseURL: databaseURL)
        let collections = try reopened.fetchCollections()
        #expect(collections.count == 1)
        #expect(collections.first?.name == "House")
        #expect(try reopened.fetchCollectionTrackIDs(collectionID: collectionID) == [trackID])
    }

    @Test
    func collectionUpsertUpdatesInPlaceAndPreservesCreatedAt() throws {
        let directory = try makeCollectionTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))

        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let collection = SoriaCollection(name: "Techno", createdAt: createdAt, updatedAt: createdAt)
        try database.upsertCollection(collection)

        var renamed = collection
        renamed.name = "Peak Techno"
        renamed.updatedAt = createdAt.addingTimeInterval(60)
        try database.upsertCollection(renamed)

        let stored = try #require(try database.fetchCollections().first)
        #expect(try database.fetchCollections().count == 1)
        #expect(stored.name == "Peak Techno")
        #expect(Int(stored.createdAt.timeIntervalSince1970) == Int(createdAt.timeIntervalSince1970))
        #expect(stored.updatedAt > stored.createdAt)
    }

    @Test
    func replaceCollectionTracksIsOrderedAndReplacesRatherThanAppends() throws {
        let directory = try makeCollectionTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))

        let first = try insertTrack(into: database, path: directory.appendingPathComponent("1.mp3").path)
        let second = try insertTrack(into: database, path: directory.appendingPathComponent("2.mp3").path)
        let third = try insertTrack(into: database, path: directory.appendingPathComponent("3.mp3").path)

        let collection = SoriaCollection(name: "Set")
        try database.upsertCollection(collection)

        try database.replaceCollectionTracks(collectionID: collection.id, trackIDs: [first.id, second.id, third.id])
        #expect(try database.fetchCollectionTrackIDs(collectionID: collection.id) == [first.id, second.id, third.id])

        try database.replaceCollectionTracks(collectionID: collection.id, trackIDs: [third.id, first.id])
        #expect(try database.fetchCollectionTrackIDs(collectionID: collection.id) == [third.id, first.id])
    }

    @Test
    func deletingACollectionReparentsItsChildrenInsteadOfDroppingThem() throws {
        let directory = try makeCollectionTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))

        let root = SoriaCollection(name: "Soria Organized", kind: .group)
        let genre = SoriaCollection(parentID: root.id, name: "House")
        let cluster = SoriaCollection(parentID: genre.id, name: "Cluster 01 - Anna")
        for collection in [root, genre, cluster] {
            try database.upsertCollection(collection)
        }

        try database.deleteCollection(id: genre.id)

        let remaining = try database.fetchCollections()
        #expect(remaining.count == 2)
        #expect(!remaining.contains { $0.id == genre.id })
        #expect(remaining.first { $0.id == cluster.id }?.parentID == root.id)
    }

    @Test
    func hierarchicalNameJoinsAncestorsAndTerminatesOnCycles() {
        let root = SoriaCollection(name: "Soria Organized", kind: .group)
        let genre = SoriaCollection(parentID: root.id, name: "House")
        let cluster = SoriaCollection(parentID: genre.id, name: "Cluster 01 - Anna")
        let byID = Dictionary(uniqueKeysWithValues: [root, genre, cluster].map { ($0.id, $0) })

        #expect(
            SoriaCollection.hierarchicalName(for: cluster.id, in: byID)
                == "Soria Organized/House/Cluster 01 - Anna"
        )
        #expect(SoriaCollection.hierarchicalName(for: root.id, in: byID) == "Soria Organized")

        // A cycle is unreachable through the UI but must not hang the exporter.
        var loopA = SoriaCollection(name: "A")
        var loopB = SoriaCollection(name: "B")
        loopA.parentID = loopB.id
        loopB.parentID = loopA.id
        let looping = [loopA.id: loopA, loopB.id: loopB]
        #expect(SoriaCollection.hierarchicalName(for: loopA.id, in: looping) == "B/A")
    }

    @Test
    func quarantineRecordsRoundTripAndPreserveTheOriginalScanTimestamp() throws {
        let directory = try makeCollectionTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))

        let track = try insertTrack(into: database, path: directory.appendingPathComponent("junk.mp3").path)
        let lastSeen = Date(timeIntervalSince1970: 1_700_000_500)
        let record = TrackQuarantineRecord(
            trackID: track.id,
            originalPath: track.filePath,
            quarantinePath: directory.appendingPathComponent("Soria Quarantine/junk.mp3").path,
            originalLastSeenInLocalScanAt: lastSeen,
            batchID: UUID()
        )
        try database.insertQuarantineRecord(record)

        let stored = try #require(try database.fetchQuarantineRecords().first)
        #expect(stored.trackID == track.id)
        #expect(stored.originalPath == track.filePath)
        #expect(stored.reason == .userDiscard)
        // Restore replays this value, so losing it would force a full rescan.
        #expect(Int(stored.originalLastSeenInLocalScanAt?.timeIntervalSince1970 ?? 0)
            == Int(lastSeen.timeIntervalSince1970))

        try database.deleteQuarantineRecord(trackID: track.id)
        #expect(try database.fetchQuarantineRecords().isEmpty)
    }

    @Test
    func organizationBatchesPersistTheirMoves() throws {
        let directory = try makeCollectionTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))

        let track = try insertTrack(into: database, path: directory.appendingPathComponent("a.mp3").path)
        let batch = OrganizationBatchRecord(kind: .genreClusters, embeddingProfileID: "profile")
        let move = OrganizationMoveRecord(
            batchID: batch.id,
            trackID: track.id,
            sourcePath: track.filePath,
            targetPath: directory.appendingPathComponent("Soria Organized/House/a.mp3").path
        )
        try database.insertOrganizationBatch(batch, moves: [move])

        let batches = try database.fetchOrganizationBatches()
        #expect(batches.count == 1)
        #expect(batches.first?.kind == .genreClusters)

        let moves = try database.fetchOrganizationMoves(batchID: batch.id)
        #expect(moves.count == 1)
        #expect(moves.first?.state == .applied)
        #expect(moves.first?.sourcePath == track.filePath)
    }

    @Test
    func relocationWithExpectedPathRejectsAStaleSourcePath() throws {
        let directory = try makeCollectionTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))

        let originalPath = directory.appendingPathComponent("Old/a.mp3").path
        let track = try insertTrack(into: database, path: originalPath)
        let newURL = directory.appendingPathComponent("New/a.mp3")

        // Someone else already moved this track; our expected path is stale.
        #expect(throws: (any Error).self) {
            _ = try database.updateTrackFileLocation(
                trackID: track.id,
                fileURL: newURL,
                modifiedTime: Date(),
                contentHash: track.contentHash,
                lastSeenInLocalScanAt: Date(),
                expectedCurrentPath: directory.appendingPathComponent("Somewhere/else.mp3").path
            )
        }
        #expect(try database.fetchTrack(id: track.id)?.filePath == originalPath)

        // The matching expected path goes through and records the alias.
        let moved = try database.updateTrackFileLocation(
            trackID: track.id,
            fileURL: newURL,
            modifiedTime: Date(),
            contentHash: track.contentHash,
            lastSeenInLocalScanAt: Date(),
            expectedCurrentPath: originalPath
        )
        #expect(moved.filePath == newURL.standardizedFileURL.path)
        #expect(try database.fetchTrackPathAliases(trackID: track.id).contains(originalPath))
    }

    @Test
    func relocationRecordsTheSuppliedAliasSource() throws {
        let directory = try makeCollectionTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))

        let originalPath = directory.appendingPathComponent("a.mp3").path
        let track = try insertTrack(into: database, path: originalPath)

        _ = try database.updateTrackFileLocation(
            trackID: track.id,
            fileURL: directory.appendingPathComponent("Soria Quarantine/a.mp3"),
            modifiedTime: Date(),
            contentHash: track.contentHash,
            lastSeenInLocalScanAt: nil,
            expectedCurrentPath: originalPath,
            aliasSource: "quarantine_move"
        )

        // The alias must still exist so vendor sync can re-match the moved file.
        #expect(try database.fetchTrackPathAliases(trackID: track.id) == [originalPath])
    }
}

private func makeCollectionTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("Soria-Collection-Tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func insertTrack(into database: LibraryDatabase, path: String) throws -> Track {
    let track = Track.empty(
        path: TrackPathNormalizer.normalizedAbsolutePath(path),
        modifiedTime: Date(),
        hash: UUID().uuidString
    )
    try database.upsertTrack(track)
    return try #require(try database.fetchTrack(id: track.id))
}
