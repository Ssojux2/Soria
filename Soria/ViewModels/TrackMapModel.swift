import Combine
import CoreGraphics
import Foundation

/// State and actions for the Map tab.
///
/// Follows `LibraryOrganizerModel`: a child `ObservableObject` observed directly by
/// its view, with everything it needs from the app arriving through `Dependencies`,
/// so `AppViewModel` gains one lazy property and a factory rather than another
/// twenty published fields.
///
/// The expensive work — reading every embedding, running PCA — is pushed off the
/// main actor with `Task.detached`. That is a real departure from the organizer,
/// which does its database reads inside a main-actor `Task`; at map scale that would
/// freeze the window for seconds.
@MainActor
final class TrackMapModel: ObservableObject {
    struct Dependencies {
        var cache: TrackMapCache
        var loadTrackEmbeddings: @Sendable (Set<UUID>?) throws -> [UUID: [Double]]
        var loadMapFeatureRows: @Sendable (Set<UUID>?) throws -> [UUID: TrackMapFeatureRow]
        var allTracks: @MainActor () -> [Track]
        var readyTrackIDs: @MainActor () -> Set<UUID>
        var embeddingProfileID: @MainActor () -> String
        var tracksByID: @MainActor () -> [UUID: Track]
        var loadCollections: @Sendable () throws -> [SoriaCollection]
        var loadCollectionTrackIDs: @Sendable (UUID) throws -> [UUID]
        var createCollection: @Sendable (String, [UUID]) throws -> Void
        var sendSelectionToPlan: @MainActor (Set<UUID>) -> Void
    }

    // MARK: - Published state

    @Published var layoutMode: TrackMapLayoutMode = .similarity {
        didSet { if layoutMode != oldValue { recomputePoints() } }
    }
    @Published var xAxis: TrackMapAxis = .bpm {
        didSet { if xAxis != oldValue { recomputePoints() } }
    }
    @Published var yAxis: TrackMapAxis = .energy {
        didSet { if yAxis != oldValue { recomputePoints() } }
    }
    @Published var colorMode: TrackMapColorMode = .genreFamily {
        didSet { if colorMode != oldValue { recomputePoints() } }
    }

    @Published private(set) var points: [TrackMapPoint] = []
    @Published private(set) var legend: [TrackMapLegendEntry] = []
    @Published var highlightedColorKey: String?
    @Published private(set) var selectedTrackIDs: Set<UUID> = []
    @Published var hoveredTrackID: UUID?

    @Published private(set) var isBuilding = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var warnings: [String] = []
    @Published private(set) var explainedVarianceRatio: Double?
    @Published private(set) var unmappedTrackCount = 0
    @Published private(set) var comparison: TrackMapComparison?

    @Published var newFolderName: String = ""
    @Published private(set) var actionMessage = ""

    // MARK: - Private state

    private let dependencies: Dependencies
    private var rowsByTrackID: [UUID: TrackMapFeatureRow] = [:]
    private var colorKeyByTrackID: [UUID: String] = [:]
    private var colorKeyDisplayNames: [String: String] = [:]
    private var collectionNameByTrackID: [UUID: String] = [:]
    private var hasLoadedOnce = false
    private var comparisonTask: Task<Void, Never>?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    // MARK: - Derived state

    var plottedTrackCount: Int { points.count }

    var canCreateFolder: Bool {
        !selectedTrackIDs.isEmpty && !isBuilding
    }

    var canSendToPlan: Bool {
        !selectedTrackIDs.isEmpty && !isBuilding
    }

    /// A projection this weak should not be presented as a precise picture.
    var isLowConfidenceProjection: Bool {
        guard layoutMode == .similarity, let ratio = explainedVarianceRatio else { return false }
        return ratio < 0.15
    }

    var varianceSummary: String? {
        guard layoutMode == .similarity, let ratio = explainedVarianceRatio else { return nil }
        return "This map captures \(Self.percentText(ratio)) of the differences between tracks."
    }

