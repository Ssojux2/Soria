import Foundation

struct RecommendationEngine {
    func matchesConstraints(
        track: Track,
        summary: TrackAnalysisSummary?,
        constraints: RecommendationConstraints
    ) -> Bool {
        if let focus = constraints.analysisFocus, summary?.analysisFocus != focus { return false }
        if let min = constraints.targetBPMMin, let bpm = track.bpm, bpm < min { return false }
        if let max = constraints.targetBPMMax, let bpm = track.bpm, bpm > max { return false }
        if let maxMinutes = constraints.maxDurationMinutes, track.duration > maxMinutes * 60 { return false }
        if !constraints.includeFolders.isEmpty && !constraints.includeFolders.contains(where: { track.filePath.hasPrefix($0) }) {
            return false
        }
        if constraints.excludeFolders.contains(where: { track.filePath.hasPrefix($0) }) {
            return false
        }
        return matchesTagFilters(
            track: track,
            summary: summary,
            includeTags: constraints.includeTags,
            excludeTags: constraints.excludeTags
        )
    }

    func recommendNextTracks(
        seed: Track,
        candidates: [Track],
        embeddingsByTrackID: [UUID: [Double]],
        summariesByTrackID: [UUID: TrackAnalysisSummary],
        vectorSimilarityByPath: [String: Double] = [:],
        vectorBreakdownByPath: [String: VectorScoreBreakdown] = [:],
        libraryRoots: [String] = [],
        constraints: RecommendationConstraints,
        weights: RecommendationWeights,
        vectorWeights: MixsetVectorWeights,
        limit: Int = 12,
        excludeTrackIDs: Set<UUID> = []
    ) -> [RecommendationCandidate] {
        let effectiveConstraints = constraints.normalizedForScoring()
        let seedEmbedding = embeddingsByTrackID[seed.id] ?? []
        let seedSummary = summariesByTrackID[seed.id]
        let seedGenreDescriptor = genreDescriptor(for: seed, libraryRoots: libraryRoots)

        let filtered = candidates.filter { track in
            guard !excludeTrackIDs.contains(track.id), track.id != seed.id else { return false }
            let trackGenreDescriptor = genreDescriptor(for: track, libraryRoots: libraryRoots)
            if shouldExclude(
                descriptor: trackGenreDescriptor,
                comparedTo: seedGenreDescriptor,
                mode: effectiveConstraints.genreSearchMode
            ) {
                return false
            }
            return matchesConstraints(
                track: track,
                summary: summariesByTrackID[track.id],
                constraints: effectiveConstraints
            )
        }

        return filtered.compactMap { track in
            let trackEmbedding = embeddingsByTrackID[track.id] ?? []
            let fallbackEmbed = cosineSimilarity(seedEmbedding, trackEmbedding)
            let vectorBreakdown = vectorBreakdownByPath[track.filePath] ?? VectorScoreBreakdown(
                fusedScore: vectorSimilarityByPath[track.filePath] ?? fallbackEmbed,
                trackScore: vectorSimilarityByPath[track.filePath] ?? fallbackEmbed,
                introScore: 0,
                middleScore: 0,
                outroScore: 0,
                bestMatchedCollection: "tracks"
            )
            let embedScore = vectorBreakdown.fusedScore
            let bpmScore = bpmCompatibility(seed: seed.bpm, next: track.bpm)
            let harmonicScore = keyCompatibility(
                seed: seed.musicalKey,
                next: track.musicalKey,
                strictness: effectiveConstraints.keyStrictness
            )
            let energyScore = energyFlow(
                seed: seed,
                seedSummary: seedSummary,
                next: track,
                nextSummary: summariesByTrackID[track.id],
                continuity: effectiveConstraints.genreContinuity
            )
            let transitionScore = transitionSuitability(
                seed: seed,
                seedSummary: seedSummary,
                next: track,
                nextSummary: summariesByTrackID[track.id],
                seedDescriptor: seedGenreDescriptor,
                nextDescriptor: genreDescriptor(for: track, libraryRoots: libraryRoots),
                continuity: effectiveConstraints.genreContinuity
            )
            let externalScore = externalMetadataConfidence(
                for: track,
                priority: effectiveConstraints.externalMetadataPriority
            )
            let summary = summariesByTrackID[track.id]

            let breakdown = ScoreBreakdown(
                embeddingSimilarity: embedScore,
                bpmCompatibility: bpmScore,
                harmonicCompatibility: harmonicScore,
                energyFlow: energyScore,
                transitionRegionMatch: transitionScore,
                externalMetadataScore: externalScore
            )

            return RecommendationCandidate(
                id: track.id,
                track: track,
                score: breakdown.finalScore(weights: weights),
                breakdown: breakdown,
                vectorBreakdown: VectorScoreBreakdown(
                    fusedScore: vectorWeights.fusedScore(
                        trackScore: vectorBreakdown.trackScore,
                        introScore: vectorBreakdown.introScore,
                        middleScore: vectorBreakdown.middleScore,
                        outroScore: vectorBreakdown.outroScore
                    ),
                    trackScore: vectorBreakdown.trackScore,
                    introScore: vectorBreakdown.introScore,
                    middleScore: vectorBreakdown.middleScore,
                    outroScore: vectorBreakdown.outroScore,
                    bestMatchedCollection: vectorBreakdown.bestMatchedCollection
                ),
                analysisFocus: summary?.analysisFocus,
                mixabilityTags: summary?.mixabilityTags ?? [],
                matchReasons: matchReasons(
                    track: track,
                    genreDescriptor: genreDescriptor(for: track, libraryRoots: libraryRoots),
                    summary: summary,
                    breakdown: breakdown
                ),
                matchedMemberships: [],
                scoreSessionID: nil
            )
        }
        .sorted { $0.score > $1.score }
        .prefix(limit)
        .map { $0 }
    }

