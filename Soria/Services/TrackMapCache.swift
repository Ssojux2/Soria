import Foundation

/// Disk cache for the similarity map's projection basis and per-track coordinates.
///
/// Building the map from scratch means reading every 3072-dimension embedding and
/// decoding every analysis summary — by far the slowest part of opening the screen,
/// and none of it changes until tracks are re-analyzed.
///
/// Caching the basis matters for more than speed. Recomputing PCA over a grown
/// library shifts and rescales both axes, so the cluster a user learned to find in
/// one corner would move somewhere else. With the basis pinned, a newly analyzed
/// track is placed with two dot products and every existing dot stays put.
///
/// Stored per profile at `<worker cache>/track-map/<sanitized profile id>.json`, so
/// switching embedding models never mixes coordinate spaces.
///
/// `@unchecked Sendable` because `FileManager` is not marked `Sendable`; building the
/// map runs off the main actor, and the only shared state here is a directory URL and
/// a file manager used for one atomic read or write at a time.
struct TrackMapCache: @unchecked Sendable {
    private let directory: URL
    private let fileManager: FileManager

    init(
        directory: URL = AppPaths.pythonCacheDirectory.appendingPathComponent(
            "track-map",
            isDirectory: true
        ),
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Reads the cached map for a profile, or nil when there is nothing reusable.
    ///
    /// A file written by an older layout version, or one that fails to decode, is
    /// treated as absent: rebuilding costs time, but honouring stale coordinates
    /// would put dots in the wrong places with no visible symptom.
    func load(profileID: String) -> TrackMapCacheFile? {
        guard let data = try? Data(contentsOf: fileURL(profileID: profileID)) else { return nil }
        guard let decoded = try? JSONDecoder().decode(TrackMapCacheFile.self, from: data) else {
            AppLogger.shared.error("track_map_cache_decode_failed profile=\(profileID)")
            return nil
        }
        guard decoded.version == TrackMapCacheFile.currentVersion, decoded.basis.isUsable else { return nil }
        guard decoded.basis.profileID == profileID else { return nil }
        return decoded
    }

    /// Writes the map for a profile.
    ///
    /// Best-effort, like the label cache: a failed write costs a rebuild next time,
    /// which is not worth failing the screen over.
    func store(_ file: TrackMapCacheFile, profileID: String) {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(file)
            try data.write(to: fileURL(profileID: profileID), options: .atomic)
        } catch {
            AppLogger.shared.error(
                "track_map_cache_write_failed profile=\(profileID) error=\(error.localizedDescription)"
            )
        }
    }

    func invalidate(profileID: String) {
        try? fileManager.removeItem(at: fileURL(profileID: profileID))
    }

    /// Which tracks the cache cannot answer for: never seen, or analyzed again since.
    ///
    /// Pure and separately testable — it decides how much work opening the map costs,
    /// so it should be provable without touching disk.
    static func trackIDsNeedingRefresh(
        cachedRows: [TrackMapFeatureRow],
        requiredTrackIDs: Set<UUID>,
        analyzedAtByTrackID: [UUID: Date]
    ) -> Set<UUID> {
        var rowsByTrackID: [UUID: TrackMapFeatureRow] = [:]
        rowsByTrackID.reserveCapacity(cachedRows.count)
        for row in cachedRows {
            rowsByTrackID[row.trackID] = row
        }

        var stale: Set<UUID> = []
        for trackID in requiredTrackIDs {
            guard let row = rowsByTrackID[trackID] else {
                stale.insert(trackID)
                continue
            }
            if row.isStale(against: analyzedAtByTrackID[trackID]) {
                stale.insert(trackID)
            }
        }
        return stale
    }

    /// Drops rows for tracks that are no longer on the map, so a cache file cannot
    /// grow forever as a library churns.
    static func prunedRows(
        _ rows: [TrackMapFeatureRow],
        keeping requiredTrackIDs: Set<UUID>
    ) -> [TrackMapFeatureRow] {
        rows.filter { requiredTrackIDs.contains($0.trackID) }
    }

    // MARK: - Private

    private func fileURL(profileID: String) -> URL {
        // One definition of this mapping for the whole app; it mirrors the worker's
        // own profile-id sanitization so a slash in a model name cannot escape the
        // cache directory.
        directory.appendingPathComponent("\(LabelEmbeddingCache.sanitizedProfileID(profileID)).json")
    }
}
