import Foundation

/// What a DJ puts *on* a track so they can find it again: rating, energy, colour.
///
/// These live on the `tracks` row, never on `external_metadata`. That table is a
/// replaceable import cache — `DJLibrarySyncService` rebuilds it wholesale on
/// every vendor sync, so anything parked there disappears the next time the user
/// presses Sync Library. Soria's own annotations have to outlive that.
///
/// Values reach a track from three directions — the user typing them, Soria's
/// analysis inferring them, and a Serato/rekordbox import carrying them — and the
/// last writer does **not** win. `TrackMetadataSource.priority` decides, through
/// the existing `shouldAdoptMetadataValue(_:from:over:currentSource:)` in
/// `TrackModels.swift`. That is why every field here is stored alongside its own
/// source: a rating the user typed (`.user`, priority 5) must survive tomorrow's
/// Serato import (priority 3), and nothing else in the app can express that.

// MARK: - Rating

/// A 0–5 star rating, matching what Serato and rekordbox both store.
///
/// Zero is "unrated" rather than "rated zero stars" — the same convention the
/// vendors use, and the reason `isUnrated` exists instead of an optional wrapper.
struct TrackRating: Equatable, Hashable, Codable, Comparable {
    static let unrated = TrackRating(0)
    static let maximumStars = 5

    let stars: Int

    /// Clamps rather than failing. Vendor libraries are full of out-of-range
    /// ratings (rekordbox writes 0–255 internally), and refusing to import a
    /// track because its rating is 6 would be worse than storing 5.
    init(_ stars: Int) {
        self.stars = min(max(stars, 0), Self.maximumStars)
    }

    /// rekordbox stores ratings as 0–255 in steps of 51. Serato uses 0–5 directly,
    /// so callers pass whichever scale they read and this normalizes it.
    init(vendorValue: Int) {
        if vendorValue > Self.maximumStars {
            self.init(Int((Double(vendorValue) / 51.0).rounded()))
        } else {
            self.init(vendorValue)
        }
    }

    var isUnrated: Bool { stars == 0 }

    static func < (lhs: TrackRating, rhs: TrackRating) -> Bool { lhs.stars < rhs.stars }
}

// MARK: - Energy

/// A 1–10 energy level, the scale Mixed In Key established and that DJs already
/// read fluently. Soria can infer it from analysis, but the user's number wins.
struct TrackEnergy: Equatable, Hashable, Codable, Comparable {
    static let minimumLevel = 1
    static let maximumLevel = 10

    let level: Int

    init(_ level: Int) {
        self.level = min(max(level, Self.minimumLevel), Self.maximumLevel)
    }

    /// Derives a level from `TrackAnalysisSummary.energyArc`, which is a
    /// per-window 0–1 curve across the track.
    ///
    /// Uses the mean rather than the peak: almost every dance track peaks near
    /// 1.0 somewhere, so peak-based levels collapse to "9 or 10" for the whole
    /// library and stop discriminating. Returns nil for an unanalyzed track so
    /// the caller stores nothing instead of a misleading default.
    init?(energyArc: [Double]) {
        let usable = energyArc.filter(\.isFinite)
        guard !usable.isEmpty else { return nil }

        let mean = usable.reduce(0, +) / Double(usable.count)
        let scaled = (mean * Double(Self.maximumLevel)).rounded()
        self.init(Int(scaled))
    }

    static func < (lhs: TrackEnergy, rhs: TrackEnergy) -> Bool { lhs.level < rhs.level }
}

// MARK: - Colour

/// The eight colour tags rekordbox exposes, which Serato's palette also covers.
///
/// Deliberately a closed set rather than free-form hex. A colour only means
/// anything if it survives the round trip to the DJ software the user actually
/// performs on, and both vendors quantize to their own palette on import — so an
/// arbitrary colour picker here would silently lose information on export.
enum TrackColorLabel: String, CaseIterable, Codable, Identifiable {
    case pink
    case red
    case orange
    case yellow
    case green
    case aqua
    case blue
    case purple

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pink: return "Pink"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .aqua: return "Aqua"
        case .blue: return "Blue"
        case .purple: return "Purple"
        }
    }

    /// Reference RGB for each slot, used both to draw the swatch and to snap an
    /// imported vendor colour onto the palette.
    var components: (red: Double, green: Double, blue: Double) {
        switch self {
        case .pink: return (0.98, 0.36, 0.65)
        case .red: return (0.90, 0.22, 0.21)
        case .orange: return (0.96, 0.55, 0.15)
        case .yellow: return (0.97, 0.83, 0.22)
        case .green: return (0.36, 0.74, 0.36)
        case .aqua: return (0.28, 0.79, 0.80)
        case .blue: return (0.26, 0.51, 0.93)
        case .purple: return (0.63, 0.40, 0.87)
        }
    }

    /// Snaps an imported `#RRGGBB` (or `RRGGBB`) string onto the nearest palette
    /// entry by squared RGB distance.
    ///
    /// Nearest-match rather than exact-match because neither vendor writes the
    /// values above verbatim; requiring an exact hit would drop every colour the
    /// user had already set in Serato.
    static func nearest(toHex hex: String) -> TrackColorLabel? {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let packed = Int(digits, radix: 16) else { return nil }

        let red = Double((packed >> 16) & 0xFF) / 255.0
        let green = Double((packed >> 8) & 0xFF) / 255.0
        let blue = Double(packed & 0xFF) / 255.0

        return allCases.min { lhs, rhs in
            squaredDistance(lhs, red, green, blue) < squaredDistance(rhs, red, green, blue)
        }
    }

    private static func squaredDistance(
        _ label: TrackColorLabel,
        _ red: Double,
        _ green: Double,
        _ blue: Double
    ) -> Double {
        let reference = label.components
        let deltaRed = reference.red - red
        let deltaGreen = reference.green - green
        let deltaBlue = reference.blue - blue
        return deltaRed * deltaRed + deltaGreen * deltaGreen + deltaBlue * deltaBlue
    }
}

