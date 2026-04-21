import Foundation
import SQLite3
import Testing
@testable import Soria

@MainActor
@Suite(.serialized)
struct SoriaTests {
    @Test func appSettingsBypassSecureLookupsDuringUITestLaunch() {
        #expect(AppSettingsStore.shouldBypassSecureLookupsForUITests(arguments: ["UITEST_SKIP_INITIAL_SETUP"]))
        #expect(AppSettingsStore.shouldBypassSecureLookupsForUITests(arguments: ["UITEST_LIBRARY_STATE=prepared"]))
        #expect(!AppSettingsStore.shouldBypassSecureLookupsForUITests(arguments: ["UITEST_START_IN_MIX_ASSISTANT"]))
    }

    @Test func appSettingsUseEnvironmentOverrideWhenUITestsBypassKeychain() {
        let loaded = AppSettingsStore.loadGoogleAIAPIKey(
            arguments: ["UITEST_LIBRARY_STATE=prepared"],
            environment: ["GOOGLE_AI_API_KEY": " ui-test-key "]
        )

        #expect(loaded == "ui-test-key")
    }

    @Test func appSettingsPreferDetectedProjectRuntimeOverStoredBundlePath() {
        let bundledPath = "/tmp/Current.app/Contents/Resources/analysis-worker/.venv/bin/python"
        let staleBundlePath = "/tmp/Old.app/Contents/Resources/analysis-worker/.venv/bin/python"
        let detectedProjectPath = "\(NSHomeDirectory())/Documents/BluePenguin/Soriga/Soria/analysis-worker/.venv/bin/python"

        let resolved = AppSettingsStore.resolvedWorkerRuntimePath(
            storedValue: staleBundlePath,
            bundledPath: bundledPath,
            detectedProjectPath: detectedProjectPath
        )

        #expect(resolved == detectedProjectPath)
    }

    @Test func appSettingsKeepCustomWorkerRuntimeOutsideProtectedFolders() throws {
        let bundledPath = "/tmp/Soria.app/Contents/Resources/analysis-worker/main.py"
        let customDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: customDirectory, withIntermediateDirectories: true)
        let customFile = customDirectory.appendingPathComponent("main.py")
        try Data("print('worker')\n".utf8).write(to: customFile)

        let resolved = AppSettingsStore.resolvedWorkerRuntimePath(
            storedValue: customFile.path,
            bundledPath: bundledPath,
            detectedProjectPath: "\(NSHomeDirectory())/Documents/BluePenguin/Soriga/Soria/analysis-worker/main.py"
        )