    var summaryText: String {
        if isBuilding { return statusMessage }
        if points.isEmpty {
            return unmappedTrackCount > 0
                ? "No prepared tracks to plot yet. Analyze tracks first — \(unmappedTrackCount) are waiting."
                : "No tracks to plot yet."
        }
        var parts = ["\(points.count) tracks plotted"]
        if unmappedTrackCount > 0 {
            parts.append("\(unmappedTrackCount) need preparation")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Loading

    /// Loads the map, reusing the cached projection unless `force` is set.
    func refreshIfNeeded() {
        guard !hasLoadedOnce else { return }
        hasLoadedOnce = true
        refresh(force: false)
    }

    func recomputeLayout() {
        refresh(force: true)
    }

    func refresh(force: Bool) {
        guard !isBuilding else { return }

        let profileID = dependencies.embeddingProfileID()
        let tracks = dependencies.allTracks()
        let readyIDs = dependencies.readyTrackIDs()
        let required = Set(tracks.map(\.id)).intersection(readyIDs)

        var analyzedAt: [UUID: Date] = [:]
        for track in tracks where required.contains(track.id) {
            if let date = track.analyzedAt { analyzedAt[track.id] = date }
        }

        unmappedTrackCount = tracks.count - required.count

        guard !required.isEmpty else {
            rowsByTrackID = [:]
            explainedVarianceRatio = nil
            statusMessage = ""
            recomputePoints()
            return
        }

        let cache = dependencies.cache
        let loadEmbeddings = dependencies.loadTrackEmbeddings
        let loadRows = dependencies.loadMapFeatureRows

        isBuilding = true
        warnings = []
        statusMessage = force ? "Recomputing the map layout..." : "Building the map..."

        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.buildMap(
                    profileID: profileID,
                    requiredTrackIDs: required,
                    analyzedAtByTrackID: analyzedAt,
                    cache: cache,
                    loadEmbeddings: loadEmbeddings,
                    loadRows: loadRows,
                    force: force
                )
            }.value

            guard let self else { return }
            self.isBuilding = false
            self.apply(outcome)
        }
    }

    private func apply(_ outcome: BuildOutcome) {
        rowsByTrackID = outcome.rowsByTrackID
        explainedVarianceRatio = outcome.explainedVarianceRatio
        warnings = outcome.warnings
        statusMessage = ""
        reloadCollectionMembership()
        recomputePoints()
    }

    // MARK: - Point construction

    private func recomputePoints() {
        rebuildColorKeys()

        let normalized: [UUID: CGPoint]
        switch layoutMode {
        case .similarity:
            let raw = rowsByTrackID.mapValues { CGPoint(x: $0.projectedX, y: $0.projectedY) }
            normalized = TrackMapProjector.normalizedPoints(raw)
        case .customAxes:
            normalized = customAxisPoints()
        }

        // Sorted by id so draw order and the accessibility summary stay stable.
        points = normalized.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { id in
            guard let position = normalized[id] else { return nil }
            return TrackMapPoint(
                id: id,
                normalized: position,
                colorKey: colorKeyByTrackID[id] ?? TrackMapPalette.unassignedKey
            )
        }

        rebuildLegend()
        pruneSelection()
    }

    /// Tracks missing either axis value are left off the map rather than pinned to
    /// zero, which would invent a cluster in the corner that does not exist.
    private func customAxisPoints() -> [UUID: CGPoint] {
        var xs: [UUID: Double] = [:]
        var ys: [UUID: Double] = [:]
        for (id, row) in rowsByTrackID {
            guard let x = row.value(for: xAxis), let y = row.value(for: yAxis) else { continue }
            xs[id] = x
            ys[id] = y
        }

        let normalizedX = TrackMapProjector.normalizedValues(xs)
        let normalizedY = TrackMapProjector.normalizedValues(ys)

        var output: [UUID: CGPoint] = [:]
        output.reserveCapacity(normalizedX.count)
        for (id, x) in normalizedX {
            guard let y = normalizedY[id] else { continue }
            output[id] = CGPoint(x: x, y: y)
        }
        return output
    }

