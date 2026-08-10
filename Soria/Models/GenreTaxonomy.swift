import Foundation

struct GenreFamilyLabel: Codable, Hashable, Identifiable {
    let id: String
    let displayName: String
    let keywords: [String]
    let relatedFamilyIDs: [String]

    var embeddingPrompt: String {
        "\(displayName) DJ track"
    }
}

enum GenreTaxonomy {
    static let familyLabels: [GenreFamilyLabel] = [
        GenreFamilyLabel(
            id: "house",
            displayName: "House",
            keywords: ["house", "tech house", "deep house", "progressive house", "jackin", "afro house"],
            relatedFamilyIDs: ["techno", "disco", "latin", "funk"]
        ),
        GenreFamilyLabel(
            id: "techno",
            displayName: "Techno",
            keywords: ["techno", "melodic techno", "peak time", "hard techno"],
            relatedFamilyIDs: ["house", "breakbeat", "bass"]
        ),
        GenreFamilyLabel(
            id: "disco",
            displayName: "Disco",
            keywords: ["disco", "nu disco", "disco edit"],
            relatedFamilyIDs: ["house", "funk", "pop"]
        ),
        GenreFamilyLabel(
            id: "hiphop",
            displayName: "Hip-Hop",
            keywords: ["hiphop", "rap", "trap"],
            relatedFamilyIDs: ["rnb", "pop", "bass"]
        ),
        GenreFamilyLabel(
            id: "rnb",
            displayName: "R&B",
            keywords: ["rnb", "soul"],
            relatedFamilyIDs: ["hiphop", "pop", "funk"]
        ),
        GenreFamilyLabel(
            id: "bass",
            displayName: "Bass",
            keywords: ["bass", "dubstep", "future bass"],
            relatedFamilyIDs: ["techno", "breakbeat", "dnb", "hiphop"]
        ),
        GenreFamilyLabel(
            id: "dnb",
            displayName: "Drum & Bass",
            keywords: ["drum and bass", "dnb", "liquid"],
            relatedFamilyIDs: ["bass", "breakbeat"]
        ),
        GenreFamilyLabel(
            id: "breakbeat",
            displayName: "Breakbeat",
            keywords: ["breakbeat", "breaks"],
            relatedFamilyIDs: ["bass", "techno", "dnb"]
        ),
        GenreFamilyLabel(
            id: "reggae",
            displayName: "Reggae",
            keywords: ["reggae", "dancehall"],
            relatedFamilyIDs: ["latin", "hiphop"]
        ),
        GenreFamilyLabel(
            id: "latin",
            displayName: "Latin",
            keywords: ["latin", "reggaeton", "baile", "afro"],
            relatedFamilyIDs: ["house", "reggae", "pop"]
        ),
        GenreFamilyLabel(
            id: "funk",
            displayName: "Funk",
            keywords: ["funk", "boogie"],
            relatedFamilyIDs: ["disco", "house", "rnb"]
        ),
        GenreFamilyLabel(
            id: "pop",
            displayName: "Pop",
            keywords: ["pop", "open format"],
            relatedFamilyIDs: ["rnb", "hiphop", "disco", "latin"]
        )
    ]

    static var promptsByFamilyID: [String: String] {
        Dictionary(uniqueKeysWithValues: familyLabels.map { ($0.id, $0.embeddingPrompt) })
    }

    static func label(for familyID: String) -> GenreFamilyLabel? {
        familyLabels.first { $0.id == familyID }
    }

    static func displayName(for familyID: String) -> String {
        label(for: familyID)?.displayName ?? familyID.capitalized
    }

    /// The genre family whose keyword best matches `value`.
    ///
    /// Matches on the LONGEST keyword rather than the first family in declaration
    /// order: "drum and bass" contains both "bass" and "drum and bass", and
    /// `bass` is declared first, so a first-match scan would file every D&B track
    /// under Bass. Ties fall back to declaration order for determinism.
    static func familyID(forNormalizedValue value: String) -> String? {
        var best: (familyID: String, keywordLength: Int)?

        for label in familyLabels {
            let longestMatch = label.keywords
                .filter(value.contains)
                .map(\.count)
                .max()
            guard let longestMatch else { continue }
            if best == nil || longestMatch > (best?.keywordLength ?? 0) {
                best = (label.id, longestMatch)
            }
        }

        return best?.familyID
    }

    static func relatedFamilyIDs(for familyID: String) -> [String] {
        label(for: familyID)?.relatedFamilyIDs ?? []
    }

    static func normalizeGenreText(_ value: String) -> String {
        // Ampersand-bearing spellings have to be rewritten before punctuation is
        // stripped, or "R&B" becomes "r b" and never matches the rnb family.
        // "r&b" is special-cased ahead of the general "& -> and" rule so it does
        // not turn into "randb".
        let lowered = value.lowercased()
            .replacingOccurrences(of: "r&b", with: "rnb")
            .replacingOccurrences(of: "r & b", with: "rnb")
            .replacingOccurrences(of: "&", with: " and ")
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        // "hip hop" runs after whitespace collapsing so any separator spelling
        // ("hip-hop", "hip  hop") lands on the same keyword.
        return String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .replacingOccurrences(of: "hip hop", with: "hiphop")
    }
}
