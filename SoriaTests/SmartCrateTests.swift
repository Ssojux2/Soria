import Foundation
import Testing

@testable import Soria

/// Rule-based crates.
///
/// The evaluator is the whole feature: a smart crate is only worth having if it
/// keeps being correct as the library changes, which means every operator has to
/// behave the same way on the thousandth track as on the first.
struct SmartCrateTests {
    private func track(
        title: String = "Track",
        artist: String = "Artist",
        album: String = "Album",
        genre: String = "",
        comment: String = "",
        bpm: Double? = nil,
        key: String? = nil,
        classification: TrackClassification = TrackClassification()
    ) -> Track {
        var made = Track.empty(path: "/Music/\(title).aiff", modifiedTime: Date(), hash: "hash")
        made.title = title
        made.artist = artist
        made.album = album
        made.genre = genre
        made.comment = comment
        made.bpm = bpm
        made.musicalKey = key
        made.classification = classification
        return made
    }

    private func matches(
        _ rules: [SmartCrateRule],
        match: SmartCrateRuleSet.Match = .all,
        track candidate: Track,
        tagIDs: Set<UUID> = [],
        now: Date = Date()
    ) -> Bool {
        SmartCrateRuleSet(match: match, rules: rules)
            .matches(SmartCrateEvaluationInput(track: candidate, tagIDs: tagIDs, now: now))
    }

    // MARK: - Empty and invalid rule sets

    @Test
    func anEmptyRuleSetMatchesNothing() {
        // A crate the user has not finished defining should look unfinished, not
        // swallow the entire library.
        #expect(!SmartCrateRuleSet().matches(SmartCrateEvaluationInput(track: track())))
    }

    @Test
    func aRuleWhoseOperatorDoesNotApplyToItsFieldIsInvalid() {
        // "BPM contains house" can never be true; catching it as invalid means the
        // builder can say so instead of silently emptying the crate.
        let nonsense = SmartCrateRule(field: .bpm, op: .contains, value: .text("house"))
        #expect(!nonsense.isValid)

        let sensible = SmartCrateRule(field: .bpm, op: .isAtLeast, value: .number(124))
        #expect(sensible.isValid)
    }

    @Test
    func invalidRulesAreSkippedRatherThanFailingTheWholeSet() {
        let candidate = track(artist: "Lower Field")
        let rules = [
            SmartCrateRule(field: .artist, op: .contains, value: .text("Lower")),
            SmartCrateRule(field: .bpm, op: .contains, value: .text("nonsense"))
        ]

        #expect(matches(rules, track: candidate))
    }

    @Test
    func aRuleNeedingAValueIsIncompleteWithoutOne() {
        #expect(!SmartCrateRule(field: .artist, op: .contains, value: .none).isValid)
        // These two are complete by themselves — offering a value box for them
        // would suggest otherwise.
        #expect(SmartCrateRule(field: .artist, op: .isEmpty).isValid)
        #expect(SmartCrateRule(field: .comment, op: .isNotEmpty).isValid)
    }

    // MARK: - Text

    @Test
    func textOperatorsAreCaseInsensitive() {
        let candidate = track(artist: "Lower Field")

        #expect(matches([SmartCrateRule(field: .artist, op: .contains, value: .text("lower"))], track: candidate))
        #expect(matches([SmartCrateRule(field: .artist, op: .is, value: .text("LOWER FIELD"))], track: candidate))
        #expect(matches([SmartCrateRule(field: .artist, op: .doesNotContain, value: .text("kite"))], track: candidate))
        #expect(matches([SmartCrateRule(field: .artist, op: .isNot, value: .text("Kite Season"))], track: candidate))
    }

    @Test
    func emptinessIsTestedOnTrimmedText() {
        let blank = track(comment: "   ")
        #expect(matches([SmartCrateRule(field: .comment, op: .isEmpty)], track: blank))

        let filled = track(comment: "Peak time")
        #expect(matches([SmartCrateRule(field: .comment, op: .isNotEmpty)], track: filled))
    }

    // MARK: - Numbers

