import Foundation

/// A position on the Camelot wheel — the notation DJs actually filter by.
///
/// Soria's key column is whatever the source handed over: the analysis worker
/// writes `"Am"`, Serato writes `"Am"` or `"8A"` depending on its settings, and
/// rekordbox writes `"Am"` or `"A min"`. Filtering on those strings directly
/// means `8A` and `Am` are two different keys, which is wrong and unusable.
/// Everything normalizes through here first.
struct CamelotKey: Equatable, Hashable, Codable, Identifiable, Comparable {
    enum Mode: String, Equatable, Hashable, Codable {
        /// The A ring — minor keys.
        case minor = "A"
        /// The B ring — major keys.
        case major = "B"
    }

    /// 1 through 12, clockwise around the wheel.
    let position: Int
    let mode: Mode

    var id: String { notation }

    /// `"8A"`, `"12B"` — how it is written on screen and stored in a filter.
    var notation: String { "\(position)\(mode.rawValue)" }

    init?(position: Int, mode: Mode) {
        guard (1...12).contains(position) else { return nil }
        self.position = position
        self.mode = mode
    }

    static func < (lhs: CamelotKey, rhs: CamelotKey) -> Bool {
        if lhs.position != rhs.position { return lhs.position < rhs.position }
        return lhs.mode == .minor && rhs.mode == .major
    }

    static let all: [CamelotKey] = (1...12).flatMap { position in
        [Mode.minor, Mode.major].compactMap { CamelotKey(position: position, mode: $0) }
    }

    // MARK: - Harmonic neighbours

    /// The keys that mix cleanly: the same key, one step around the wheel in
    /// either direction, and the relative major/minor. This is the standard
    /// harmonic-mixing rule every DJ app implements, and it is why the wheel is
    /// numbered the way it is.
    var compatibleKeys: [CamelotKey] {
        let forward = position == 12 ? 1 : position + 1
        let backward = position == 1 ? 12 : position - 1
        let relative: Mode = mode == .minor ? .major : .minor

        return [
            CamelotKey(position: position, mode: mode),
            CamelotKey(position: forward, mode: mode),
            CamelotKey(position: backward, mode: mode),
            CamelotKey(position: position, mode: relative)
        ].compactMap { $0 }
    }

    // MARK: - Parsing

    /// Reads a key in any notation the library actually contains.
    ///
    /// Accepts Camelot (`"8A"`, `"08a"`), plain note names (`"Am"`, `"A min"`,
    /// `"C"`, `"F#m"`, `"Gbm"`), and the Open Key notation some tools write
    /// (`"1m"`, `"1d"`). Returns nil rather than guessing when it cannot tell —
    /// a wrong key is worse than a missing one, because the user mixes on it.
    init?(_ rawValue: String?) {
        guard let rawValue else { return nil }

        let condensed = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")

        guard !condensed.isEmpty else { return nil }

        if let camelot = Self.parseCamelot(condensed) {
            self = camelot
            return
        }
        if let openKey = Self.parseOpenKey(condensed) {
            self = openKey
            return
        }
        if let musical = Self.parseMusical(condensed) {
            self = musical
            return
        }
        return nil
    }

    /// `"8A"` / `"08a"` / `"12B"`.
    private static func parseCamelot(_ value: String) -> CamelotKey? {
        let upper = value.uppercased()
        guard let last = upper.last, last == "A" || last == "B" else { return nil }

        let digits = String(upper.dropLast())
        guard let position = Int(digits), digits.allSatisfy(\.isNumber) else { return nil }

        return CamelotKey(position: position, mode: last == "A" ? .minor : .major)
    }

    /// Open Key: `"1m"` (minor) / `"1d"` (major). Its wheel is rotated five
    /// positions from Camelot's, which is exactly the sort of detail that makes
    /// raw string comparison unusable.
    private static func parseOpenKey(_ value: String) -> CamelotKey? {
        let lower = value.lowercased()
        guard let last = lower.last, last == "m" || last == "d" else { return nil }

        let digits = String(lower.dropLast())
        guard let openPosition = Int(digits), digits.allSatisfy(\.isNumber),
              (1...12).contains(openPosition)
        else { return nil }

        // Open Key 1 is Camelot 8 (C major / A minor), and both wheels advance in
        // fifths from there, so the whole ring is a seven-step rotation.
        let camelotPosition = ((openPosition + 6) % 12) + 1
        return CamelotKey(position: camelotPosition, mode: last == "m" ? .minor : .major)
    }

    /// Note names, with or without a minor marker.
    private static func parseMusical(_ value: String) -> CamelotKey? {
        var working = value.lowercased()

        var isMinor = false
        for suffix in ["minor", "min", "moll", "m"] where working.hasSuffix(suffix) {
            // "m" alone would also strip the "m" from nothing sensible, but the
            // root lookup below rejects whatever is left if it goes wrong.
            working = String(working.dropLast(suffix.count))
            isMinor = true
            break
        }
        if !isMinor {
            for suffix in ["major", "maj", "dur"] where working.hasSuffix(suffix) {
                working = String(working.dropLast(suffix.count))
                break
            }
        }

        // Normalize the accidental so "a#" and "bb" land on the same root.
        let root = working
            .replacingOccurrences(of: "♯", with: "#")
            .replacingOccurrences(of: "♭", with: "b")

        guard let semitone = Self.semitones[root] else { return nil }
        guard let position = Self.wheelPosition(semitone: semitone, isMinor: isMinor) else { return nil }

        return CamelotKey(position: position, mode: isMinor ? .minor : .major)
    }

    /// Pitch class for every spelling that shows up in the wild.
    private static let semitones: [String: Int] = [
        "c": 0, "b#": 0,
        "c#": 1, "db": 1,
        "d": 2,
        "d#": 3, "eb": 3,
        "e": 4, "fb": 4,
        "f": 5, "e#": 5,
        "f#": 6, "gb": 6,
        "g": 7,
        "g#": 8, "ab": 8,
        "a": 9,
        "a#": 10, "bb": 10,
        "b": 11, "cb": 11
    ]

    /// Camelot numbers the wheel in fifths, so the mapping from pitch class is a
    /// table rather than arithmetic anyone should try to read.
    private static func wheelPosition(semitone: Int, isMinor: Bool) -> Int? {
        // Index by pitch class: C, C#, D, D#, E, F, F#, G, G#, A, A#, B.
        let majorPositions = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1]
        let minorPositions = [5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10]

        guard (0..<12).contains(semitone) else { return nil }
        return isMinor ? minorPositions[semitone] : majorPositions[semitone]
    }
}