    private func rebuildColorKeys() {
        let tracks = dependencies.tracksByID()
        var keys: [UUID: String] = [:]
        var names: [String: String] = [:]

        for id in rowsByTrackID.keys {
            let track = tracks[id]
            switch colorMode {
            case .genreFamily:
                let normalizedGenre = GenreTaxonomy.normalizeGenreText(track?.genre ?? "")
                if let familyID = GenreTaxonomy.familyID(forNormalizedValue: normalizedGenre) {
                    keys[id] = familyID
                    names[familyID] = GenreTaxonomy.displayName(for: familyID)
                } else {
                    keys[id] = TrackMapPalette.unassignedKey
                    names[TrackMapPalette.unassignedKey] = "Untagged"
                }
            case .collection:
                if let name = collectionNameByTrackID[id] {
                    keys[id] = name
                    names[name] = name
                } else {
                    keys[id] = TrackMapPalette.unassignedKey
                    names[TrackMapPalette.unassignedKey] = "Not in a folder"
                }
            case .bpmRange:
                let bucket = Self.bpmBucket(for: rowsByTrackID[id]?.bpm ?? track?.bpm)
                keys[id] = bucket.key
                names[bucket.key] = bucket.name
            }
        }

        colorKeyByTrackID = keys
        colorKeyDisplayNames = names
    }

    private func rebuildLegend() {
        var counts: [String: Int] = [:]
        for point in points {
            counts[point.colorKey, default: 0] += 1
        }
        legend = counts
            .map {
                TrackMapLegendEntry(
                    id: $0.key,
                    displayName: colorKeyDisplayNames[$0.key] ?? ($0.key.isEmpty ? "Other" : $0.key),
                    count: $0.value
                )
            }
            // Biggest groups first; name breaks ties so the order never wobbles.
            .sorted { lhs, rhs in
                lhs.count == rhs.count ? lhs.displayName < rhs.displayName : lhs.count > rhs.count
            }

        if let highlightedColorKey, !counts.keys.contains(highlightedColorKey) {
            self.highlightedColorKey = nil
        }
    }

    private func reloadCollectionMembership() {
        var membership: [UUID: String] = [:]
        do {
            for collection in try dependencies.loadCollections() {
                let trackIDs = try dependencies.loadCollectionTrackIDs(collection.id)
                for trackID in trackIDs where membership[trackID] == nil {
                    membership[trackID] = collection.name
                }
            }
        } catch {
            AppLogger.shared.error("track_map_collection_load_failed error=\(error.localizedDescription)")
        }
        collectionNameByTrackID = membership
    }

    // MARK: - Selection

    func updateSelection(_ trackIDs: Set<UUID>, additive: Bool) {
        selectedTrackIDs = additive ? selectedTrackIDs.union(trackIDs) : trackIDs
        actionMessage = ""
        refreshComparison()
    }

    func clearSelection() {
        selectedTrackIDs = []
        comparison = nil
        actionMessage = ""
    }

    func toggleHighlight(_ colorKey: String) {
        highlightedColorKey = highlightedColorKey == colorKey ? nil : colorKey
    }

    private func pruneSelection() {
        let plotted = Set(points.map(\.id))
        let survivors = selectedTrackIDs.intersection(plotted)
        guard survivors != selectedTrackIDs else { return }
        selectedTrackIDs = survivors
        refreshComparison()
    }

    // MARK: - Comparison