        #expect(resolved == customFile.path)
    }

    @Test func appSettingsFallbackToCurrentBundleWhenProjectRuntimeIsUnavailable() {
        let staleBundlePath = "/tmp/Old.app/Contents/Resources/analysis-worker/main.py"
        let currentBundlePath = "/tmp/Current.app/Contents/Resources/analysis-worker/main.py"

        let resolved = AppSettingsStore.resolvedWorkerRuntimePath(
            storedValue: staleBundlePath,
            bundledPath: currentBundlePath,
            detectedProjectPath: nil
        )

        #expect(resolved == currentBundlePath)
    }

    @Test func bundleAnalysisWorkerBuildPhaseAlwaysRuns() throws {
        let projectFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Soria.xcodeproj/project.pbxproj")
        let contents = try String(contentsOf: projectFile, encoding: .utf8)

        guard
            let start = contents.range(of: "84B5A1D331B91B4200A8EB7B /* Bundle Analysis Worker */ = {"),
            let end = contents[start.upperBound...].range(of: "};")
        else {
            Issue.record("Bundle Analysis Worker build phase was not found in project.pbxproj.")
            return
        }

        let block = String(contents[start.lowerBound..<end.upperBound])
        #expect(block.contains("alwaysOutOfDate = 1;"))
        #expect(!block.contains("analysis-worker/.venv/pyvenv.cfg"))
    }

    @Test func recommendationRankingPrefersCloserBPMAndKey() {
        let engine = RecommendationEngine()
        let seed = makeTrack(
            path: "/a/seed.mp3",
            title: "Seed",
            genre: "House",
            bpm: 124,
            musicalKey: "8A",
            analyzedAt: Date(),
            hasSeratoMetadata: true
        )
        let good = makeTrack(
            path: "/a/good.mp3",
            title: "Good",
            genre: "House",
            bpm: 125,
            musicalKey: "9A",
            analyzedAt: Date(),
            hasSeratoMetadata: true,
            hasRekordboxMetadata: true
        )
        let weak = makeTrack(
            path: "/a/weak.mp3",
            title: "Weak",
            genre: "HipHop",
            bpm: 140,
            musicalKey: "2B",
            analyzedAt: Date()
        )

        let recommendations = engine.recommendNextTracks(
            seed: seed,
            candidates: [good, weak],
            embeddingsByTrackID: [
                seed.id: [1, 0, 0],
                good.id: [0.95, 0.1, 0],
                weak.id: [0.2, 0.8, 0]
            ],
            summariesByTrackID: [:],
            vectorSimilarityByPath: [:],
            constraints: RecommendationConstraints(),
            weights: RecommendationWeights(),
            vectorWeights: MixsetVectorWeights(),
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

    @Test func recommendationWeightsNormalizeBeforeScoring() {
        let weights = RecommendationWeights(embed: 4, bpm: 2, key: 2, energy: 1, introOutro: 1, external: 0)
        let normalized = weights.normalized()

        let totalWeight =
            normalized.embed
            + normalized.bpm
            + normalized.key
            + normalized.energy
            + normalized.introOutro
            + normalized.external
        #expect(abs(totalWeight - 1.0) < 0.0001)

        let breakdown = ScoreBreakdown(
            embeddingSimilarity: 0.9,
            bpmCompatibility: 0.8,
            harmonicCompatibility: 0.7,
            energyFlow: 0.6,
            transitionRegionMatch: 0.5,
            externalMetadataScore: 0.4
        )
        let score = breakdown.finalScore(weights: weights)

        #expect(score >= 0)
        #expect(score <= 1)
    }

    @Test func mixsetVectorWeightsNormalizeBeforeFusingScores() {
        let weights = MixsetVectorWeights(track: 6, intro: 1, middle: 2, outro: 1)
        let normalized = weights.normalized()

        let totalWeight = normalized.track + normalized.intro + normalized.middle + normalized.outro
        #expect(abs(totalWeight - 1.0) < 0.0001)

        let fused = weights.fusedScore(trackScore: 0.9, introScore: 0.8, middleScore: 0.7, outroScore: 0.6)
        #expect(fused >= 0)
        #expect(fused <= 1)
    }

    @Test func recommendationHandlesParallelKeysAndHalfDoubleTempo() {
        let engine = RecommendationEngine()
        let seed = makeTrack(
            path: "/a/seed.mp3",
            title: "Seed",
            genre: "Techno",
            bpm: 70,
            musicalKey: "8A",
            analyzedAt: Date()
        )
        let doubleTempo = makeTrack(
            path: "/a/double.mp3",
            title: "Double",
            genre: "Techno",
            bpm: 140,
            musicalKey: "8B",
            analyzedAt: Date(),
            hasRekordboxMetadata: true
        )

        let recommendations = engine.recommendNextTracks(
            seed: seed,
            candidates: [doubleTempo],
            embeddingsByTrackID: [
                seed.id: [1, 0, 0],
                doubleTempo.id: [0.9, 0.1, 0]
            ],
            summariesByTrackID: [:],
            vectorSimilarityByPath: [:],
            constraints: RecommendationConstraints(),
            weights: RecommendationWeights(),
            vectorWeights: MixsetVectorWeights(),
            limit: 1,
            excludeTrackIDs: []
        )

        #expect(recommendations.first?.breakdown.bpmCompatibility ?? 0 > 0.7)
        #expect(recommendations.first?.breakdown.harmonicCompatibility ?? 0 > 0.5)
    }

    @Test func recommendationKeepsVendorOnlyTracksAsCandidatesWithoutEmbeddings() {
        let engine = RecommendationEngine()
        let seed = makeTrack(
            path: "/a/seed.mp3",
            title: "Seed",
            genre: "House",
            bpm: 122,
            musicalKey: "8A",
            analyzedAt: Date(),
            hasSeratoMetadata: true
        )
        let vendorOnly = makeTrack(
            path: "/a/vendor.mp3",
            title: "Vendor",
            genre: "House",
            bpm: 123,
            musicalKey: "9A",
            hasSeratoMetadata: true,
            bpmSource: .serato,
            keySource: .serato
        )

        let recommendations = engine.recommendNextTracks(
            seed: seed,
            candidates: [vendorOnly],
            embeddingsByTrackID: [seed.id: [1, 0, 0]],
            summariesByTrackID: [:],
            vectorSimilarityByPath: [:],
            constraints: RecommendationConstraints(),
            weights: RecommendationWeights(),
            vectorWeights: MixsetVectorWeights(),
            limit: 1,
            excludeTrackIDs: []
        )

        #expect(recommendations.count == 1)
        #expect(recommendations.first?.track.id == vendorOnly.id)
        #expect(recommendations.first?.breakdown.externalMetadataScore ?? 0 >= 0.75)
    }

    @Test func externalMetadataPriorityInterpolatesBetweenNeutralAndVendorConfidence() {
        let engine = RecommendationEngine()
        let seed = makeTrack(
            path: "/a/seed.mp3",
            title: "Seed",
            genre: "House",
            bpm: 122,
            musicalKey: "8A",
            analyzedAt: Date()
        )
        let vendorOnly = makeTrack(
            path: "/a/vendor.mp3",
            title: "Vendor",
            genre: "House",
            bpm: 123,
            musicalKey: "9A",
            analyzedAt: Date(),
            hasSeratoMetadata: true
        )

        var neutralConstraints = RecommendationConstraints()
        neutralConstraints.externalMetadataPriority = 0
        var midConstraints = RecommendationConstraints()
        midConstraints.externalMetadataPriority = 0.5
        var strongConstraints = RecommendationConstraints()
        strongConstraints.externalMetadataPriority = 1

        let neutral = engine.recommendNextTracks(
            seed: seed,
            candidates: [vendorOnly],
            embeddingsByTrackID: [seed.id: [1, 0], vendorOnly.id: [1, 0]],
            summariesByTrackID: [:],
            vectorSimilarityByPath: [:],
            constraints: neutralConstraints,
            weights: RecommendationWeights(),
            vectorWeights: MixsetVectorWeights(),
            limit: 1,
            excludeTrackIDs: []
        ).first
        let mid = engine.recommendNextTracks(
            seed: seed,
            candidates: [vendorOnly],
            embeddingsByTrackID: [seed.id: [1, 0], vendorOnly.id: [1, 0]],
            summariesByTrackID: [:],
            vectorSimilarityByPath: [:],
            constraints: midConstraints,
            weights: RecommendationWeights(),
            vectorWeights: MixsetVectorWeights(),
            limit: 1,
            excludeTrackIDs: []
        ).first
        let strong = engine.recommendNextTracks(
            seed: seed,
            candidates: [vendorOnly],
            embeddingsByTrackID: [seed.id: [1, 0], vendorOnly.id: [1, 0]],
            summariesByTrackID: [:],
            vectorSimilarityByPath: [:],
            constraints: strongConstraints,
            weights: RecommendationWeights(),
            vectorWeights: MixsetVectorWeights(),
            limit: 1,
            excludeTrackIDs: []
        ).first

        #expect(abs((neutral?.breakdown.externalMetadataScore ?? -1) - 0.5) < 0.0001)
        #expect(abs((mid?.breakdown.externalMetadataScore ?? -1) - 0.625) < 0.0001)
        #expect(abs((strong?.breakdown.externalMetadataScore ?? -1) - 0.75) < 0.0001)
    }

    @Test func recommendationFiltersByAnalysisFocusAndCarriesMixabilityMetadata() {
        let engine = RecommendationEngine()
        let seed = makeTrack(
            path: "/a/seed.mp3",
            title: "Seed",
            genre: "House",
            bpm: 122,
            musicalKey: "8A",
            analyzedAt: Date()
        )
        let warmup = makeTrack(
            path: "/a/warmup.mp3",
            title: "Warmup",
            genre: "House",
            bpm: 123,
            musicalKey: "9A",
            analyzedAt: Date()
        )
        let peak = makeTrack(
            path: "/a/peak.mp3",
            title: "Peak",
            genre: "House",
            bpm: 124,
            musicalKey: "9A",
            analyzedAt: Date()
        )

        var constraints = RecommendationConstraints()
        constraints.analysisFocus = .warmUpDeep

        let recommendations = engine.recommendNextTracks(
            seed: seed,
            candidates: [warmup, peak],
            embeddingsByTrackID: [
                seed.id: [1, 0, 0],
                warmup.id: [0.96, 0.04, 0],
                peak.id: [0.92, 0.08, 0]
            ],
            summariesByTrackID: [
                seed.id: makeSummary(
                    trackID: seed.id,
                    analysisFocus: .balanced,
                    introLengthSec: 16,
                    outroLengthSec: 32,
                    energyArc: [0.42, 0.54, 0.61],
                    mixabilityTags: ["steady_groove"]
                ),
                warmup.id: makeSummary(
                    trackID: warmup.id,
                    analysisFocus: .warmUpDeep,
                    introLengthSec: 32,
                    outroLengthSec: 24,
                    energyArc: [0.34, 0.44, 0.52],
                    mixabilityTags: ["long_intro", "clean_outro"]
                ),
                peak.id: makeSummary(
                    trackID: peak.id,
                    analysisFocus: .peakTime,
                    introLengthSec: 8,
                    outroLengthSec: 8,
                    energyArc: [0.72, 0.84, 0.93],
                    mixabilityTags: ["high_brightness"]
                )
            ],
            vectorSimilarityByPath: [:],
            constraints: constraints,
            weights: RecommendationWeights(),
            vectorWeights: MixsetVectorWeights(),
            limit: 2,
            excludeTrackIDs: []
        )

        #expect(recommendations.count == 1)
        #expect(recommendations.first?.track.id == warmup.id)
        #expect(recommendations.first?.analysisFocus == .warmUpDeep)
        #expect(recommendations.first?.mixabilityTags == ["long_intro", "clean_outro"])
        #expect(recommendations.first?.matchReasons.contains("Warm-up / Deep") == true)
    }

    @Test func appSettingsPersistScoreControls() {
        let weights = RecommendationWeights(embed: 0.2, bpm: 0.2, key: 0.2, energy: 0.2, introOutro: 0.1, external: 0.1)
        let vectorWeights = MixsetVectorWeights(track: 0.5, intro: 0.1, middle: 0.3, outro: 0.1)
        let constraints = RecommendationConstraints(
            targetBPMMin: 118,
            targetBPMMax: 126,
            analysisFocus: .warmUpDeep,
            keyStrictness: 0.73,
            genreContinuity: 0.64,
            maxDurationMinutes: 7.5,
            includeTags: ["warm", "rolling"],
            excludeTags: ["hard"],
            externalMetadataPriority: 0.42
        )

        AppSettingsStore.saveRecommendationWeights(weights)
        AppSettingsStore.saveMixsetVectorWeights(vectorWeights)
        AppSettingsStore.saveRecommendationConstraints(constraints)

        #expect(AppSettingsStore.loadRecommendationWeights() == weights)
        #expect(AppSettingsStore.loadMixsetVectorWeights() == vectorWeights)
        #expect(AppSettingsStore.loadRecommendationConstraints() == constraints)

        AppSettingsStore.saveRecommendationWeights(.defaults)
        AppSettingsStore.saveMixsetVectorWeights(.defaults)
        AppSettingsStore.saveRecommendationConstraints(.defaults)
    }

    @Test func scoreSessionSnapshotStoresScoringConfiguration() throws {
        let snapshot = ScoreSessionCandidateSnapshot(
            vectorBreakdown: VectorScoreBreakdown(
                fusedScore: 0.82,
                trackScore: 0.9,
                introScore: 0.7,
                middleScore: 0.8,
                outroScore: 0.6,
                bestMatchedCollection: "tracks"
            ),
            matchedMemberships: ["Warmup / Deep"],
            matchReasons: ["Seed track"],
            analysisFocus: .warmUpDeep,
            mixabilityTags: ["long_intro"],
            queryMode: "hybrid",
            normalizedFinalWeights: RecommendationWeights(embed: 0.4, bpm: 0.2, key: 0.1, energy: 0.1, introOutro: 0.1, external: 0.1),
            normalizedVectorWeights: MixsetVectorWeights(track: 0.6, intro: 0.1, middle: 0.2, outro: 0.1),
            effectiveConstraints: RecommendationConstraints(
                targetBPMMin: 118,
                targetBPMMax: 126,
                analysisFocus: .warmUpDeep,
                keyStrictness: 0.8,
                genreContinuity: 0.65,
                maxDurationMinutes: 7,
                includeTags: ["warm"],
                excludeTags: ["hard"],
                externalMetadataPriority: 0.5
            )
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ScoreSessionCandidateSnapshot.self, from: data)

        #expect(decoded == snapshot)
    }

    @Test func seratoMarkers2ParserExtractsCueAndHotCue() {
        let memoryCue = Data([
            0x00, 0x00,
            0x00, 0x00, 0x0b, 0xb8,
            0x00,
            0xcc, 0x00, 0x00,
            0x00, 0x00,
            0x00
        ])
        let hotCue = Data([
            0x00, 0x03,
            0x00, 0x00, 0x17, 0x70,
            0x00,
            0x00, 0xcc, 0x00,
            0x00, 0x00
        ]) + Data("Drop".utf8) + Data([0x00])

        var payload = Data([0x01, 0x01])
        payload.append(Data("CUE".utf8))
        payload.append(Data([0x00]))
        payload.append(bigEndian32(memoryCue.count))
        payload.append(memoryCue)
        payload.append(Data("CUE".utf8))
        payload.append(Data([0x00]))
        payload.append(bigEndian32(hotCue.count))
        payload.append(hotCue)
        payload.append(Data([0x00]))

        let encoded = Data([0x01, 0x01]) + Data(payload.base64EncodedString().utf8) + Data([0x00])
        let points = ExternalVisualizationResolver.parseSeratoMarkers2TagData(encoded)

        #expect(points.count == 2)
        #expect(points[0].kind == .cue)
        #expect(abs(points[0].startSec - 3.0) < 0.001)
        #expect(points[1].kind == .hotcue)
        #expect(points[1].index == 3)
        #expect(points[1].name == "Drop")
        #expect(abs(points[1].startSec - 6.0) < 0.001)

        let overview = Data([0x01, 0x05])
            + Data(repeating: 0x00, count: 16)
            + Data(repeating: 0xff, count: 16)

        let waveform = ExternalVisualizationResolver.parseSeratoOverviewTagData(overview)

        #expect(waveform.count == 2)
        #expect(waveform[0] == 0)
        #expect(waveform[1] == 1)
    }

    @Test func rekordboxAnalysisParserExtractsWaveformAndCue() {
        let waveformChunk = rekordboxChunk(
            id: "PWV2",
            headerData: bigEndian32(4) + bigEndian32(0x0001_0000),
            payload: Data([0x00, 0x10, 0x1f, 0x08])
        )

        var cueEntry = Data("PCPT".utf8)
        cueEntry.append(bigEndian32(56))
        cueEntry.append(bigEndian32(56))
        cueEntry.append(bigEndian32(2))
        cueEntry.append(bigEndian32(0))
        cueEntry.append(bigEndian32(0x0001_0000))
        cueEntry.append(bigEndian16(0xffff))
        cueEntry.append(bigEndian16(0xffff))
        cueEntry.append(Data([0x01, 0x00, 0x00, 0x00]))
        cueEntry.append(bigEndian32(5_000))
        cueEntry.append(bigEndian32(0))
        cueEntry.append(Data(repeating: 0x00, count: 16))

        let cueChunk = rekordboxChunk(
            id: "PCOB",
            headerData: bigEndian32(1) + Data([0x00, 0x00]) + bigEndian16(1) + bigEndian32(1),
            payload: cueEntry
        )

        let analysisData = rekordboxAnalysisFile(chunks: [waveformChunk, cueChunk])
        let waveform = ExternalVisualizationResolver.parseRekordboxWaveformPreviewFromAnalysisData(analysisData)
        let cuePoints = ExternalVisualizationResolver.parseRekordboxCuePointsFromAnalysisData(analysisData)

        #expect(waveform.count == 4)
        #expect(waveform[0] == 0)
        #expect(abs(waveform[1] - (16.0 / 31.0)) < 0.001)
        #expect(cuePoints.count == 1)
        #expect(cuePoints[0].kind == .hotcue)
        #expect(cuePoints[0].index == 2)
        #expect(abs(cuePoints[0].startSec - 5.0) < 0.001)
    }

    @Test func seratoLibraryServiceParsesAssetsAndCrates() throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("master.sqlite")

        try createSQLiteDatabase(
            at: databaseURL,
            statements: [
                """
                CREATE TABLE asset (
                    id INTEGER PRIMARY KEY,
                    portable_id TEXT,
                    file_name TEXT,
                    name TEXT,
                    artist TEXT,
                    album TEXT,
                    genre TEXT,
                    bpm REAL,
                    key TEXT,
                    rating INTEGER,
                    dj_play_count INTEGER,
                    comments TEXT,
                    length_sec REAL,
                    analysis_flags INTEGER
                );
                """,
                "CREATE TABLE container (id INTEGER PRIMARY KEY, parent_id INTEGER, name TEXT);",
                "CREATE TABLE container_asset (asset_id INTEGER, location_container_id INTEGER);",
                "INSERT INTO container VALUES (0, NULL, 'root');",
                "INSERT INTO container VALUES (5, 0, 'Serato Library root');",
                "INSERT INTO container VALUES (21, 5, 'Warmup');",
                """
                INSERT INTO asset VALUES (
                    1,
                    'Users/test/Music/Warmup Track.mp3',
                    'Warmup Track.mp3',
                    'Warmup Track',
                    'DJ Test',
                    'Set One',
                    'House',
                    124.5,
                    '8A',
                    5,
                    12,
                    'Peak-time weapon',
                    301.2,
                    3
                );
                """,
                "INSERT INTO container_asset VALUES (1, 21);"
            ]
        )

        let service = SeratoLibraryService()
        let tracks = try service.loadTracks(from: databaseURL)

        #expect(tracks.count == 1)
        #expect(tracks.first?.normalizedPath == "/Users/test/Music/Warmup Track.mp3")
        #expect(tracks.first?.metadata.playlistMemberships == ["Warmup"])
        #expect(tracks.first?.metadata.vendorTrackID == "1")
        #expect(tracks.first?.metadata.analysisState == "flags=3")
        #expect(tracks.first?.bpm == 124.5)
        #expect(tracks.first?.musicalKey == "8A")
    }

    @Test func rekordboxServiceResolvesDirectoryAndLoadsManageTable() throws {
        let directory = try makeTemporaryDirectory()
        let rekordboxDirectory = directory.appendingPathComponent("rekordbox", isDirectory: true)
        try FileManager.default.createDirectory(at: rekordboxDirectory, withIntermediateDirectories: true)

        let settingsURL = directory.appendingPathComponent("rekordbox3.settings")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <PROPERTIES>
            <VALUE name="masterDbDirectory" val="\(rekordboxDirectory.path)"/>
        </PROPERTIES>
        """.write(to: settingsURL, atomically: true, encoding: .utf8)

        let databaseURL = rekordboxDirectory.appendingPathComponent("networkRecommend.db")
        try createSQLiteDatabase(
            at: databaseURL,
            statements: [
                """
                CREATE TABLE manage_tbl (
                    SongFilePath TEXT,
                    AnalyzeFilePath TEXT,
                    AnalyzeStatus INTEGER,
                    AnalyzeKey INTEGER,
                    AnalyzeBPMRange INTEGER,
                    TrackID TEXT,
                    TrackCheckSum TEXT,
                    Duration REAL,
                    RekordboxVersion TEXT,
                    AnalyzeVersion TEXT
                );
                """,
                """
                INSERT INTO manage_tbl VALUES (
                    '/Users/test/Music/Rekordbox Track.mp3',
                    '/Users/test/Library/Pioneer/ANLZ0000.DAT',
                    1,
                    8,
                    5,
                    'rk-1',
                    'checksum-1',
                    215000,
                    '7.2.8',
                    '6'
                );
                """
            ]
        )

        let service = RekordboxLibraryService()
        let resolvedDirectory = try service.resolvedDatabaseDirectory(from: settingsURL)
        let tracks = try service.loadTracks(from: rekordboxDirectory)

        #expect(resolvedDirectory?.path == rekordboxDirectory.path)
        #expect(tracks.count == 1)
        #expect(tracks.first?.normalizedPath == "/Users/test/Music/Rekordbox Track.mp3")
        #expect(tracks.first?.duration == 215)
        #expect(tracks.first?.metadata.vendorTrackID == "rk-1")
        #expect(tracks.first?.metadata.analysisCachePath == "/Users/test/Library/Pioneer/ANLZ0000.DAT")
        #expect(tracks.first?.metadata.analysisState == "status=1 keyCode=8 bpmRange=5")
        #expect(tracks.first?.metadata.syncVersion == "7.2.8/6")
    }

    @Test func rekordboxPlaylistsResolveTrackIDsViaKeyTypeZero() throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("networkRecommend.db")
        try createSQLiteDatabase(
            at: databaseURL,
            statements: [
                """
                CREATE TABLE manage_tbl (
                    SongFilePath TEXT,
                    AnalyzeFilePath TEXT,
                    AnalyzeStatus INTEGER,
                    AnalyzeKey INTEGER,
                    AnalyzeBPMRange INTEGER,
                    TrackID TEXT,
                    TrackCheckSum TEXT,
                    Duration REAL,
                    RekordboxVersion TEXT,
                    AnalyzeVersion TEXT
                );
                """,
                """
                INSERT INTO manage_tbl VALUES (
                    '/Users/test/Music/Track ID Playlist.mp3',
                    NULL,
                    NULL,
                    NULL,
                    NULL,
                    'rk-1',
                    'checksum-1',
                    240000,
                    '7.2.8',
                    '6'
                );
                """
            ]
        )

        let playlistsURL = directory.appendingPathComponent("masterPlaylists6.xml")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <DJ_PLAYLISTS>
          <PLAYLISTS>
            <NODE Name="ROOT" Type="0">
              <NODE Name="Warmup" Type="1" KeyType="0" Entries="1">
                <TRACK Key="rk-1" />
              </NODE>
            </NODE>
          </PLAYLISTS>
        </DJ_PLAYLISTS>
        """.write(to: playlistsURL, atomically: true, encoding: .utf8)

        let service = RekordboxLibraryService()
        let tracks = try service.loadTracks(from: directory)

        #expect(tracks.count == 1)
        #expect(tracks.first?.metadata.playlistMemberships == ["Warmup"])
    }

    @Test func rekordboxPlaylistsResolveLocationsViaKeyTypeOne() throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("networkRecommend.db")
        try createSQLiteDatabase(
            at: databaseURL,
            statements: [
                """
                CREATE TABLE manage_tbl (
                    SongFilePath TEXT,
                    AnalyzeFilePath TEXT,
                    AnalyzeStatus INTEGER,
                    AnalyzeKey INTEGER,
                    AnalyzeBPMRange INTEGER,
                    TrackID TEXT,
                    TrackCheckSum TEXT,
                    Duration REAL,
                    RekordboxVersion TEXT,
                    AnalyzeVersion TEXT
                );
                """,
                """
                INSERT INTO manage_tbl VALUES (
                    '/Users/test/Music/Location Key Playlist.mp3',
                    NULL,
                    NULL,
                    NULL,
                    NULL,
                    'rk-2',
                    'checksum-2',
                    240000,
                    '7.2.8',
                    '6'
                );
                """
            ]
        )

        let playlistsURL = directory.appendingPathComponent("masterPlaylists6.xml")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <DJ_PLAYLISTS>
          <PLAYLISTS>
            <NODE Name="ROOT" Type="0">
              <NODE Name="Travel" Type="1" KeyType="1" Entries="1">
                <TRACK Key="file://localhost/Users/test/Music/Location%20Key%20Playlist.mp3" />
              </NODE>
            </NODE>
          </PLAYLISTS>
        </DJ_PLAYLISTS>
        """.write(to: playlistsURL, atomically: true, encoding: .utf8)

        let service = RekordboxLibraryService()
        let tracks = try service.loadTracks(from: directory)

        #expect(tracks.count == 1)
        #expect(tracks.first?.metadata.playlistMemberships == ["Travel"])
    }

    @Test func rekordboxServiceLoadsMasterPlaylists7XMLWhenPresent() throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("networkRecommend.db")
        try createSQLiteDatabase(
            at: databaseURL,
            statements: [
                """
                CREATE TABLE manage_tbl (
                    SongFilePath TEXT,
                    AnalyzeFilePath TEXT,
                    AnalyzeStatus INTEGER,
                    AnalyzeKey INTEGER,
                    AnalyzeBPMRange INTEGER,
                    TrackID TEXT,
                    TrackCheckSum TEXT,
                    Duration REAL,
                    RekordboxVersion TEXT,
                    AnalyzeVersion TEXT
                );
                """,
                """
                INSERT INTO manage_tbl VALUES (
                    '/Users/test/Music/Rekordbox Seven Playlist.mp3',
                    NULL,
                    NULL,
                    NULL,
                    NULL,
                    'rk-7',
                    'checksum-7',
                    240000,
                    '7.3.0',
                    '7'
                );
                """
            ]
        )

        let playlistsURL = directory.appendingPathComponent("masterPlaylists7.xml")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <DJ_PLAYLISTS>
          <PLAYLISTS>
            <NODE Name="Playlists Root">
              <NODE Name="Club">
                <NODE Name="Closing">
                  <TRACK Key="rk-7" />
                </NODE>
              </NODE>
            </NODE>
          </PLAYLISTS>
        </DJ_PLAYLISTS>
        """.write(to: playlistsURL, atomically: true, encoding: .utf8)

        let service = RekordboxLibraryService()
        let tracks = try service.loadTracks(from: directory)

        #expect(tracks.count == 1)
        #expect(tracks.first?.metadata.playlistMemberships == ["Club / Closing"])
    }

    @Test func rekordboxXMLParserParsesTrackMetadataAndLeafPlaylists() throws {
        let directory = try makeTemporaryDirectory()
        let xmlURL = directory.appendingPathComponent("rekordbox-export.xml")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <DJ_PLAYLISTS Version="1.0.0">
          <COLLECTION Entries="2">
            <TRACK
              TrackID="track-1"
              Name="Alpha Track"
              Artist="DJ Test"
              Genre="House"
              Location="file://localhost/Users/test/Music/Alpha%20Track.mp3"
              AverageBpm="124.5"
              Tonality="8A"
              Rating="4"
              Colour="Blue"
              PlayCount="9"
              DateAdded="2026-04-10 09:30:00"
              Comments="Peak-time weapon">
              <POSITION_MARK Name="Drop" Type="0" Num="3" Start="64.5" />
            </TRACK>
            <TRACK
              TrackID="track-2"
              Name="Beta Track"
              Location="/Users/test/Music/Beta Track.mp3" />
          </COLLECTION>
          <PLAYLISTS>
            <NODE Name="ROOT" Type="0">
              <NODE Name="Festival">
                <NODE Name="Day 1">
                  <NODE Name="Sunrise">
                    <TRACK Key="track-1" />
                  </NODE>
                </NODE>
              </NODE>
              <NODE Name="Tools">
                <TRACK Location="file://localhost/Users/test/Music/Beta%20Track.mp3" />
              </NODE>
            </NODE>
          </PLAYLISTS>
        </DJ_PLAYLISTS>
        """.write(to: xmlURL, atomically: true, encoding: .utf8)

        let parsed = try RekordboxXMLParser().parse(from: xmlURL)
        let alphaTrackPath = "/Users/test/Music/Alpha Track.mp3"
        let betaTrackPath = "/Users/test/Music/Beta Track.mp3"

        #expect(parsed.tracks.count == 2)
        #expect(parsed.trackPathsByID["track-1"] == alphaTrackPath)
        #expect(parsed.memberships(forTrackPath: alphaTrackPath) == ["Festival / Day 1 / Sunrise"])
        #expect(parsed.memberships(forTrackPath: betaTrackPath) == ["Tools"])

        let alpha = parsed.tracks.first(where: { $0.trackID == "track-1" })
        #expect(alpha?.trackPath == alphaTrackPath)
        #expect(alpha?.bpm == 124.5)
        #expect(alpha?.musicalKey == "8A")
        #expect(alpha?.genre == "House")
        #expect(alpha?.comment == "Peak-time weapon")
        #expect(alpha?.rating == 4)
        #expect(alpha?.color == "Blue")
        #expect(alpha?.playCount == 9)
        #expect(alpha?.cuePoints.count == 1)
        #expect(alpha?.cuePoints.first?.index == 3)
        #expect(alpha?.cuePoints.first?.kind == .cue)
        #expect(abs((alpha?.cuePoints.first?.startSec ?? 0) - 64.5) < 0.001)
    }

    @Test func externalMetadataServiceAutomaticSearchIgnoresInvalidXMLAndReturnsValidCandidate() throws {
        let directory = try makeTemporaryDirectory()
        let validXML = directory.appendingPathComponent("rekordbox-export.xml")
        let invalidXML = directory.appendingPathComponent("not-rekordbox.xml")

        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <DJ_PLAYLISTS>
          <PLAYLISTS>
            <NODE Name="ROOT">
              <NODE Name="Detected">
                <TRACK Location="/Users/test/Music/New.mp3" />
              </NODE>
            </NODE>
          </PLAYLISTS>
        </DJ_PLAYLISTS>
        """.write(to: validXML, atomically: true, encoding: .utf8)
        try "<root />".write(to: invalidXML, atomically: true, encoding: .utf8)

        let service = ExternalMetadataService(
            rekordboxXMLSearchDirectories: [directory],
            lastRekordboxXMLPathProvider: { nil }
        )

        let automaticCandidate = service.detectRekordboxXMLCandidate()
        #expect(automaticCandidate?.url.resolvingSymlinksInPath().path == validXML.resolvingSymlinksInPath().path)
        #expect(automaticCandidate?.origin == .automaticSearch)
    }

    @Test func externalMetadataServicePrefersSavedRekordboxXMLPathWhenValid() throws {
        let directory = try makeTemporaryDirectory()
        let savedXML = directory.appendingPathComponent("saved-rekordbox.xml")
        let otherXML = directory.appendingPathComponent("other-rekordbox.xml")

        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <DJ_PLAYLISTS>
          <COLLECTION Entries="1">
            <TRACK TrackID="saved" Location="/Users/test/Music/Saved.mp3" />
          </COLLECTION>
        </DJ_PLAYLISTS>
        """.write(to: savedXML, atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <DJ_PLAYLISTS>
          <COLLECTION Entries="1">
            <TRACK TrackID="other" Location="/Users/test/Music/Other.mp3" />
          </COLLECTION>
        </DJ_PLAYLISTS>
        """.write(to: otherXML, atomically: true, encoding: .utf8)

        let savedPathService = ExternalMetadataService(
            rekordboxXMLSearchDirectories: [directory],
            lastRekordboxXMLPathProvider: { savedXML.path }
        )
        let savedCandidate = savedPathService.detectRekordboxXMLCandidate()
        #expect(savedCandidate?.url.resolvingSymlinksInPath().path == savedXML.resolvingSymlinksInPath().path)
        #expect(savedCandidate?.origin == .savedPath)
    }

    @Test func externalMetadataServiceCandidateSelectionPrefersNewestThenAlphabeticalPath() {
        let older = RekordboxXMLCandidate(
            url: URL(fileURLWithPath: "/tmp/z-older.xml"),
            modifiedAt: Date(timeIntervalSince1970: 10),
            origin: .automaticSearch
        )
        let newer = RekordboxXMLCandidate(
            url: URL(fileURLWithPath: "/tmp/a-newer.xml"),
            modifiedAt: Date(timeIntervalSince1970: 20),
            origin: .automaticSearch
        )
        let undated = RekordboxXMLCandidate(
            url: URL(fileURLWithPath: "/tmp/m-undated.xml"),
            modifiedAt: nil,
            origin: .automaticSearch
        )

        #expect(
            ExternalMetadataService.preferredRekordboxXMLCandidate(from: [older, newer, undated])?.url.path
                == newer.url.path
        )

        let alphabeticalA = RekordboxXMLCandidate(
            url: URL(fileURLWithPath: "/tmp/A.xml"),
            modifiedAt: Date(timeIntervalSince1970: 30),
            origin: .automaticSearch
        )
        let alphabeticalB = RekordboxXMLCandidate(
            url: URL(fileURLWithPath: "/tmp/B.xml"),
            modifiedAt: Date(timeIntervalSince1970: 30),
            origin: .automaticSearch
        )

        #expect(
            ExternalMetadataService.preferredRekordboxXMLCandidate(from: [alphabeticalB, alphabeticalA])?.url.path
                == alphabeticalA.url.path
        )
        #expect(ExternalMetadataService.preferredRekordboxXMLCandidate(from: []) == nil)
    }

    @Test func cuePresentationGroupsBySourceAndUsesDisplayLabels() {
        let seratoMetadata = ExternalDJMetadata(
            id: UUID(),
            trackPath: "/music/serato-track.mp3",
            source: .serato,
            bpm: nil,
            musicalKey: nil,
            rating: nil,
            color: nil,
            tags: [],
            playCount: nil,
            lastPlayed: nil,
            playlistMemberships: [],
            cueCount: 2,
            cuePoints: [
                ExternalDJCuePoint(
                    kind: .hotcue,
                    name: "Drop",
                    index: 3,
                    startSec: 64.25,
                    endSec: nil,
                    color: "#FF9900",
                    source: "serato:markers2"
                ),
                ExternalDJCuePoint(
                    kind: .cue,
                    name: "Mix In",
                    index: nil,
                    startSec: 12.5,
                    endSec: nil,
                    color: nil,
                    source: "serato:markers2"
                )
            ],
            comment: nil,
            vendorTrackID: nil,
            analysisState: nil,
            analysisCachePath: nil,
            syncVersion: nil
        )
        let rekordboxMetadata = ExternalDJMetadata(
            id: UUID(),
            trackPath: "/music/rekordbox-track.mp3",
            source: .rekordbox,
            bpm: nil,
            musicalKey: nil,
            rating: nil,
            color: nil,
            tags: [],
            playCount: nil,
            lastPlayed: nil,
            playlistMemberships: [],
            cueCount: 1,
            cuePoints: [
                ExternalDJCuePoint(
                    kind: .loop,
                    name: "Utility Loop",
                    index: 2,
                    startSec: 96.0,
                    endSec: 104.0,
                    color: "#663399",
                    source: "rekordbox:anlz_ext"
                )
            ],
            comment: nil,
            vendorTrackID: nil,
            analysisState: nil,
            analysisCachePath: nil,
            syncVersion: nil
        )

        let groups = TrackCuePresentation.groups(from: [seratoMetadata, rekordboxMetadata])

        #expect(groups.count == 2)
        #expect(groups[0].source == .serato)
        #expect(groups[0].items.map(\.kindLabel) == ["Memory Cue", "Hot Cue"])
        #expect(groups[0].items.map(\.timeText) == ["0:12.500", "1:04.250"])
        #expect(groups[0].items[0].indexLabel == nil)
        #expect(groups[0].items[1].indexLabel == "Slot 3")
        #expect(groups[0].items[1].noteText == "Drop")
        #expect(groups[0].items[1].sourceTag == "serato:markers2")
        #expect(groups[1].source == .rekordbox)
        #expect(groups[1].items.map(\.kindLabel) == ["Loop"])
        #expect(groups[1].items[0].indexLabel == "Loop 2")
    }

    @Test func waveformCacheRoundTripsAndLegacyAnalysisSummaryStillDecodes() throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase(databaseURL: databaseURL)
        let track = makeTrack(path: "/music/cache-track.wav", title: "Cache Track")
        try database.upsertTrack(track)

        let waveformEnvelope = TrackWaveformEnvelope(
            durationSec: 180,
            upperPeaks: [0.2, 0.4, 0.6, 0.8],
            lowerPeaks: [-0.2, -0.4, -0.6, -0.8],
            binCount: 4,
            sourceVersion: TrackWaveformEnvelope.canonicalSourceVersion
        )
        try database.replaceWaveformCache(trackID: track.id, waveformEnvelope: waveformEnvelope)
        #expect(try database.fetchWaveformCache(trackID: track.id) == waveformEnvelope)

        var rawDB: OpaquePointer?
        defer { sqlite3_close(rawDB) }
        #expect(sqlite3_open(databaseURL.path, &rawDB) == SQLITE_OK)

        let legacySummaryJSON = """
        {
          "trackID": "\(track.id.uuidString)",
          "segments": [],
          "trackEmbedding": null,
          "estimatedBPM": 124.0,
          "estimatedKey": "8A",
          "brightness": 0.5,
          "onsetDensity": 0.4,
          "rhythmicDensity": 0.3,
          "lowMidHighBalance": [0.2, 0.5, 0.3],
          "waveformPreview": [0.1, 0.2, 0.3],
          "analysisFocus": "balanced",
          "introLengthSec": 12.0,
          "outroLengthSec": 18.0,
          "energyArc": [0.2, 0.4, 0.6],
          "mixabilityTags": ["test"],
          "confidence": 0.75
        }
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        #expect(
            sqlite3_prepare_v2(
                rawDB,
                "UPDATE tracks SET analysis_summary_json = ? WHERE id = ?;",
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        )
        sqlite3_bind_text(statement, 1, legacySummaryJSON, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, track.id.uuidString, -1, sqliteTransient)
        #expect(sqlite3_step(statement) == SQLITE_DONE)

        let decodedSummary = try database.fetchAnalysisSummary(trackID: track.id)
        #expect(decodedSummary?.waveformEnvelope == nil)
        #expect(decodedSummary?.waveformPreview == [0.1, 0.2, 0.3])
        #expect(decodedSummary?.analysisFocus == .balanced)
    }

    @Test func syncMergesSourcesAndPreservesExistingAnalysis() async throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase(databaseURL: databaseURL)
        let syncService = DJLibrarySyncService(database: database)

        let existingTrack = makeTrack(
            path: "/missing/source-track.mp3",
            title: "Existing",
            artist: "",
            genre: "House",
            bpm: 122,
            musicalKey: "8A",
            analyzedAt: Date(),
            embeddingProfileID: "profile",
            embeddingUpdatedAt: Date(),
            genreSource: .audioTags,
            bpmSource: .soriaAnalysis,
            keySource: .soriaAnalysis,
            lastSeenInLocalScanAt: Date()
        )
        try database.upsertTrack(existingTrack)
        try database.replaceSegments(
            trackID: existingTrack.id,
            segments: [
                TrackSegment(
                    id: UUID(),
                    trackID: existingTrack.id,
                    type: .intro,
                    startSec: 0,
                    endSec: 30,
                    energyScore: 0.5,
                    descriptorText: "intro",
                    vector: [0.1, 0.2]
                )
            ],
            analysisSummary: TrackAnalysisSummary(
                trackID: existingTrack.id,
                segments: [],
                trackEmbedding: [0.2, 0.3],
                estimatedBPM: 122,
                estimatedKey: "8A",
                brightness: 0.4,
                onsetDensity: 0.5,
                rhythmicDensity: 0.6,
                lowMidHighBalance: [0.3, 0.4, 0.3],
                waveformPreview: [0.1, 0.2, 0.3]
            )
        )
        try database.markTrackEmbeddingIndexed(
            trackID: existingTrack.id,
            embeddingProfileID: "profile",
            embeddingPipelineID: EmbeddingPipeline.audioSegmentsV1.id
        )

        let seratoRecord = VendorLibraryTrackRecord(
            source: .serato,
            normalizedPath: existingTrack.filePath,
            fileName: "source-track.mp3",
            title: "Serato Title",
            artist: "DJ Merge",
            album: "Set",
            genre: "House",
            duration: 300,
            bpm: 124,
            musicalKey: "9A",
            metadata: ExternalDJMetadata(
                id: UUID(),
                trackPath: existingTrack.filePath,
                source: .serato,
                bpm: 124,
                musicalKey: "9A",
                rating: 5,
                color: nil,
                tags: ["House"],
                playCount: 7,
                lastPlayed: nil,
                playlistMemberships: ["Warmup"],
                cueCount: nil,
                comment: "serato",
                vendorTrackID: "serato-1",
                analysisState: "flags=2",
                analysisCachePath: nil,
                syncVersion: "master.sqlite"
            )
        )
        let rekordboxRecord = VendorLibraryTrackRecord(
            source: .rekordbox,
            normalizedPath: existingTrack.filePath,
            fileName: "source-track.mp3",
            title: "Rekordbox Title",
            artist: "",
            album: "",
            genre: "",
            duration: 300,
            bpm: nil,
            musicalKey: nil,
            metadata: ExternalDJMetadata(
                id: UUID(),
                trackPath: existingTrack.filePath,
                source: .rekordbox,
                bpm: nil,
                musicalKey: nil,
                rating: nil,
                color: nil,
                tags: [],
                playCount: nil,
                lastPlayed: nil,
                playlistMemberships: [],
                cueCount: nil,
                comment: nil,
                vendorTrackID: "rk-1",
                analysisState: "status=1",
                analysisCachePath: "/Users/test/ANLZ0000.DAT",
                syncVersion: "7.2.8/6"
            )
        )

        let summary = try await syncService.syncImportedTracks([seratoRecord, rekordboxRecord])
        let tracks = try database.fetchAllTracks()
        let metadata = try database.fetchExternalMetadata(trackID: existingTrack.id)

        #expect(summary.matchedTrackCount == 1)
        #expect(summary.matchedEntryCount == 2)
        #expect(summary.unmatchedEntryCount == 0)
        #expect(tracks.count == 1)
        #expect(tracks.first?.hasSeratoMetadata == true)
        #expect(tracks.first?.hasRekordboxMetadata == true)
        #expect(tracks.first?.analyzedAt != nil)
        #expect(tracks.first?.artist == "DJ Merge")
        #expect(tracks.first?.album == "Set")
        #expect(tracks.first?.comment == "serato")
        #expect(tracks.first?.genre == "House")
        #expect(tracks.first?.genreSource == .audioTags)
        #expect(tracks.first?.bpm == 122)
        #expect(tracks.first?.bpmSource == .soriaAnalysis)
        #expect(metadata.count == 2)
        #expect(Set(metadata.map(\.source)) == Set([.serato, .rekordbox]))
        #expect(metadata.first(where: { $0.source == .serato })?.comment == "serato")
        #expect(metadata.first(where: { $0.source == .rekordbox })?.analysisCachePath == "/Users/test/ANLZ0000.DAT")
    }

    @Test func vendorMergeOrderIsDeterministicForGenreAndComment() async throws {
        func runSync(with records: [VendorLibraryTrackRecord]) async throws -> Track {
            let directory = try makeTemporaryDirectory()
            let databaseURL = directory.appendingPathComponent("library.sqlite")
            let database = try LibraryDatabase(databaseURL: databaseURL)
            let syncService = DJLibrarySyncService(database: database)

            let track = makeTrack(
                path: "/music/order-sensitive.mp3",
                title: "Order Sensitive",
                artist: "",
                genre: "",
                lastSeenInLocalScanAt: Date()
            )
            try database.upsertTrack(track)

            _ = try await syncService.syncImportedTracks(records)
            let refreshedTrack = try database.fetchTrack(path: track.filePath)
            return try #require(refreshedTrack)
        }

        let seratoRecord = VendorLibraryTrackRecord(
            source: .serato,
            normalizedPath: "/music/order-sensitive.mp3",
            fileName: "order-sensitive.mp3",
            title: "Serato Title",
            artist: "Serato Artist",
            album: "Serato Album",
            genre: "House",
            duration: nil,
            bpm: 124,
            musicalKey: "8A",
            metadata: ExternalDJMetadata(
                id: UUID(),
                trackPath: "/music/order-sensitive.mp3",
                source: .serato,
                bpm: 124,
                musicalKey: "8A",
                rating: nil,
                color: nil,
                tags: ["House"],
                playCount: nil,
                lastPlayed: nil,
                playlistMemberships: ["Warmup"],
                cueCount: nil,
                cuePoints: [],
                comment: "Serato Comment",
                vendorTrackID: "serato-order",
                analysisState: nil,
                analysisCachePath: nil,
                syncVersion: nil
            )
        )
        let rekordboxRecord = VendorLibraryTrackRecord(
            source: .rekordbox,
            normalizedPath: "/music/order-sensitive.mp3",
            fileName: "order-sensitive.mp3",
            title: "Rekordbox Title",
            artist: "Rekordbox Artist",
            album: "Rekordbox Album",
            genre: "Tech House",
            duration: nil,
            bpm: 123,
            musicalKey: "9A",
            metadata: ExternalDJMetadata(
                id: UUID(),
                trackPath: "/music/order-sensitive.mp3",
                source: .rekordbox,
                bpm: 123,
                musicalKey: "9A",
                rating: nil,
                color: nil,
                tags: ["Tech House"],
                playCount: nil,
                lastPlayed: nil,
                playlistMemberships: ["Peak"],
                cueCount: nil,
                cuePoints: [],
                comment: "Rekordbox Comment",
                vendorTrackID: "rekordbox-order",
                analysisState: nil,
                analysisCachePath: nil,
                syncVersion: nil
            )
        )

        let firstPass = try await runSync(with: [rekordboxRecord, seratoRecord])
        let secondPass = try await runSync(with: [seratoRecord, rekordboxRecord])

        #expect(firstPass.genre == "House")
        #expect(firstPass.genreSource == .serato)
        #expect(firstPass.comment == "Serato Comment")
        #expect(firstPass.artist == "Serato Artist")
        #expect(firstPass.album == "Serato Album")

        #expect(secondPass.genre == firstPass.genre)
        #expect(secondPass.genreSource == firstPass.genreSource)
        #expect(secondPass.comment == firstPass.comment)
        #expect(secondPass.artist == firstPass.artist)
        #expect(secondPass.album == firstPass.album)
    }

    @Test func rekordboxNativeAndXMLMetadataAreMergedForMatchedLocalTracksOnly() async throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase(databaseURL: databaseURL)
        let syncService = DJLibrarySyncService(database: database)

        let localTrack = makeTrack(
            path: "/music/rekordbox-local.mp3",
            title: "Local Rekordbox Track",
            artist: "",
            genre: "",
            lastSeenInLocalScanAt: Date()
        )
        try database.upsertTrack(localTrack)

        let nativeRecord = VendorLibraryTrackRecord(
            source: .rekordbox,
            normalizedPath: localTrack.filePath,
            fileName: "rekordbox-local.mp3",
            title: "Local Rekordbox Track",
            artist: "",
            album: "",
            genre: "",
            duration: 300,
            bpm: nil,
            musicalKey: nil,
            metadata: ExternalDJMetadata(
                id: UUID(),
                trackPath: localTrack.filePath,
                source: .rekordbox,
                bpm: nil,
                musicalKey: nil,
                rating: nil,
                color: nil,
                tags: [],
                playCount: nil,
                lastPlayed: nil,
                playlistMemberships: ["Native Playlist"],
                cueCount: 1,
                cuePoints: [
                    ExternalDJCuePoint(
                        kind: .hotcue,
                        name: "Drop",
                        index: 1,
                        startSec: 64,
                        endSec: nil,
                        color: nil,
                        source: "rekordbox:native"
                    )
                ],
                comment: nil,
                vendorTrackID: "rk-native",
                analysisState: "status=1",
                analysisCachePath: "/Users/test/ANLZ0001.DAT",
                syncVersion: "7.2.8/6"
            )
        )
        let xmlMatchedRecord = VendorLibraryTrackRecord(
            source: .rekordbox,
            normalizedPath: localTrack.filePath,
            fileName: "rekordbox-local.mp3",
            title: "XML Title",
            artist: "XML Artist",
            album: "XML Album",
            genre: "House",
            duration: nil,
            bpm: 125,
            musicalKey: "8A",
            metadata: ExternalDJMetadata(
                id: UUID(),
                trackPath: localTrack.filePath,
                source: .rekordbox,
                bpm: 125,
                musicalKey: "8A",
                rating: 4,
                color: "Blue",
                tags: ["House"],
                playCount: 8,
                lastPlayed: nil,
                playlistMemberships: ["Festival / Day 1 / Sunrise"],
                cueCount: nil,
                cuePoints: [],
                comment: "Peak-time weapon",
                vendorTrackID: "rk-native",
                analysisState: nil,
                analysisCachePath: nil,
                syncVersion: nil
            )
        )
        let xmlUnmatchedRecord = VendorLibraryTrackRecord(
            source: .rekordbox,
            normalizedPath: "/music/not-scanned.mp3",
            fileName: "not-scanned.mp3",
            title: "Missing",
            artist: "Missing Artist",
            album: "",
            genre: "House",
            duration: nil,
            bpm: 124,
            musicalKey: "7A",
            metadata: ExternalDJMetadata(
                id: UUID(),
                trackPath: "/music/not-scanned.mp3",
                source: .rekordbox,
                bpm: 124,
                musicalKey: "7A",
                rating: nil,
                color: nil,
                tags: ["House"],
                playCount: nil,
                lastPlayed: nil,
                playlistMemberships: ["Unmatched"],
                cueCount: nil,
                cuePoints: [],
                comment: "Should not import",
                vendorTrackID: "rk-missing",
                analysisState: nil,
                analysisCachePath: nil,
                syncVersion: nil
            )
        )

        let summary = try await syncService.syncImportedTracks([nativeRecord, xmlMatchedRecord, xmlUnmatchedRecord])
        let refreshedTrackRecord = try database.fetchTrack(path: localTrack.filePath)
        let refreshedTrack = try #require(refreshedTrackRecord)
        let metadata = try database.fetchExternalMetadata(trackID: localTrack.id)

        #expect(summary.matchedTrackCount == 1)
        #expect(summary.matchedEntryCount == 2)
        #expect(summary.unmatchedEntryCount == 1)
        #expect(summary.referenceAttachmentCount == 2)

        #expect(refreshedTrack.artist == "XML Artist")
        #expect(refreshedTrack.album == "XML Album")
        #expect(refreshedTrack.genre == "House")
        #expect(refreshedTrack.genreSource == .rekordbox)
        #expect(refreshedTrack.comment == "Peak-time weapon")

        #expect(metadata.count == 1)
        #expect(metadata.first?.source == .rekordbox)
        #expect(metadata.first?.analysisCachePath == "/Users/test/ANLZ0001.DAT")
        #expect(metadata.first?.comment == "Peak-time weapon")
        #expect(Set(metadata.first?.playlistMemberships ?? []) == Set(["Native Playlist", "Festival / Day 1 / Sunrise"]))
    }

    @Test func libraryScannerTracksMultipleRootsAndDropsReferencesForRemovedRoots() async throws {
        let directory = try makeTemporaryDirectory()
        let firstRoot = directory.appendingPathComponent("RootA", isDirectory: true)
        let secondRoot = directory.appendingPathComponent("RootB", isDirectory: true)
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)

        let firstTrackURL = firstRoot.appendingPathComponent("Alpha.wav")
        let secondTrackURL = secondRoot.appendingPathComponent("Beta.wav")
        try writeTestWAV(to: firstTrackURL, frequency: 440)
        try writeTestWAV(to: secondTrackURL, frequency: 554.37)

        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase(databaseURL: databaseURL)
        let scanner = LibraryScannerService(database: database)

        await scanner.scan(roots: [firstRoot, secondRoot]) { _ in }

        let firstTrackPath = TrackPathNormalizer.normalizedAbsolutePath(firstTrackURL)
        let secondTrackPath = TrackPathNormalizer.normalizedAbsolutePath(secondTrackURL)
        let firstTrackRecord = try database.fetchTrack(path: firstTrackPath)
        let secondTrackRecord = try database.fetchTrack(path: secondTrackPath)
        let firstTrack = try #require(firstTrackRecord)
        let secondTrack = try #require(secondTrackRecord)

        #expect(Set(try database.fetchScannedTracks().map(\.filePath)) == Set([firstTrackPath, secondTrackPath]))

        try database.replaceExternalMetadata(
            trackID: firstTrack.id,
            source: .serato,
            entries: [
                ExternalDJMetadata(
                    id: UUID(),
                    trackPath: firstTrackPath,
                    source: .serato,
                    bpm: nil,
                    musicalKey: nil,
                    rating: nil,
                    color: nil,
                    tags: [],
                    playCount: nil,
                    lastPlayed: nil,
                    playlistMemberships: ["Root A / Warmup"],
                    cueCount: nil,
                    cuePoints: [],
                    comment: nil,
                    vendorTrackID: nil,
                    analysisState: nil,
                    analysisCachePath: nil,
                    syncVersion: nil
                )
            ]
        )
        try database.replaceExternalMetadata(
            trackID: secondTrack.id,
            source: .serato,
            entries: [
                ExternalDJMetadata(
                    id: UUID(),
                    trackPath: secondTrackPath,
                    source: .serato,
                    bpm: nil,
                    musicalKey: nil,
                    rating: nil,
                    color: nil,
                    tags: [],
                    playCount: nil,
                    lastPlayed: nil,
                    playlistMemberships: ["Root B / Peak"],
                    cueCount: nil,
                    cuePoints: [],
                    comment: nil,
                    vendorTrackID: nil,
                    analysisState: nil,
                    analysisCachePath: nil,
                    syncVersion: nil
                )
            ]
        )

        let initialFacets = try database.fetchMembershipFacets(source: .serato)
        #expect(Set(initialFacets.map(\.membershipPath)) == Set(["Root A / Warmup", "Root B / Peak"]))

        await scanner.scan(roots: [firstRoot]) { _ in }

        let rescannedTracks = try database.fetchScannedTracks()
        let secondTrackAfterRemovalRecord = try database.fetchTrack(path: secondTrackPath)
        let secondTrackAfterRemoval = try #require(secondTrackAfterRemovalRecord)
        let finalFacets = try database.fetchMembershipFacets(source: .serato)

        #expect(Set(rescannedTracks.map(\.filePath)) == Set([firstTrackPath]))
        #expect(secondTrackAfterRemoval.lastSeenInLocalScanAt == nil)
        #expect(finalFacets.map(\.membershipPath) == ["Root A / Warmup"])
    }

    @Test func membershipCatalogAndScopeQueriesIgnoreInactiveTracks() throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase(databaseURL: databaseURL)

        let activeTrack = makeTrack(
            path: "/music/active.mp3",
            title: "Active",
            lastSeenInLocalScanAt: Date()
        )
        let inactiveTrack = makeTrack(
            path: "/music/inactive.mp3",
            title: "Inactive",
            lastSeenInLocalScanAt: nil
        )
        try database.upsertTrack(activeTrack)
        try database.upsertTrack(inactiveTrack)

        let sharedMembership = "Warmup / Deep"
        try database.replaceExternalMetadata(
            trackID: activeTrack.id,
            source: .serato,
            entries: [
                ExternalDJMetadata(
                    id: UUID(),
                    trackPath: activeTrack.filePath,
                    source: .serato,
                    bpm: nil,
                    musicalKey: nil,
                    rating: nil,
                    color: nil,
                    tags: [],
                    playCount: nil,
                    lastPlayed: nil,
                    playlistMemberships: [sharedMembership],
                    cueCount: nil,
                    cuePoints: [],
                    comment: nil,
                    vendorTrackID: nil,
                    analysisState: nil,
                    analysisCachePath: nil,
                    syncVersion: nil
                )
            ]
        )
        try database.replaceExternalMetadata(
            trackID: inactiveTrack.id,
            source: .serato,
            entries: [
                ExternalDJMetadata(
                    id: UUID(),
                    trackPath: inactiveTrack.filePath,
                    source: .serato,
                    bpm: nil,
                    musicalKey: nil,
                    rating: nil,
                    color: nil,
                    tags: [],
                    playCount: nil,
                    lastPlayed: nil,
                    playlistMemberships: [sharedMembership],
                    cueCount: nil,
                    cuePoints: [],
                    comment: nil,
                    vendorTrackID: nil,
                    analysisState: nil,
                    analysisCachePath: nil,
                    syncVersion: nil
                )
            ]
        )

        let facets = try database.fetchMembershipFacets(source: .serato)
        var filter = LibraryScopeFilter()
        filter.seratoMembershipPaths = [sharedMembership]
        let scopedTrackIDs = try database.fetchTrackIDs(matching: filter)

        #expect(facets.count == 1)
        #expect(facets.first?.membershipPath == sharedMembership)
        #expect(facets.first?.trackCount == 1)
        #expect(scopedTrackIDs == Set([activeTrack.id]))
    }

    @Test func readyTrackIDsRequireStoredTrackAndSegmentVectors() throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase(databaseURL: databaseURL)

        let readyTrack = makeTrack(
            path: "/music/ready.mp3",
            title: "Ready",
            analyzedAt: Date()
        )
        try database.upsertTrack(readyTrack)
        let readySegments = [
            TrackSegment(
                id: UUID(),
                trackID: readyTrack.id,
                type: .intro,
                startSec: 0,
                endSec: 30,
                energyScore: 0.5,
                descriptorText: "intro",
                vector: [0.1, 0.2]
            )
        ]
        try database.replaceSegments(
            trackID: readyTrack.id,
            segments: readySegments,
            analysisSummary: TrackAnalysisSummary(
                trackID: readyTrack.id,
                segments: readySegments,
                trackEmbedding: [0.2, 0.3],
                estimatedBPM: nil,
                estimatedKey: nil,
                brightness: 0.4,
                onsetDensity: 0.5,
                rhythmicDensity: 0.6,
                lowMidHighBalance: [0.3, 0.4, 0.3],
                waveformPreview: [0.1, 0.2]
            )
        )
        try database.markTrackEmbeddingIndexed(
            trackID: readyTrack.id,
            embeddingProfileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id,
            embeddingPipelineID: EmbeddingPipeline.audioSegmentsV1.id
        )

        let incompleteTrack = makeTrack(
            path: "/music/incomplete.mp3",
            title: "Incomplete",
            analyzedAt: Date()
        )
        try database.upsertTrack(incompleteTrack)
        let incompleteSegments = [
            TrackSegment(
                id: UUID(),
                trackID: incompleteTrack.id,
                type: .intro,
                startSec: 0,
                endSec: 30,
                energyScore: 0.5,
                descriptorText: "intro",
                vector: nil
            )
        ]
        try database.replaceSegments(
            trackID: incompleteTrack.id,
            segments: incompleteSegments,
            analysisSummary: TrackAnalysisSummary(
                trackID: incompleteTrack.id,
                segments: incompleteSegments,
                trackEmbedding: nil,
                estimatedBPM: nil,
                estimatedKey: nil,
                brightness: 0.4,
                onsetDensity: 0.5,
                rhythmicDensity: 0.6,
                lowMidHighBalance: [0.3, 0.4, 0.3],
                waveformPreview: [0.1, 0.2]
            )
        )
        var capturedError: Error?
        do {
            try database.markTrackEmbeddingIndexed(
                trackID: incompleteTrack.id,
                embeddingProfileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id,
                embeddingPipelineID: EmbeddingPipeline.audioSegmentsV1.id
            )
        } catch {
            capturedError = error
        }
        #expect({
            guard let databaseError = capturedError as? DatabaseError else { return false }
            if case .writeFailed = databaseError {
                return true
            }
            return false
        }())

        let readyIDs = try database.fetchReadyTrackIDs(
            profileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id,
            pipelineID: EmbeddingPipeline.audioSegmentsV1.id
        )
        #expect(readyIDs == Set([readyTrack.id]))
    }

    @Test func verifyPersistedEmbeddingStateConfirmsAnalysisArtifactsAfterIndexing() throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase(databaseURL: databaseURL)

        let track = makeTrack(
            path: "/music/persisted.mp3",
            title: "Persisted",
            analyzedAt: Date()
        )
        try database.upsertTrack(track)

        let segments = TrackSegment.SegmentType.allCases.enumerated().map { index, type in
            TrackSegment(
                id: UUID(),
                trackID: track.id,
                type: type,
                startSec: Double(index * 30),
                endSec: Double((index + 1) * 30),
                energyScore: 0.4 + (Double(index) * 0.1),
                descriptorText: "\(type.rawValue) descriptor",
                vector: [0.1 + Double(index), 0.2 + Double(index)]
            )
        }

        try database.replaceSegments(
            trackID: track.id,
            segments: segments,
            analysisSummary: TrackAnalysisSummary(
                trackID: track.id,
                segments: segments,
                trackEmbedding: [0.3, 0.5, 0.7],
                estimatedBPM: 122,
                estimatedKey: "8A",
                brightness: 0.4,
                onsetDensity: 0.5,
                rhythmicDensity: 0.6,
                lowMidHighBalance: [0.3, 0.4, 0.3],
                waveformPreview: [0.1, 0.2, 0.3]
            )
        )
        try database.markTrackEmbeddingIndexed(
            trackID: track.id,
            embeddingProfileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id,
            embeddingPipelineID: EmbeddingPipeline.audioSegmentsV1.id
        )

        let snapshot = try database.verifyPersistedEmbeddingState(
            trackID: track.id,
            expectedEmbeddingProfileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id,
            expectedEmbeddingPipelineID: EmbeddingPipeline.audioSegmentsV1.id,
            context: "test"
        )

        #expect(snapshot.analyzedAt != nil)
        #expect(snapshot.hasTrackEmbedding)
        #expect(snapshot.hasAnalysisSummary)
        #expect(snapshot.embeddingProfileID == EmbeddingProfile.googleGeminiEmbedding2Preview.id)
        #expect(snapshot.embeddingPipelineID == EmbeddingPipeline.audioSegmentsV1.id)
        #expect(snapshot.embeddingUpdatedAt != nil)
        #expect(snapshot.segmentCount == 3)
        #expect(snapshot.embeddedSegmentCount == 3)
    }

    @Test func rekordboxXMLImportPopulatesMembershipCatalogForMatchedIndexedTracksOnly() throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase(databaseURL: databaseURL)
        let importer = ExternalMetadataService()

        let matchedTrack = makeTrack(
            path: "/Users/test/Music/Matched Track.mp3",
            title: "Matched Track",
            analyzedAt: Date(),
            lastSeenInLocalScanAt: Date()
        )
        try database.upsertTrack(matchedTrack)

        let xmlURL = directory.appendingPathComponent("rekordbox-import.xml")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <DJ_PLAYLISTS Version="1.0.0">
          <COLLECTION Entries="2">
            <TRACK TrackID="match-1" Location="/Users/test/Music/Matched Track.mp3" />
            <TRACK TrackID="miss-1" Location="/Users/test/Music/Unmatched Track.mp3" />
          </COLLECTION>
          <PLAYLISTS>
            <NODE Name="ROOT">
              <NODE Name="Festival">
                <NODE Name="Day 1">
                  <NODE Name="Sunrise">
                    <TRACK Key="match-1" />
                    <TRACK Key="miss-1" />
                  </NODE>
                </NODE>
              </NODE>
            </NODE>
          </PLAYLISTS>
        </DJ_PLAYLISTS>
        """.write(to: xmlURL, atomically: true, encoding: .utf8)

        let imported = try importer.importRekordboxXML(from: xmlURL)
        let entriesByPath = Dictionary(grouping: imported, by: \.trackPath)
        if let entries = entriesByPath[matchedTrack.filePath] {
            try database.replaceExternalMetadata(
                trackID: matchedTrack.id,
                source: .rekordbox,
                entries: entries
            )
        }

        let facets = try database.fetchMembershipFacets(source: .rekordbox)
        let snapshots = try database.fetchTrackMembershipSnapshots(trackIDs: [matchedTrack.id])

        #expect(facets.count == 1)
        #expect(facets.first?.membershipPath == "Festival / Day 1 / Sunrise")
        #expect(snapshots[matchedTrack.id]?.rekordboxMembershipPaths == ["Festival / Day 1 / Sunrise"])
    }

    @Test func membershipNormalizationSupportsUnionScopeQueriesAndScopedReadyCounts() throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase(databaseURL: databaseURL)
        let profileID = EmbeddingProfile.googleGeminiEmbedding2Preview.id

        let warmupTrack = try makeReadyTrack(
            in: database,
            path: "/music/warmup.mp3",
            title: "Warmup",
            profileID: profileID
        )
        let peakTrack = try makeReadyTrack(
            in: database,
            path: "/music/peak.mp3",
            title: "Peak",
            profileID: profileID
        )
        let rekordboxOnlyTrack = makeTrack(
            path: "/music/playlist.mp3",
            title: "Playlist Only",
            analyzedAt: Date(),
            lastSeenInLocalScanAt: Date()
        )
        try database.upsertTrack(rekordboxOnlyTrack)

        try database.replaceExternalMetadata(
            trackID: warmupTrack.id,
            source: .serato,
            entries: [
                ExternalDJMetadata(
                    id: UUID(),
                    trackPath: warmupTrack.filePath,
                    source: .serato,
                    bpm: 122,
                    musicalKey: "8A",
                    rating: nil,
                    color: nil,
                    tags: [],
                    playCount: nil,
                    lastPlayed: nil,
                    playlistMemberships: ["Warmup / Deep"],
                    cueCount: nil,
                    cuePoints: [],
                    comment: nil,
                    vendorTrackID: nil,
                    analysisState: nil,
                    analysisCachePath: nil,
                    syncVersion: nil
                )
            ]
        )
        try database.replaceExternalMetadata(
            trackID: peakTrack.id,
            source: .serato,
            entries: [
                ExternalDJMetadata(
                    id: UUID(),
                    trackPath: peakTrack.filePath,
                    source: .serato,
                    bpm: 126,
                    musicalKey: "9A",
                    rating: nil,
                    color: nil,
                    tags: [],
                    playCount: nil,
                    lastPlayed: nil,
                    playlistMemberships: ["Peak / Tools"],
                    cueCount: nil,
                    cuePoints: [],
                    comment: nil,
                    vendorTrackID: nil,
                    analysisState: nil,
                    analysisCachePath: nil,
                    syncVersion: nil
                )
            ]
        )
        try database.replaceExternalMetadata(
            trackID: rekordboxOnlyTrack.id,
            source: .rekordbox,
            entries: [
                ExternalDJMetadata(
                    id: UUID(),
                    trackPath: rekordboxOnlyTrack.filePath,
                    source: .rekordbox,
                    bpm: nil,
                    musicalKey: nil,
                    rating: nil,
                    color: nil,
                    tags: [],
                    playCount: nil,
                    lastPlayed: nil,
                    playlistMemberships: ["Festival / Day 1 / Sunrise"],
                    cueCount: nil,
                    cuePoints: [],
                    comment: nil,
                    vendorTrackID: nil,
                    analysisState: nil,
                    analysisCachePath: nil,
                    syncVersion: nil
                )
            ]
        )

        let seratoFacets = try database.fetchMembershipFacets(source: .serato)
        let rekordboxFacets = try database.fetchMembershipFacets(source: .rekordbox)

        #expect(seratoFacets.count == 2)
        #expect(seratoFacets.first(where: { $0.membershipPath == "Warmup / Deep" })?.displayName == "Deep")
        #expect(seratoFacets.first(where: { $0.membershipPath == "Warmup / Deep" })?.parentPath == "Warmup")
        #expect(seratoFacets.first(where: { $0.membershipPath == "Warmup / Deep" })?.depth == 1)
        #expect(rekordboxFacets.first?.membershipPath == "Festival / Day 1 / Sunrise")
        #expect(rekordboxFacets.first?.depth == 2)

        var scopeFilter = LibraryScopeFilter()
        scopeFilter.seratoMembershipPaths = ["Warmup / Deep", "Peak / Tools"]
        scopeFilter.rekordboxMembershipPaths = ["Festival / Day 1 / Sunrise"]

        let scopedTrackIDs = try database.fetchTrackIDs(matching: scopeFilter)
        let scopedReadyTrackIDs = try database.fetchScopedReadyTrackIDs(
            matching: scopeFilter,
            profileID: profileID,
            pipelineID: EmbeddingPipeline.audioSegmentsV1.id
        )

        #expect(scopedTrackIDs == Set([warmupTrack.id, peakTrack.id, rekordboxOnlyTrack.id]))
        #expect(scopedReadyTrackIDs == Set([warmupTrack.id, peakTrack.id]))
    }

    @Test func scoreSessionRetentionKeepsLatestThirtySessionsPerProfileAndKind() throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase(databaseURL: databaseURL)

        for index in 0..<31 {
            _ = try database.insertScoreSession(
                session: ScoreSession(
                    id: UUID(),
                    kind: .search,
                    embeddingProfileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id,
                    searchMode: "text",
                    queryText: "query-\(index)",
                    seedTrackID: nil,
                    referenceTrackIDs: [],
                    scopeFilter: LibraryScopeFilter(),
                    candidateCountBeforeScope: 10,
                    candidateCountAfterScope: 5,
                    resultLimit: 5,
                    createdAt: Date(timeIntervalSince1970: Double(index))
                ),
                candidates: [
                    ScoreSessionCandidateRecord(
                        trackID: UUID(),
                        rank: 1,
                        finalScore: 0.9,
                        vectorBreakdown: .zero,
                        embeddingSimilarity: nil,
                        bpmCompatibility: nil,
                        harmonicCompatibility: nil,
                        energyFlow: nil,
                        transitionRegionMatch: nil,
                        externalMetadataScore: nil,
                        matchedMemberships: [],
                        matchReasons: [],
                        snapshot: ScoreSessionCandidateSnapshot(
                            vectorBreakdown: .zero,
                            matchedMemberships: [],
                            matchReasons: [],
                            analysisFocus: nil,
                            mixabilityTags: [],
                            queryMode: "text",
                            normalizedFinalWeights: .defaults.normalized(),
                            normalizedVectorWeights: .defaults.normalized(),
                            effectiveConstraints: .defaults.normalizedForScoring()
                        )
                    )
                ]
            )
        }

        #expect(try sqliteInt(at: databaseURL, sql: "SELECT COUNT(*) FROM score_sessions;") == 30)
        #expect(try sqliteInt(at: databaseURL, sql: "SELECT COUNT(*) FROM score_session_candidates;") == 30)
        #expect(try sqliteInt(at: databaseURL, sql: "SELECT COUNT(*) FROM score_sessions WHERE query_text = 'query-0';") == 0)
        #expect(try sqliteInt(at: databaseURL, sql: "SELECT COUNT(*) FROM score_sessions WHERE query_text = 'query-30';") == 1)
    }

    @Test func rekordboxPlaylistsPreserveNestedFullPaths() throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("networkRecommend.db")
        try createSQLiteDatabase(
            at: databaseURL,
            statements: [
                """
                CREATE TABLE manage_tbl (
                    SongFilePath TEXT,
                    AnalyzeFilePath TEXT,
                    AnalyzeStatus INTEGER,
                    AnalyzeKey INTEGER,
                    AnalyzeBPMRange INTEGER,
                    TrackID TEXT,
                    TrackCheckSum TEXT,
                    Duration REAL,
                    RekordboxVersion TEXT,
                    AnalyzeVersion TEXT
                );
                """,
                """
                INSERT INTO manage_tbl VALUES (
                    '/Users/test/Music/Nested Playlist Track.mp3',
                    NULL,
                    NULL,
                    NULL,
                    NULL,
                    'rk-1',
                    'checksum-1',
                    240000,
                    '7.2.8',
                    '6'
                );
                """
            ]
        )

        let playlistsURL = directory.appendingPathComponent("masterPlaylists6.xml")
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <DJ_PLAYLISTS>
          <PLAYLISTS>
            <NODE Name="root">
              <NODE Name="Festival">
                <NODE Name="Day 1">
                  <NODE Name="Sunrise">
                    <TRACK Location="/Users/test/Music/Nested Playlist Track.mp3" />
                  </NODE>
                </NODE>
                <NODE Name="Day 2">
                  <NODE Name="Sunrise">
                    <TRACK Location="/Users/test/Music/Nested Playlist Track.mp3" />
                  </NODE>
                </NODE>
              </NODE>
            </NODE>
          </PLAYLISTS>
        </DJ_PLAYLISTS>
        """.write(to: playlistsURL, atomically: true, encoding: .utf8)

        let service = RekordboxLibraryService()
        let tracks = try service.loadTracks(from: directory)

        #expect(tracks.count == 1)
        #expect(
            Set(tracks[0].metadata.playlistMemberships)
                == Set(["Festival / Day 1 / Sunrise", "Festival / Day 2 / Sunrise"])
        )
    }

    @Test func metadataImportStatusMessageSummarizesSuccessfulMatches() {
        let message = AppViewModel.metadataImportStatusMessage(
            for: [
                MetadataImportSummary(source: .rekordbox, importedEntries: 18, matchedLocalTracks: 12, unmatchedEntries: 6, referenceAttachmentCount: 9),
                MetadataImportSummary(source: .serato, importedEntries: 4, matchedLocalTracks: 4, unmatchedEntries: 0, referenceAttachmentCount: 3)
            ]
        )

        #expect(message.contains("rekordbox: 12 matched local tracks / 6 unmatched / 9 references"))
        #expect(message.contains("Serato: 4 matched local tracks / 0 unmatched / 3 references"))
        #expect(message.contains("Some vendor entries did not match scanned local tracks yet."))
    }

    @Test func metadataImportStatusMessageIncludesFallbackHintWhenNothingMatches() {
        let message = AppViewModel.metadataImportStatusMessage(
            for: [
                MetadataImportSummary(source: .rekordbox, importedEntries: 18, matchedLocalTracks: 0, unmatchedEntries: 18, referenceAttachmentCount: 0)
            ]
        )

        #expect(message.contains("rekordbox: 0 matched local tracks / 18 unmatched / 0 references"))
        #expect(message.contains("No scanned local tracks matched the imported vendor metadata yet. Scan Music Folders first."))
    }

    @Test func libraryScannerIncludesAudioInNestedSubfolders() async throws {
        let directory = try makeTemporaryDirectory()
        let packageDirectory = directory.appendingPathComponent("Collection.musiclibrary", isDirectory: true)
        let nestedDirectory = packageDirectory.appendingPathComponent("Media/Deep Set", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)

        let rootTrackURL = directory.appendingPathComponent("Root Track.wav")
        let nestedTrackURL = nestedDirectory.appendingPathComponent("Nested Track.wav")
        try writeTestWAV(to: rootTrackURL, frequency: 440)
        try writeTestWAV(to: nestedTrackURL, frequency: 554.37)

        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase(databaseURL: databaseURL)
        let scanner = LibraryScannerService(database: database)

        await scanner.scan(roots: [directory]) { _ in }

        let scannedTracks = try database.fetchScannedTracks()
        let scannedPaths = Set(scannedTracks.map(\.filePath))

        #expect(scannedPaths.contains(TrackPathNormalizer.normalizedAbsolutePath(rootTrackURL)))
        #expect(scannedPaths.contains(TrackPathNormalizer.normalizedAbsolutePath(nestedTrackURL)))
    }

    @Test func libraryScannerRecoversExistingUnscannedTrackWhenFileIsUnchanged() async throws {
        let directory = try makeTemporaryDirectory()
        let trackURL = directory.appendingPathComponent("Recovered Track.wav")
        try writeTestWAV(to: trackURL)

        let normalizedPath = TrackPathNormalizer.normalizedAbsolutePath(trackURL)
        let modified = try #require(
            FileManager.default.attributesOfItem(atPath: trackURL.path)[.modificationDate] as? Date
        )
        let contentHash = FileHashingService.contentHash(for: trackURL)
        let analysisDate = Date(timeIntervalSince1970: 1_234)

        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase(databaseURL: databaseURL)
        try database.upsertTrack(
            Track(
                id: UUID(),
                filePath: normalizedPath,
                fileName: trackURL.lastPathComponent,
                title: "Stale Title",
                artist: "Legacy Artist",
                album: "",
                genre: "",
                duration: 0,
                sampleRate: 0,
                bpm: nil,
                musicalKey: nil,
                modifiedTime: modified,
                contentHash: contentHash,
                analyzedAt: analysisDate,
                embeddingProfileID: "profile",
                embeddingPipelineID: EmbeddingPipeline.audioSegmentsV1.id,
                embeddingUpdatedAt: analysisDate,
                hasSeratoMetadata: false,
                hasRekordboxMetadata: false,
                bpmSource: nil,
                keySource: nil,
                lastSeenInLocalScanAt: nil
            )
        )

        let scanner = LibraryScannerService(database: database)
        await scanner.scan(roots: [directory]) { _ in }

        let recovered = try database.fetchTrack(path: normalizedPath)
        let recoveredTrack = try #require(recovered)

        #expect(recoveredTrack.lastSeenInLocalScanAt != nil)
        #expect(recoveredTrack.title == "Recovered Track")
        #expect(abs(recoveredTrack.sampleRate - 22_050) < 0.001)
        #expect(recoveredTrack.analyzedAt == analysisDate)
        #expect(recoveredTrack.embeddingProfileID == "profile")
        #expect(Set(try database.fetchScannedTracks().map(\.filePath)) == Set([normalizedPath]))
    }

    @Test func libraryScannerFastSkipRefreshesLastSeenWithoutClearingAnalysis() async throws {
        let directory = try makeTemporaryDirectory()
        let trackURL = directory.appendingPathComponent("Fast Skip Track.wav")
        try writeTestWAV(to: trackURL)

        let normalizedPath = TrackPathNormalizer.normalizedAbsolutePath(trackURL)
        let modified = try #require(
            FileManager.default.attributesOfItem(atPath: trackURL.path)[.modificationDate] as? Date
        )
        let contentHash = FileHashingService.contentHash(for: trackURL)
        let analysisDate = Date(timeIntervalSince1970: 4_321)
        let previousLastSeen = Date(timeIntervalSince1970: 200)

        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase(databaseURL: databaseURL)
        try database.upsertTrack(
            Track(
                id: UUID(),
                filePath: normalizedPath,
                fileName: trackURL.lastPathComponent,
                title: "Existing Title",
                artist: "Indexed Artist",
                album: "",
                genre: "",
                duration: 42,
                sampleRate: 11_025,
                bpm: nil,
                musicalKey: nil,
                modifiedTime: modified,
                contentHash: contentHash,
                analyzedAt: analysisDate,
                embeddingProfileID: "profile",
                embeddingPipelineID: EmbeddingPipeline.audioSegmentsV1.id,
                embeddingUpdatedAt: analysisDate,
                hasSeratoMetadata: false,
                hasRekordboxMetadata: false,
                bpmSource: nil,
                keySource: nil,
                lastSeenInLocalScanAt: previousLastSeen
            )
        )

        let scanner = LibraryScannerService(database: database)
        await scanner.scan(roots: [directory]) { _ in }

        let refreshed = try database.fetchTrack(path: normalizedPath)
        let refreshedTrack = try #require(refreshed)

        #expect(refreshedTrack.lastSeenInLocalScanAt != nil)
        #expect(refreshedTrack.lastSeenInLocalScanAt! > previousLastSeen)
        #expect(refreshedTrack.title == "Existing Title")
        #expect(abs(refreshedTrack.sampleRate - 11_025) < 0.001)
        #expect(refreshedTrack.analyzedAt == analysisDate)
        #expect(refreshedTrack.embeddingProfileID == "profile")
    }

    @Test func libraryScannerIgnoresHistoricalUnscannedHashMatchesForDuplicateDetection() async throws {
        let directory = try makeTemporaryDirectory()
        let trackURL = directory.appendingPathComponent("Visible Track.wav")
        try writeTestWAV(to: trackURL)

        let normalizedPath = TrackPathNormalizer.normalizedAbsolutePath(trackURL)
        let modified = try #require(
            FileManager.default.attributesOfItem(atPath: trackURL.path)[.modificationDate] as? Date
        )
        let contentHash = FileHashingService.contentHash(for: trackURL)

        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase(databaseURL: databaseURL)
        try database.upsertTrack(
            Track(
                id: UUID(),
                filePath: "/Archive/Historical Copy.wav",
                fileName: "Historical Copy.wav",
                title: "Historical Copy",
                artist: "Archive",
                album: "",
                genre: "",
                duration: 1,
                sampleRate: 22_050,
                bpm: nil,
                musicalKey: nil,
                modifiedTime: modified,
                contentHash: contentHash,
                analyzedAt: nil,
                embeddingProfileID: nil,
                embeddingPipelineID: nil,
                embeddingUpdatedAt: nil,
                hasSeratoMetadata: true,
                hasRekordboxMetadata: false,
                bpmSource: nil,
                keySource: nil,
                lastSeenInLocalScanAt: nil
            )
        )

        let scanner = LibraryScannerService(database: database)
        await scanner.scan(roots: [directory]) { _ in }

        let scannedTracks = try database.fetchScannedTracks()

        #expect(scannedTracks.count == 1)
        #expect(scannedTracks.first?.filePath == normalizedPath)
    }

    @Test func libraryScannerRefreshTrackClearsAnalysisAndWaveformCacheForChangedFile() async throws {
        let directory = try makeTemporaryDirectory()
        let trackURL = directory.appendingPathComponent("Refresh Track.wav")
        try writeTestWAV(to: trackURL, frequency: 330)

        let normalizedPath = TrackPathNormalizer.normalizedAbsolutePath(trackURL)
        let originalModified = try #require(
            FileManager.default.attributesOfItem(atPath: trackURL.path)[.modificationDate] as? Date
        )

        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase(databaseURL: databaseURL)
        let invalidatedTracks = InvalidatedTracksRecorder()
        let scanner = LibraryScannerService(database: database) { track in
            await invalidatedTracks.record(track.id)
        }

        let track = Track(
            id: UUID(),
            filePath: normalizedPath,
            fileName: trackURL.lastPathComponent,
            title: "Before Normalize",
            artist: "Soria",
            album: "",
            genre: "",
            duration: 42,
            sampleRate: 22_050,
            bpm: 123,
            musicalKey: "8A",
            modifiedTime: originalModified,
            contentHash: FileHashingService.contentHash(for: trackURL),
            analyzedAt: Date(timeIntervalSince1970: 999),
            embeddingProfileID: "profile",
            embeddingPipelineID: EmbeddingPipeline.audioSegmentsV1.id,
            embeddingUpdatedAt: Date(timeIntervalSince1970: 999),
            hasSeratoMetadata: false,
            hasRekordboxMetadata: false,
            bpmSource: .soriaAnalysis,
            keySource: .soriaAnalysis,
            lastSeenInLocalScanAt: Date(timeIntervalSince1970: 500)
        )
        try database.upsertTrack(track)
        try database.replaceSegments(
            trackID: track.id,
            segments: [],
            analysisSummary: makeSummary(trackID: track.id)
        )
        try database.replaceWaveformCache(
            trackID: track.id,
            waveformEnvelope: TrackWaveformEnvelope(
                durationSec: 42,
                upperPeaks: [0.4, 0.2],
                lowerPeaks: [-0.4, -0.2]
            )
        )

        try writeTestWAV(to: trackURL, frequency: 660)
        try FileManager.default.setAttributes(
            [.modificationDate: originalModified.addingTimeInterval(30)],
            ofItemAtPath: trackURL.path
        )

        let refreshed = try await scanner.refreshTrack(at: trackURL)

        #expect(refreshed.id == track.id)
        #expect(refreshed.analyzedAt == nil)
        #expect(refreshed.embeddingProfileID == nil)
        #expect(refreshed.embeddingPipelineID == nil)
        #expect(refreshed.embeddingUpdatedAt == nil)
        #expect(refreshed.bpm == nil)
        #expect(refreshed.musicalKey == nil)
        #expect(refreshed.bpmSource == nil)
        #expect(refreshed.keySource == nil)
        #expect(try database.fetchAnalysisSummary(trackID: track.id) == nil)
        #expect((try database.fetchSegments(trackID: track.id)).isEmpty)
        #expect(try database.fetchWaveformCache(trackID: track.id) == nil)
        #expect(await invalidatedTracks.snapshot() == [track.id])
    }

    @Test func audioNormalizationServiceMovesOriginalToTrashWithOriginalFileName() async throws {
        let directory = try makeTemporaryDirectory()
        let fakeTrashDirectory = directory.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeTrashDirectory, withIntermediateDirectories: true)
        let trackURL = directory.appendingPathComponent("Normalize Me.wav")
        try writeTestWAV(to: trackURL, frequency: 440)

        let originalTrack = makeTrack(path: TrackPathNormalizer.normalizedAbsolutePath(trackURL), title: "Normalize Me")
        let updatedTrack = Track(
            id: originalTrack.id,
            filePath: originalTrack.filePath,
            fileName: originalTrack.fileName,
            title: originalTrack.title,
            artist: originalTrack.artist,
            album: originalTrack.album,
            genre: originalTrack.genre,
            duration: originalTrack.duration,
            sampleRate: originalTrack.sampleRate,
            bpm: originalTrack.bpm,
            musicalKey: originalTrack.musicalKey,
            modifiedTime: Date().addingTimeInterval(10),
            contentHash: "normalized-hash",
            analyzedAt: nil,
            embeddingProfileID: nil,
            embeddingPipelineID: nil,
            embeddingUpdatedAt: nil,
            hasSeratoMetadata: originalTrack.hasSeratoMetadata,
            hasRekordboxMetadata: originalTrack.hasRekordboxMetadata,
            bpmSource: originalTrack.bpmSource,
            keySource: originalTrack.keySource,
            lastSeenInLocalScanAt: originalTrack.lastSeenInLocalScanAt
        )

        let worker = StubNormalizationWorker(
            inspectionResult: WorkerNormalizationInspectionResponse(
                state: .needsNormalize,
                peakAmplitude: 0.25,
                formatName: "WAV",
                subtype: "PCM_16",
                endian: "FILE",
                sampleRate: 22_050,
                channelCount: 1,
                frameCount: 22_050,
                hasMetadata: false,
                isLossy: false,
                detailMessage: nil
            ),
            normalizeHandler: { _, outputPath in
                try writeTestWAV(to: URL(fileURLWithPath: outputPath), frequency: 880)
                return WorkerNormalizationResultResponse(
                    state: .ready,
                    originalPeakAmplitude: 0.25,
                    normalizedPeakAmplitude: 1.0,
                    appliedGain: 4.0,
                    didNormalize: true,
                    outputPath: outputPath,
                    formatName: "WAV",
                    subtype: "PCM_16",
                    endian: "FILE",
                    sampleRate: 22_050,
                    channelCount: 1,
                    frameCount: 22_050,
                    hasMetadata: false,
                    isLossy: false,
                    detailMessage: nil
                )
            }
        )

        let service = AudioNormalizationService(
            worker: worker,
            fileManager: .default,
            trackRefresher: { _ in updatedTrack },
            trashBackupOperation: { fileManager, originalURL in
                let destinationURL = fakeTrashDirectory.appendingPathComponent(originalURL.lastPathComponent)
                try fileManager.moveItem(at: originalURL, to: destinationURL)
                return destinationURL
            }
        )

        let result = await service.normalizeQueuedTracks([originalTrack])
        let fakeTrashedURL = fakeTrashDirectory.appendingPathComponent("Normalize Me.wav")
        let directoryContents = try FileManager.default.contentsOfDirectory(atPath: directory.path)

        #expect(result.updatedTracksByID[originalTrack.id]?.contentHash == "normalized-hash")
        #expect(result.warnings.isEmpty)
        #expect(FileManager.default.fileExists(atPath: trackURL.path))
        #expect(FileManager.default.fileExists(atPath: fakeTrashedURL.path))
        #expect(directoryContents.contains("Normalize Me.wav"))
        #expect(!directoryContents.contains(where: { $0.contains("soria-backup") }))
    }

    @Test func audioNormalizationServiceKeepsBackupWhenTrashMoveFails() async throws {
        let directory = try makeTemporaryDirectory()
        let trackURL = directory.appendingPathComponent("Normalize Me.wav")
        try writeTestWAV(to: trackURL)

        let originalTrack = makeTrack(path: TrackPathNormalizer.normalizedAbsolutePath(trackURL), title: "Normalize Me")
        let updatedTrack = Track(
            id: originalTrack.id,
            filePath: originalTrack.filePath,
            fileName: originalTrack.fileName,
            title: originalTrack.title,
            artist: originalTrack.artist,
            album: originalTrack.album,
            genre: originalTrack.genre,
            duration: originalTrack.duration,
            sampleRate: originalTrack.sampleRate,
            bpm: originalTrack.bpm,
            musicalKey: originalTrack.musicalKey,
            modifiedTime: Date().addingTimeInterval(10),
            contentHash: "normalized-hash",
            analyzedAt: nil,
            embeddingProfileID: nil,
            embeddingPipelineID: nil,
            embeddingUpdatedAt: nil,
            hasSeratoMetadata: originalTrack.hasSeratoMetadata,
            hasRekordboxMetadata: originalTrack.hasRekordboxMetadata,
            bpmSource: originalTrack.bpmSource,
            keySource: originalTrack.keySource,
            lastSeenInLocalScanAt: originalTrack.lastSeenInLocalScanAt
        )

        let worker = StubNormalizationWorker(
            inspectionResult: WorkerNormalizationInspectionResponse(
                state: .needsNormalize,
                peakAmplitude: 0.25,
                formatName: "WAV",
                subtype: "PCM_16",
                endian: "FILE",
                sampleRate: 22_050,
                channelCount: 1,
                frameCount: 22_050,
                hasMetadata: false,
                isLossy: false,
                detailMessage: nil
            ),
            normalizeHandler: { inputPath, outputPath in
                try FileManager.default.copyItem(atPath: inputPath, toPath: outputPath)
                return WorkerNormalizationResultResponse(
                    state: .ready,
                    originalPeakAmplitude: 0.25,
                    normalizedPeakAmplitude: 1.0,
                    appliedGain: 4.0,
                    didNormalize: true,
                    outputPath: outputPath,
                    formatName: "WAV",
                    subtype: "PCM_16",
                    endian: "FILE",
                    sampleRate: 22_050,
                    channelCount: 1,
                    frameCount: 22_050,
                    hasMetadata: false,
                    isLossy: false,
                    detailMessage: nil
                )
            }
        )

        let service = AudioNormalizationService(
            worker: worker,
            fileManager: .default,
            trackRefresher: { _ in updatedTrack },
            trashBackupOperation: { _, _ in
                throw NSError(domain: "SoriaTests", code: 7, userInfo: [NSLocalizedDescriptionKey: "Trash unavailable"])
            }
        )

        let result = await service.normalizeQueuedTracks([originalTrack])
        let warnings = result.warnings

        #expect(result.updatedTracksByID[originalTrack.id]?.contentHash == "normalized-hash")
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("Backup kept at") == true)
        let directoryContents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(directoryContents.contains(where: { $0.contains("Normalize Me-soria-backup-") }))
    }

    @Test func normalizationInspectionDerivesQueueNeedTiers() {
        let track = makeTrack(path: "/music/tiered.wav", title: "Tiered")

        let legacyReadyInspection = TrackNormalizationInspection(
            trackID: track.id,
            signature: TrackNormalizationSignature.make(for: track),
            state: .ready,
            peakAmplitude: 0.9781,
            formatName: "MP3",
            subtype: "MPEG_LAYER_III",
            endian: "FILE",
            sampleRate: 44_100,
            channelCount: 2,
            frameCount: 44_100,
            hasMetadata: false,
            isLossy: true,
            detailMessage: nil
        )
        let lowInspection = TrackNormalizationInspection(
            trackID: track.id,
            signature: TrackNormalizationSignature.make(for: track),
            state: .needsNormalize,
            peakAmplitude: 0.95,
            formatName: "WAV",
            subtype: "PCM_16",
            endian: "FILE",
            sampleRate: 44_100,
            channelCount: 2,
            frameCount: 44_100,
            hasMetadata: false,
            isLossy: false,
            detailMessage: nil
        )
        let mediumInspection = TrackNormalizationInspection(
            trackID: track.id,
            signature: TrackNormalizationSignature.make(for: track),
            state: .needsNormalize,
            peakAmplitude: 0.85,
            formatName: "WAV",
            subtype: "PCM_16",
            endian: "FILE",
            sampleRate: 44_100,
            channelCount: 2,
            frameCount: 44_100,
            hasMetadata: false,
            isLossy: false,
            detailMessage: nil
        )
        let highInspection = TrackNormalizationInspection(
            trackID: track.id,
            signature: TrackNormalizationSignature.make(for: track),
            state: .needsNormalize,
            peakAmplitude: 0.75,
            formatName: "WAV",
            subtype: "PCM_16",
            endian: "FILE",
            sampleRate: 44_100,
            channelCount: 2,
            frameCount: 44_100,
            hasMetadata: false,
            isLossy: false,
            detailMessage: nil
        )
        let floatPCMInspection = TrackNormalizationInspection(
            trackID: track.id,
            signature: TrackNormalizationSignature.make(for: track),
            state: .ready,
            peakAmplitude: 1.2,
            formatName: "WAV",
            subtype: "FLOAT",
            endian: "FILE",
            sampleRate: 44_100,
            channelCount: 2,
            frameCount: 44_100,
            hasMetadata: false,
            isLossy: false,
            detailMessage: nil
        )
        let supraUnityInspection = TrackNormalizationInspection(
            trackID: track.id,
            signature: TrackNormalizationSignature.make(for: track),
            state: .needsNormalize,
            peakAmplitude: 1.021,
            formatName: "MP3",
            subtype: "MPEG_LAYER_III",
            endian: "FILE",
            sampleRate: 44_100,
            channelCount: 2,
            frameCount: 44_100,
            hasMetadata: false,
            isLossy: true,
            detailMessage: nil
        )

        #expect(legacyReadyInspection.effectiveQueueState == .needsNormalize)
        #expect(legacyReadyInspection.needTier == .low)
        #expect(legacyReadyInspection.shouldNormalizeInQueue == false)
        #expect(legacyReadyInspection.needsExportAttention == false)
        #expect(legacyReadyInspection.peakMeasurementLabel == "Decoded Peak")
        #expect(legacyReadyInspection.peakMeasurementExplanation == nil)

        #expect(lowInspection.needTier == .low)
        #expect(lowInspection.shouldNormalizeInQueue == false)
        #expect(lowInspection.needsExportAttention == false)
        #expect(lowInspection.peakMeasurementLabel == "Sample Peak")
        #expect(lowInspection.peakMeasurementExplanation == nil)

        #expect(mediumInspection.needTier == .medium)
        #expect(mediumInspection.shouldNormalizeInQueue == true)
        #expect(mediumInspection.needsExportAttention == true)

        #expect(highInspection.needTier == .high)
        #expect(highInspection.shouldNormalizeInQueue == true)
        #expect(highInspection.needsExportAttention == true)

        #expect(floatPCMInspection.effectiveQueueState == .ready)
        #expect(floatPCMInspection.peakMeasurementLabel == "Sample Peak")
        #expect(floatPCMInspection.peakMeasurementExplanation == "Float PCM can store sample peaks outside +/-1.0.")

        #expect(supraUnityInspection.effectiveQueueState == .ready)
        #expect(supraUnityInspection.needTier == nil)
        #expect(supraUnityInspection.shouldNormalizeInQueue == false)
        #expect(supraUnityInspection.needsExportAttention == false)
        #expect(supraUnityInspection.peakMeasurementLabel == "Decoded Peak")
        #expect(supraUnityInspection.peakMeasurementExplanation == "Lossy decoding can reconstruct sample peaks above 1.0.")
    }

    @Test func audioNormalizationServiceSkipsLowPriorityQueueTracks() async throws {
        let directory = try makeTemporaryDirectory()
        let trackURL = directory.appendingPathComponent("Low Priority.wav")
        try writeTestWAV(to: trackURL)

        let track = makeTrack(path: TrackPathNormalizer.normalizedAbsolutePath(trackURL), title: "Low Priority")
        let invocationCounter = NormalizationInvocationCounter()

        let worker = StubNormalizationWorker(
            inspectionResult: WorkerNormalizationInspectionResponse(
                state: .needsNormalize,
                peakAmplitude: 0.95,
                formatName: "WAV",
                subtype: "PCM_16",
                endian: "FILE",
                sampleRate: 22_050,
                channelCount: 1,
                frameCount: 22_050,
                hasMetadata: false,
                isLossy: false,
                detailMessage: nil
            ),
            normalizeHandler: { _, _ in
                await invocationCounter.recordInvocation()
                Issue.record("Low-priority queue tracks should not be normalized.")
                throw NSError(domain: "SoriaTests", code: 11)
            }
        )

        let service = AudioNormalizationService(
            worker: worker,
            fileManager: .default,
            trackRefresher: { _ in
                Issue.record("Low-priority queue tracks should not refresh.")
                throw NSError(domain: "SoriaTests", code: 12)
            }
        )

        let result = await service.normalizeQueuedTracks([track])

        #expect(result.normalizedCount == 0)
        #expect(result.skippedLowPriorityCount == 1)
        #expect(result.updatedTracksByID.isEmpty)
        #expect(result.inspectionsByTrackID[track.id]?.needTier == .low)
        #expect(result.inspectionsByTrackID[track.id]?.shouldNormalizeInQueue == false)
        #expect(await invocationCounter.count == 0)
    }

    @Test func audioNormalizationServiceNormalizesEligibleTracksInParallelAndRefreshesSequentially() async throws {
        let directory = try makeTemporaryDirectory()
        let firstURL = directory.appendingPathComponent("Medium.wav")
        let secondURL = directory.appendingPathComponent("High.wav")
        try writeTestWAV(to: firstURL)
        try writeTestWAV(to: secondURL)

        let firstTrack = makeTrack(path: TrackPathNormalizer.normalizedAbsolutePath(firstURL), title: "Medium")
        let secondTrack = makeTrack(path: TrackPathNormalizer.normalizedAbsolutePath(secondURL), title: "High")
        let recorder = NormalizationExecutionRecorder()

        let refreshedTracksByPath = [
            firstTrack.filePath: Track(
                id: firstTrack.id,
                filePath: firstTrack.filePath,
                fileName: firstTrack.fileName,
                title: firstTrack.title,
                artist: firstTrack.artist,
                album: firstTrack.album,
                genre: firstTrack.genre,
                duration: firstTrack.duration,
                sampleRate: firstTrack.sampleRate,
                bpm: firstTrack.bpm,
                musicalKey: firstTrack.musicalKey,
                modifiedTime: Date().addingTimeInterval(5),
                contentHash: "medium-normalized",
                analyzedAt: nil,
                embeddingProfileID: nil,
                embeddingPipelineID: nil,
                embeddingUpdatedAt: nil,
                hasSeratoMetadata: false,
                hasRekordboxMetadata: false,
                bpmSource: nil,
                keySource: nil,
                lastSeenInLocalScanAt: nil
            ),
            secondTrack.filePath: Track(
                id: secondTrack.id,
                filePath: secondTrack.filePath,
                fileName: secondTrack.fileName,
                title: secondTrack.title,
                artist: secondTrack.artist,
                album: secondTrack.album,
                genre: secondTrack.genre,
                duration: secondTrack.duration,
                sampleRate: secondTrack.sampleRate,
                bpm: secondTrack.bpm,
                musicalKey: secondTrack.musicalKey,
                modifiedTime: Date().addingTimeInterval(10),
                contentHash: "high-normalized",
                analyzedAt: nil,
                embeddingProfileID: nil,
                embeddingPipelineID: nil,
                embeddingUpdatedAt: nil,
                hasSeratoMetadata: false,
                hasRekordboxMetadata: false,
                bpmSource: nil,
                keySource: nil,
                lastSeenInLocalScanAt: nil
            )
        ]

        let inspectionByPath = [
            firstTrack.filePath: WorkerNormalizationInspectionResponse(
                state: .needsNormalize,
                peakAmplitude: 0.85,
                formatName: "WAV",
                subtype: "PCM_16",
                endian: "FILE",
                sampleRate: 22_050,
                channelCount: 1,
                frameCount: 22_050,
                hasMetadata: false,
                isLossy: false,
                detailMessage: nil
            ),
            secondTrack.filePath: WorkerNormalizationInspectionResponse(
                state: .needsNormalize,
                peakAmplitude: 0.75,
                formatName: "WAV",
                subtype: "PCM_16",
                endian: "FILE",
                sampleRate: 22_050,
                channelCount: 1,
                frameCount: 22_050,
                hasMetadata: false,
                isLossy: false,
                detailMessage: nil
            )
        ]

        let worker = PathAwareStubNormalizationWorker(
            inspectByPath: inspectionByPath,
            normalizeHandler: { inputPath, outputPath in
                await recorder.normalizationStarted(for: inputPath)
                try await Task.sleep(nanoseconds: 60_000_000)
                try FileManager.default.copyItem(atPath: inputPath, toPath: outputPath)
                await recorder.normalizationFinished(for: inputPath)
                return WorkerNormalizationResultResponse(
                    state: .ready,
                    originalPeakAmplitude: inspectionByPath[inputPath]?.peakAmplitude,
                    normalizedPeakAmplitude: 1.0,
                    appliedGain: 2.0,
                    didNormalize: true,
                    outputPath: outputPath,
                    formatName: "WAV",
                    subtype: "PCM_16",
                    endian: "FILE",
                    sampleRate: 22_050,
                    channelCount: 1,
                    frameCount: 22_050,
                    hasMetadata: false,
                    isLossy: false,
                    detailMessage: nil
                )
            }
        )

        let service = AudioNormalizationService(
            worker: worker,
            fileManager: .default,
            trackRefresher: { url in
                await recorder.recordRefresh(for: url.path)
                guard let refreshed = refreshedTracksByPath[url.path] else {
                    throw NSError(domain: "SoriaTests", code: 13, userInfo: [NSLocalizedDescriptionKey: "Missing refreshed track"])
                }
                return refreshed
            }
        )

        let result = await service.normalizeQueuedTracks([firstTrack, secondTrack], maxConcurrent: 2)
        let snapshot = await recorder.snapshot()

        #expect(result.normalizedCount == 2)
        #expect(result.skippedLowPriorityCount == 0)
        #expect(snapshot.maxConcurrentNormalizations == 2)
        #expect(snapshot.refreshedPaths == [firstTrack.filePath, secondTrack.filePath])
        #expect(result.updatedTracksByID[firstTrack.id]?.contentHash == "medium-normalized")
        #expect(result.updatedTracksByID[secondTrack.id]?.contentHash == "high-normalized")
    }

    @Test func appViewModelExportsImmediatelyWhenQueueNeedsNormalization() async throws {
        let directory = try makeTemporaryDirectory()
        let trackURL = directory.appendingPathComponent("Needs Normalize.wav")
        try writeTestWAV(to: trackURL)

        let worker = StubNormalizationWorker(
            inspectionResult: WorkerNormalizationInspectionResponse(
                state: .needsNormalize,
                peakAmplitude: 0.42,
                formatName: "WAV",
                subtype: "PCM_16",
                endian: "FILE",
                sampleRate: 22_050,
                channelCount: 1,
                frameCount: 22_050,
                hasMetadata: false,
                isLossy: false,
                detailMessage: nil
            ),
            normalizeHandler: { _, _ in
                Issue.record("Normalization should not run during export.")
                throw NSError(domain: "SoriaTests", code: 9)
            }
        )
        let normalizationService = AudioNormalizationService(
            worker: worker,
            fileManager: .default,
            trackRefresher: { _ in
                Issue.record("Track refresh should not run during export.")
                throw NSError(domain: "SoriaTests", code: 10)
            }
        )

        let viewModel = AppViewModel(
            skipAsyncBootstrap: true,
            audioNormalizationService: normalizationService
        )
        let track = makeTrack(path: TrackPathNormalizer.normalizedAbsolutePath(trackURL), title: "Needs Normalize")
        viewModel.playlistTracks = [track]

        let exportURL = directory.appendingPathComponent("Test Playlist.m3u8")
        await viewModel.beginExport(to: exportURL)

        #expect(await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            FileManager.default.fileExists(atPath: exportURL.path)
        })
        #expect(viewModel.exportWarnings.allSatisfy { !$0.localizedCaseInsensitiveContains("normalize") })
        #expect(viewModel.exportMessage.contains("export complete"))
    }

    @Test func appViewModelAllowsExportWhenQueueOnlyHasLowPriorityNormalization() async throws {
        let directory = try makeTemporaryDirectory()
        let trackURL = directory.appendingPathComponent("Low Priority Export.wav")
        try writeTestWAV(to: trackURL)

        let worker = StubNormalizationWorker(
            inspectionResult: WorkerNormalizationInspectionResponse(
                state: .needsNormalize,
                peakAmplitude: 0.95,
                formatName: "WAV",
                subtype: "PCM_16",
                endian: "FILE",
                sampleRate: 22_050,
                channelCount: 1,
                frameCount: 22_050,
                hasMetadata: false,
                isLossy: false,
                detailMessage: nil
            ),
            normalizeHandler: { _, _ in
                Issue.record("Low-priority export should not normalize the queue.")
                throw NSError(domain: "SoriaTests", code: 14)
            }
        )
        let normalizationService = AudioNormalizationService(
            worker: worker,
            fileManager: .default,
            trackRefresher: { _ in
                Issue.record("Export should not refresh tracks.")
                throw NSError(domain: "SoriaTests", code: 15)
            }
        )

        let viewModel = AppViewModel(
            skipAsyncBootstrap: true,
            audioNormalizationService: normalizationService
        )
        let track = makeTrack(path: TrackPathNormalizer.normalizedAbsolutePath(trackURL), title: "Low Priority Export")
        viewModel.playlistTracks = [track]

        let exportURL = directory.appendingPathComponent("Low Priority Playlist.m3u8")
        await viewModel.beginExport(to: exportURL)

        #expect(await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            FileManager.default.fileExists(atPath: exportURL.path)
        })
        #expect(viewModel.exportWarnings.allSatisfy { !$0.localizedCaseInsensitiveContains("normalize") })
        #expect(viewModel.exportMessage.contains("export complete"))
    }

    @Test func appViewModelExportsSeratoUsingSelectedOutputURLWithoutNormalizationReview() async throws {
        let fileManager = FileManager.default
        let directory = try makeTemporaryDirectory()
        let cratesRoot = directory.appendingPathComponent("MockSeratoRoot", isDirectory: true)
        let subcratesURL = cratesRoot.appendingPathComponent("Subcrates", isDirectory: true)
        try fileManager.createDirectory(at: subcratesURL, withIntermediateDirectories: true)

        let trackDirectory = directory.appendingPathComponent("Tracks", isDirectory: true)
        try fileManager.createDirectory(at: trackDirectory, withIntermediateDirectories: true)
        let trackURL = trackDirectory.appendingPathComponent("Needs Normalize Serato.wav")
        try writeTestWAV(to: trackURL)

        let exportURL = subcratesURL.appendingPathComponent("Soria Test \(UUID().uuidString).crate")
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let worker = StubNormalizationWorker(
            inspectionResult: WorkerNormalizationInspectionResponse(
                state: .needsNormalize,
                peakAmplitude: 0.42,
                formatName: "WAV",
                subtype: "PCM_16",
                endian: "FILE",
                sampleRate: 22_050,
                channelCount: 1,
                frameCount: 22_050,
                hasMetadata: false,
                isLossy: false,
                detailMessage: nil
            ),
            normalizeHandler: { _, _ in
                Issue.record("Normalization should not run during export.")
                throw NSError(domain: "SoriaTests", code: 18)
            }
        )
        let normalizationService = AudioNormalizationService(
            worker: worker,
            fileManager: .default,
            trackRefresher: { _ in
                Issue.record("Track refresh should not run during export.")
                throw NSError(domain: "SoriaTests", code: 19)
            }
        )
        let exporter = PlaylistExportService(
            preflight: VendorExportPreflight(
                fileManager: .default,
                runningApplicationTokensProvider: { [] }
            )
        )

        let viewModel = AppViewModel(
            skipAsyncBootstrap: true,
            exporter: exporter,
            audioNormalizationService: normalizationService,
            initialDetectedVendorTargets: DetectedVendorTargets(
                rekordboxLibraryDirectory: nil,
                rekordboxSettingsPath: nil,
                seratoDatabasePath: nil,
                seratoCratesRoot: cratesRoot.path
            )
        )
        viewModel.selectedExportTarget = .seratoCrate
        let track = makeTrack(path: TrackPathNormalizer.normalizedAbsolutePath(trackURL), title: "Needs Normalize Serato")
        viewModel.playlistTracks = [track]

        await viewModel.beginExport(to: exportURL)

        #expect(await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            fileManager.fileExists(atPath: exportURL.path)
        })
        #expect(viewModel.exportMessage.contains("Serato crate export complete"))
        #expect(viewModel.exportMessage.contains(exportURL.path))
    }

    @Test func appViewModelNormalizesOnlySuggestedTracksAndTracksSuggestedProgress() async throws {
        let directory = try makeTemporaryDirectory()
        let lowURL = directory.appendingPathComponent("Low Suggested.wav")
        let mediumURL = directory.appendingPathComponent("Medium Suggested.wav")
        try writeTestWAV(to: lowURL)
        try writeTestWAV(to: mediumURL)

        let lowTrack = makeTrack(path: TrackPathNormalizer.normalizedAbsolutePath(lowURL), title: "Low Suggested")
        let mediumTrack = makeTrack(path: TrackPathNormalizer.normalizedAbsolutePath(mediumURL), title: "Medium Suggested")
        let recorder = NormalizationExecutionRecorder()

        let worker = PathAwareStubNormalizationWorker(
            inspectByPath: [
                lowTrack.filePath: WorkerNormalizationInspectionResponse(
                    state: .needsNormalize,
                    peakAmplitude: 0.95,
                    formatName: "WAV",
                    subtype: "PCM_16",
                    endian: "FILE",
                    sampleRate: 22_050,
                    channelCount: 1,
                    frameCount: 22_050,
                    hasMetadata: false,
                    isLossy: false,
                    detailMessage: nil
                ),
                mediumTrack.filePath: WorkerNormalizationInspectionResponse(
                    state: .needsNormalize,
                    peakAmplitude: 0.85,
                    formatName: "WAV",
                    subtype: "PCM_16",
                    endian: "FILE",
                    sampleRate: 22_050,
                    channelCount: 1,
                    frameCount: 22_050,
                    hasMetadata: false,
                    isLossy: false,
                    detailMessage: nil
                )
            ],
            normalizeHandler: { inputPath, outputPath in
                await recorder.normalizationStarted(for: inputPath)
                try await Task.sleep(nanoseconds: 80_000_000)
                try FileManager.default.copyItem(atPath: inputPath, toPath: outputPath)
                await recorder.normalizationFinished(for: inputPath)
                return WorkerNormalizationResultResponse(
                    state: .ready,
                    originalPeakAmplitude: inputPath == mediumTrack.filePath ? 0.85 : 0.95,
                    normalizedPeakAmplitude: 1.0,
                    appliedGain: 2.0,
                    didNormalize: true,
                    outputPath: outputPath,
                    formatName: "WAV",
                    subtype: "PCM_16",
                    endian: "FILE",
                    sampleRate: 22_050,
                    channelCount: 1,
                    frameCount: 22_050,
                    hasMetadata: false,
                    isLossy: false,
                    detailMessage: nil
                )
            }
        )

        let normalizationService = AudioNormalizationService(
            worker: worker,
            fileManager: .default,
            trackRefresher: { url in
                await recorder.recordRefresh(for: url.path)
                return url.path == mediumTrack.filePath ? mediumTrack : lowTrack
            }
        )

        let viewModel = AppViewModel(
            skipAsyncBootstrap: true,
            audioNormalizationService: normalizationService
        )
        viewModel.playlistTracks = [lowTrack, mediumTrack]

        viewModel.normalizePlaylistQueue()

        #expect(await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            viewModel.playlistQueueNormalizationProgress?.phase == .normalizingSuggestedTracks
        })
        #expect(viewModel.playlistQueueNormalizationProgress?.totalSuggestedTrackCount == 1)
        #expect(viewModel.playlistSuggestedNormalizationTrackCount == 1)
        #expect(viewModel.normalizePlaylistQueueButtonTitle == "Normalize Suggested")

        #expect(await waitUntil(timeoutNanoseconds: 2_000_000_000) {
            !viewModel.isNormalizingPlaylistQueue
        })
        #expect(viewModel.playlistQueueNormalizationProgress == nil)
        #expect(viewModel.exportMessage.contains("Normalized 1 suggested track"))
        let snapshot = await recorder.snapshot()
        #expect(snapshot.maxConcurrentNormalizations == 1)
        #expect(snapshot.refreshedPaths == [mediumTrack.filePath])
    }
}

private actor InvalidatedTracksRecorder {
    private var trackIDs: [UUID] = []

    func record(_ trackID: UUID) {
        trackIDs.append(trackID)
    }

    func snapshot() -> [UUID] {
        trackIDs
    }
}

private actor NormalizationInvocationCounter {
    private var invocations = 0

    func recordInvocation() {
        invocations += 1
    }

    var count: Int {
        invocations
    }
}

private actor NormalizationExecutionRecorder {
    private var activeNormalizations = 0
    private(set) var maxConcurrentNormalizations = 0
    private(set) var refreshedPaths: [String] = []

    func normalizationStarted(for path: String) {
        activeNormalizations += 1
        maxConcurrentNormalizations = max(maxConcurrentNormalizations, activeNormalizations)
    }

    func normalizationFinished(for _: String) {
        activeNormalizations = max(activeNormalizations - 1, 0)
    }

    func recordRefresh(for path: String) {
        refreshedPaths.append(path)
    }

    func snapshot() -> (maxConcurrentNormalizations: Int, refreshedPaths: [String]) {
        (maxConcurrentNormalizations, refreshedPaths)
    }
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    pollIntervalNanoseconds: UInt64 = 10_000_000,
    condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
    while ContinuousClock.now < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }
    return await condition()
}

private struct StubNormalizationWorker: AudioNormalizationWorkering {
    let inspectionResult: WorkerNormalizationInspectionResponse
    let normalizeHandler: @Sendable (String, String) async throws -> WorkerNormalizationResultResponse

    func inspectAudioNormalization(filePath: String) async throws -> WorkerNormalizationInspectionResponse {
        inspectionResult
    }

    func normalizeAudioFile(filePath: String, outputPath: String) async throws -> WorkerNormalizationResultResponse {
        try await normalizeHandler(filePath, outputPath)
    }
}

private struct PathAwareStubNormalizationWorker: AudioNormalizationWorkering {
    let inspectByPath: [String: WorkerNormalizationInspectionResponse]
    let normalizeHandler: @Sendable (String, String) async throws -> WorkerNormalizationResultResponse

    func inspectAudioNormalization(filePath: String) async throws -> WorkerNormalizationInspectionResponse {
        guard let response = inspectByPath[filePath] else {
            throw NSError(domain: "SoriaTests", code: 16, userInfo: [NSLocalizedDescriptionKey: "Missing inspection for \(filePath)"])
        }
        return response
    }

    func normalizeAudioFile(filePath: String, outputPath: String) async throws -> WorkerNormalizationResultResponse {
        try await normalizeHandler(filePath, outputPath)
    }
}

private func makeTrack(
    path: String,
    title: String,
    artist: String = "DJ",
    album: String = "",
    genre: String = "",
    comment: String = "",
    duration: TimeInterval = 300,
    sampleRate: Double = 44_100,
    bpm: Double? = nil,
    musicalKey: String? = nil,
    analyzedAt: Date? = nil,
    embeddingProfileID: String? = nil,
    embeddingPipelineID: String? = nil,
    embeddingUpdatedAt: Date? = nil,
    hasSeratoMetadata: Bool = false,
    hasRekordboxMetadata: Bool = false,
    genreSource: TrackMetadataSource? = nil,
    bpmSource: TrackMetadataSource? = nil,
    keySource: TrackMetadataSource? = nil,
    lastSeenInLocalScanAt: Date? = nil
) -> Track {
    Track(
        id: UUID(),
        filePath: path,
        fileName: URL(fileURLWithPath: path).lastPathComponent,
        title: title,
        artist: artist,
        album: album,
        genre: genre,
        comment: comment,
        duration: duration,
        sampleRate: sampleRate,
        bpm: bpm,
        musicalKey: musicalKey,
        modifiedTime: Date(),
        contentHash: title,
        analyzedAt: analyzedAt,
        embeddingProfileID: embeddingProfileID,
        embeddingPipelineID: embeddingPipelineID,
        embeddingUpdatedAt: embeddingUpdatedAt,
        hasSeratoMetadata: hasSeratoMetadata,
        hasRekordboxMetadata: hasRekordboxMetadata,
        genreSource: genreSource,
        bpmSource: bpmSource,
        keySource: keySource,
        lastSeenInLocalScanAt: lastSeenInLocalScanAt
    )
}

private func makeSummary(
    trackID: UUID,
    analysisFocus: AnalysisFocus = .balanced,
    introLengthSec: Double = 0,
    outroLengthSec: Double = 0,
    energyArc: [Double] = [],
    mixabilityTags: [String] = [],
    confidence: Double = 0.5
) -> TrackAnalysisSummary {
    TrackAnalysisSummary(
        trackID: trackID,
        segments: [],
        trackEmbedding: [0.2, 0.3],
        estimatedBPM: 122,
        estimatedKey: "8A",
        brightness: 0.4,
        onsetDensity: 0.5,
        rhythmicDensity: 0.6,
        lowMidHighBalance: [0.3, 0.4, 0.3],
        waveformPreview: [0.1, 0.2, 0.3],
        analysisFocus: analysisFocus,
        introLengthSec: introLengthSec,
        outroLengthSec: outroLengthSec,
        energyArc: energyArc,
        mixabilityTags: mixabilityTags,
        confidence: confidence
    )
}

private func rekordboxAnalysisFile(chunks: [Data]) -> Data {
    var data = Data("PMAI".utf8)
    data.append(bigEndian32(28))
    data.append(bigEndian32(28 + chunks.reduce(0) { $0 + $1.count }))
    data.append(bigEndian32(1))
    data.append(Data(repeating: 0x00, count: 12))
    for chunk in chunks {
        data.append(chunk)
    }
    return data
}

private func rekordboxChunk(id: String, headerData: Data, payload: Data) -> Data {
    var data = Data(id.utf8)
    let headerLength = 12 + headerData.count
    let totalLength = headerLength + payload.count
    data.append(bigEndian32(headerLength))
    data.append(bigEndian32(totalLength))
    data.append(headerData)
    data.append(payload)
    return data
}

private func bigEndian16(_ value: Int) -> Data {
    Data([
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff)
    ])
}

private func bigEndian32(_ value: Int) -> Data {
    Data([
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff)
    ])
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeTestWAV(
    to url: URL,
    frequency: Double = 440,
    durationSec: Double = 1.0
) throws {
    let sampleRate = 22_050
    let sampleCount = Int(Double(sampleRate) * durationSec)
    var pcmData = Data(capacity: sampleCount * MemoryLayout<Int16>.size)

    for index in 0..<sampleCount {
        let sample = sin(2 * Double.pi * frequency * Double(index) / Double(sampleRate))
        let scaled = Int16(max(min(sample * Double(Int16.max) * 0.25, Double(Int16.max)), Double(Int16.min)))
        var littleEndian = scaled.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            pcmData.append(contentsOf: bytes)
        }
    }

    let byteRate = sampleRate * 2
    let blockAlign: UInt16 = 2
    let bitsPerSample: UInt16 = 16
    let dataSize = UInt32(pcmData.count)
    let riffSize = 36 + dataSize

    var wavData = Data()
    wavData.append(Data("RIFF".utf8))
    wavData.append(contentsOf: withUnsafeBytes(of: riffSize.littleEndian, Array.init))
    wavData.append(Data("WAVE".utf8))
    wavData.append(Data("fmt ".utf8))

    let fmtChunkSize: UInt32 = 16
    let audioFormat: UInt16 = 1
    let numChannels: UInt16 = 1
    wavData.append(contentsOf: withUnsafeBytes(of: fmtChunkSize.littleEndian, Array.init))
    wavData.append(contentsOf: withUnsafeBytes(of: audioFormat.littleEndian, Array.init))
    wavData.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian, Array.init))
    wavData.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian, Array.init))
    wavData.append(contentsOf: withUnsafeBytes(of: UInt32(byteRate).littleEndian, Array.init))
    wavData.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian, Array.init))
    wavData.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian, Array.init))
    wavData.append(Data("data".utf8))
    wavData.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian, Array.init))
    wavData.append(pcmData)

    try wavData.write(to: url)
}

private func createSQLiteDatabase(at url: URL, statements: [String]) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else {
        throw DatabaseError.openFailed
    }
    defer { sqlite3_close(db) }

    for statement in statements {
        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed
        }
    }
}

private func makeReadyTrack(
    in database: LibraryDatabase,
    path: String,
    title: String,
    profileID: String
) throws -> Track {
    let track = makeTrack(
        path: path,
        title: title,
        analyzedAt: Date(),
        lastSeenInLocalScanAt: Date()
    )
    try database.upsertTrack(track)
    let segments = [
        TrackSegment(
            id: UUID(),
            trackID: track.id,
            type: .intro,
            startSec: 0,
            endSec: 32,
            energyScore: 0.5,
            descriptorText: "intro",
            vector: [0.1, 0.2, 0.3]
        )
    ]
    try database.replaceSegments(
        trackID: track.id,
        segments: segments,
        analysisSummary: TrackAnalysisSummary(
            trackID: track.id,
            segments: segments,
            trackEmbedding: [0.2, 0.3, 0.4],
            estimatedBPM: 122,
            estimatedKey: "8A",
            brightness: 0.4,
            onsetDensity: 0.5,
            rhythmicDensity: 0.6,
            lowMidHighBalance: [0.3, 0.4, 0.3],
            waveformPreview: [0.1, 0.2, 0.3]
        )
    )
    try database.markTrackEmbeddingIndexed(
        trackID: track.id,
        embeddingProfileID: profileID,
        embeddingPipelineID: EmbeddingPipeline.audioSegmentsV1.id
    )
    return track
}

private func sqliteInt(at url: URL, sql: String) throws -> Int {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else {
        throw DatabaseError.openFailed
    }
    defer { sqlite3_close(db) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        throw DatabaseError.queryFailed
    }
    defer { sqlite3_finalize(statement) }

    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw DatabaseError.queryFailed
    }
    return Int(sqlite3_column_int64(statement, 0))
}
