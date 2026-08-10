import Foundation
import Testing

@testable import Soria

/// Tag suggestions from embeddings.
///
/// The guardrails matter more than the scoring here. This engine proposes changes
/// to a five-thousand-track library, so the tests that earn their keep are the
/// ones proving it refuses to run on thin evidence and never returns something
/// the user did not ask to see.
struct ClassificationSuggestionTests {
    /// Deterministic unit vectors so cosine values are predictable. Two points
    /// close together on the same axis, one far away.
    private let warmA = [1.0, 0.0, 0.0]
    private let warmB = [0.95, 0.10, 0.0]
    private let warmC = [0.90, 0.20, 0.0]
    private let darkA = [0.0, 0.0, 1.0]

    private func ids(_ count: Int) -> [UUID] {
        (0..<count).map { _ in UUID() }
    }

    // MARK: - Centroids

    @Test
    func aCentroidAveragesTheTracksCarryingItsTag() throws {
        let tag = UUID()
        let tracks = ids(3)
        let assignments = Dictionary(uniqueKeysWithValues: tracks.map { ($0, Set([tag])) })
        let embeddings = [tracks[0]: warmA, tracks[1]: warmB, tracks[2]: warmC]

        let centroids = ClassificationSuggestionEngine.centroids(
            tagAssignments: assignments,
            embeddings: embeddings
        )

        let centroid = try #require(centroids[tag])
        #expect(centroid.count == 3)
        #expect(abs(centroid[0] - 0.95) < 0.0001)
        #expect(abs(centroid[1] - 0.10) < 0.0001)
    }