    /// Loads the two selected vectors on demand rather than keeping the whole library
    /// in memory: at 3072 dimensions a few thousand tracks would cost tens of
    /// megabytes to hold for a feature used two tracks at a time.
    private func refreshComparison() {
        comparisonTask?.cancel()

        guard selectedTrackIDs.count == 2 else {
            comparison = nil
            return
        }

        let tracks = dependencies.tracksByID()
        let ids = selectedTrackIDs.sorted { $0.uuidString < $1.uuidString }
        guard let left = tracks[ids[0]], let right = tracks[ids[1]] else {
            comparison = nil
            return
        }

        let pair: Set<UUID> = [ids[0], ids[1]]
        let loadEmbeddings = dependencies.loadTrackEmbeddings
        let leftRow = rowsByTrackID[ids[0]]
        let rightRow = rowsByTrackID[ids[1]]

        comparisonTask = Task { [weak self] in
            let vectors = await Task.detached(priority: .userInitiated) {
                (try? loadEmbeddings(pair)) ?? [:]
            }.value

            guard let self, !Task.isCancelled else { return }
            guard self.selectedTrackIDs == pair else { return }

            var similarity: Double?
            if let a = vectors[ids[0]], let b = vectors[ids[1]], !a.isEmpty, !b.isEmpty {
                // The planner's true cosine, not `AppViewModel.similarityScore`, which
                // is a 1/(1+distance) score on a different scale.
                similarity = LibraryOrganizationPlanner.cosineSimilarity(a, b)
            }

            self.comparison = TrackMapComparison(
                left: left,
                right: right,
                leftRow: leftRow,
                rightRow: rightRow,
                cosineSimilarity: similarity
            )
        }
    }

    // MARK: - Actions

    /// Records the selection as a Soria collection.
    ///
    /// Nothing on disk moves: the map groups tracks, and the existing batch export
    /// can send that grouping to Serato or rekordbox immediately. Moving files is the
    /// Plan tab's job, which is what `sendSelectionToPlan` hands off to.
    func createFolderFromSelection() {
        guard canCreateFolder else { return }

        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? Self.defaultFolderName(count: selectedTrackIDs.count) : trimmed
        let trackIDs = selectedTrackIDs.sorted { $0.uuidString < $1.uuidString }

        do {
            try dependencies.createCollection(name, trackIDs)
            newFolderName = ""
            actionMessage = "Created \"\(name)\" with \(trackIDs.count) tracks. Export it from the Plan tab."
            reloadCollectionMembership()
            if colorMode == .collection { recomputePoints() }
        } catch {
            actionMessage = "Could not create the folder: \(error.localizedDescription)"
            AppLogger.shared.error("track_map_create_collection_failed error=\(error.localizedDescription)")
        }
    }

    func sendSelectionToPlan() {
        guard canSendToPlan else { return }
        let count = selectedTrackIDs.count
        dependencies.sendSelectionToPlan(selectedTrackIDs)
        actionMessage = "Sent \(count) tracks to the Plan tab."
    }

    func track(for trackID: UUID) -> Track? {
        dependencies.tracksByID()[trackID]
    }

    func featureRow(for trackID: UUID) -> TrackMapFeatureRow? {
        rowsByTrackID[trackID]
    }

    // MARK: - Build (off the main actor)

    private struct BuildOutcome: Sendable {
        var rowsByTrackID: [UUID: TrackMapFeatureRow]
        var explainedVarianceRatio: Double?
        var warnings: [String]
    }

