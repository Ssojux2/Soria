import Foundation
import Testing

@testable import Soria

/// The user's tag vocabulary and its assignments.
///
/// Two things are load-bearing here. The four-category cap is what keeps an
/// export to rekordbox lossless, and it is enforced by `TagCategorySlot` having
/// four cases rather than by a runtime check — these tests confirm that holds
/// even when the database hands back garbage. The other is the three-state
/// selection: a tag that half a selection carries must not render as "off",
/// because clicking an off checkbox would wipe the tags from the half that had it.
struct TagCatalogTests {
    // MARK: - Categories

    @Test
    func aFreshCatalogHasExactlyFourNamedCategoriesAndNoTags() {
        let catalog = TagCatalog.empty

        #expect(catalog.categories.count == 4)
        #expect(catalog.categories.map(\.name) == ["Vibe", "Situation", "Element", "Custom"])
        // No starter tags: shipping a vocabulary would bias how the user
        // classifies before they have listened to anything.
        #expect(catalog.isEmpty)
    }

    @Test
    func missingSlotsAreFilledInWhenReadingFromTheDatabase() {
        // The tag tables arrive by migration on an existing library, so a partial
        // read has to produce a usable catalog rather than a crash.
        let partial = TagCatalog(
            categories: [TagCategory(slot: .two, name: "Room")],
            tags: []
        )

        #expect(partial.categories.count == 4)
        #expect(partial.category(.two).name == "Room")
        #expect(partial.category(.one).name == "Vibe")
    }

    @Test
    func renamingACategoryKeepsItsSlot() throws {
        let renamed = try TagCatalog.empty.renamingCategory(.one, to: "  Mood  ")

        #expect(renamed.category(.one).name == "Mood")
        #expect(renamed.categories.count == 4)
    }

