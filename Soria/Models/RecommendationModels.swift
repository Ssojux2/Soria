import Foundation

struct ScoreBreakdown: Codable, Hashable {
    var embeddingSimilarity: Double
    var bpmCompatibility: Double
    var harmonicCompatibility: Double
    var energyFlow: Double
    var transitionRegionMatch: Double
    var externalMetadataScore: Double

    func finalScore(weights: RecommendationWeights) -> Double {
        let normalizedWeights = weights.normalized()
        return normalizedWeights.embed * embeddingSimilarity
            + normalizedWeights.bpm * bpmCompatibility
            + normalizedWeights.key * harmonicCompatibility
            + normalizedWeights.energy * energyFlow
            + normalizedWeights.introOutro * transitionRegionMatch
            + normalizedWeights.external * externalMetadataScore
    }
}

struct RecommendationCandidate: Identifiable, Hashable {
    let id: UUID
    let track: Track
    let score: Double
    let breakdown: ScoreBreakdown
    let vectorBreakdown: VectorScoreBreakdown
    let analysisFocus: AnalysisFocus?
    let mixabilityTags: [String]
    let matchReasons: [String]
    let matchedMemberships: [String]
    let scoreSessionID: UUID?
}

enum PlaylistBuildStage: String, Hashable, Sendable {
    case resolvingSeed
    case preparingCuratedPool
    case orderingTrack
    case finalizingQueue
    case completed
    case failed

    var displayName: String {
        switch self {
        case .resolvingSeed:
            return "Resolving Seed"
        case .preparingCuratedPool:
            return "Preparing Curated Pool"
        case .orderingTrack:
            return "Ordering Tracks"
        case .finalizingQueue:
            return "Finalizing Queue"
        case .completed:
            return "Playlist Ready"
        case .failed:
            return "Build Failed"
        }
    }
}

struct PlaylistBuildProgress: Hashable, Sendable {
    let stage: PlaylistBuildStage
    let completedCount: Int
    let totalCount: Int
    let progress: Double
    let currentSeedTitle: String
    let latestTrackTitle: String?
    let message: String

    var headlineText: String {
        switch stage {
        case .orderingTrack:
            let nextIndex = min(max(completedCount + 1, 1), max(totalCount, 1))
            return "Ordering track \(nextIndex)/\(max(totalCount, 1))"
        case .resolvingSeed:
            return "Resolving seed"
        case .preparingCuratedPool:
            return "Preparing curated pool"
        case .finalizingQueue:
            return "Finalizing queue"
        case .completed:
            return "Playlist ready"
        case .failed:
            return "Playlist build failed"
        }
    }

    var clampedProgress: Double {
        min(max(progress, 0), 1)
    }
}

struct RecommendationWeights: Codable, Hashable {
    var embed: Double = 0.45
    var bpm: Double = 0.15
    var key: Double = 0.15
    var energy: Double = 0.10
    var introOutro: Double = 0.10
    var external: Double = 0.05

    static let defaults = RecommendationWeights()

    func normalized() -> RecommendationWeights {
        let normalizedValues = normalizedWeightValues(
            [embed, bpm, key, energy, introOutro, external],
            fallback: [
                Self.defaults.embed,
                Self.defaults.bpm,
                Self.defaults.key,
                Self.defaults.energy,
                Self.defaults.introOutro,
                Self.defaults.external
            ]
        )
        return RecommendationWeights(
            embed: normalizedValues[0],
            bpm: normalizedValues[1],
            key: normalizedValues[2],
            energy: normalizedValues[3],
            introOutro: normalizedValues[4],
            external: normalizedValues[5]
        )
    }
}

struct MixsetVectorWeights: Codable, Hashable {
    var track: Double = 0.60
    var intro: Double = 0.10
    var middle: Double = 0.20
    var outro: Double = 0.10

    static let defaults = MixsetVectorWeights()

    func normalized() -> MixsetVectorWeights {
        let normalizedValues = normalizedWeightValues(
            [track, intro, middle, outro],
            fallback: [
                Self.defaults.track,
                Self.defaults.intro,
                Self.defaults.middle,
                Self.defaults.outro
            ]
        )
        return MixsetVectorWeights(
            track: normalizedValues[0],
            intro: normalizedValues[1],
            middle: normalizedValues[2],
            outro: normalizedValues[3]
        )
    }

    func asWorkerWeights() -> [String: Double] {
        let normalizedWeights = normalized()
        return [
            "tracks": normalizedWeights.track,
            "intro": normalizedWeights.intro,
            "middle": normalizedWeights.middle,
            "outro": normalizedWeights.outro
        ]
    }

    func fusedScore(
        trackScore: Double,
        introScore: Double,
        middleScore: Double,
        outroScore: Double
    ) -> Double {
        let normalizedWeights = normalized()
        return normalizedWeights.track * trackScore
            + normalizedWeights.intro * introScore
            + normalizedWeights.middle * middleScore
            + normalizedWeights.outro * outroScore
    }
}