    private nonisolated static func buildMap(
        profileID: String,
        requiredTrackIDs: Set<UUID>,
        analyzedAtByTrackID: [UUID: Date],
        cache: TrackMapCache,
        loadEmbeddings: @Sendable (Set<UUID>?) throws -> [UUID: [Double]],
        loadRows: @Sendable (Set<UUID>?) throws -> [UUID: TrackMapFeatureRow],
        force: Bool
    ) -> BuildOutcome {
        var warnings: [String] = []
        let cached = force ? nil : cache.load(profileID: profileID)

        var basis = cached?.basis
        var rows: [UUID: TrackMapFeatureRow] = [:]
        for row in cached?.rows ?? [] {
            rows[row.trackID] = row
        }

        var stale = TrackMapCache.trackIDsNeedingRefresh(
            cachedRows: Array(rows.values),
            requiredTrackIDs: requiredTrackIDs,
            analyzedAtByTrackID: analyzedAtByTrackID
        )

        // No usable basis means a full pass: derive one from every embedding, then
        // reproject everything so old and new coordinates share the same axes.
        let needsFullRebuild = basis == nil || !(basis?.isUsable ?? false)
        if needsFullRebuild {
            stale = requiredTrackIDs
        }

        do {
            let embeddings = try loadEmbeddings(needsFullRebuild ? requiredTrackIDs : stale)

            if needsFullRebuild {
                let ordered = requiredTrackIDs
                    .sorted { $0.uuidString < $1.uuidString }
                    .compactMap { embeddings[$0] }
                basis = TrackMapProjector.computeBasis(vectors: ordered, profileID: profileID)
            }

            guard let resolvedBasis = basis, resolvedBasis.isUsable else {
                return BuildOutcome(
                    rowsByTrackID: [:],
                    explainedVarianceRatio: nil,
                    warnings: ["Not enough prepared tracks to build a similarity map yet."]
                )
            }

            let features = try loadRows(stale)

            for trackID in stale {
                guard let vector = embeddings[trackID],
                      let projected = TrackMapProjector.project(vector, using: resolvedBasis)
                else { continue }

                var row = features[trackID] ?? TrackMapFeatureRow(trackID: trackID)
                row.projectedX = Double(projected.x)
                row.projectedY = Double(projected.y)
                row.analyzedAtEpoch = analyzedAtByTrackID[trackID]?.timeIntervalSince1970
                rows[trackID] = row
            }

            let cachedRowCount = cached?.rows.count ?? 0
            let pruned = TrackMapCache.prunedRows(Array(rows.values), keeping: requiredTrackIDs)
            rows = Dictionary(uniqueKeysWithValues: pruned.map { ($0.trackID, $0) })

            // Only rewrite when something actually changed. Opening the tab on an
            // unchanged library should not spend a multi-megabyte write every time.
            let cacheChanged = needsFullRebuild || !stale.isEmpty || pruned.count != cachedRowCount
            if cacheChanged {
                cache.store(
                    TrackMapCacheFile(
                        basis: resolvedBasis,
                        rows: pruned.sorted { $0.trackID.uuidString < $1.trackID.uuidString }
                    ),
                    profileID: profileID
                )
            }

            let missing = requiredTrackIDs.count - rows.count
            if missing > 0 {
                warnings.append("\(missing) prepared tracks could not be placed on the map.")
            }

            return BuildOutcome(
                rowsByTrackID: rows,
                explainedVarianceRatio: resolvedBasis.explainedVarianceRatio,
                warnings: warnings
            )
        } catch {
            AppLogger.shared.error("track_map_build_failed error=\(error.localizedDescription)")
            return BuildOutcome(
                rowsByTrackID: [:],
                explainedVarianceRatio: nil,
                warnings: ["Could not read track data for the map: \(error.localizedDescription)"]
            )
        }
    }

    // MARK: - Formatting helpers

    static func percentText(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }

    static func defaultFolderName(count: Int) -> String {
        "Map Selection (\(count) tracks)"
    }

    static func bpmBucket(for bpm: Double?) -> (key: String, name: String) {
        guard let bpm, bpm > 0 else { return (TrackMapPalette.unassignedKey, "No BPM") }
        switch bpm {
        case ..<100: return ("bpm-0", "Under 100")
        case ..<115: return ("bpm-1", "100–115")
        case ..<125: return ("bpm-2", "115–125")
        case ..<135: return ("bpm-3", "125–135")
        case ..<150: return ("bpm-4", "135–150")
        default: return ("bpm-5", "150+")
        }
    }
}

/// The side-by-side reading for exactly two selected tracks.
struct TrackMapComparison {
    let left: Track
    let right: Track
    let leftRow: TrackMapFeatureRow?
    let rightRow: TrackMapFeatureRow?
    /// True cosine in `[0, 1]`, or nil when either embedding could not be read.
    let cosineSimilarity: Double?
}
