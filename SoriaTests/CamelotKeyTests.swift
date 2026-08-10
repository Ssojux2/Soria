import Foundation
import Testing

@testable import Soria

/// Key normalization.
///
/// Worth this much coverage because the wheel mapping is a lookup table nobody
/// can eyeball, and a single wrong entry sends a DJ into a set with two tracks
/// that clash. The library's key column arrives from three sources in at least
/// three notations, so every one of them has to land on the same value.
struct CamelotKeyTests {
    private func notation(_ raw: String) -> String? {
        CamelotKey(raw)?.notation
    }

    @Test
    func theWholeWheelMapsFromMinorNoteNames() {
        #expect(notation("Abm") == "1A")
        #expect(notation("Ebm") == "2A")
        #expect(notation("Bbm") == "3A")
        #expect(notation("Fm") == "4A")
        #expect(notation("Cm") == "5A")
        #expect(notation("Gm") == "6A")
        #expect(notation("Dm") == "7A")
        #expect(notation("Am") == "8A")
        #expect(notation("Em") == "9A")
        #expect(notation("Bm") == "10A")
        #expect(notation("F#m") == "11A")
        #expect(notation("Dbm") == "12A")
    }

    @Test
    func theWholeWheelMapsFromMajorNoteNames() {
        #expect(notation("B") == "1B")
        #expect(notation("F#") == "2B")
        #expect(notation("Db") == "3B")
        #expect(notation("Ab") == "4B")
        #expect(notation("Eb") == "5B")
        #expect(notation("Bb") == "6B")
        #expect(notation("F") == "7B")
        #expect(notation("C") == "8B")
        #expect(notation("G") == "9B")
        #expect(notation("D") == "10B")
        #expect(notation("A") == "11B")
        #expect(notation("E") == "12B")
    }

    @Test
    func enharmonicSpellingsLandOnTheSameKey() {
        // Serato and rekordbox disagree about sharps and flats for the same track.
        #expect(notation("G#m") == notation("Abm"))
        #expect(notation("A#m") == notation("Bbm"))
        #expect(notation("C#m") == notation("Dbm"))
        #expect(notation("Gb") == notation("F#"))
        #expect(notation("C#") == notation("Db"))
    }

    @Test
    func camelotNotationSurvivesItsOwnRoundTrip() {
        // Serato can be configured to write Camelot directly, so the parser has
        // to accept what it produces.
        #expect(notation("8A") == "8A")
        #expect(notation("12B") == "12B")
        #expect(notation("08a") == "8A")
        #expect(notation(" 3b ") == "3B")
    }

    @Test
    func openKeyNotationIsRotatedOntoTheCamelotWheel() {
        // Open Key 1 is Camelot 8; the two wheels are seven steps apart, which is
        // exactly the sort of thing raw string comparison gets wrong.
        #expect(notation("1d") == "8B")
        #expect(notation("1m") == "8A")
        #expect(notation("2d") == "9B")
        #expect(notation("5d") == "12B")
        #expect(notation("6d") == "1B")
        #expect(notation("12m") == "7A")
    }

    @Test
    func spelledOutModesAreAccepted() {
        #expect(notation("A minor") == "8A")
        #expect(notation("A min") == "8A")
        #expect(notation("F# minor") == "11A")
        #expect(notation("C major") == "8B")
        #expect(notation("C maj") == "8B")
    }

    @Test
    func unreadableKeysAreRejectedRatherThanGuessed() {
        // A wrong key is worse than a missing one — the user mixes on it.
        #expect(CamelotKey(nil) == nil)
        #expect(CamelotKey("") == nil)
        #expect(CamelotKey("   ") == nil)
        #expect(CamelotKey("13A") == nil)
        #expect(CamelotKey("0A") == nil)
        #expect(CamelotKey("H") == nil)
        #expect(CamelotKey("unknown") == nil)
    }

    @Test
    func everyWheelPositionIsRepresentedExactlyOnce() {
        #expect(CamelotKey.all.count == 24)
        #expect(Set(CamelotKey.all.map(\.notation)).count == 24)
    }

    // MARK: - Harmonic mixing

    @Test
    func compatibleKeysAreTheNeighboursAndTheRelativeMode() throws {
        let eightA = try #require(CamelotKey("8A"))
        let compatible = Set(eightA.compatibleKeys.map(\.notation))

        #expect(compatible == ["8A", "9A", "7A", "8B"])
    }

    @Test
    func theWheelWrapsAtBothEnds() throws {
        let one = try #require(CamelotKey("1A"))
        #expect(Set(one.compatibleKeys.map(\.notation)) == ["1A", "2A", "12A", "1B"])

        let twelve = try #require(CamelotKey("12B"))
        #expect(Set(twelve.compatibleKeys.map(\.notation)) == ["12B", "1B", "11B", "12A"])
    }

    @Test
    func compatibilityIsSymmetric() throws {
        // If 8A mixes into 9A then 9A has to mix back, or a filter built from one
        // direction quietly disagrees with a filter built from the other.
        for key in CamelotKey.all {
            for neighbour in key.compatibleKeys {
                #expect(neighbour.compatibleKeys.contains(key))
            }
        }
    }
}
