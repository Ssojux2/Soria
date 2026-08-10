import Foundation
import Testing

@testable import Soria

/// The crate tree and the classification filter — the two pure pieces the
/// redesigned Library pane is built on.
struct LibraryBrowserTests {
    // MARK: - Helpers

    private func collection(
        _ name: String,
        id: UUID = UUID(),
        parent: UUID? = nil,
        kind: SoriaCollection.Kind = .organizedFolder,
        sortIndex: Int = 0
    ) -> SoriaCollection {
        SoriaCollection(id: id, parentID: parent, name: name, kind: kind, sortIndex: sortIndex)
    }

    private func track(
        bpm: Double? = nil,
        key: String? = nil,
        classification: TrackClassification = TrackClassification()
    ) -> Track {
        var made = Track.empty(path: "/Music/\(UUID().uuidString).aiff", modifiedTime: Date(), hash: "hash")
        made.bpm = bpm
        made.musicalKey = key
        made.classification = classification
        return made
    }

    private func sections(_ context: CrateTreeContext) -> [CrateTreeSection] {
        LibraryCrateTree.makeSections(from: context)
    }

    private func section(_ id: String, in context: CrateTreeContext) -> CrateTreeSection? {
        sections(context).first { $0.id == id }
    }

    // MARK: - Fixed library scopes

    @Test
    func theLibrarySectionAlwaysOffersAllTracks() {
        var context = CrateTreeContext()
        context.totalTrackCount = 5_004

        let library = section("library", in: context)
        #expect(library?.nodes.map(\.title) == ["All Tracks"])
        #expect(library?.nodes.first?.trackCount == 5_004)
    }

    @Test
    func emptyScopesAreHiddenRatherThanShownAtZero() {
        var context = CrateTreeContext()
        context.totalTrackCount = 100
        context.inboxTrackCount = 0
        context.needsPreparationCount = 0

        // An Inbox that permanently reads 0 is a standing reminder of nothing.
        #expect(section("library", in: context)?.nodes.count == 1)

        context.inboxTrackCount = 12
        context.needsPreparationCount = 40
        #expect(section("library", in: context)?.nodes.map(\.title) == ["All Tracks", "Inbox", "Needs Prep"])
    }

    @Test
    func maintenanceAlwaysCarriesTrashEvenWhenEmpty() {
        // Unlike Inbox this one stays: it is where things go, so it has to be
        // findable before there is anything in it.
        let maintenance = section("maintenance", in: CrateTreeContext())
        #expect(maintenance?.nodes.first?.selection == .trash)
        #expect(maintenance?.nodes.first?.trackCount == 0)
    }

    // MARK: - Soria folders

    @Test
    func collectionsNestByParentIdentifier() {
        let houseID = UUID()
        var context = CrateTreeContext()
        context.collections = [
            collection("Cluster 01", parent: houseID, sortIndex: 0),
            collection("House", id: houseID, kind: .group),
            collection("Cluster 02", parent: houseID, sortIndex: 1)
        ]

        let roots = section("soria-folders", in: context)?.nodes ?? []
        #expect(roots.count == 1)
        #expect(roots.first?.title == "House")
        #expect(roots.first?.depth == 0)
        #expect(roots.first?.children.map(\.title) == ["Cluster 01", "Cluster 02"])
        #expect(roots.first?.children.allSatisfy { $0.depth == 1 } == true)
    }

    @Test
    func countsRollUpSoACollapsedFolderStillReportsWhatIsUnderIt() {
        let houseID = UUID()
        let clusterOne = UUID()
        let clusterTwo = UUID()

        var context = CrateTreeContext()
        context.collections = [
            collection("House", id: houseID, kind: .group),
            collection("Cluster 01", id: clusterOne, parent: houseID),
            collection("Cluster 02", id: clusterTwo, parent: houseID)
        ]
        context.trackCountsByCollectionID = [clusterOne: 34, clusterTwo: 28]

        let house = section("soria-folders", in: context)?.nodes.first
        #expect(house?.trackCount == 62)
    }

