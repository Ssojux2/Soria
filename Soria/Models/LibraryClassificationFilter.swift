import Foundation

/// The Filter tab's state, and the predicate it produces.
///
/// Composed into `AppViewModel.libraryTracksMatchingCurrentFilters` alongside the
/// existing vendor scope, text search, and prep-status filters rather than
/// replacing any of them — this adds a dimension, it does not take one over.
///
/// Kept pure and `Codable` because Phase 3 turns a filter the user liked into a
/// saved smart crate, and that conversion should be a serialization, not a
/// re-implementation.
struct LibraryClassificationFilter: Equatable, Codable {
    /// How multiple selected tags combine. `any` is the default because a DJ
    /// picking "Peak" and "Dark" is almost always asking for either, not for the
    /// handful of tracks carrying both.
    enum TagMatch: String, Equatable, Codable, CaseIterable, Identifiable {
        case any
        case all

        var id: String { rawValue }
        var displayName: String { self == .any ? "Any" : "All" }
    }

    var minimumBPM: Double?
    var maximumBPM: Double?
    /// Camelot notation, e.g. `"8A"`. Empty means no key constraint.
    var camelotNotations: Set<String> = []
    /// When set, also admits the harmonically compatible neighbours of every
    /// selected key — the whole reason a DJ filters by key at all.
    var includesHarmonicNeighbours: Bool = false
    var minimumRating: Int?
    var minimumEnergy: Int?
    var maximumEnergy: Int?
    var colorLabels: Set<TrackColorLabel> = []
    var genreFamilyIDs: Set<String> = []
    var tagIDs: Set<UUID> = []
    var tagMatch: TagMatch = .any
    /// Restricts to tracks nobody has classified yet — the Inbox scope, reusable
    /// as an ordinary filter so "untagged and 4 stars" is expressible.
    var onlyUnclassified: Bool = false

    init() {}

    var isEmpty: Bool {
        minimumBPM == nil
            && maximumBPM == nil
            && camelotNotations.isEmpty
            && minimumRating == nil
            && minimumEnergy == nil
            && maximumEnergy == nil
            && colorLabels.isEmpty
            && genreFamilyIDs.isEmpty
            && tagIDs.isEmpty
            && !onlyUnclassified
    }

    /// How many dimensions are constrained, for the "3 filters active" chip.
    var activeConstraintCount: Int {
        var count = 0
        if minimumBPM != nil || maximumBPM != nil { count += 1 }
        if !camelotNotations.isEmpty { count += 1 }
        if minimumRating != nil { count += 1 }
        if minimumEnergy != nil || maximumEnergy != nil { count += 1 }
        if !colorLabels.isEmpty { count += 1 }
        if !genreFamilyIDs.isEmpty { count += 1 }
        if !tagIDs.isEmpty { count += 1 }
        if onlyUnclassified { count += 1 }
        return count
    }

    /// The set of Camelot notations a track may carry to pass, expanded to
    /// include harmonic neighbours when that is switched on.
    var admissibleCamelotNotations: Set<String> {
        guard includesHarmonicNeighbours else { return camelotNotations }

        var expanded = camelotNotations
        for notation in camelotNotations {
            guard let key = CamelotKey(notation) else { continue }
            for neighbour in key.compatibleKeys {
                expanded.insert(neighbour.notation)
            }
        }
        return expanded
    }

    /// Whether one track passes.
    ///
    /// `tagIDs` is passed in rather than read from the track because tag
    /// membership lives in its own in-memory index — the Library re-filters on
    /// every keystroke and cannot afford a lookup per row.
    func matches(_ track: Track, tagIDs trackTagIDs: Set<UUID>) -> Bool {
        let classification = track.classification

        if let minimumBPM {
            guard let bpm = track.bpm, bpm >= minimumBPM else { return false }
        }
        if let maximumBPM {
            guard let bpm = track.bpm, bpm <= maximumBPM else { return false }
        }

        let admissibleKeys = admissibleCamelotNotations
        if !admissibleKeys.isEmpty {
            // An unreadable or missing key fails a key filter rather than passing
            // it: the user asked for tracks that mix in 8A, and "we don't know"
            // is not an answer they can mix on.
            guard let key = CamelotKey(track.musicalKey),
                  admissibleKeys.contains(key.notation)
            else { return false }
        }

        if let minimumRating {
            guard let rating = classification.rating, rating.stars >= minimumRating else { return false }
        }

        if let minimumEnergy {
            guard let energy = classification.energy, energy.level >= minimumEnergy else { return false }
        }
        if let maximumEnergy {
            guard let energy = classification.energy, energy.level <= maximumEnergy else { return false }
        }

        if !colorLabels.isEmpty {
            guard let color = classification.colorLabel, colorLabels.contains(color) else { return false }
        }

        if !genreFamilyIDs.isEmpty {
            guard let family = classification.genreFamilyID, genreFamilyIDs.contains(family) else { return false }
        }

        if !tagIDs.isEmpty {
            switch tagMatch {
            case .any:
                guard !trackTagIDs.isDisjoint(with: tagIDs) else { return false }
            case .all:
                guard tagIDs.isSubset(of: trackTagIDs) else { return false }
            }
        }

        if onlyUnclassified {
            guard classification.isUnclassified, trackTagIDs.isEmpty else { return false }
        }

        return true
    }
}
