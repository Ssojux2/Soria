import Combine
import Foundation

/// State and actions for the Library's crate tree and classifier panel.
///
/// Lives outside `AppViewModel` for the same reason `LibraryOrganizerModel` does:
/// that file is already 7,000 lines. Everything it needs arrives through
/// `Dependencies`, and views observe this object directly — SwiftUI does not
/// forward a nested `ObservableObject`'s changes to its parent, which is what
/// makes that work without any `objectWillChange` plumbing.
///
/// Writes go to the database first and to the in-memory index second. The index
/// exists because the Library re-filters on every keystroke over thousands of
/// tracks and cannot afford a query per row; it is a cache of the database, never
/// the source of truth.
@MainActor
final class LibraryBrowserModel: ObservableObject {
    struct Dependencies {
        var loadTagCatalog: @Sendable () throws -> TagCatalog
        var saveTagCategory: @Sendable (TagCategory) throws -> Void
        var saveTag: @Sendable (Tag) throws -> Void
        var deleteTag: @Sendable (UUID) throws -> Void

        var loadTrackTagIndex: @Sendable () throws -> TrackTagIndex
        var assignTag: @Sendable (UUID, [UUID]) throws -> Void
        var removeTag: @Sendable (UUID, [UUID]) throws -> Void

        var updateClassification: @Sendable (UUID, TrackClassification) throws -> Void
        /// Track embeddings for the given IDs. Missing or unanalysed tracks are
        /// simply absent from the result.
        var loadTrackEmbeddings: @Sendable (Set<UUID>) throws -> [UUID: [Double]]

        var loadCollections: @Sendable () throws -> [SoriaCollection]
        var saveCollection: @Sendable (SoriaCollection) throws -> Void
        var deleteCollection: @Sendable (UUID) throws -> Void
        var loadCollectionTrackCounts: @Sendable () throws -> [UUID: Int]
        var loadCollectionTrackIDs: @Sendable (UUID) throws -> [UUID]
        /// Track IDs inside one Serato crate or rekordbox playlist, including its
        /// nested children. Resolved by `AppViewModel`, which already owns the
        /// membership snapshot the scope filter is built on.
        var loadMembershipTrackIDs: @MainActor (ExternalDJMetadata.Source, String) -> Set<UUID>

        var allTracks: @MainActor () -> [Track]
        var selectedTracks: @MainActor () -> [Track]
        var readyTrackIDs: @MainActor () -> Set<UUID>
        var quarantinedTrackCount: @MainActor () -> Int
        var membershipFacets: @MainActor (ExternalDJMetadata.Source) -> [MembershipFacet]
        var applyTrackEdits: @MainActor ([Track]) -> Void
    }

    enum ClassifierTab: String, CaseIterable, Identifiable {
        case tag = "Tag"
        case filter = "Filter"

        var id: String { rawValue }
    }

    /// A track counts as "new" for this long after it was added. Long enough to
    /// survive a week of not touching the app, short enough that the Inbox stays
    /// a working pile rather than a second copy of the library.
    static let inboxWindow: TimeInterval = 30 * 24 * 60 * 60

    @Published var crateSelection: CrateSelection = .allTracks
    @Published var expandedNodeIDs: Set<String> = []
    @Published var classifierTab: ClassifierTab = .tag
    @Published var classificationFilter = LibraryClassificationFilter()

    @Published private(set) var tagCatalog: TagCatalog = .empty
    @Published private(set) var tagIndex = TrackTagIndex()
    @Published private(set) var collections: [SoriaCollection] = []
    @Published private(set) var collectionTrackCounts: [UUID: Int] = [:]
    @Published private(set) var statusMessage = ""

    @Published private(set) var suggestions: [ClassificationSuggestionEngine.Suggestion] = []
    @Published var isSuggestionSheetPresented = false
    @Published private(set) var isBuildingSuggestions = false

    /// Track IDs belonging to the selected crate, or nil when the selection puts
    /// no membership constraint on the table (All Tracks, Inbox, Needs Prep).
    /// Loaded on selection rather than held for every crate at once.
    @Published private(set) var selectedCrateTrackIDs: Set<UUID>?

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    // MARK: - Loading