    @Test
    func containerNodesContributeNoTracksOfTheirOwn() {
        let groupID = UUID()
        var context = CrateTreeContext()
        context.collections = [collection("House", id: groupID, kind: .group)]
        // A stale direct count on a pure container must not be double counted
        // against the children that actually hold the tracks.
        context.trackCountsByCollectionID = [groupID: 999]

        #expect(section("soria-folders", in: context)?.nodes.first?.trackCount == 0)
    }

    @Test
    func aCollectionWhoseParentIsGoneIsReRootedNotDropped() {
        var context = CrateTreeContext()
        context.collections = [collection("Orphan", parent: UUID())]

        // Hiding it would leave the user with tracks they cannot navigate to.
        let roots = section("soria-folders", in: context)?.nodes ?? []
        #expect(roots.map(\.title) == ["Orphan"])
        #expect(roots.first?.depth == 0)
    }

    @Test
    func aCycleTerminatesInsteadOfHangingTheRenderLoop() {
        let first = UUID()
        let second = UUID()
        var context = CrateTreeContext()
        // The schema permits this even though the app never writes it.
        context.collections = [
            collection("First", id: first, parent: second),
            collection("Second", id: second, parent: first)
        ]

        let roots = section("soria-folders", in: context)?.nodes ?? []
        #expect(roots.isEmpty || roots.allSatisfy { $0.flattened.count < 10 })
    }

    @Test
    func theFolderSectionDisappearsWhenNothingHasBeenOrganizedYet() {
        #expect(section("soria-folders", in: CrateTreeContext()) == nil)
    }

    @Test
    func siblingsSortBySortIndexThenName() {
        var context = CrateTreeContext()
        context.collections = [
            collection("Zebra", sortIndex: 0),
            collection("Alpha", sortIndex: 1),
            collection("Beta", sortIndex: 0)
        ]

        #expect(section("soria-folders", in: context)?.nodes.map(\.title) == ["Beta", "Zebra", "Alpha"])
    }

    // MARK: - Vendor references

    @Test
    func vendorCratesNestUnderOneNodePerSource() {
        var context = CrateTreeContext()
        context.seratoFacets = [
            MembershipFacet(source: .serato, membershipPath: "Gigs", displayName: "Gigs", parentPath: nil, depth: 0, trackCount: 120),
            MembershipFacet(source: .serato, membershipPath: "Gigs/June", displayName: "June", parentPath: "Gigs", depth: 1, trackCount: 40)
        ]

        let references = section("references", in: context)?.nodes ?? []
        #expect(references.count == 1)
        #expect(references.first?.title == "Serato")
        #expect(references.first?.children.map(\.title) == ["Gigs"])
        #expect(references.first?.children.first?.children.map(\.title) == ["June"])
    }

    @Test
    func aVendorCrateWhoseParentIsMissingStillAppears() {
        var context = CrateTreeContext()
        context.rekordboxFacets = [
            MembershipFacet(
                source: .rekordbox,
                membershipPath: "Deleted/Child",
                displayName: "Child",
                parentPath: "Deleted",
                depth: 1,
                trackCount: 5
            )
        ]

        let rekordbox = section("references", in: context)?.nodes.first
        #expect(rekordbox?.children.map(\.title) == ["Child"])
    }

    @Test
    func theReferencesSectionIsAbsentWithoutAConnectedVendorLibrary() {
        #expect(section("references", in: CrateTreeContext()) == nil)
    }

    // MARK: - Classification filter

    @Test
    func anEmptyFilterAdmitsEverything() {
        let filter = LibraryClassificationFilter()

        #expect(filter.isEmpty)
        #expect(filter.activeConstraintCount == 0)
        #expect(filter.matches(track(), tagIDs: []))
    }

    @Test
    func bpmAndRatingConstraintsCompose() {
        var filter = LibraryClassificationFilter()
        filter.minimumBPM = 124
        filter.maximumBPM = 128
        filter.minimumRating = 4

        #expect(filter.activeConstraintCount == 2)

        let match = track(bpm: 126, classification: TrackClassification(rating: TrackRating(5)))
        #expect(filter.matches(match, tagIDs: []))

        let tooSlow = track(bpm: 118, classification: TrackClassification(rating: TrackRating(5)))
        #expect(!filter.matches(tooSlow, tagIDs: []))

        let tooLowRated = track(bpm: 126, classification: TrackClassification(rating: TrackRating(2)))
        #expect(!filter.matches(tooLowRated, tagIDs: []))
    }

