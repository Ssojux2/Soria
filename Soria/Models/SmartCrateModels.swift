import Foundation

/// A crate defined by rules instead of by membership.
///
/// The shape Serato's Smart Crates and Lexicon's Smartlists both settled on:
/// field, operator, value; match all or any; re-evaluated as the library changes.
/// It earns its keep on a library this size because the useful groupings are
/// descriptions, not lists — "peak-time house I rated four or better" stays true
/// as tracks arrive, and a hand-built crate does not.
///
/// Stored in `soria_collections.rules_json`, deliberately **not** in
/// `prompt_text`: that column already means "the prompt this folder was built
/// from" for prompt folders, and overloading it would break them.
///
/// Pure and dependency-free, so `evaluate` can be tested without a database.

// MARK: - Fields

enum SmartCrateField: String, Codable, CaseIterable, Identifiable {
    case title
    case artist
    case album
    case genre
    case comment
    case genreFamily
    case bpm
    case rating
    case energy
    case musicalKey
    case colorLabel
    case tag
    case dateAdded

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .title: return "Title"
        case .artist: return "Artist"
        case .album: return "Album"
        case .genre: return "Genre"
        case .comment: return "Comment"
        case .genreFamily: return "Genre family"
        case .bpm: return "BPM"
        case .rating: return "Rating"
        case .energy: return "Energy"
        case .musicalKey: return "Key"
        case .colorLabel: return "Colour"
        case .tag: return "Tag"
        case .dateAdded: return "Added"
        }
    }

    /// Only the operators that mean something for this field. The builder offers
    /// exactly these, so "BPM contains house" is not expressible rather than
    /// merely never true.
    var supportedOperators: [SmartCrateOperator] {
        switch self {
        case .title, .artist, .album, .genre, .comment:
            return [.contains, .doesNotContain, .is, .isNot, .isEmpty, .isNotEmpty]
        case .genreFamily, .musicalKey, .colorLabel:
            return [.is, .isNot, .isEmpty, .isNotEmpty]
        case .bpm, .rating, .energy:
            return [.isAtLeast, .isAtMost, .between, .is, .isEmpty, .isNotEmpty]
        case .tag:
            return [.is, .isNot]
        case .dateAdded:
            return [.withinLastDays, .isEmpty, .isNotEmpty]
        }
    }
}

// MARK: - Operators

enum SmartCrateOperator: String, Codable, CaseIterable, Identifiable {
    case contains
    case doesNotContain
    case `is`
    case isNot
    case isAtLeast
    case isAtMost
    case between
    case withinLastDays
    case isEmpty
    case isNotEmpty

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .contains: return "contains"
        case .doesNotContain: return "does not contain"
        case .is: return "is"
        case .isNot: return "is not"
        case .isAtLeast: return "is at least"
        case .isAtMost: return "is at most"
        case .between: return "is between"
        case .withinLastDays: return "within the last"
        case .isEmpty: return "is empty"
        case .isNotEmpty: return "is not empty"
        }
    }

    /// Whether the rule needs a value at all. `isEmpty` does not, and offering an
    /// input for it would suggest otherwise.
    var requiresValue: Bool {
        self != .isEmpty && self != .isNotEmpty
    }
}

// MARK: - Values

enum SmartCrateValue: Equatable, Codable {
    case text(String)
    case number(Double)
    case range(Double, Double)
    case tag(UUID)
    case color(TrackColorLabel)
    case none

    var textValue: String? {
        if case let .text(value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }
}

// MARK: - Rules

struct SmartCrateRule: Equatable, Codable, Identifiable {
    var id: UUID
    var field: SmartCrateField
    var op: SmartCrateOperator
    var value: SmartCrateValue

    init(id: UUID = UUID(), field: SmartCrateField, op: SmartCrateOperator, value: SmartCrateValue = .none) {
        self.id = id
        self.field = field
        self.op = op
        self.value = value
    }

    /// A rule whose operator does not apply to its field can never be satisfied
    /// and would silently empty the crate, so it is caught at edit time instead.
    var isValid: Bool {
        guard field.supportedOperators.contains(op) else { return false }
        guard op.requiresValue else { return true }
        return value != .none
    }
}

struct SmartCrateRuleSet: Equatable, Codable {
    enum Match: String, Codable, CaseIterable, Identifiable {
        case all
        case any

        var id: String { rawValue }
        var displayName: String { self == .all ? "all" : "any" }
    }

    var match: Match
    var rules: [SmartCrateRule]