    @Test
    func aTagWithTooFewExamplesGetsNoCentroid() {
        let tag = UUID()
        let tracks = ids(2)
        let assignments = Dictionary(uniqueKeysWithValues: tracks.map { ($0, Set([tag])) })
        let embeddings = [tracks[0]: warmA, tracks[1]: warmB]

        // One or two examples is an anecdote: the centroid would just be those
        // tracks, and everything vaguely like them would be proposed.
        #expect(
            ClassificationSuggestionEngine.centroids(
                tagAssignments: assignments,
                embeddings: embeddings
            ).isEmpty
        )
    }

    @Test
    func embeddingsOfDifferentWidthsAreNotMixed() throws {
        let tag = UUID()
        let tracks = ids(3)
        let assignments = Dictionary(uniqueKeysWithValues: tracks.map { ($0, Set([tag])) })
        // A library re-analysed under a new profile can hold both widths at once;
        // averaging across them would produce a meaningless centroid.
        let embeddings = [tracks[0]: warmA, tracks[1]: warmB, tracks[2]: [1.0, 0.0]]

        let centroid = try #require(
            ClassificationSuggestionEngine.centroids(
                tagAssignments: assignments,
                embeddings: embeddings,
                minimumExamples: 2
            )[tag]
        )
        #expect(centroid.count == 3)
    }

    // MARK: - Suggesting

    @Test
    func tracksThatSoundLikeATagAreSuggestedAndOthersAreNot() throws {
        let warmTag = UUID()
        let tagged = ids(3)
        let candidateNear = UUID()
        let candidateFar = UUID()

        let assignments = Dictionary(uniqueKeysWithValues: tagged.map { ($0, Set([warmTag])) })
        var embeddings = [tagged[0]: warmA, tagged[1]: warmB, tagged[2]: warmC]
        embeddings[candidateNear] = [0.98, 0.05, 0.0]
        embeddings[candidateFar] = darkA

        let centroids = ClassificationSuggestionEngine.centroids(
            tagAssignments: assignments,
            embeddings: embeddings
        )
        let suggestions = ClassificationSuggestionEngine.suggest(
            candidates: [candidateNear, candidateFar],
            embeddings: embeddings,
            centroids: centroids,
            existingAssignments: assignments
        )

        #expect(suggestions.count == 1)
        let only = try #require(suggestions.first)
        #expect(only.trackID == candidateNear)
        #expect(only.tags.first?.tagID == warmTag)
    }

    @Test
    func aTagTheTrackAlreadyCarriesIsNotSuggestedAgain() {
        let warmTag = UUID()
        let tagged = ids(3)
        let candidate = UUID()

        var assignments = Dictionary(uniqueKeysWithValues: tagged.map { ($0, Set([warmTag])) })
        assignments[candidate] = [warmTag]

        var embeddings = [tagged[0]: warmA, tagged[1]: warmB, tagged[2]: warmC]
        embeddings[candidate] = warmA

        let centroids = ClassificationSuggestionEngine.centroids(
            tagAssignments: assignments,
            embeddings: embeddings
        )
        let suggestions = ClassificationSuggestionEngine.suggest(
            candidates: [candidate],
            embeddings: embeddings,
            centroids: centroids,
            existingAssignments: assignments
        )

        #expect(suggestions.isEmpty)
    }

    @Test
    func aTrackIsNeverOfferedMoreTagsThanTheLimit() {
        let tags = ids(5)
        let tagged = ids(3)
        let candidate = UUID()

        // Every tag applied to the same three tracks, so all five centroids sit on
        // top of each other and every one scores highly.
        let assignments = Dictionary(uniqueKeysWithValues: tagged.map { ($0, Set(tags)) })
        var embeddings = [tagged[0]: warmA, tagged[1]: warmB, tagged[2]: warmC]
        embeddings[candidate] = warmA

        let centroids = ClassificationSuggestionEngine.centroids(
            tagAssignments: assignments,
            embeddings: embeddings
        )
        let suggestions = ClassificationSuggestionEngine.suggest(
            candidates: [candidate],
            embeddings: embeddings,
            centroids: centroids,
            existingAssignments: [:]
        )

        #expect(centroids.count == 5)
        #expect(suggestions.first?.tags.count == ClassificationSuggestionEngine.maximumSuggestionsPerTrack)
    }

    @Test
    func anUnanalyzedCandidateIsSkippedRatherThanGuessedAt() {
        let tag = UUID()
        let tagged = ids(3)
        let candidate = UUID()

        let assignments = Dictionary(uniqueKeysWithValues: tagged.map { ($0, Set([tag])) })
        let embeddings = [tagged[0]: warmA, tagged[1]: warmB, tagged[2]: warmC]

        let centroids = ClassificationSuggestionEngine.centroids(
            tagAssignments: assignments,
            embeddings: embeddings
        )
        let suggestions = ClassificationSuggestionEngine.suggest(
            candidates: [candidate],
            embeddings: embeddings,
            centroids: centroids,
            existingAssignments: [:]
        )

        #expect(suggestions.isEmpty)
    }

    @Test
    func theSameInputAlwaysProducesTheSameOrder() {
        let tags = ids(3)
        let tagged = ids(3)
        let candidates = ids(4)

        let assignments = Dictionary(uniqueKeysWithValues: tagged.map { ($0, Set(tags)) })
        var embeddings = [tagged[0]: warmA, tagged[1]: warmB, tagged[2]: warmC]
        for candidate in candidates {
            embeddings[candidate] = warmA
        }

        let centroids = ClassificationSuggestionEngine.centroids(
            tagAssignments: assignments,
            embeddings: embeddings
        )
        let first = ClassificationSuggestionEngine.suggest(
            candidates: candidates,
            embeddings: embeddings,
            centroids: centroids,
            existingAssignments: [:]
        )
        let second = ClassificationSuggestionEngine.suggest(
            candidates: candidates,
            embeddings: embeddings,
            centroids: centroids,
            existingAssignments: [:]
        )

        // A review list that reshuffles between runs is impossible to work through.
        #expect(first == second)
    }

    @Test
    func noCentroidsMeansNoSuggestions() {
        #expect(
            ClassificationSuggestionEngine.suggest(
                candidates: ids(3),
                embeddings: [:],
                centroids: [:],
                existingAssignments: [:]
            ).isEmpty
        )
    }

    // MARK: - Availability

    @Test
    func theFeatureExplainsWhyItCannotRun() {
        let tracks = ids(3)

        #expect(
            ClassificationSuggestionEngine.unavailability(tagAssignments: [:], embeddings: [:])
                == .noEmbeddings
        )

        let embeddings = [tracks[0]: warmA, tracks[1]: warmB, tracks[2]: warmC]
        #expect(
            ClassificationSuggestionEngine.unavailability(
                tagAssignments: [tracks[0]: []],
                embeddings: embeddings
            ) == .noTagsYet
        )

        let tag = UUID()
        #expect(
            ClassificationSuggestionEngine.unavailability(
                tagAssignments: [tracks[0]: [tag]],
                embeddings: embeddings
            ) == .notEnoughExamples(needed: ClassificationSuggestionEngine.minimumExamplesPerTag)
        )
    }

    @Test
    func aReadyLibraryReportsNoObstacle() {
        let tag = UUID()
        let tracks = ids(3)
        let assignments = Dictionary(uniqueKeysWithValues: tracks.map { ($0, Set([tag])) })
        let embeddings = [tracks[0]: warmA, tracks[1]: warmB, tracks[2]: warmC]

        #expect(
            ClassificationSuggestionEngine.unavailability(
                tagAssignments: assignments,
                embeddings: embeddings
            ) == nil
        )
    }

    @Test
    func everyUnavailabilityReasonTellsTheUserWhatToDo() {
        let reasons: [ClassificationSuggestionEngine.Unavailability] = [
            .noTagsYet,
            .notEnoughExamples(needed: 3),
            .noEmbeddings
        ]

        for reason in reasons {
            #expect(!reason.message.isEmpty)
            // A dead end reads as a bug; each of these has to name a next step.
            #expect(reason.message.contains("first") || reason.message.contains("then"))
        }
    }
}
