import Foundation
import Testing

@testable import Soria

/// Serialized because every case writes into its own temporary directory on disk.
@Suite(.serialized)
struct TrackMapCacheTests {
    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soria-track-map-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeBasis(profileID: String = "google/gemini", dimension: Int = 4) -> TrackMapProjectionBasis {
        TrackMapProjectionBasis(
            profileID: profileID,
            dimension: dimension,
            mean: Array(repeating: 0.5, count: dimension),
            componentX: [1, 0, 0, 0],
            componentY: [0, 1, 0, 0],
            explainedVarianceRatio: 0.21,
            sourceTrackCount: 12
        )
    }

    // MARK: - Round trip

    @Test
    func storeAndLoadRoundTrip() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = TrackMapCache(directory: directory)
        let trackID = UUID()
        let file = TrackMapCacheFile(
            basis: makeBasis(),
            rows: [TrackMapFeatureRow(trackID: trackID, projectedX: 1.5, projectedY: -2.5, bpm: 128, durationSec: 300)]
        )

        cache.store(file, profileID: "google/gemini")
        let loaded = try #require(cache.load(profileID: "google/gemini"))

        #expect(loaded.basis == file.basis)
        #expect(loaded.rows.count == 1)
        #expect(loaded.rows[0].trackID == trackID)
        #expect(loaded.rows[0].projectedX == 1.5)
        #expect(loaded.rows[0].bpm == 128)
    }

    @Test
    func loadingAnAbsentProfileReturnsNil() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(TrackMapCache(directory: directory).load(profileID: "nothing/here") == nil)
    }

    @Test
    func profilesGetSeparateFilesSoVectorSpacesNeverMix() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = TrackMapCache(directory: directory)
        cache.store(TrackMapCacheFile(basis: makeBasis(profileID: "a/one"), rows: []), profileID: "a/one")
        cache.store(TrackMapCacheFile(basis: makeBasis(profileID: "b/two"), rows: []), profileID: "b/two")

        #expect(cache.load(profileID: "a/one")?.basis.profileID == "a/one")
        #expect(cache.load(profileID: "b/two")?.basis.profileID == "b/two")
    }

    @Test
    func aFileWrittenForAnotherProfileIsRejected() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = TrackMapCache(directory: directory)
        // Basis says one profile, filename says another: coordinates from a different
        // embedding space must never be reused.
        cache.store(TrackMapCacheFile(basis: makeBasis(profileID: "other/model"), rows: []), profileID: "google/gemini")

        #expect(cache.load(profileID: "google/gemini") == nil)
    }

    @Test
    func aStaleFormatVersionIsDiscarded() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = TrackMapCache(directory: directory)
        var file = TrackMapCacheFile(basis: makeBasis(), rows: [])
        file.version = TrackMapCacheFile.currentVersion + 1
        cache.store(file, profileID: "google/gemini")

        #expect(cache.load(profileID: "google/gemini") == nil)
    }

    @Test
    func corruptContentRebuildsInsteadOfCrashing() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = TrackMapCache(directory: directory)
        cache.store(TrackMapCacheFile(basis: makeBasis(), rows: []), profileID: "google/gemini")

        let file = directory.appendingPathComponent("google_gemini.json")
        try Data("{ not json".utf8).write(to: file)

        #expect(cache.load(profileID: "google/gemini") == nil)
    }

    @Test
    func invalidateRemovesTheFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = TrackMapCache(directory: directory)
        cache.store(TrackMapCacheFile(basis: makeBasis(), rows: []), profileID: "google/gemini")
        #expect(cache.load(profileID: "google/gemini") != nil)

        cache.invalidate(profileID: "google/gemini")
        #expect(cache.load(profileID: "google/gemini") == nil)
    }

    @Test
    func profileIdentifiersCannotEscapeTheCacheDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = TrackMapCache(directory: directory)
        cache.store(TrackMapCacheFile(basis: makeBasis(profileID: "../../evil"), rows: []), profileID: "../../evil")

        // The slashes and dots are sanitized away, so the file lands inside the cache.
        let written = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(written == ["______evil.json"])
        #expect(cache.load(profileID: "../../evil")?.basis.profileID == "../../evil")
    }

    // MARK: - Staleness

    @Test
    func tracksMissingFromTheCacheNeedRefreshing() {
        let cached = UUID()
        let fresh = UUID()
        let rows = [TrackMapFeatureRow(trackID: cached, analyzedAtEpoch: 1000)]

        let stale = TrackMapCache.trackIDsNeedingRefresh(
            cachedRows: rows,
            requiredTrackIDs: [cached, fresh],
            analyzedAtByTrackID: [cached: Date(timeIntervalSince1970: 1000)]
        )

        #expect(stale == [fresh])
    }

    @Test
    func reanalyzedTracksNeedRefreshingButUntouchedOnesDoNot() {
        let untouched = UUID()
        let reanalyzed = UUID()
        let rows = [
            TrackMapFeatureRow(trackID: untouched, analyzedAtEpoch: 1000),
            TrackMapFeatureRow(trackID: reanalyzed, analyzedAtEpoch: 1000),
        ]

        let stale = TrackMapCache.trackIDsNeedingRefresh(
            cachedRows: rows,
            requiredTrackIDs: [untouched, reanalyzed],
            analyzedAtByTrackID: [
                untouched: Date(timeIntervalSince1970: 1000),
                reanalyzed: Date(timeIntervalSince1970: 5000),
            ]
        )

        #expect(stale == [reanalyzed])
    }

    @Test
    func subSecondTimestampDriftDoesNotForceARebuild() {
        // The epoch survives a JSON round trip as a double, so an exact comparison
        // would mark the whole library stale on every launch.
        let trackID = UUID()
        let rows = [TrackMapFeatureRow(trackID: trackID, analyzedAtEpoch: 1000.0000001)]

        let stale = TrackMapCache.trackIDsNeedingRefresh(
            cachedRows: rows,
            requiredTrackIDs: [trackID],
            analyzedAtByTrackID: [trackID: Date(timeIntervalSince1970: 1000)]
        )

        #expect(stale.isEmpty)
    }

    @Test
    func gainingOrLosingAnAnalysisDateCountsAsStale() {
        let gained = UUID()
        let lost = UUID()
        let rows = [
            TrackMapFeatureRow(trackID: gained, analyzedAtEpoch: nil),
            TrackMapFeatureRow(trackID: lost, analyzedAtEpoch: 1000),
        ]

        let stale = TrackMapCache.trackIDsNeedingRefresh(
            cachedRows: rows,
            requiredTrackIDs: [gained, lost],
            analyzedAtByTrackID: [gained: Date(timeIntervalSince1970: 1000)]
        )

        #expect(stale == [gained, lost])
    }

    @Test
    func pruningDropsRowsForTracksNoLongerOnTheMap() {
        let keep = UUID()
        let drop = UUID()
        let rows = [
            TrackMapFeatureRow(trackID: keep),
            TrackMapFeatureRow(trackID: drop),
        ]

        let pruned = TrackMapCache.prunedRows(rows, keeping: [keep])

        #expect(pruned.count == 1)
        #expect(pruned[0].trackID == keep)
    }
}
