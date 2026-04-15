import Foundation

struct ScoreBreakdown: Codable, Hashable {
    var embeddingSimilarity: Double
    var bpmCompatibility: Double
    var harmonicCompatibility: Double
    var energyFlow: Double
    var transitionRegionMatch: Double
    var externalMetadataScore: Double

    func finalScore(weights: RecommendationWeights) -> Double {
        weights.embed * embeddingSimilarity
        + weights.bpm * bpmCompatibility
        + weights.key * harmonicCompatibility
        + weights.energy * energyFlow
        + weights.introOutro * transitionRegionMatch
        + weights.external * externalMetadataScore
    }
}

struct RecommendationCandidate: Identifiable, Hashable {
    let id: UUID
    let track: Track
    let score: Double
    let breakdown: ScoreBreakdown
    let analysisFocus: AnalysisFocus?
    let mixabilityTags: [String]
    let matchReasons: [String]
}

struct RecommendationWeights: Codable, Hashable {
    var embed: Double = 0.45
    var bpm: Double = 0.15
    var key: Double = 0.15
    var energy: Double = 0.10
    var introOutro: Double = 0.10
    var external: Double = 0.05
}

struct RecommendationConstraints: Codable, Hashable {
    var targetBPMMin: Double?
    var targetBPMMax: Double?
    var analysisFocus: AnalysisFocus?
    var keyStrictness: Double = 0.6
    var genreContinuity: Double = 0.5
    var maxDurationMinutes: Double?
    var includeFolders: [String] = []
    var excludeFolders: [String] = []
    var includeTags: [String] = []
    var excludeTags: [String] = []
    var prioritizeExternalMetadata: Bool = true
}