// MARK: - The per-track record

/// Everything Soria owns about how a track is classified, plus where each piece
/// came from. Held separately from `Track` so a vendor sync can merge into it
/// without touching the scanner-owned fields.
struct TrackClassification: Equatable, Hashable, Codable {
    var rating: TrackRating?
    var ratingSource: TrackMetadataSource?
    var energy: TrackEnergy?
    var energySource: TrackMetadataSource?
    var colorLabel: TrackColorLabel?
    var colorSource: TrackMetadataSource?

    /// The genre family `LibraryOrganizationPlanner` infers from the track
    /// embedding. Recorded here so the Library can show and filter on it —
    /// today it is computed inside `buildPlan()` and thrown away.
    var genreFamilyID: String?
    var genreFamilyScore: Double?

    var dateAdded: Date?

    init(
        rating: TrackRating? = nil,
        ratingSource: TrackMetadataSource? = nil,
        energy: TrackEnergy? = nil,
        energySource: TrackMetadataSource? = nil,
        colorLabel: TrackColorLabel? = nil,
        colorSource: TrackMetadataSource? = nil,
        genreFamilyID: String? = nil,
        genreFamilyScore: Double? = nil,
        dateAdded: Date? = nil
    ) {
        self.rating = rating
        self.ratingSource = ratingSource
        self.energy = energy
        self.energySource = energySource
        self.colorLabel = colorLabel
        self.colorSource = colorSource
        self.genreFamilyID = genreFamilyID
        self.genreFamilyScore = genreFamilyScore
        self.dateAdded = dateAdded
    }

    /// True when nothing has classified this track yet — the Inbox test.
    /// Tags are held separately, so callers combine this with a tag lookup.
    var isUnclassified: Bool {
        (rating?.isUnrated ?? true) && energy == nil && colorLabel == nil
    }
}

extension TrackClassification {
    /// Merges an incoming value for one field, honouring source priority.
    ///
    /// Every merge goes through `shouldAdoptMetadataValue`, the same arbitration
    /// the scanner already uses for genre/BPM/key, so classification cannot drift
    /// into a second, subtly different set of precedence rules.
    static func merged<Value>(
        incoming: Value?,
        incomingSource: TrackMetadataSource,
        current: Value?,
        currentSource: TrackMetadataSource?
    ) -> (value: Value?, source: TrackMetadataSource?) {
        guard shouldAdoptMetadataValue(
            incoming,
            from: incomingSource,
            over: current,
            currentSource: currentSource
        ) else {
            return (current, currentSource)
        }
        return (incoming, incomingSource)
    }

    /// Folds what a Serato/rekordbox import knows into an existing
    /// classification. Anything the user set survives untouched.
    func mergingVendor(
        rating incomingRating: TrackRating?,
        colorLabel incomingColor: TrackColorLabel?,
        from source: TrackMetadataSource
    ) -> TrackClassification {
        var merged = self

        let resolvedRating = Self.merged(
            incoming: incomingRating,
            incomingSource: source,
            current: rating,
            currentSource: ratingSource
        )
        merged.rating = resolvedRating.value
        merged.ratingSource = resolvedRating.source

        let resolvedColor = Self.merged(
            incoming: incomingColor,
            incomingSource: source,
            current: colorLabel,
            currentSource: colorSource
        )
        merged.colorLabel = resolvedColor.value
        merged.colorSource = resolvedColor.source

        return merged
    }

    /// Records a value the user set. Always wins, by construction.
    func settingUserRating(_ newRating: TrackRating?) -> TrackClassification {
        var updated = self
        updated.rating = newRating
        updated.ratingSource = newRating == nil ? nil : .user
        return updated
    }

    func settingUserEnergy(_ newEnergy: TrackEnergy?) -> TrackClassification {
        var updated = self
        updated.energy = newEnergy
        updated.energySource = newEnergy == nil ? nil : .user
        return updated
    }

    func settingUserColorLabel(_ newColor: TrackColorLabel?) -> TrackClassification {
        var updated = self
        updated.colorLabel = newColor
        updated.colorSource = newColor == nil ? nil : .user
        return updated
    }
}