enum GenreSearchMode: String, Codable, CaseIterable, Identifiable {
    case auto
    case lock
    case expand
    case any

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:
            return "Auto"
        case .lock:
            return "Lock"
        case .expand:
            return "Expand"
        case .any:
            return "Any"
        }
    }

    var helperText: String {
        switch self {
        case .auto:
            return "Follow the seed track family when Soria can infer one."
        case .lock:
            return "Keep recommendations inside the same genre family."
        case .expand:
            return "Favor the same family, but allow related families."
        case .any:
            return "Do not use genre family to constrain recommendations."
        }
    }
}

struct GenreDescriptor: Codable, Hashable {
    let canonicalGenre: String?
    let primaryFamily: String?
    let aliases: [String]
    let relatedFamilies: [String]
    let pathHints: [String]
}

struct RecommendationConstraints: Codable, Hashable {
    var targetBPMMin: Double?
    var targetBPMMax: Double?
    var analysisFocus: AnalysisFocus?
    var keyStrictness: Double = 0.6
    var genreContinuity: Double = 0.5
    var genreSearchMode: GenreSearchMode = .auto
    var maxDurationMinutes: Double?
    var includeFolders: [String] = []
    var excludeFolders: [String] = []
    var includeTags: [String] = []
    var excludeTags: [String] = []
    var externalMetadataPriority: Double = 1

    static let defaults = RecommendationConstraints()

    init(
        targetBPMMin: Double? = nil,
        targetBPMMax: Double? = nil,
        analysisFocus: AnalysisFocus? = nil,
        keyStrictness: Double = 0.6,
        genreContinuity: Double = 0.5,
        genreSearchMode: GenreSearchMode = .auto,
        maxDurationMinutes: Double? = nil,
        includeFolders: [String] = [],
        excludeFolders: [String] = [],
        includeTags: [String] = [],
        excludeTags: [String] = [],
        externalMetadataPriority: Double = 1
    ) {
        self.targetBPMMin = targetBPMMin
        self.targetBPMMax = targetBPMMax
        self.analysisFocus = analysisFocus
        self.keyStrictness = keyStrictness
        self.genreContinuity = genreContinuity
        self.genreSearchMode = genreSearchMode
        self.maxDurationMinutes = maxDurationMinutes
        self.includeFolders = includeFolders
        self.excludeFolders = excludeFolders
        self.includeTags = includeTags
        self.excludeTags = excludeTags
        self.externalMetadataPriority = externalMetadataPriority
    }

    init(from decoder: Decoder) throws {
        enum CodingKeys: String, CodingKey {
            case targetBPMMin
            case targetBPMMax
            case analysisFocus
            case keyStrictness
            case genreContinuity
            case genreSearchMode
            case maxDurationMinutes
            case includeFolders
            case excludeFolders
            case includeTags
            case excludeTags
            case externalMetadataPriority
            case prioritizeExternalMetadata
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        targetBPMMin = try container.decodeIfPresent(Double.self, forKey: .targetBPMMin)
        targetBPMMax = try container.decodeIfPresent(Double.self, forKey: .targetBPMMax)
        analysisFocus = try container.decodeIfPresent(AnalysisFocus.self, forKey: .analysisFocus)
        keyStrictness = try container.decodeIfPresent(Double.self, forKey: .keyStrictness) ?? Self.defaults.keyStrictness
        genreContinuity = try container.decodeIfPresent(Double.self, forKey: .genreContinuity) ?? Self.defaults.genreContinuity
        genreSearchMode = try container.decodeIfPresent(GenreSearchMode.self, forKey: .genreSearchMode) ?? Self.defaults.genreSearchMode
        maxDurationMinutes = try container.decodeIfPresent(Double.self, forKey: .maxDurationMinutes)
        includeFolders = try container.decodeIfPresent([String].self, forKey: .includeFolders) ?? []
        excludeFolders = try container.decodeIfPresent([String].self, forKey: .excludeFolders) ?? []
        includeTags = try container.decodeIfPresent([String].self, forKey: .includeTags) ?? []
        excludeTags = try container.decodeIfPresent([String].self, forKey: .excludeTags) ?? []
        if let priority = try container.decodeIfPresent(Double.self, forKey: .externalMetadataPriority) {
            externalMetadataPriority = priority
        } else {
            let prioritize = try container.decodeIfPresent(Bool.self, forKey: .prioritizeExternalMetadata) ?? true
            externalMetadataPriority = prioritize ? 1 : 0
        }
    }

    func normalizedForScoring() -> RecommendationConstraints {
        var normalized = self
        normalized.keyStrictness = keyStrictness.clamped(to: 0...1)
        normalized.genreContinuity = genreContinuity.clamped(to: 0...1)
        normalized.externalMetadataPriority = externalMetadataPriority.clamped(to: 0...1)
        if let min = targetBPMMin, let max = targetBPMMax, min > max {
            normalized.targetBPMMin = max
            normalized.targetBPMMax = min
        }
        return normalized
    }
}

private func normalizedWeightValues(_ values: [Double], fallback: [Double]) -> [Double] {
    let clampedValues = values.map { max(0, $0) }
    let total = clampedValues.reduce(0, +)
    if total > 0 {
        return clampedValues.map { $0 / total }
    }

    let fallbackTotal = fallback.reduce(0, +)
    guard fallbackTotal > 0 else {
        return Array(repeating: 1.0 / Double(max(values.count, 1)), count: values.count)
    }
    return fallback.map { $0 / fallbackTotal }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