    @Test
    func numericComparisonsCoverTheRangeOperators() {
        let candidate = track(bpm: 126)

        #expect(matches([SmartCrateRule(field: .bpm, op: .isAtLeast, value: .number(124))], track: candidate))
        #expect(matches([SmartCrateRule(field: .bpm, op: .isAtMost, value: .number(128))], track: candidate))
        #expect(matches([SmartCrateRule(field: .bpm, op: .between, value: .range(124, 128))], track: candidate))
        #expect(!matches([SmartCrateRule(field: .bpm, op: .between, value: .range(130, 140))], track: candidate))
    }

    @Test
    func aReversedRangeStillWorks() {
        // Typing the higher number into the first box is a slip, not a request for
        // an empty crate.
        let candidate = track(bpm: 126)
        #expect(matches([SmartCrateRule(field: .bpm, op: .between, value: .range(128, 124))], track: candidate))
    }

    @Test
    func aMissingNumberFailsEveryComparison() {
        // "BPM at least 124" must not sweep in every unanalysed track.
        let unanalyzed = track(bpm: nil)
        #expect(!matches([SmartCrateRule(field: .bpm, op: .isAtLeast, value: .number(124))], track: unanalyzed))
        #expect(!matches([SmartCrateRule(field: .bpm, op: .isAtMost, value: .number(200))], track: unanalyzed))
        #expect(matches([SmartCrateRule(field: .bpm, op: .isEmpty)], track: unanalyzed))
    }

    @Test
    func ratingAndEnergyReadFromTheClassification() {
        let candidate = track(classification: TrackClassification(rating: TrackRating(4), energy: TrackEnergy(8)))

        #expect(matches([SmartCrateRule(field: .rating, op: .isAtLeast, value: .number(4))], track: candidate))
        #expect(!matches([SmartCrateRule(field: .rating, op: .isAtLeast, value: .number(5))], track: candidate))
        #expect(matches([SmartCrateRule(field: .energy, op: .between, value: .range(6, 9))], track: candidate))
    }

    // MARK: - Key

    @Test
    func keyRulesNormalizeBothSides() {
        let candidate = track(key: "Am")

        // The rule may be written in Camelot and the track stored in note names,
        // or the other way round.
        #expect(matches([SmartCrateRule(field: .musicalKey, op: .is, value: .text("8A"))], track: candidate))
        #expect(matches([SmartCrateRule(field: .musicalKey, op: .is, value: .text("Am"))], track: candidate))
        #expect(!matches([SmartCrateRule(field: .musicalKey, op: .is, value: .text("9A"))], track: candidate))
    }

    // MARK: - Colour and tags

    @Test
    func colourRulesCompareTheLabel() {
        let candidate = track(classification: TrackClassification(colorLabel: .orange))

        #expect(matches([SmartCrateRule(field: .colorLabel, op: .is, value: .color(.orange))], track: candidate))
        #expect(matches([SmartCrateRule(field: .colorLabel, op: .isNot, value: .color(.blue))], track: candidate))
        #expect(matches([SmartCrateRule(field: .colorLabel, op: .isNotEmpty)], track: candidate))
        #expect(matches([SmartCrateRule(field: .colorLabel, op: .isEmpty)], track: track()))
    }

    @Test
    func tagRulesReadFromTheIndexNotTheTrack() {
        let peak = UUID()
        let candidate = track()

        #expect(matches([SmartCrateRule(field: .tag, op: .is, value: .tag(peak))], track: candidate, tagIDs: [peak]))
        #expect(!matches([SmartCrateRule(field: .tag, op: .is, value: .tag(peak))], track: candidate))
        #expect(matches([SmartCrateRule(field: .tag, op: .isNot, value: .tag(peak))], track: candidate))
    }

    // MARK: - Dates

    @Test
    func recencyIsMeasuredAgainstAnInjectedNow() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let threeDaysAgo = now.addingTimeInterval(-3 * 24 * 60 * 60)
        let candidate = track(classification: TrackClassification(dateAdded: threeDaysAgo))

