import CoreGraphics
import Foundation

/// One track's precomputed place on the similarity map, plus the scalar features
/// the custom-axis modes plot.
///
/// These rows are cached to disk because deriving them is the expensive part of
/// opening the map: the projected coordinates need every 3072-dimension embedding,
/// and the audio features live inside `analysis_summary_json`, which also carries
/// the embedding and the waveform. Parsing that for a few thousand tracks is far
/// too slow to redo on every visit, and none of it changes until a track is
/// re-analyzed.
struct TrackMapFeatureRow: Codable, Hashable, Identifiable {
    let trackID: UUID
    /// Coordinate on the first principal component, before display normalization.
    var projectedX: Double
    /// Coordinate on the second principal component, before display normalization.
    var projectedY: Double
    var bpm: Double?
    var durationSec: Double
    var brightness: Double?
    var onsetDensity: Double?
    /// Mean of the analysis energy arc; the closest thing the app has to a single
    /// "how hard does this hit" number.
    var energy: Double?
    /// `Track.analyzedAt` as a Unix timestamp when this row was built. A track whose
    /// analysis date has moved on needs recomputing; everything else is reusable.
    var analyzedAtEpoch: Double?

    var id: UUID { trackID }

    init(
        trackID: UUID,
        projectedX: Double = 0,
        projectedY: Double = 0,
        bpm: Double? = nil,
        durationSec: Double = 0,
        brightness: Double? = nil,
        onsetDensity: Double? = nil,
        energy: Double? = nil,
        analyzedAtEpoch: Double? = nil
    ) {
        self.trackID = trackID
        self.projectedX = projectedX
        self.projectedY = projectedY
        self.bpm = bpm
        self.durationSec = durationSec
        self.brightness = brightness
        self.onsetDensity = onsetDensity
        self.energy = energy
        self.analyzedAtEpoch = analyzedAtEpoch
    }

    func value(for axis: TrackMapAxis) -> Double? {
        switch axis {
        case .bpm: return bpm
        case .duration: return durationSec > 0 ? durationSec : nil
        case .brightness: return brightness
        case .onsetDensity: return onsetDensity
        case .energy: return energy
        }
    }

    /// True when this row was built from an analysis run that has since been redone.
    func isStale(against analyzedAt: Date?) -> Bool {
        let current = analyzedAt?.timeIntervalSince1970
        switch (analyzedAtEpoch, current) {
        case (nil, nil):
            return false
        case let (cached?, latest?):
            // Stored as a JSON double, so compare with a tolerance rather than ==.
            return abs(cached - latest) > 0.5
        default:
            return true
        }
    }
}

/// A measurable track property that can be put on an axis.
///
/// Deliberately excludes the two principal components: those are the `similarity`
/// layout, and offering "component 1 on X, BPM on Y" would invite combinations that
/// look meaningful but are not.
enum TrackMapAxis: String, Codable, CaseIterable, Identifiable {
    case bpm
    case duration
    case brightness
    case onsetDensity
    case energy

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bpm: return "BPM"
        case .duration: return "Length"
        case .brightness: return "Brightness"
        case .onsetDensity: return "Onset Density"
        case .energy: return "Energy"
        }
    }
}

enum TrackMapLayoutMode: String, Codable, CaseIterable, Identifiable {
    /// Both axes come from the PCA projection of the audio embeddings.
    case similarity
    /// Each axis is a track property the user picked.
    case customAxes

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .similarity: return "Similarity Map"
        case .customAxes: return "Custom Axes"
        }
    }
}

/// What the dot colours mean.
///
/// There is deliberately no "prep status" mode: only prepared tracks have the
/// embeddings and analysis the map is built from, so every dot would be one colour.
enum TrackMapColorMode: String, Codable, CaseIterable, Identifiable {
    /// Genre family derived from the track's own tag through `GenreTaxonomy`.
    case genreFamily
    /// Which Soria collection, if any, already contains the track.
    case collection
    /// Coarse tempo bands.
    case bpmRange

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .genreFamily: return "Genre"
        case .collection: return "Soria Folder"
        case .bpmRange: return "BPM Range"
        }
    }
}

/// A single dot as the canvas draws it.
struct TrackMapPoint: Identifiable, Hashable {
    let id: UUID
    /// Position in `[0, 1]` on both axes, y measured upward.
    let normalized: CGPoint
    /// Groups dots that share a colour; also the legend key.
    let colorKey: String
}

/// A legend entry: one colour, its label, and how many dots carry it.
struct TrackMapLegendEntry: Identifiable, Hashable {
    let id: String
    let displayName: String
    let count: Int
}

/// The mean vector and top two principal components of one embedding profile.
///
/// Persisting this is what keeps the map stable over time. Recomputing PCA from
/// scratch whenever the library grows would shift and possibly flip both axes, so
/// the cluster a user learned to recognise in the top-left would move. With a
/// stored basis, a newly analyzed track is placed with two dot products and
/// everything already on the map stays exactly where it was.
struct TrackMapProjectionBasis: Codable, Hashable {
    let profileID: String
    let dimension: Int
    let mean: [Double]
    let componentX: [Double]
    let componentY: [Double]
    /// Share of total variance the two components capture, in `[0, 1]`. Surfaced in
    /// the UI so a low-information projection cannot masquerade as a precise map.
    let explainedVarianceRatio: Double
    let sourceTrackCount: Int

    var isUsable: Bool {
        dimension > 0
            && mean.count == dimension
            && componentX.count == dimension
            && componentY.count == dimension
    }
}

/// What one profile's cache file holds.
struct TrackMapCacheFile: Codable, Hashable {
    /// Bumped when the layout maths changes in a way that invalidates stored
    /// coordinates, so an old file is discarded instead of silently misplacing dots.
    static let currentVersion = 1

    var version: Int
    var basis: TrackMapProjectionBasis
    var rows: [TrackMapFeatureRow]

    init(version: Int = TrackMapCacheFile.currentVersion, basis: TrackMapProjectionBasis, rows: [TrackMapFeatureRow]) {
        self.version = version
        self.basis = basis
        self.rows = rows
    }
}