    /// Reloads everything the tree and the tag panel draw from. Cheap enough to
    /// call whenever the Library appears or the track list changes.
    func refresh() {
        do {
            tagCatalog = try dependencies.loadTagCatalog()
            tagIndex = try dependencies.loadTrackTagIndex()
            collections = try dependencies.loadCollections()
            collectionTrackCounts = try dependencies.loadCollectionTrackCounts()
            reloadSelectedCrateMembership()
            statusMessage = ""
        } catch {
            statusMessage = "Could not load crates and tags: \(error.localizedDescription)"
        }
    }

    private func reloadSelectedCrateMembership() {
        switch crateSelection {
        case let .collection(collectionID):
            do {
                selectedCrateTrackIDs = Set(try dependencies.loadCollectionTrackIDs(collectionID))
            } catch {
                // An empty set, not nil: failing open would silently show the
                // whole library under a folder the user picked.
                selectedCrateTrackIDs = []
                statusMessage = "Could not read that folder: \(error.localizedDescription)"
            }

        case let .vendorMembership(source, path):
            selectedCrateTrackIDs = dependencies.loadMembershipTrackIDs(source, path)

        case .allTracks, .inbox, .needsPreparation, .smartCrate, .trash:
            selectedCrateTrackIDs = nil
        }
    }

    func selectCrate(_ selection: CrateSelection) {
        crateSelection = selection
        reloadSelectedCrateMembership()
    }

    func toggleExpansion(_ nodeID: String) {
        if expandedNodeIDs.contains(nodeID) {
            expandedNodeIDs.remove(nodeID)
        } else {
            expandedNodeIDs.insert(nodeID)
        }
    }

    func isExpanded(_ nodeID: String) -> Bool {
        expandedNodeIDs.contains(nodeID)
    }

    // MARK: - The tree

    var treeSections: [CrateTreeSection] {
        LibraryCrateTree.makeSections(from: crateTreeContext)
    }

    private var crateTreeContext: CrateTreeContext {
        let tracks = dependencies.allTracks()
        let readyIDs = dependencies.readyTrackIDs()

        var context = CrateTreeContext()
        context.totalTrackCount = tracks.count
        context.inboxTrackCount = tracks.count { isInInbox($0) }
        context.needsPreparationCount = tracks.count { !readyIDs.contains($0.id) }
        context.quarantinedTrackCount = dependencies.quarantinedTrackCount()
        // Smart crates are evaluated, not stored, so they are filtered out of the
        // folder tree and rebuilt as their own section.
        context.collections = collections.filter { $0.kind != .smart }
        context.trackCountsByCollectionID = collectionTrackCounts
        context.smartCrates = smartCrateSummaries(tracks: tracks)
        context.seratoFacets = dependencies.membershipFacets(.serato)
        context.rekordboxFacets = dependencies.membershipFacets(.rekordbox)
        return context
    }

    // MARK: - Smart crates

    /// Decoded rule sets, keyed by crate. A crate whose JSON will not decode is
    /// dropped from this map and therefore matches nothing, which surfaces as an
    /// empty crate rather than as a crash.
    private var ruleSetsByCrateID: [UUID: SmartCrateRuleSet] {
        var result: [UUID: SmartCrateRuleSet] = [:]
        let decoder = JSONDecoder()

        for collection in collections where collection.kind == .smart {
            guard
                let json = collection.rulesJSON,
                let data = json.data(using: .utf8),
                let ruleSet = try? decoder.decode(SmartCrateRuleSet.self, from: data)
            else { continue }
            result[collection.id] = ruleSet
        }
        return result
    }

    private func smartCrateSummaries(tracks: [Track]) -> [SmartCrateSummary] {
        let ruleSets = ruleSetsByCrateID
        let now = Date()

        return collections
            .filter { $0.kind == .smart }
            .map { collection in
                let matchCount = ruleSets[collection.id].map { ruleSet in
                    tracks.count { track in
                        ruleSet.matches(
                            SmartCrateEvaluationInput(track: track, tagIDs: tagIndex.tagIDs(for: track.id), now: now)
                        )
                    }
                } ?? 0

                return SmartCrateSummary(
                    id: collection.id,
                    name: collection.name,
                    colorLabel: nil,
                    matchCount: matchCount,
                    sortIndex: collection.sortIndex
                )
            }
    }