    init(match: Match = .all, rules: [SmartCrateRule] = []) {
        self.match = match
        self.rules = rules
    }

    var validRules: [SmartCrateRule] { rules.filter(\.isValid) }
}

// MARK: - Evaluation

/// The per-track facts a rule set is evaluated against.
///
/// Passed in rather than read off `Track` because tag membership lives in its own
/// in-memory index and `now` has to be injectable — a rule about the last seven
/// days must not produce different results depending on when the test runs.
struct SmartCrateEvaluationInput {
    let track: Track
    let tagIDs: Set<UUID>
    let now: Date

    init(track: Track, tagIDs: Set<UUID> = [], now: Date = Date()) {
        self.track = track
        self.tagIDs = tagIDs
        self.now = now
    }
}

extension SmartCrateRuleSet {
    /// Whether a track belongs in the crate.
    ///
    /// An empty rule set matches nothing rather than everything. A crate the user
    /// has not finished defining should look unfinished, not swallow the library.
    func matches(_ input: SmartCrateEvaluationInput) -> Bool {
        let applicable = validRules
        guard !applicable.isEmpty else { return false }

        switch match {
        case .all:
            return applicable.allSatisfy { Self.evaluate($0, against: input) }
        case .any:
            return applicable.contains { Self.evaluate($0, against: input) }
        }
    }

    static func evaluate(_ rule: SmartCrateRule, against input: SmartCrateEvaluationInput) -> Bool {
        switch rule.field {
        case .title:
            return evaluateText(rule, actual: input.track.title)
        case .artist:
            return evaluateText(rule, actual: input.track.artist)
        case .album:
            return evaluateText(rule, actual: input.track.album)
        case .genre:
            return evaluateText(rule, actual: input.track.genre)
        case .comment:
            return evaluateText(rule, actual: input.track.comment)
        case .genreFamily:
            return evaluateText(rule, actual: input.track.classification.genreFamilyID)
        case .bpm:
            return evaluateNumber(rule, actual: input.track.bpm)
        case .rating:
            return evaluateNumber(rule, actual: input.track.classification.rating.map { Double($0.stars) })
        case .energy:
            return evaluateNumber(rule, actual: input.track.classification.energy.map { Double($0.level) })
        case .musicalKey:
            // Normalized first, so a rule written as "8A" matches a track stored
            // as "Am".
            return evaluateText(
                rule,
                actual: CamelotKey(input.track.musicalKey)?.notation,
                normalizingExpected: { CamelotKey($0)?.notation ?? $0 }
            )
        case .colorLabel:
            return evaluateColor(rule, actual: input.track.classification.colorLabel)
        case .tag:
            return evaluateTag(rule, tagIDs: input.tagIDs)
        case .dateAdded:
            return evaluateDate(rule, actual: input.track.classification.dateAdded, now: input.now)
        }
    }

    // MARK: Per-type evaluation

    private static func evaluateText(
        _ rule: SmartCrateRule,
        actual: String?,
        normalizingExpected: ((String) -> String)? = nil
    ) -> Bool {
        let trimmed = actual?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch rule.op {
        case .isEmpty:
            return trimmed.isEmpty
        case .isNotEmpty:
            return !trimmed.isEmpty
        default:
            break
        }

        guard var expected = rule.value.textValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expected.isEmpty
        else { return false }

        if let normalizingExpected { expected = normalizingExpected(expected) }

        let haystack = trimmed.lowercased()
        let needle = expected.lowercased()

        switch rule.op {
        case .contains: return haystack.contains(needle)
        case .doesNotContain: return !haystack.contains(needle)
        case .is: return haystack == needle
        case .isNot: return haystack != needle
        default: return false
        }
    }

    private static func evaluateNumber(_ rule: SmartCrateRule, actual: Double?) -> Bool {
        switch rule.op {
        case .isEmpty:
            return actual == nil
        case .isNotEmpty:
            return actual != nil
        default:
            break
        }

        // A missing value fails every comparison rather than passing one: "BPM at
        // least 124" should not sweep in every unanalysed track.
        guard let actual else { return false }

        switch (rule.op, rule.value) {
        case let (.isAtLeast, .number(bound)):
            return actual >= bound
        case let (.isAtMost, .number(bound)):
            return actual <= bound
        case let (.is, .number(target)):
            return actual == target
        case let (.between, .range(lower, upper)):
            return actual >= min(lower, upper) && actual <= max(lower, upper)
        default:
            return false
        }
    }