        // Injected rather than read from the clock, so "within the last 7 days"
        // does not depend on when the suite happens to run.
        let rule = SmartCrateRule(field: .dateAdded, op: .withinLastDays, value: .number(7))
        #expect(matches([rule], track: candidate, now: now))

        let strict = SmartCrateRule(field: .dateAdded, op: .withinLastDays, value: .number(1))
        #expect(!matches([strict], track: candidate, now: now))
    }

    // MARK: - Matching mode

    @Test
    func allRequiresEveryRuleAndAnyRequiresOne() {
        let candidate = track(artist: "Lower Field", bpm: 126)
        let rules = [
            SmartCrateRule(field: .artist, op: .contains, value: .text("Lower")),
            SmartCrateRule(field: .bpm, op: .isAtLeast, value: .number(130))
        ]

        #expect(!matches(rules, match: .all, track: candidate))
        #expect(matches(rules, match: .any, track: candidate))
    }

    // MARK: - Persistence

    @Test
    func aRuleSetSurvivesEncodingAndDecoding() throws {
        let original = SmartCrateRuleSet(
            match: .any,
            rules: [
                SmartCrateRule(field: .artist, op: .contains, value: .text("Lower")),
                SmartCrateRule(field: .bpm, op: .between, value: .range(124, 128)),
                SmartCrateRule(field: .colorLabel, op: .is, value: .color(.aqua)),
                SmartCrateRule(field: .tag, op: .isNot, value: .tag(UUID())),
                SmartCrateRule(field: .comment, op: .isEmpty)
            ]
        )

        // This round trip is the storage format for `soria_collections.rules_json`.
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(SmartCrateRuleSet.self, from: data)

        #expect(restored == original)
    }

    // MARK: - Conversion from the filter panel

    @Test
    func savingAFilterProducesEquivalentRules() {
        var filter = LibraryClassificationFilter()
        filter.minimumBPM = 124
        filter.maximumBPM = 128
        filter.minimumRating = 4

        let ruleSet = SmartCrateRuleSet.from(filter)
        let match = track(bpm: 126, classification: TrackClassification(rating: TrackRating(5)))
        let miss = track(bpm: 132, classification: TrackClassification(rating: TrackRating(5)))

        // The crate has to match the list the user was looking at when they saved.
        #expect(ruleSet.matches(SmartCrateEvaluationInput(track: match)))
        #expect(!ruleSet.matches(SmartCrateEvaluationInput(track: miss)))
    }

    @Test
    func aOneSidedBpmFilterBecomesAOneSidedRule() {
        var filter = LibraryClassificationFilter()
        filter.minimumBPM = 124

        let rules = SmartCrateRuleSet.from(filter).rules
        #expect(rules.count == 1)
        #expect(rules.first?.op == .isAtLeast)
    }

    @Test
    func constraintsTheRulesCannotExpressAreReportedNotDropped() {
        var filter = LibraryClassificationFilter()
        filter.camelotNotations = ["8A", "9A"]
        filter.colorLabels = [.red, .blue]
        filter.onlyUnclassified = true

        // Silently saving a crate that means something looser than the filter is
        // worse than saying which parts did not survive.
        let lost = SmartCrateRuleSet.unconvertibleConstraints(in: filter)
        #expect(lost.contains("2 keys"))
        #expect(lost.contains("2 colours"))
        #expect(lost.contains("the unclassified-only filter"))
    }

    @Test
    func aSingleKeyOrColourDoesConvert() {
        var filter = LibraryClassificationFilter()
        filter.camelotNotations = ["8A"]
        filter.colorLabels = [.orange]

        #expect(SmartCrateRuleSet.unconvertibleConstraints(in: filter).isEmpty)

        let ruleSet = SmartCrateRuleSet.from(filter)
        let candidate = track(key: "Am", classification: TrackClassification(colorLabel: .orange))
        #expect(ruleSet.matches(SmartCrateEvaluationInput(track: candidate)))
    }

    @Test
    func everyFieldOffersAtLeastOneOperator() {
        for field in SmartCrateField.allCases {
            #expect(!field.supportedOperators.isEmpty, "\(field.rawValue) has no operators")
        }
    }
}