    private func cosineSimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return 0 }
        let dot = zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
        let l = sqrt(lhs.reduce(0) { $0 + $1 * $1 })
        let r = sqrt(rhs.reduce(0) { $0 + $1 * $1 })
        guard l > 0, r > 0 else { return 0 }
        return max(0, min(1, dot / (l * r)))
    }

    private func bpmCompatibility(seed: Double?, next: Double?) -> Double {
        guard let seed, let next else { return 0.4 }
        let directDiff = abs(seed - next)
        let halfDoubleDiff = min(abs(seed - next * 2), abs(seed * 2 - next))
        let diff = min(directDiff, halfDoubleDiff)
        if diff <= 2 { return 1.0 }
        if diff <= 5 { return 0.8 }
        if diff <= 8 { return 0.55 }
        return 0.2
    }

    private func keyCompatibility(seed: String?, next: String?, strictness: Double) -> Double {
        guard let seed, let next else { return 0.4 }
        if seed == next { return 1.0 }
        if areParallelCamelot(seed, next) { return max(0.55, 0.85 * strictness) }
        // 한국어: 간단한 Camelot 인접 키 호환 규칙을 적용합니다.
        if areNeighboringCamelot(seed, next) { return max(0.5, 0.9 * strictness) }
        return 0.2 * (1 - strictness)
    }

    private func areNeighboringCamelot(_ a: String, _ b: String) -> Bool {
        let regex = try? NSRegularExpression(pattern: "^([0-9]{1,2})([AB])$", options: .caseInsensitive)
        func parse(_ key: String) -> (Int, String)? {
            let range = NSRange(location: 0, length: key.utf16.count)
            guard let match = regex?.firstMatch(in: key, options: [], range: range), match.numberOfRanges == 3,
                  let nRange = Range(match.range(at: 1), in: key),
                  let lRange = Range(match.range(at: 2), in: key),
                  let number = Int(key[nRange])
            else { return nil }
            return (number, String(key[lRange]).uppercased())
        }
        guard let p1 = parse(a), let p2 = parse(b), p1.1 == p2.1 else { return false }
        let diff = abs(p1.0 - p2.0)
        return diff == 1 || diff == 11
    }

    private func areParallelCamelot(_ a: String, _ b: String) -> Bool {
        let regex = try? NSRegularExpression(pattern: "^([0-9]{1,2})([AB])$", options: .caseInsensitive)
        func parse(_ key: String) -> (Int, String)? {
            let range = NSRange(location: 0, length: key.utf16.count)
            guard let match = regex?.firstMatch(in: key, options: [], range: range), match.numberOfRanges == 3,
                  let numberRange = Range(match.range(at: 1), in: key),
                  let letterRange = Range(match.range(at: 2), in: key),
                  let number = Int(key[numberRange])
            else { return nil }
            return (number, String(key[letterRange]).uppercased())
        }
        guard let lhs = parse(a), let rhs = parse(b) else { return false }
        return lhs.0 == rhs.0 && lhs.1 != rhs.1
    }

    private func energyFlow(
        seed: Track,
        seedSummary: TrackAnalysisSummary?,
        next: Track,
        nextSummary: TrackAnalysisSummary?,
        continuity: Double
    ) -> Double {
        let s = seed.bpm ?? 120
        let n = next.bpm ?? 120
        let ratio = n / max(1, s)
        let base: Double
        if ratio >= 0.96, ratio <= 1.08 { base = 0.9 }
        else if ratio >= 0.90, ratio <= 1.15 { base = 0.7 }
        else { base = 0.4 }
        let energyBias = 0.15 * (1 - continuity)
        let energyArcBonus: Double
        if
            let seedMiddle = seedSummary?.energyArc.dropFirst().first,
            let nextIntro = nextSummary?.energyArc.first
        {
            energyArcBonus = max(0, 0.12 - abs(seedMiddle - nextIntro))
        } else {
            energyArcBonus = 0
        }
        return min(1.0, base + (ratio >= 1.0 ? energyBias : 0) + energyArcBonus)
    }

    private func transitionSuitability(
        seed: Track,
        seedSummary: TrackAnalysisSummary?,
        next: Track,
        nextSummary: TrackAnalysisSummary?,
        seedDescriptor: GenreDescriptor,
        nextDescriptor: GenreDescriptor,
        continuity: Double
    ) -> Double {
        let score: Double
        switch genreRelation(seedDescriptor: seedDescriptor, nextDescriptor: nextDescriptor) {
        case .same:
            score = 0.65 + 0.35 * continuity
        case .related:
            score = 0.56 + 0.24 * continuity
        case .none:
            score = 0.45 + 0.40 * (1 - continuity)
        }
        var adjustedScore = score

        if let seedSummary, seedSummary.outroLengthSec >= 24 {
            adjustedScore += 0.08
        }
        if let nextSummary, nextSummary.introLengthSec >= 24 {
            adjustedScore += 0.08
        }
        if let nextSummary, nextSummary.mixabilityTags.contains("clean_outro") || nextSummary.mixabilityTags.contains("long_intro") {
            adjustedScore += 0.05
        }
        return min(1.0, adjustedScore)
    }

    private func externalMetadataConfidence(for track: Track, priority: Double) -> Double {
        let vendorCoverageScore: Double
        if track.hasSeratoMetadata && track.hasRekordboxMetadata {
            vendorCoverageScore = 1.0
        } else if track.hasSeratoMetadata || track.hasRekordboxMetadata {
            vendorCoverageScore = 0.75
        } else {
            vendorCoverageScore = 0.35
        }
        let clampedPriority = min(max(priority, 0), 1)
        return 0.5 + ((vendorCoverageScore - 0.5) * clampedPriority)
    }

    private func matchesTagFilters(
        track: Track,
        summary: TrackAnalysisSummary?,
        includeTags: [String],
        excludeTags: [String]
    ) -> Bool {
        let searchable = (
            [track.genre, track.artist, track.album, track.title]
            + (summary?.mixabilityTags ?? [])
            + [summary?.analysisFocus.displayName ?? ""]
        )
        .joined(separator: " ")
        .lowercased()
        if !includeTags.isEmpty {
            let hasInclude = includeTags.contains { tag in
                searchable.contains(tag.lowercased())
            }
            if !hasInclude { return false }
        }
        let hasExcluded = excludeTags.contains { tag in
            searchable.contains(tag.lowercased())
        }
        return !hasExcluded
    }

    private func matchReasons(
        track: Track,
        genreDescriptor: GenreDescriptor,
        summary: TrackAnalysisSummary?,
        breakdown: ScoreBreakdown
    ) -> [String] {
        var reasons: [String] = []
        if let summary {
            reasons.append(summary.analysisFocus.displayName)
            reasons.append(contentsOf: summary.mixabilityTags.prefix(2).map { $0.replacingOccurrences(of: "_", with: " ").capitalized })
        }
        if breakdown.transitionRegionMatch >= 0.75 {
            reasons.append("Blend-friendly intro/outro")
        }
        if breakdown.embeddingSimilarity >= 0.75 {
            reasons.append("High embedding match")
        }
        if reasons.isEmpty, let family = genreDescriptor.primaryFamily, !family.isEmpty {
            reasons.append(family.capitalized + " family")
        }
        if reasons.isEmpty, !track.genre.isEmpty {
            reasons.append(track.genre)
        }
        return Array(reasons.prefix(3))
    }

    private func shouldExclude(
        descriptor: GenreDescriptor,
        comparedTo seedDescriptor: GenreDescriptor,
        mode: GenreSearchMode
    ) -> Bool {
        guard mode == .lock, let seedFamily = seedDescriptor.primaryFamily, !seedFamily.isEmpty else {
            return false
        }
        return descriptor.primaryFamily != seedFamily
    }

    private func genreRelation(seedDescriptor: GenreDescriptor, nextDescriptor: GenreDescriptor) -> GenreRelation {
        if let seedFamily = seedDescriptor.primaryFamily,
           let nextFamily = nextDescriptor.primaryFamily
        {
            if seedFamily == nextFamily {
                return .same
            }
            if relatedFamilies(for: seedFamily).contains(nextFamily) || relatedFamilies(for: nextFamily).contains(seedFamily) {
                return .related
            }
        }

        let sharedHints = Set(seedDescriptor.pathHints.map(normalizeGenreText)).intersection(
            nextDescriptor.pathHints.map(normalizeGenreText)
        )
        return sharedHints.isEmpty ? .none : .related
    }

    private func genreDescriptor(for track: Track, libraryRoots: [String]) -> GenreDescriptor {
        let pathHints = folderPathHints(for: track.filePath, libraryRoots: libraryRoots)
        let rawGenre = normalizeGenreText(track.genre)
        let aliases = Array(
            Set(
                ([rawGenre] + pathHints.map(normalizeGenreText))
                    .filter { !$0.isEmpty }
            )
        ).sorted()
        let primaryFamily = aliases.compactMap(family(for:)).first
        let canonicalGenre = rawGenre.isEmpty ? pathHints.first : track.genre.trimmingCharacters(in: .whitespacesAndNewlines)
        return GenreDescriptor(
            canonicalGenre: canonicalGenre?.nilIfBlank,
            primaryFamily: primaryFamily,
            aliases: aliases,
            relatedFamilies: primaryFamily.map(relatedFamilies(for:)) ?? [],
            pathHints: pathHints
        )
    }

    private func folderPathHints(for filePath: String, libraryRoots: [String]) -> [String] {
        let normalizedPath = TrackPathNormalizer.normalizedAbsolutePath(filePath)
        let normalizedRoots = libraryRoots
            .map(TrackPathNormalizer.normalizedAbsolutePath)
            .filter { !$0.isEmpty && normalizedPath.hasPrefix($0) }
            .sorted { $0.count > $1.count }
        guard let bestRoot = normalizedRoots.first else { return [] }

        let rootComponents = URL(fileURLWithPath: bestRoot).pathComponents
        let pathComponents = URL(fileURLWithPath: normalizedPath).pathComponents
        guard pathComponents.count > rootComponents.count else { return [] }
        let relativeComponents = Array(pathComponents.dropFirst(rootComponents.count).dropLast())
        let endIndex = min(2, relativeComponents.count)
        return Array(relativeComponents[..<endIndex])
    }

    private func family(for value: String) -> String? {
        for (family, tokens) in genreFamilyKeywords where tokens.contains(where: value.contains) {
            return family
        }
        return nil
    }

    private func relatedFamilies(for family: String) -> [String] {
        relatedGenreFamilies[family] ?? []
    }

    private func normalizeGenreText(_ value: String) -> String {
        let lowered = value.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        return String(scalars)
            .replacingOccurrences(of: "hip hop", with: "hiphop")
            .replacingOccurrences(of: "r&b", with: "rnb")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private let genreFamilyKeywords: [(String, [String])] = [
        ("house", ["house", "tech house", "deep house", "progressive house", "jackin", "afro house"]),
        ("techno", ["techno", "melodic techno", "peak time", "hard techno"]),
        ("disco", ["disco", "nu disco", "disco edit"]),
        ("hiphop", ["hiphop", "rap", "trap"]),
        ("rnb", ["rnb", "soul"]),
        ("bass", ["bass", "dubstep", "future bass"]),
        ("dnb", ["drum and bass", "dnb", "liquid"]),
        ("breakbeat", ["breakbeat", "breaks"]),
        ("reggae", ["reggae", "dancehall"]),
        ("latin", ["latin", "reggaeton", "baile", "afro"]),
        ("funk", ["funk", "boogie"]),
        ("pop", ["pop", "open format"])
    ]

    private let relatedGenreFamilies: [String: [String]] = [
        "house": ["techno", "disco", "latin", "funk"],
        "techno": ["house", "breakbeat", "bass"],
        "disco": ["house", "funk", "pop"],
        "hiphop": ["rnb", "pop", "bass"],
        "rnb": ["hiphop", "pop", "funk"],
        "bass": ["techno", "breakbeat", "dnb", "hiphop"],
        "dnb": ["bass", "breakbeat"],
        "breakbeat": ["bass", "techno", "dnb"],
        "reggae": ["latin", "hiphop"],
        "latin": ["house", "reggae", "pop"],
        "funk": ["disco", "house", "rnb"],
        "pop": ["rnb", "hiphop", "disco", "latin"]
    ]

    private enum GenreRelation {
        case same
        case related
        case none
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