    private static func evaluateColor(_ rule: SmartCrateRule, actual: TrackColorLabel?) -> Bool {
        switch rule.op {
        case .isEmpty:
            return actual == nil
        case .isNotEmpty:
            return actual != nil
        case .is:
            guard case let .color(expected) = rule.value else { return false }
            return actual == expected
        case .isNot:
            guard case let .color(expected) = rule.value else { return false }
            return actual != expected
        default:
            return false
        }
    }

    private static func evaluateTag(_ rule: SmartCrateRule, tagIDs: Set<UUID>) -> Bool {
        guard case let .tag(expected) = rule.value else { return false }

        switch rule.op {
        case .is: return tagIDs.contains(expected)
        case .isNot: return !tagIDs.contains(expected)
        default: return false
        }
    }

    private static func evaluateDate(_ rule: SmartCrateRule, actual: Date?, now: Date) -> Bool {
        switch rule.op {
        case .isEmpty:
            return actual == nil
        case .isNotEmpty:
            return actual != nil
        case .withinLastDays:
            guard let actual, case let .number(days) = rule.value else { return false }
            return now.timeIntervalSince(actual) <= days * 24 * 60 * 60
        default:
            return false
        }
    }
}

// MARK: - Conversion from the filter panel

extension SmartCrateRuleSet {
    /// Turns the Filter tab's current state into rules.
    ///
    /// This is what "Save as Smart Crate" does. Building it as a conversion rather
    /// than a second authoring path means the crate a user saves always matches
    /// the list they were looking at when they saved it.
    static func from(_ filter: LibraryClassificationFilter, tagMatchOverride: Match? = nil) -> SmartCrateRuleSet {
        var rules: [SmartCrateRule] = []

        if let minimum = filter.minimumBPM, let maximum = filter.maximumBPM {
            rules.append(SmartCrateRule(field: .bpm, op: .between, value: .range(minimum, maximum)))
        } else if let minimum = filter.minimumBPM {
            rules.append(SmartCrateRule(field: .bpm, op: .isAtLeast, value: .number(minimum)))
        } else if let maximum = filter.maximumBPM {
            rules.append(SmartCrateRule(field: .bpm, op: .isAtMost, value: .number(maximum)))
        }

        if let rating = filter.minimumRating {
            rules.append(SmartCrateRule(field: .rating, op: .isAtLeast, value: .number(Double(rating))))
        }

        if let minimum = filter.minimumEnergy, let maximum = filter.maximumEnergy {
            rules.append(
                SmartCrateRule(field: .energy, op: .between, value: .range(Double(minimum), Double(maximum)))
            )
        } else if let minimum = filter.minimumEnergy {
            rules.append(SmartCrateRule(field: .energy, op: .isAtLeast, value: .number(Double(minimum))))
        } else if let maximum = filter.maximumEnergy {
            rules.append(SmartCrateRule(field: .energy, op: .isAtMost, value: .number(Double(maximum))))
        }

        // Several selected keys or colours mean "any of these", which an
        // all-matching rule set cannot express — so those collapse to one rule
        // each only when a single value is selected, and are otherwise dropped
        // with the count reported by the caller.
        if filter.admissibleCamelotNotations.count == 1, let only = filter.admissibleCamelotNotations.first {
            rules.append(SmartCrateRule(field: .musicalKey, op: .is, value: .text(only)))
        }
        if filter.colorLabels.count == 1, let only = filter.colorLabels.first {
            rules.append(SmartCrateRule(field: .colorLabel, op: .is, value: .color(only)))
        }

        for tagID in filter.tagIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            rules.append(SmartCrateRule(field: .tag, op: .is, value: .tag(tagID)))
        }

        let match: Match = tagMatchOverride ?? (filter.tagMatch == .any && filter.tagIDs.count > 1 ? .any : .all)
        return SmartCrateRuleSet(match: match, rules: rules)
    }

    /// Constraints the conversion above cannot represent, so the UI can say so
    /// instead of quietly saving a crate that means something else.
    static func unconvertibleConstraints(in filter: LibraryClassificationFilter) -> [String] {
        var lost: [String] = []
        if filter.admissibleCamelotNotations.count > 1 {
            lost.append("\(filter.admissibleCamelotNotations.count) keys")
        }
        if filter.colorLabels.count > 1 {
            lost.append("\(filter.colorLabels.count) colours")
        }
        if filter.onlyUnclassified {
            lost.append("the unclassified-only filter")
        }
        return lost
    }
}
