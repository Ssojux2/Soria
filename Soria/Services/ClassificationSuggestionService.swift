import Foundation

/// Proposes tags for tracks nobody has tagged yet.
///
/// This is the one thing rekordbox, Serato and Lexicon cannot do. Their filters
/// need the tag to already be there; Soria has an embedding per track, so it can
/// ask a different question — *which of the tracks you already called "Peak" does
/// this one sound like?* — and answer it from audio rather than from metadata.
///
/// The method is deliberately boring: average the embeddings of the tracks
/// carrying a tag, then score untagged tracks by cosine against that centroid.
/// It learns the user's own vocabulary rather than a general-purpose genre model,
/// which is why a tag like "works after the lights come up" is as learnable as
/// "techno".
///
/// **Suggestions are never applied on their own.** The engine returns proposals;
/// writing them is a separate call the user has to make. A tool that silently
/// retags a five-thousand-track library is worse than one that suggests nothing.
enum ClassificationSuggestionEngine {
    /// Below this, a match is not worth the user's attention. Cosine on these
    /// embeddings runs high in absolute terms, so the bar sits well above zero.
    static let defaultThreshold: Double = 0.55

    /// Tags a track can be offered at once. More than this and the review sheet
    /// stops being a decision and becomes a form.
    static let maximumSuggestionsPerTrack = 3

    /// A tag needs this many examples before it can be suggested from. One
    /// example is an anecdote — its centroid is just that track, and everything
    /// that sounds vaguely like it would be proposed.
    static let minimumExamplesPerTag = 3

    struct ScoredTag: Equatable {
        let tagID: UUID
        let confidence: Double
    }

    struct Suggestion: Identifiable, Equatable {
        let trackID: UUID
        let tags: [ScoredTag]

        var id: UUID { trackID }
    }

    /// Why the feature is unavailable, phrased as something the user can act on.
    enum Unavailability: Equatable {
        case noTagsYet
        case notEnoughExamples(needed: Int)
        case noEmbeddings

        var message: String {
            switch self {
            case .noTagsYet:
                return "Tag a few tracks first — suggestions are learned from your own tags."
            case let .notEnoughExamples(needed):
                return "Tag at least \(needed) tracks with the same tag, then Soria can find more like them."
            case .noEmbeddings:
                return "Prepare some tracks first. Suggestions are based on the analysed audio."
            }
        }
    }

    /// The average embedding of the tracks carrying each tag.
    ///
    /// Tags with too few examples are left out entirely rather than given a weak
    /// centroid, so a tag applied to one track cannot start recommending itself
    /// across the library.
    static func centroids(
        tagAssignments: [UUID: Set<UUID>],
        embeddings: [UUID: [Double]],
        minimumExamples: Int = minimumExamplesPerTag
    ) -> [UUID: [Double]] {
        var vectorsByTag: [UUID: [[Double]]] = [:]

        for (trackID, tagIDs) in tagAssignments {
            guard let embedding = embeddings[trackID], !embedding.isEmpty else { continue }
            for tagID in tagIDs {
                vectorsByTag[tagID, default: []].append(embedding)
            }
        }

        var centroids: [UUID: [Double]] = [:]
        for (tagID, vectors) in vectorsByTag where vectors.count >= minimumExamples {
            guard let mean = averaged(vectors) else { continue }
            centroids[tagID] = mean
        }
        return centroids
    }

    /// Scores candidate tracks against the centroids.
    ///
    /// Candidates already carrying a tag are skipped for that tag but still
    /// considered for others — a track tagged "Peak" can still be missing "Vocal".
    static func suggest(
        candidates: [UUID],
        embeddings: [UUID: [Double]],
        centroids: [UUID: [Double]],
        existingAssignments: [UUID: Set<UUID>],
        threshold: Double = defaultThreshold,
        maximumPerTrack: Int = maximumSuggestionsPerTrack
    ) -> [Suggestion] {
        guard !centroids.isEmpty else { return [] }

        var suggestions: [Suggestion] = []

        for trackID in candidates {
            guard let embedding = embeddings[trackID], !embedding.isEmpty else { continue }
            let alreadyCarried = existingAssignments[trackID] ?? []

            var scored: [ScoredTag] = []
            for (tagID, centroid) in centroids where !alreadyCarried.contains(tagID) {
                let confidence = LibraryOrganizationPlanner.cosineSimilarity(embedding, centroid)
                guard confidence >= threshold else { continue }
                scored.append(ScoredTag(tagID: tagID, confidence: confidence))
            }

            // Ties broken by identifier so the same library always produces the
            // same sheet — a review list that reshuffles between runs is
            // impossible to work through.
            scored.sort { left, right in
                if left.confidence == right.confidence {
                    return left.tagID.uuidString < right.tagID.uuidString
                }
                return left.confidence > right.confidence
            }

            guard !scored.isEmpty else { continue }
            suggestions.append(Suggestion(trackID: trackID, tags: Array(scored.prefix(maximumPerTrack))))
        }

        return suggestions.sorted {
            let left = $0.tags.first?.confidence ?? 0
            let right = $1.tags.first?.confidence ?? 0
            return left == right ? $0.trackID.uuidString < $1.trackID.uuidString : left > right
        }
    }

    /// Whether the feature can run at all, and if not, what the user should do.
    static func unavailability(
        tagAssignments: [UUID: Set<UUID>],
        embeddings: [UUID: [Double]],
        minimumExamples: Int = minimumExamplesPerTag
    ) -> Unavailability? {
        if embeddings.isEmpty { return .noEmbeddings }
        if tagAssignments.allSatisfy({ $0.value.isEmpty }) { return .noTagsYet }

        let usable = centroids(
            tagAssignments: tagAssignments,
            embeddings: embeddings,
            minimumExamples: minimumExamples
        )
        if usable.isEmpty { return .notEnoughExamples(needed: minimumExamples) }

        return nil
    }

    private static func averaged(_ vectors: [[Double]]) -> [Double]? {
        guard let width = vectors.first?.count, width > 0 else { return nil }
        // Embeddings from different profiles have different widths; mixing them
        // would produce a meaningless centroid, so odd ones out are dropped.
        let usable = vectors.filter { $0.count == width }
        guard !usable.isEmpty else { return nil }

        var sums = [Double](repeating: 0, count: width)
        for vector in usable {
            for index in 0..<width {
                sums[index] += vector[index]
            }
        }

        let count = Double(usable.count)
        return sums.map { $0 / count }
    }
}