    @Test
    func aCategoryCannotBeRenamedToNothing() {
        #expect(throws: TagCatalogError.emptyName) {
            try TagCatalog.empty.renamingCategory(.one, to: "   ")
        }
    }

    // MARK: - Tags

    @Test
    func addingATagPlacesItInItsCategory() throws {
        let (catalog, tag) = try TagCatalog.empty.addingTag(named: "Peak Time", to: .two)

        #expect(tag.name == "Peak Time")
        #expect(tag.slot == .two)
        #expect(catalog.tags(in: .two).map(\.name) == ["Peak Time"])
        #expect(catalog.tags(in: .one).isEmpty)
    }

    @Test
    func duplicateTagNamesAreRejectedRegardlessOfCaseOrSpacing() throws {
        let (catalog, _) = try TagCatalog.empty.addingTag(named: "Peak Time", to: .two)

        // "Peak Time", "peak time" and "peak  time" are one tag to the person
        // typing them; letting all three in makes the filter useless.
        #expect(throws: TagCatalogError.duplicateName(slot: .two, name: "peak  time")) {
            try catalog.addingTag(named: "peak  time", to: .two)
        }
    }

    @Test
    func theSameNameIsAllowedInADifferentCategory() throws {
        let (first, _) = try TagCatalog.empty.addingTag(named: "Dark", to: .one)
        let (second, _) = try first.addingTag(named: "Dark", to: .three)

        #expect(second.tags(in: .one).count == 1)
        #expect(second.tags(in: .three).count == 1)
    }

    @Test
    func aCategoryFillsUpAtTheRekordboxLimit() throws {
        var catalog = TagCatalog.empty
        for index in 0..<TagCatalog.maximumTagsPerCategory {
            catalog = try catalog.addingTag(named: "Tag \(index)", to: .four).catalog
        }

        #expect(catalog.tags(in: .four).count == 50)
        #expect(
            throws: TagCatalogError.categoryFull(slot: .four, limit: 50)
        ) {
            try catalog.addingTag(named: "One too many", to: .four)
        }
    }

    @Test
    func blankTagNamesAreRejected() {
        #expect(throws: TagCatalogError.emptyName) {
            try TagCatalog.empty.addingTag(named: "\n  ", to: .one)
        }
    }

    @Test
    func renamingATagCannotCollideWithASiblingButCanKeepItsOwnName() throws {
        let (withWarm, warm) = try TagCatalog.empty.addingTag(named: "Warm", to: .one)
        let (withBoth, _) = try withWarm.addingTag(named: "Dark", to: .one)

        #expect(throws: TagCatalogError.duplicateName(slot: .one, name: "Dark")) {
            try withBoth.renamingTag(id: warm.id, to: "Dark")
        }

        // Renaming a tag to the name it already has must not trip the collision
        // check against itself.
        let unchanged = try withBoth.renamingTag(id: warm.id, to: "Warm")
        #expect(unchanged.tag(id: warm.id)?.name == "Warm")

        let renamed = try withBoth.renamingTag(id: warm.id, to: "Warmup")
        #expect(renamed.tag(id: warm.id)?.name == "Warmup")
    }

    @Test
    func operatingOnAnUnknownTagIsAnError() {
        let missing = UUID()

        #expect(throws: TagCatalogError.unknownTag(id: missing)) {
            try TagCatalog.empty.removingTag(id: missing)
        }
        #expect(throws: TagCatalogError.unknownTag(id: missing)) {
            try TagCatalog.empty.renamingTag(id: missing, to: "Anything")
        }
    }

    @Test
    func removingATagLeavesTheOtherCategoriesAlone() throws {
        let (withVibe, vibe) = try TagCatalog.empty.addingTag(named: "Warm", to: .one)
        let (both, _) = try withVibe.addingTag(named: "Closing", to: .two)

        let pruned = try both.removingTag(id: vibe.id)

        #expect(pruned.tags(in: .one).isEmpty)
        #expect(pruned.tags(in: .two).count == 1)
        #expect(pruned.categories.count == 4)
    }

    // MARK: - Assignments

    @Test
    func selectionStateDistinguishesPartialFromNone() {
        let tagID = UUID()
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let index = TrackTagIndex().applying(tagID: tagID, to: [first, second])

        #expect(index.selectionState(for: tagID, across: [first, second]) == .all)
        // The case that matters: rendering this as "off" and letting a click
        // clear it would strip the tag from the two tracks that had it.
        #expect(index.selectionState(for: tagID, across: [first, second, third]) == .partial)
        #expect(index.selectionState(for: tagID, across: [third]) == .none)
        #expect(index.selectionState(for: tagID, across: []) == .none)
    }

    @Test
    func applyingAndRemovingTagsAcrossASelection() {
        let tagID = UUID()
        let trackA = UUID()
        let trackB = UUID()

        let applied = TrackTagIndex().applying(tagID: tagID, to: [trackA, trackB])
        #expect(applied.tagIDs(for: trackA) == [tagID])
        #expect(applied.trackIDs(carrying: tagID) == [trackA, trackB])

        let removed = applied.removing(tagID: tagID, from: [trackA])
        #expect(removed.isUntagged(trackA))
        #expect(removed.hasTag(tagID, on: trackB))
    }

    @Test
    func deletingATagDropsItFromEveryTrack() {
        let doomed = UUID()
        let kept = UUID()
        let trackA = UUID()
        let trackB = UUID()

        let index = TrackTagIndex()
            .applying(tagID: doomed, to: [trackA, trackB])
            .applying(tagID: kept, to: [trackA])

        let pruned = index.removingTagEverywhere(doomed)

        #expect(pruned.trackIDs(carrying: doomed).isEmpty)
        #expect(pruned.tagIDs(for: trackA) == [kept])
        #expect(pruned.isUntagged(trackB))
    }

    @Test
    func tracksWithNoTagsLeftAreNotKeptAsEmptyEntries() {
        let tagID = UUID()
        let trackID = UUID()

        let index = TrackTagIndex()
            .applying(tagID: tagID, to: [trackID])
            .removing(tagID: tagID, from: [trackID])

        // An empty set left behind would make the Inbox count wrong: the track
        // would look like it had been tagged at some point and stay out of it.
        #expect(index.tagIDsByTrack.isEmpty)
        #expect(index.isUntagged(trackID))
    }
}