    @Test
    func aTrackWithNoValueFailsAConstraintOnThatValue() {
        var filter = LibraryClassificationFilter()
        filter.minimumBPM = 120

        // "We don't know its BPM" is not an answer the user can mix on, so an
        // unanalysed track drops out rather than slipping through.
        #expect(!filter.matches(track(bpm: nil), tagIDs: []))
    }

    @Test
    func keyFilteringWorksAcrossNotations() {
        var filter = LibraryClassificationFilter()
        filter.camelotNotations = ["8A"]

        #expect(filter.matches(track(key: "8A"), tagIDs: []))
        // Same key, different notation — this is why the filter normalizes.
        #expect(filter.matches(track(key: "Am"), tagIDs: []))
        #expect(!filter.matches(track(key: "9A"), tagIDs: []))
        #expect(!filter.matches(track(key: nil), tagIDs: []))
    }

    @Test
    func harmonicNeighboursExpandTheKeyFilterWhenAsked() {
        var filter = LibraryClassificationFilter()
        filter.camelotNotations = ["8A"]
        filter.includesHarmonicNeighbours = true

        #expect(filter.admissibleCamelotNotations == ["8A", "9A", "7A", "8B"])
        #expect(filter.matches(track(key: "Em"), tagIDs: []))   // 9A
        #expect(filter.matches(track(key: "C"), tagIDs: []))    // 8B
        #expect(!filter.matches(track(key: "3A"), tagIDs: []))
    }

    @Test
    func tagsMatchAnyByDefaultAndAllOnRequest() {
        let peak = UUID()
        let dark = UUID()

        var filter = LibraryClassificationFilter()
        filter.tagIDs = [peak, dark]

        // Picking two tags almost always means "either", not the handful
        // carrying both.
        #expect(filter.tagMatch == .any)
        #expect(filter.matches(track(), tagIDs: [peak]))

        filter.tagMatch = .all
        #expect(!filter.matches(track(), tagIDs: [peak]))
        #expect(filter.matches(track(), tagIDs: [peak, dark]))
    }

    @Test
    func colourAndGenreFamilyNarrowToTheSelectedValues() {
        var filter = LibraryClassificationFilter()
        filter.colorLabels = [.red, .blue]
        filter.genreFamilyIDs = ["house"]

        let match = track(classification: TrackClassification(colorLabel: .blue, genreFamilyID: "house"))
        #expect(filter.matches(match, tagIDs: []))

        let wrongColour = track(classification: TrackClassification(colorLabel: .green, genreFamilyID: "house"))
        #expect(!filter.matches(wrongColour, tagIDs: []))

        let wrongGenre = track(classification: TrackClassification(colorLabel: .red, genreFamilyID: "techno"))
        #expect(!filter.matches(wrongGenre, tagIDs: []))
    }

    @Test
    func theUnclassifiedFilterRequiresNoTagsAsWellAsNoRating() {
        var filter = LibraryClassificationFilter()
        filter.onlyUnclassified = true

        #expect(filter.matches(track(), tagIDs: []))
        // A tagged track has been classified even if nobody rated it.
        #expect(!filter.matches(track(), tagIDs: [UUID()]))
        #expect(!filter.matches(track(classification: TrackClassification(rating: TrackRating(3))), tagIDs: []))
    }

    @Test
    func aFilterSurvivesSerializationSoItCanBecomeASmartCrate() throws {
        var filter = LibraryClassificationFilter()
        filter.minimumBPM = 124
        filter.maximumBPM = 128
        filter.camelotNotations = ["8A", "9A"]
        filter.includesHarmonicNeighbours = true
        filter.minimumRating = 4
        filter.colorLabels = [.orange]
        filter.tagIDs = [UUID()]
        filter.tagMatch = .all

        let data = try JSONEncoder().encode(filter)
        let restored = try JSONDecoder().decode(LibraryClassificationFilter.self, from: data)

        // Phase 3 turns a filter into a saved crate by serializing it, so this
        // round trip is the feature, not just hygiene.
        #expect(restored == filter)
    }
}
