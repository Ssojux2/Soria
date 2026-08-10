import Foundation
import Testing

@testable import Soria

/// Rating, energy, colour, and — the part that actually matters — which source
/// wins when two of them disagree.
///
/// The arbitration tests are the point of this suite. Soria imports ratings and
/// colours from Serato and rekordbox on every sync, and infers energy from its
/// own analysis. If any of those can overwrite a value the user typed, the user
/// loses work silently, which is the worst possible failure for a tool whose job
/// is remembering how you classified five thousand tracks.
struct TrackClassificationTests {
    // MARK: - Rating

    @Test
    func ratingClampsInsteadOfRefusingOutOfRangeInput() {
        #expect(TrackRating(3).stars == 3)
        #expect(TrackRating(-2).stars == 0)
        // Refusing a track because its stored rating is 9 would be worse than
        // storing 5 — vendor libraries genuinely contain values like this.
        #expect(TrackRating(9).stars == 5)
    }

    @Test
    func vendorRatingsOnBothScalesNormalizeToStars() {
        // Serato writes 0-5 directly.
        #expect(TrackRating(vendorValue: 4).stars == 4)
        // rekordbox writes 0-255 in steps of 51.
        #expect(TrackRating(vendorValue: 255).stars == 5)
        #expect(TrackRating(vendorValue: 204).stars == 4)
        #expect(TrackRating(vendorValue: 51).stars == 1)
        #expect(TrackRating(vendorValue: 0).stars == 0)
    }

    @Test
    func zeroStarsMeansUnratedNotRatedZero() {
        #expect(TrackRating(0).isUnrated)
        #expect(!TrackRating(1).isUnrated)
    }

    // MARK: - Energy

    @Test
    func energyClampsToTheMixedInKeyScale() {
        #expect(TrackEnergy(7).level == 7)
        #expect(TrackEnergy(0).level == 1)
        #expect(TrackEnergy(99).level == 10)
    }

    @Test
    func energyIsDerivedFromTheMeanOfTheArcNotItsPeak() throws {
        // A track that spikes to full energy once but sits low otherwise. Using
        // the peak would score this 10 and, since nearly every dance track peaks
        // near 1.0 somewhere, would flatten the whole library to 9s and 10s.
        let spiky = try #require(TrackEnergy(energyArc: [0.1, 0.2, 1.0, 0.1, 0.1]))
        #expect(spiky.level == 3)

        let sustained = try #require(TrackEnergy(energyArc: [0.8, 0.9, 0.85, 0.85]))
        #expect(sustained.level == 9)
    }

    @Test
    func energyIsNilForAnUnanalyzedTrack() {
        // Storing a default here would claim knowledge the analysis never
        // produced, and the Library would filter on it as if it were real.
        #expect(TrackEnergy(energyArc: []) == nil)
        #expect(TrackEnergy(energyArc: [.nan, .infinity]) == nil)
    }

    // MARK: - Colour

    @Test
    func vendorColoursSnapToTheNearestPaletteEntry() {
        // Neither vendor writes Soria's reference values verbatim, so exact
        // matching would drop every colour the user already set.
        #expect(TrackColorLabel.nearest(toHex: "#FF0000") == .red)
        #expect(TrackColorLabel.nearest(toHex: "0000FF") == .blue)
        #expect(TrackColorLabel.nearest(toHex: "#FFEE33") == .yellow)
        #expect(TrackColorLabel.nearest(toHex: "#2ECC71") == .green)
    }

    @Test
    func malformedColourStringsAreRejectedRatherThanGuessed() {
        #expect(TrackColorLabel.nearest(toHex: "") == nil)
        #expect(TrackColorLabel.nearest(toHex: "#GGGGGG") == nil)
        #expect(TrackColorLabel.nearest(toHex: "#FFF") == nil)
    }

    // MARK: - Source arbitration

    @Test
    func aUserRatingSurvivesALaterVendorImport() {
        let userSet = TrackClassification().settingUserRating(TrackRating(5))
        #expect(userSet.ratingSource == .user)

        let afterSync = userSet.mergingVendor(
            rating: TrackRating(2),
            colorLabel: .blue,
            from: .serato
        )

        // This is the whole reason each field carries its own source.
        #expect(afterSync.rating == TrackRating(5))
        #expect(afterSync.ratingSource == .user)
        // The colour was never user-set, so the import is free to fill it in.
        #expect(afterSync.colorLabel == .blue)
        #expect(afterSync.colorSource == .serato)
    }

    @Test
    func vendorValuesFillEmptyFieldsAndHigherPrioritySourcesWin() {
        let empty = TrackClassification()

        let seeded = empty.mergingVendor(rating: TrackRating(3), colorLabel: .aqua, from: .rekordbox)
        #expect(seeded.rating == TrackRating(3))
        #expect(seeded.ratingSource == .rekordbox)

        // Serato and rekordbox share a priority, so a second vendor does not
        // get to flip a value the first one already set.
        let secondVendor = seeded.mergingVendor(rating: TrackRating(1), colorLabel: nil, from: .serato)
        #expect(secondVendor.rating == TrackRating(3))
        #expect(secondVendor.ratingSource == .rekordbox)
    }

    @Test
    func userOutranksEverySourceIncludingSoriasOwnAnalysis() {
        #expect(TrackMetadataSource.user.priority > TrackMetadataSource.soriaAnalysis.priority)
        #expect(TrackMetadataSource.soriaAnalysis.priority > TrackMetadataSource.serato.priority)
        #expect(TrackMetadataSource.serato.priority == TrackMetadataSource.rekordbox.priority)
        #expect(TrackMetadataSource.rekordbox.priority > TrackMetadataSource.audioTags.priority)
        #expect(TrackMetadataSource.audioTags.priority > TrackMetadataSource.unknown.priority)
    }

    @Test
    func clearingAFieldClearsItsSourceToo() {
        let rated = TrackClassification().settingUserRating(TrackRating(4))
        let cleared = rated.settingUserRating(nil)

        // A dangling `.user` source on an empty field would make the next vendor
        // import think a user value was there and refuse to fill it in.
        #expect(cleared.rating == nil)
        #expect(cleared.ratingSource == nil)
    }

    @Test
    func settingEnergyAndColourRecordsTheUserAsTheSource() {
        let classified = TrackClassification()
            .settingUserEnergy(TrackEnergy(8))
            .settingUserColorLabel(.purple)

        #expect(classified.energy == TrackEnergy(8))
        #expect(classified.energySource == .user)
        #expect(classified.colorLabel == .purple)
        #expect(classified.colorSource == .user)
    }

    // MARK: - Inbox

    @Test
    func unclassifiedMeansNoRatingNoEnergyAndNoColour() {
        #expect(TrackClassification().isUnclassified)
        // An explicit zero-star rating is still "unrated", matching the vendors.
        #expect(TrackClassification(rating: TrackRating(0)).isUnclassified)

        #expect(!TrackClassification(rating: TrackRating(1)).isUnclassified)
        #expect(!TrackClassification(energy: TrackEnergy(5)).isUnclassified)
        #expect(!TrackClassification(colorLabel: .green).isUnclassified)
    }

    @Test
    func genreFamilyRidesAlongWithoutAffectingTheInboxTest() {
        // The genre family is inferred by analysis, not chosen by the user, so a
        // track that only has one has still not been classified by anybody.
        let inferred = TrackClassification(genreFamilyID: "house", genreFamilyScore: 0.91)
        #expect(inferred.isUnclassified)
        #expect(inferred.genreFamilyID == "house")
    }
}
