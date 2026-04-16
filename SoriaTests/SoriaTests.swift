import Foundation
import SQLite3
import Testing
@testable import Soria

@MainActor
@Suite(.serialized)
struct SoriaTests {
    @Test func appSettingsPreferBundledWorkerRuntimeForProtectedLegacyPath() {
        let bundledPath = "/tmp/Soria.app/Contents/Resources/analysis-worker/.venv/bin/python"
        let legacyPath = "\(NSHomeDirectory())/Documents/BluePenguin/Soriga/Soria/analysis-worker/.venv/bin/python"

        let resolved = AppSettingsStore.resolvedWorkerRuntimePath(
            storedValue: legacyPath,
            bundledPath: bundledPath,
            detectedProjectPath: legacyPath
        )

        #expect(resolved == bundledPath)
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
            limit: 1,
            excludeTrackIDs: []
        )

        #expect(recommendations.count == 1)
        #expect(recommendations.first?.track.id == vendorOnly.id)
        #expect(recommendations.first?.breakdown.externalMetadataScore ?? 0 >= 0.75)
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
            limit: 2,
            excludeTrackIDs: []
        )

        #expect(recommendations.count == 1)
        #expect(recommendations.first?.track.id == warmup.id)
        #expect(recommendations.first?.analysisFocus == .warmUpDeep)
        #expect(recommendations.first?.mixabilityTags == ["long_intro", "clean_outro"])
        #expect(recommendations.first?.matchReasons.contains("Warm-up / Deep") == true)
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

    @Test func syncMergesSourcesAndPreservesExistingAnalysis() async throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase(databaseURL: databaseURL)
        let syncService = DJLibrarySyncService(database: database)

        let existingTrack = makeTrack(
            path: "/missing/source-track.mp3",
            title: "Existing",
            genre: "House",
            bpm: 122,
            musicalKey: "8A",
            analyzedAt: Date(),
            embeddingProfileID: "profile",
            embeddingUpdatedAt: Date(),
            bpmSource: .soriaAnalysis,
            keySource: .soriaAnalysis
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
        try database.markTrackEmbeddingIndexed(trackID: existingTrack.id, embeddingProfileID: "profile")

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

        let mergedCount = try await syncService.syncImportedTracks([seratoRecord, rekordboxRecord])
        let tracks = try database.fetchAllTracks()
        let metadata = try database.fetchExternalMetadata(trackID: existingTrack.id)

        #expect(mergedCount == 1)
        #expect(tracks.count == 1)
        #expect(tracks.first?.hasSeratoMetadata == true)
        #expect(tracks.first?.hasRekordboxMetadata == true)
        #expect(tracks.first?.analyzedAt != nil)
        #expect(tracks.first?.bpm == 122)
        #expect(tracks.first?.bpmSource == .soriaAnalysis)
        #expect(metadata.count == 2)
        #expect(Set(metadata.map(\.source)) == Set([.serato, .rekordbox]))
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
            embeddingProfileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id
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
                embeddingProfileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id
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

        let readyIDs = try database.fetchReadyTrackIDs(profileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id)
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
            embeddingProfileID: EmbeddingProfile.googleGeminiEmbedding001.id
        )

        let snapshot = try database.verifyPersistedEmbeddingState(
            trackID: track.id,
            expectedEmbeddingProfileID: EmbeddingProfile.googleGeminiEmbedding001.id,
            context: "test"
        )

        #expect(snapshot.analyzedAt != nil)
        #expect(snapshot.hasTrackEmbedding)
        #expect(snapshot.hasAnalysisSummary)
        #expect(snapshot.embeddingProfileID == EmbeddingProfile.googleGeminiEmbedding001.id)
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
            analyzedAt: Date()
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
        let profileID = EmbeddingProfile.googleGeminiEmbedding001.id

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
            analyzedAt: Date()
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
            profileID: profileID
        )

        #expect(scopedTrackIDs == Set([warmupTrack.id, peakTrack.id, rekordboxOnlyTrack.id]))
        #expect(scopedReadyTrackIDs == Set([warmupTrack.id, peakTrack.id]))
    }

    @Test func scoreSessionRetentionKeepsLatestThirtySessionsPerProfileAndKind() throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let database = try LibraryDatabase(databaseURL: databaseURL)

        for index in 0..<31 {
            try database.insertScoreSession(
                session: ScoreSession(
                    id: UUID(),
                    kind: .search,
                    embeddingProfileID: EmbeddingProfile.googleGeminiEmbedding001.id,
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
                            queryMode: "text"
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
}

private func makeTrack(
    path: String,
    title: String,
    artist: String = "DJ",
    album: String = "",
    genre: String = "",
    duration: TimeInterval = 300,
    sampleRate: Double = 44_100,
    bpm: Double? = nil,
    musicalKey: String? = nil,
    analyzedAt: Date? = nil,
    embeddingProfileID: String? = nil,
    embeddingUpdatedAt: Date? = nil,
    hasSeratoMetadata: Bool = false,
    hasRekordboxMetadata: Bool = false,
    bpmSource: TrackMetadataSource? = nil,
    keySource: TrackMetadataSource? = nil
) -> Track {
    Track(
        id: UUID(),
        filePath: path,
        fileName: URL(fileURLWithPath: path).lastPathComponent,
        title: title,
        artist: artist,
        album: album,
        genre: genre,
        duration: duration,
        sampleRate: sampleRate,
        bpm: bpm,
        musicalKey: musicalKey,
        modifiedTime: Date(),
        contentHash: title,
        analyzedAt: analyzedAt,
        embeddingProfileID: embeddingProfileID,
        embeddingUpdatedAt: embeddingUpdatedAt,
        hasSeratoMetadata: hasSeratoMetadata,
        hasRekordboxMetadata: hasRekordboxMetadata,
        bpmSource: bpmSource,
        keySource: keySource
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
        analyzedAt: Date()
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
    try database.markTrackEmbeddingIndexed(trackID: track.id, embeddingProfileID: profileID)
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
