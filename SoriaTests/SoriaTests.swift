import Foundation
import Testing
@testable import Soria

struct SoriaTests {
    @Test func recommendationRankingPrefersCloserBPMAndKey() {
        let engine = RecommendationEngine()
        let seed = Track(
            id: UUID(),
            filePath: "/a/seed.mp3",
            fileName: "seed.mp3",
            title: "Seed",
            artist: "DJ",
            album: "",
            genre: "House",
            duration: 300,
            sampleRate: 44100,
            bpm: 124,
            musicalKey: "8A",
            modifiedTime: Date(),
            contentHash: "seed",
            analyzedAt: Date(),
            hasSeratoMetadata: true,
            hasRekordboxMetadata: false
        )

        let good = Track(
            id: UUID(),
            filePath: "/a/good.mp3",
            fileName: "good.mp3",
            title: "Good",
            artist: "DJ",
            album: "",
            genre: "House",
            duration: 320,
            sampleRate: 44100,
            bpm: 125,
            musicalKey: "9A",
            modifiedTime: Date(),
            contentHash: "good",
            analyzedAt: Date(),
            hasSeratoMetadata: true,
            hasRekordboxMetadata: true
        )

        let weak = Track(
            id: UUID(),
            filePath: "/a/weak.mp3",
            fileName: "weak.mp3",
            title: "Weak",
            artist: "DJ",
            album: "",
            genre: "HipHop",
            duration: 280,
            sampleRate: 44100,
            bpm: 140,
            musicalKey: "2B",
            modifiedTime: Date(),
            contentHash: "weak",
            analyzedAt: Date(),
            hasSeratoMetadata: false,
            hasRekordboxMetadata: false
        )

        let recommendations = engine.recommendNextTracks(
            seed: seed,
            candidates: [good, weak],
            embeddingsByTrackID: [
                seed.id: [1, 0, 0],
                good.id: [0.95, 0.1, 0],
                weak.id: [0.2, 0.8, 0]
            ],
            vectorSimilarityByPath: [:],
            constraints: RecommendationConstraints(),
            weights: RecommendationWeights(),
            limit: 2,
            excludeTrackIDs: []
        )

        #expect(recommendations.count == 2)
        #expect(recommendations.first?.track.id == good.id)
    }

    @Test func scoreBreakdownComputesFinalScore() {
        let breakdown = ScoreBreakdown(
            embeddingSimilarity: 1,
            bpmCompatibility: 1,
            harmonicCompatibility: 1,
            energyFlow: 1,
            transitionRegionMatch: 1,
            externalMetadataScore: 1
        )
        let score = breakdown.finalScore(weights: RecommendationWeights())
        #expect(score > 0.99)
    }

    @Test func recommendationHandlesParallelKeysAndHalfDoubleTempo() {
        let engine = RecommendationEngine()
        let seed = Track(
            id: UUID(),
            filePath: "/a/seed.mp3",
            fileName: "seed.mp3",
            title: "Seed",
            artist: "DJ",
            album: "",
            genre: "Techno",
            duration: 360,
            sampleRate: 44100,
            bpm: 70,
            musicalKey: "8A",
            modifiedTime: Date(),
            contentHash: "seed",
            analyzedAt: Date(),
            hasSeratoMetadata: false,
            hasRekordboxMetadata: false
        )

        let doubleTempo = Track(
            id: UUID(),
            filePath: "/a/double.mp3",
            fileName: "double.mp3",
            title: "Double",
            artist: "DJ",
            album: "",
            genre: "Techno",
            duration: 370,
            sampleRate: 44100,
            bpm: 140,
            musicalKey: "8B",
            modifiedTime: Date(),
            contentHash: "double",
            analyzedAt: Date(),
            hasSeratoMetadata: false,
            hasRekordboxMetadata: true
        )

        let recommendations = engine.recommendNextTracks(
            seed: seed,
            candidates: [doubleTempo],
            embeddingsByTrackID: [
                seed.id: [1, 0, 0],
                doubleTempo.id: [0.9, 0.1, 0]
            ],
            vectorSimilarityByPath: [:],
            constraints: RecommendationConstraints(),
            weights: RecommendationWeights(),
            limit: 1,
            excludeTrackIDs: []
        )

        #expect(recommendations.first?.breakdown.bpmCompatibility ?? 0 > 0.7)
        #expect(recommendations.first?.breakdown.harmonicCompatibility ?? 0 > 0.5)
    }
}