    /// Saves whatever the Filter tab is currently showing as a rule-based crate.
    ///
    /// Returns the constraints the rule model could not express, so the caller can
    /// say so rather than let the user believe the crate means exactly what the
    /// filter did.
    @discardableResult
    func saveFilterAsSmartCrate(named name: String) -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "Give the crate a name."
            return []
        }

        let ruleSet = SmartCrateRuleSet.from(classificationFilter)
        guard !ruleSet.validRules.isEmpty else {
            statusMessage = "Set at least one filter before saving a crate."
            return []
        }

        do {
            let encoded = try JSONEncoder().encode(ruleSet)
            let collection = SoriaCollection(
                name: trimmed,
                kind: .smart,
                origin: .user,
                rulesJSON: String(decoding: encoded, as: UTF8.self),
                sortIndex: collections.filter { $0.kind == .smart }.count
            )
            try dependencies.saveCollection(collection)
            collections.append(collection)

            let lost = SmartCrateRuleSet.unconvertibleConstraints(in: classificationFilter)
            statusMessage = lost.isEmpty
                ? "Saved \"\(trimmed)\"."
                : "Saved \"\(trimmed)\", but \(lost.joined(separator: " and ")) could not be saved as rules."
            return lost
        } catch {
            statusMessage = "Could not save that crate: \(error.localizedDescription)"
            return []
        }
    }

    func deleteSmartCrate(_ crateID: UUID) {
        do {
            try dependencies.deleteCollection(crateID)
            collections.removeAll { $0.id == crateID }
            if crateSelection == .smartCrate(crateID) {
                selectCrate(.allTracks)
            }
            statusMessage = ""
        } catch {
            statusMessage = "Could not delete that crate: \(error.localizedDescription)"
        }
    }

    func ruleSet(for crateID: UUID) -> SmartCrateRuleSet? {
        ruleSetsByCrateID[crateID]
    }

    func smartCrateName(for crateID: UUID) -> String? {
        collections.first { $0.id == crateID && $0.kind == .smart }?.name
    }

    /// How many tracks a rule set would take in. Drives the live count in the
    /// rule builder, so it is evaluated against the candidate rules rather than
    /// the saved ones.
    func matchCount(for ruleSet: SmartCrateRuleSet) -> Int {
        let now = Date()
        return dependencies.allTracks().count { track in
            ruleSet.matches(
                SmartCrateEvaluationInput(track: track, tagIDs: tagIndex.tagIDs(for: track.id), now: now)
            )
        }
    }

    func updateSmartCrate(_ crateID: UUID, ruleSet: SmartCrateRuleSet) {
        guard var collection = collections.first(where: { $0.id == crateID }) else {
            statusMessage = "That crate no longer exists."
            return
        }

        do {
            let encoded = try JSONEncoder().encode(ruleSet)
            collection.rulesJSON = String(decoding: encoded, as: UTF8.self)
            collection.updatedAt = Date()
            try dependencies.saveCollection(collection)
            collections = collections.map { $0.id == crateID ? collection : $0 }
            statusMessage = ""
        } catch {
            statusMessage = "Could not save those rules: \(error.localizedDescription)"
        }
    }

    /// Recently added and nobody has classified it. Both halves matter: a track
    /// added last year that was never tagged is not "new", and a track added
    /// yesterday that the user already rated is already dealt with.
    private func isInInbox(_ track: Track) -> Bool {
        guard let addedAt = track.classification.dateAdded else { return false }
        guard Date().timeIntervalSince(addedAt) <= Self.inboxWindow else { return false }
        return track.classification.isUnclassified && tagIndex.isUntagged(track.id)
    }

    // MARK: - Filtering

    /// Whether a track belongs to the current crate. Combined by `AppViewModel`
    /// with the existing search, prep-status, and vendor-scope filters rather
    /// than replacing them.
    func matchesCrate(_ track: Track, readyTrackIDs: Set<UUID>) -> Bool {
        switch crateSelection {
        case .allTracks:
            return true
        case .inbox:
            return isInInbox(track)
        case .needsPreparation:
            return !readyTrackIDs.contains(track.id)
        case .collection, .vendorMembership:
            return selectedCrateTrackIDs?.contains(track.id) ?? false
        case let .smartCrate(crateID):
            // Evaluated per track rather than materialized, which is what makes a
            // smart crate stay correct as the library changes. An undecodable
            // rule set matches nothing.
            guard let ruleSet = ruleSetsByCrateID[crateID] else { return false }
            return ruleSet.matches(
                SmartCrateEvaluationInput(track: track, tagIDs: tagIndex.tagIDs(for: track.id))
            )
        case .trash:
            // Quarantined tracks are reviewed in their own pane, which reads the
            // quarantine table directly — the Library table never lists them.
            return false
        }
    }

    func matchesClassificationFilter(_ track: Track) -> Bool {
        classificationFilter.matches(track, tagIDs: tagIndex.tagIDs(for: track.id))
    }

    // MARK: - Tagging

    var selectedTrackIDs: [UUID] {
        dependencies.selectedTracks().map(\.id)
    }

    func selectionState(for tagID: UUID) -> TrackTagIndex.SelectionState {
        tagIndex.selectionState(for: tagID, across: selectedTrackIDs)
    }

    /// Applies or clears a tag across the selection.
    ///
    /// A partially-applied tag resolves to "apply to all" rather than "clear",
    /// so a single click can never strip the tag from the tracks that already
    /// carry it.
    func toggleTag(_ tagID: UUID) {
        let trackIDs = selectedTrackIDs
        guard !trackIDs.isEmpty else {
            statusMessage = "Select a track first."
            return
        }

        let shouldApply = selectionState(for: tagID) != .all
        do {
            if shouldApply {
                try dependencies.assignTag(tagID, trackIDs)
                tagIndex = tagIndex.applying(tagID: tagID, to: trackIDs)
            } else {
                try dependencies.removeTag(tagID, trackIDs)
                tagIndex = tagIndex.removing(tagID: tagID, from: trackIDs)
            }
            statusMessage = ""
        } catch {
            statusMessage = "Could not save that tag: \(error.localizedDescription)"
        }
    }

    func addTag(named name: String, to slot: TagCategorySlot) {
        do {
            let result = try tagCatalog.addingTag(named: name, to: slot)
            try dependencies.saveTag(result.tag)
            tagCatalog = result.catalog
            statusMessage = ""
        } catch let error as TagCatalogError {
            statusMessage = Self.message(for: error)
        } catch {
            statusMessage = "Could not add that tag: \(error.localizedDescription)"
        }
    }

    func renameCategory(_ slot: TagCategorySlot, to name: String) {
        do {
            tagCatalog = try tagCatalog.renamingCategory(slot, to: name)
            try dependencies.saveTagCategory(tagCatalog.category(slot))
            statusMessage = ""
        } catch let error as TagCatalogError {
            statusMessage = Self.message(for: error)
        } catch {
            statusMessage = "Could not rename that category: \(error.localizedDescription)"
        }
    }

    func deleteTag(_ tagID: UUID) {
        do {
            let updated = try tagCatalog.removingTag(id: tagID)
            try dependencies.deleteTag(tagID)
            tagCatalog = updated
            tagIndex = tagIndex.removingTagEverywhere(tagID)
            classificationFilter.tagIDs.remove(tagID)
            statusMessage = ""
        } catch let error as TagCatalogError {
            statusMessage = Self.message(for: error)
        } catch {
            statusMessage = "Could not delete that tag: \(error.localizedDescription)"
        }
    }

    private static func message(for error: TagCatalogError) -> String {
        switch error {
        case .emptyName:
            return "Give the tag a name."
        case let .duplicateName(_, name):
            return "\"\(name)\" is already in that category."
        case let .categoryFull(_, limit):
            return "That category is full at \(limit) tags. Delete one to add another."
        case .unknownTag:
            return "That tag no longer exists."
        }
    }

    // MARK: - Rating, energy, colour

    func setRating(_ rating: TrackRating?, on tracks: [Track]) {
        applyClassification(to: tracks) { $0.settingUserRating(rating) }
    }

    func setEnergy(_ energy: TrackEnergy?, on tracks: [Track]) {
        applyClassification(to: tracks) { $0.settingUserEnergy(energy) }
    }

    func setColorLabel(_ color: TrackColorLabel?, on tracks: [Track]) {
        applyClassification(to: tracks) { $0.settingUserColorLabel(color) }
    }

    private func applyClassification(
        to tracks: [Track],
        _ transform: (TrackClassification) -> TrackClassification
    ) {
        guard !tracks.isEmpty else {
            statusMessage = "Select a track first."
            return
        }

        var updated: [Track] = []
        updated.reserveCapacity(tracks.count)

        do {
            for track in tracks {
                var edited = track
                edited.classification = transform(track.classification)
                try dependencies.updateClassification(track.id, edited.classification)
                updated.append(edited)
            }
            dependencies.applyTrackEdits(updated)
            statusMessage = ""
        } catch {
            // Whatever was written before the failure stays written — reporting
            // it is more honest than pretending the batch was atomic when the
            // rows are already on disk.
            dependencies.applyTrackEdits(updated)
            statusMessage = "Saved \(updated.count) of \(tracks.count): \(error.localizedDescription)"
        }
    }

    // MARK: - Suggestions

    /// Scores untagged tracks against the tracks the user has already tagged.
    ///
    /// Builds proposals only — nothing reaches `track_tags` until
    /// `applySuggestions` is called with the rows the user ticked.
    func buildSuggestions() {
        guard !isBuildingSuggestions else { return }
        isBuildingSuggestions = true
        defer { isBuildingSuggestions = false }

        let tracks = dependencies.allTracks()
        let taggedIDs = Set(tagIndex.tagIDsByTrack.keys)
        let untaggedIDs = tracks.map(\.id).filter { !taggedIDs.contains($0) }

        do {
            // Only the tracks that matter: the tagged ones teach, the untagged
            // ones are scored. Loading the whole library's vectors would be far
            // more work for the same answer.
            let embeddings = try dependencies.loadTrackEmbeddings(taggedIDs.union(untaggedIDs))

            if let blocked = ClassificationSuggestionEngine.unavailability(
                tagAssignments: tagIndex.tagIDsByTrack,
                embeddings: embeddings
            ) {
                suggestions = []
                statusMessage = blocked.message
                return
            }

            let centroids = ClassificationSuggestionEngine.centroids(
                tagAssignments: tagIndex.tagIDsByTrack,
                embeddings: embeddings
            )
            suggestions = ClassificationSuggestionEngine.suggest(
                candidates: untaggedIDs,
                embeddings: embeddings,
                centroids: centroids,
                existingAssignments: tagIndex.tagIDsByTrack
            )
            statusMessage = ""
            isSuggestionSheetPresented = true
        } catch {
            suggestions = []
            statusMessage = "Could not read the analysed audio: \(error.localizedDescription)"
        }
    }

    /// Writes only what the user accepted.
    ///
    /// The assignments are recorded with `.soriaAnalysis` as their source, so a
    /// tag Soria proposed is distinguishable later from one the user typed.
    func applySuggestions(_ accepted: [ClassificationSuggestionEngine.Suggestion]) {
        guard !accepted.isEmpty else {
            isSuggestionSheetPresented = false
            return
        }

        var trackIDsByTag: [UUID: [UUID]] = [:]
        for suggestion in accepted {
            for scored in suggestion.tags {
                trackIDsByTag[scored.tagID, default: []].append(suggestion.trackID)
            }
        }

        var applied = 0
        var updatedIndex = tagIndex
        do {
            for (tagID, trackIDs) in trackIDsByTag {
                try dependencies.assignTag(tagID, trackIDs)
                updatedIndex = updatedIndex.applying(tagID: tagID, to: trackIDs)
                applied += trackIDs.count
            }
            tagIndex = updatedIndex
            statusMessage = "Applied \(applied) \(applied == 1 ? "tag" : "tags")."
        } catch {
            // Partial writes are already on disk; the index is updated to match
            // what actually landed rather than what was requested.
            tagIndex = updatedIndex
            statusMessage = "Applied \(applied) before failing: \(error.localizedDescription)"
        }

        suggestions = []
        isSuggestionSheetPresented = false
    }

    func dismissSuggestions() {
        suggestions = []
        isSuggestionSheetPresented = false
    }

    // MARK: - Filter helpers

    func clearClassificationFilter() {
        classificationFilter = LibraryClassificationFilter()
    }

    func toggleFilterTag(_ tagID: UUID) {
        if classificationFilter.tagIDs.contains(tagID) {
            classificationFilter.tagIDs.remove(tagID)
        } else {
            classificationFilter.tagIDs.insert(tagID)
        }
    }

    func toggleFilterColor(_ color: TrackColorLabel) {
        if classificationFilter.colorLabels.contains(color) {
            classificationFilter.colorLabels.remove(color)
        } else {
            classificationFilter.colorLabels.insert(color)
        }
    }

    func toggleFilterKey(_ key: CamelotKey) {
        if classificationFilter.camelotNotations.contains(key.notation) {
            classificationFilter.camelotNotations.remove(key.notation)
        } else {
            classificationFilter.camelotNotations.insert(key.notation)
        }
    }
}
