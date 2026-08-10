import Foundation
import Testing

@testable import Soria

/// Sorting the Library table.
///
/// This suite exists because the sort logic used to be written twice — once in
/// `LibraryTrackSortComparator` for the table header and once in
/// `AppViewModel.compareLibraryTracks` for `filteredTracks` — and adding a column
/// to one but not the other would have produced two silently different orderings
/// of the same list. The duplicate is gone and `sortLibraryTracks` now drives the
/// comparator below, so these tests cover the one remaining implementation.
struct LibrarySortTests {
    private func track(
        title: String = "Track",
        artist: String = "Artist",
        bpm: Double? = nil,
        rating: Int? = nil,
        energy: Int? = nil,
        color: TrackColorLabel? = nil
    ) -> Track {
        var made = Track.empty(path: "/Music/\(title).aiff", modifiedTime: Date(), hash: "hash")
        made.title = title
        made.artist = artist
        made.bpm = bpm
        made.classification = TrackClassification(
            rating: rating.map { TrackRating($0) },
            energy: energy.map { TrackEnergy($0) },
            colorLabel: color
        )
        return made
    }

    private func sortedTitles(
        _ tracks: [Track],
        by column: LibraryTrackSortColumn,
        order: SortOrder = .forward
    ) -> [String] {
        let comparator = LibraryTrackSortComparator(column: column, order: order)
        return tracks.sorted { comparator.compare($0, $1) == .orderedAscending }.map(\.title)
    }

    @Test
    func ratingSortsLowToHighAndBackAgain() {
        let tracks = [
            track(title: "Three", rating: 3),
            track(title: "Five", rating: 5),
            track(title: "One", rating: 1)
        ]

        #expect(sortedTitles(tracks, by: .rating) == ["One", "Three", "Five"])
        #expect(sortedTitles(tracks, by: .rating, order: .reverse) == ["Five", "Three", "One"])
    }

    @Test
    func unratedTracksSinkInBothDirections() {
        let tracks = [
            track(title: "Unrated"),
            track(title: "Four", rating: 4),
            track(title: "Two", rating: 2)
        ]

        // Reversing the column should bring the best tracks to the top, not float
        // a thousand unrated ones there.
        #expect(sortedTitles(tracks, by: .rating) == ["Two", "Four", "Unrated"])
        #expect(sortedTitles(tracks, by: .rating, order: .reverse) == ["Four", "Two", "Unrated"])
    }

    @Test
    func energyFollowsTheSameRuleAsRating() {
        let tracks = [
            track(title: "Unanalyzed"),
            track(title: "Nine", energy: 9),
            track(title: "Four", energy: 4)
        ]

        #expect(sortedTitles(tracks, by: .energy) == ["Four", "Nine", "Unanalyzed"])
        #expect(sortedTitles(tracks, by: .energy, order: .reverse) == ["Nine", "Four", "Unanalyzed"])
    }

    @Test
    func colourSortsAroundThePaletteNotAlphabetically() {
        let tracks = [
            track(title: "Blue", color: .blue),
            track(title: "Pink", color: .pink),
            track(title: "Green", color: .green)
        ]

        // Alphabetically this would be Blue, Green, Pink. The swatches are shown in
        // wheel order, so the sort has to group them the way the eye reads them.
        #expect(sortedTitles(tracks, by: .colorLabel) == ["Pink", "Green", "Blue"])
    }

    @Test
    func uncolouredTracksSinkToo() {
        let tracks = [
            track(title: "None"),
            track(title: "Red", color: .red)
        ]

        #expect(sortedTitles(tracks, by: .colorLabel) == ["Red", "None"])
        #expect(sortedTitles(tracks, by: .colorLabel, order: .reverse) == ["Red", "None"])
    }

    @Test
    func bpmKeepsItsExistingNilHandling() {
        // The pre-existing rule the new columns were modelled on, pinned so a
        // refactor of the shared optional comparison cannot quietly change it.
        let tracks = [
            track(title: "NoBPM"),
            track(title: "Fast", bpm: 130),
            track(title: "Slow", bpm: 118)
        ]

        #expect(sortedTitles(tracks, by: .bpm) == ["Slow", "Fast", "NoBPM"])
        #expect(sortedTitles(tracks, by: .bpm, order: .reverse) == ["Fast", "Slow", "NoBPM"])
    }

    @Test
    func textColumnsUseLocaleAwareComparison() {
        let tracks = [
            track(title: "track 10"),
            track(title: "track 9"),
            track(title: "Track 2")
        ]

        // `localizedStandardCompare` orders embedded numbers numerically, which is
        // why "track 9" comes before "track 10".
        #expect(sortedTitles(tracks, by: .title) == ["Track 2", "track 9", "track 10"])
    }

    @Test
    func everySortColumnActuallyOrdersSomething() {
        var first = track(title: "A", artist: "A Artist", bpm: 118, rating: 1, energy: 1, color: .pink)
        first.genre = "Ambient"
        first.comment = "A comment"

        var second = track(title: "B", artist: "B Artist", bpm: 130, rating: 5, energy: 9, color: .purple)
        second.genre = "Breaks"
        second.comment = "B comment"

        let statusValues = [first.id: "Needs prep", second.id: "Ready"]

        // A column that fell through to a default would report everything equal;
        // this catches a case being added to the enum but not to the comparator.
        for column in [LibraryTrackSortColumn.title, .artist, .genre, .comment, .bpm, .rating, .energy, .colorLabel] {
            let comparator = LibraryTrackSortComparator(column: column)
            #expect(comparator.compare(first, second) == .orderedAscending, "\(column.rawValue) did not order")
        }

        let statusComparator = LibraryTrackSortComparator(column: .status, statusValues: statusValues)
        #expect(statusComparator.compare(first, second) == .orderedAscending)
    }
}
