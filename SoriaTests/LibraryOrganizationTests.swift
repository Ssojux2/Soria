import Foundation
import Testing
@testable import Soria

@Suite(.serialized)
struct LibraryOrganizationTests {
    @Test
    func genreAssignmentUsesEmbeddingBeforeMetadata() throws {
        let root = "/Library"
        let track = makeOrganizationTrack(
            path: "\(root)/HipHop/Wrong Tag.wav",
            title: "Wrong Tag",
            genre: "HipHop"
        )
        let planner = LibraryOrganizationPlanner()
        let plan = planner.makePlan(
            tracks: [track],
            readyTrackIDs: [track.id],
            embeddingsByTrackID: [track.id: [1.0, 0.0]],
            labelEmbeddingsByFamilyID: [
                "house": [1.0, 0.0],
                "hiphop": [0.0, 1.0]
            ],
            destinationRootPath: "\(root)/Organized",
            libraryRoots: [root]
        )

        let move = try #require(plan.moves.first)
        #expect(move.genreID == "house")
        #expect(move.genreName == "House")
        #expect(move.targetPath.contains("/House/"))
    }

    @Test
    func plannerCreatesDeterministicClustersAndCollisionSuffixes() {
        let root = "/Library"
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let first = makeOrganizationTrack(
            id: firstID,
            path: "\(root)/Loose/A:One/Track.wav",
            title: "A One",
            artist: "Artist/One"
        )
        let second = makeOrganizationTrack(
            id: secondID,
            path: "\(root)/Loose/B:Two/Track.wav",
            title: "B Two",
            artist: "Artist/One"
        )
        let planner = LibraryOrganizationPlanner(
            config: LibraryOrganizationClusterConfig(
                assignThreshold: 0.80,
                mergeThreshold: 0.90,
                smallClusterFoldThreshold: 0.76,
                maxClusterSize: 35
            )
        )

        let plan = planner.makePlan(
            tracks: [second, first],
            readyTrackIDs: [first.id, second.id],
            embeddingsByTrackID: [
                first.id: [1.0, 0.0],
                second.id: [0.98, 0.02]
            ],
            labelEmbeddingsByFamilyID: ["house": [1.0, 0.0]],
            destinationRootPath: "\(root)/Organized",
            libraryRoots: [root]
        )

        #expect(plan.groups.count == 1)
        #expect(plan.moves.count == 2)
        #expect(Set(plan.moves.map(\.targetPath)).count == 2)
        #expect(plan.moves.contains { $0.targetPath.contains("00000000") })
        #expect(plan.groups.first?.clusterName.contains("/") == false)
        #expect(plan.groups.first?.clusterName.contains(":") == false)
    }

    @Test
    func pathComponentSanitizerRemovesMacOSUnsafeCharacters() {
        let sanitized = LibraryOrganizationPlanner.sanitizedPathComponent("  Peak/Time: Folder  ")

        #expect(sanitized == "Peak-Time- Folder")
        #expect(sanitized.contains("/") == false)
        #expect(sanitized.contains(":") == false)
    }

    @Test
    func sanitizerKeepsNonLatinTitlesAndClampsLongNames() {
        // Korean and Japanese titles are common in this library and must survive
        // intact rather than being stripped to "Untitled".
        #expect(LibraryOrganizationPlanner.sanitizedPathComponent("피크타임 뱅어") == "피크타임 뱅어")
        #expect(LibraryOrganizationPlanner.sanitizedFileName("夜のテクノ.mp3") == "夜のテクノ.mp3")

        // Empty and dot-only names would create invisible or invalid folders.
        #expect(LibraryOrganizationPlanner.sanitizedPathComponent("   ") == "Untitled")
        #expect(LibraryOrganizationPlanner.sanitizedPathComponent("...") == "Untitled")

        let long = String(repeating: "a", count: 300)
        #expect(LibraryOrganizationPlanner.sanitizedPathComponent(long).count == 80)
        #expect(LibraryOrganizationPlanner.sanitizedFileName(long).count == 160)
    }

    @Test
    func genreNormalizationCollapsesCommonSpellings() {
        #expect(GenreTaxonomy.normalizeGenreText("Hip Hop") == "hiphop")
        #expect(GenreTaxonomy.normalizeGenreText("Hip-Hop") == "hiphop")
        #expect(GenreTaxonomy.normalizeGenreText("  Deep   House  ") == "deep house")

        // Ampersand spellings must survive punctuation stripping, or these tags
        // silently fall through to whatever the embedding guesses.
        #expect(GenreTaxonomy.normalizeGenreText("R&B") == "rnb")
        #expect(GenreTaxonomy.normalizeGenreText("R & B") == "rnb")
        #expect(GenreTaxonomy.normalizeGenreText("Drum & Bass") == "drum and bass")

        #expect(GenreTaxonomy.familyID(forNormalizedValue: "deep house") == "house")
        #expect(GenreTaxonomy.familyID(forNormalizedValue: GenreTaxonomy.normalizeGenreText("R&B")) == "rnb")
        #expect(GenreTaxonomy.familyID(forNormalizedValue: GenreTaxonomy.normalizeGenreText("Drum & Bass")) == "dnb")
        #expect(GenreTaxonomy.familyID(forNormalizedValue: "polka") == nil)
    }

    @Test
    func plannerOutputIsIndependentOfInputOrdering() {
        let root = "/Library"
        let tracks = (1...6).map { index in
            makeOrganizationTrack(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index)")!,
                path: "\(root)/Loose/T\(index).wav",
                title: "Track \(index)",
                artist: "Artist \(index)"
            )
        }
        let embeddings = Dictionary(
            uniqueKeysWithValues: tracks.enumerated().map { index, track in
                (track.id, [1.0 - Double(index) * 0.01, Double(index) * 0.01])
            }
        )
        let planner = LibraryOrganizationPlanner()

        func plan(for ordered: [Track]) -> [String] {
            planner.makePlan(
                tracks: ordered,
                readyTrackIDs: Set(tracks.map(\.id)),
                embeddingsByTrackID: embeddings,
                labelEmbeddingsByFamilyID: ["house": [1.0, 0.0]],
                destinationRootPath: "\(root)/Organized",
                libraryRoots: [root]
            ).moves.map(\.targetPath).sorted()
        }

        #expect(plan(for: tracks) == plan(for: tracks.reversed()))
        #expect(plan(for: tracks) == plan(for: tracks.shuffled()))
    }

    @Test
    func promptFoldersAssignByPromptAndSkipClustering() throws {
        let root = "/Library"
        let peak = makeOrganizationTrack(path: "\(root)/a.wav", title: "Peak", artist: "A")
        let warm = makeOrganizationTrack(path: "\(root)/b.wav", title: "Warm", artist: "B")
        let planner = LibraryOrganizationPlanner()

        let plan = planner.makePlan(
            tracks: [peak, warm],
            readyTrackIDs: [peak.id, warm.id],
            embeddingsByTrackID: [peak.id: [1.0, 0.0], warm.id: [0.0, 1.0]],
            labelEmbeddingsByFamilyID: ["peak": [1.0, 0.0], "warm": [0.0, 1.0]],
            destinationRootPath: "\(root)/Organized",
            libraryRoots: [root],
            kind: .promptFolders(prompts: ["peak time bangers", "warm up deep"]),
            labelDisplayNames: ["peak": "peak time bangers", "warm": "warm up deep"]
        )

        #expect(plan.groups.count == 2)
        // A prompt is already the grouping, so folders are one level deep with no
        // "Cluster NN" layer underneath.
        let peakMove = try #require(plan.moves.first { $0.trackID == peak.id })
        #expect(peakMove.targetPath == "\(root)/Organized/peak time bangers/a.wav")
        #expect(!peakMove.targetPath.contains("Cluster"))

        let warmMove = try #require(plan.moves.first { $0.trackID == warm.id })
        #expect(warmMove.targetPath == "\(root)/Organized/warm up deep/b.wav")
    }

    @Test
    func promptFoldersSendWeakMatchesToUnmatched() throws {
        let root = "/Library"
        let track = makeOrganizationTrack(path: "\(root)/a.wav", title: "Nothing Like It", artist: "A")
        let planner = LibraryOrganizationPlanner()

        let plan = planner.makePlan(
            tracks: [track],
            readyTrackIDs: [track.id],
            // Orthogonal to the prompt: cosine similarity is 0, below the floor.
            embeddingsByTrackID: [track.id: [0.0, 1.0]],
            labelEmbeddingsByFamilyID: ["peak": [1.0, 0.0]],
            destinationRootPath: "\(root)/Organized",
            libraryRoots: [root],
            kind: .promptFolders(prompts: ["peak time bangers"]),
            labelDisplayNames: ["peak": "peak time bangers"]
        )

        let move = try #require(plan.moves.first)
        #expect(move.genreID == LibraryOrganizationBuckets.unmatchedID)
        #expect(move.targetPath.contains("/\(LibraryOrganizationBuckets.unmatchedName)/"))
    }

    @Test
    func degenerateAssignmentsRaiseALowConfidenceWarning() {
        let planner = LibraryOrganizationPlanner()

        // Nine of ten in one bucket: the signature of a model that cannot compare
        // text labels against audio.
        let lopsided = Array(repeating: "house", count: 9) + ["techno"]
        let warning = planner.lowConfidenceWarning(genreIDs: lopsided, isPromptMode: false)
        #expect(warning?.contains("Low confidence") == true)
        #expect(warning?.contains("genre") == true)

        // A healthy spread stays quiet.
        let spread = ["house", "house", "techno", "techno", "disco", "disco", "bass", "dnb"]
        #expect(planner.lowConfidenceWarning(genreIDs: spread, isPromptMode: false) == nil)

        // Too small a sample to judge.
        #expect(planner.lowConfidenceWarning(genreIDs: ["house", "house"], isPromptMode: false) == nil)

        let promptWarning = planner.lowConfidenceWarning(genreIDs: lopsided, isPromptMode: true)
        #expect(promptWarning?.contains("prompt") == true)
    }

    @Test
    func everyPlanWarnsThatMovingBreaksVendorReferences() {
        let root = "/Library"
        let track = makeOrganizationTrack(path: "\(root)/a.wav", title: "A", artist: "A")
        let plan = LibraryOrganizationPlanner().makePlan(
            tracks: [track],
            readyTrackIDs: [track.id],
            embeddingsByTrackID: [track.id: [1.0, 0.0]],
            labelEmbeddingsByFamilyID: ["house": [1.0, 0.0]],
            destinationRootPath: "\(root)/Organized",
            libraryRoots: [root]
        )

        #expect(plan.warnings.contains { $0.contains("Serato crates and rekordbox playlists") })
    }

    @Test
    func excludedMovesAreDroppedFromTheAppliedSet() {
        let root = "/Library"
        let tracks = (1...3).map {
            makeOrganizationTrack(path: "\(root)/t\($0).wav", title: "T\($0)", artist: "A")
        }
        let plan = LibraryOrganizationPlanner().makePlan(
            tracks: tracks,
            readyTrackIDs: Set(tracks.map(\.id)),
            embeddingsByTrackID: Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, [1.0, 0.0]) }),
            labelEmbeddingsByFamilyID: ["house": [1.0, 0.0]],
            destinationRootPath: "\(root)/Organized",
            libraryRoots: [root]
        )

        #expect(plan.moves.count == 3)
        let excluded = Set(plan.moves.prefix(2).map(\.id))
        #expect(plan.includedMoves(excluding: excluded).count == 1)
        #expect(plan.includedMoves(excluding: []).count == 3)
    }

    @Test
    func groupsCarryStableCollectionIdentity() {
        let root = "/Library"
        let track = makeOrganizationTrack(path: "\(root)/a.wav", title: "A", artist: "A")
        let plan = LibraryOrganizationPlanner().makePlan(
            tracks: [track],
            readyTrackIDs: [track.id],
            embeddingsByTrackID: [track.id: [1.0, 0.0]],
            labelEmbeddingsByFamilyID: ["house": [1.0, 0.0]],
            destinationRootPath: "\(root)/Organized",
            libraryRoots: [root]
        )

        // Preview rows and the collections written on apply must agree on identity.
        let group = plan.groups.first
        #expect(group?.collectionID != nil)
        #expect(plan.groups.map(\.collectionID).count == Set(plan.groups.map(\.collectionID)).count)
    }

    @Test
    func labelEmbeddingCacheReturnsHitsAndReportsMisses() throws {
        let directory = try makeOrganizationTemporaryDirectory()
        let cache = LabelEmbeddingCache(directory: directory.appendingPathComponent("labels"))
        let profileID = "google/gemini-embedding-2-preview"

        let empty = cache.load(labels: ["house DJ track", "techno DJ track"], profileID: profileID)
        #expect(empty.cached.isEmpty)
        #expect(empty.missing == ["house DJ track", "techno DJ track"])

        cache.store(["house DJ track": [1.0, 0.0]], profileID: profileID)

        let partial = cache.load(labels: ["house DJ track", "techno DJ track"], profileID: profileID)
        #expect(partial.cached["house DJ track"] == [1.0, 0.0])
        #expect(partial.missing == ["techno DJ track"])

        // A different profile is a different vector space and must not share hits.
        let otherProfile = cache.load(labels: ["house DJ track"], profileID: "local/clap-htsat-unfused")
        #expect(otherProfile.cached.isEmpty)
        #expect(otherProfile.missing == ["house DJ track"])
    }

    @Test
    func labelCacheProfileIDCannotEscapeItsDirectory() {
        // Profile ids contain slashes; they must never become path separators.
        #expect(LabelEmbeddingCache.sanitizedProfileID("google/gemini-embedding-2-preview")
            == "google_gemini-embedding-2-preview")
        #expect(!LabelEmbeddingCache.sanitizedProfileID("../../etc/passwd").contains("/"))
        #expect(LabelEmbeddingCache.sanitizedProfileID("") == "default")
    }

    @Test
    func databaseLocationUpdatePreservesAnalysisAndEmbeddingState() throws {
        let directory = try makeOrganizationTemporaryDirectory()
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        let oldPath = directory.appendingPathComponent("Old.wav").path
        let newPath = directory.appendingPathComponent("Organized/New.wav").path
        let track = makeOrganizationTrack(path: oldPath, title: "Move Me")
        let segment = makeOrganizationSegment(trackID: track.id, vector: [1.0, 0.0])
        let summary = makeOrganizationSummary(trackID: track.id, segments: [segment], trackEmbedding: [1.0, 0.0])

        try database.upsertTrack(track)
        try database.replaceSegments(trackID: track.id, segments: [segment], analysisSummary: summary)
        try database.markTrackEmbeddingIndexed(
            trackID: track.id,
            embeddingProfileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id,
            embeddingPipelineID: EmbeddingPipeline.audioSegmentsV1.id
        )

        let updated = try database.updateTrackFileLocation(
            trackID: track.id,
            fileURL: URL(fileURLWithPath: newPath),
            modifiedTime: Date(timeIntervalSince1970: 123),
            contentHash: "new-hash",
            lastSeenInLocalScanAt: Date(timeIntervalSince1970: 456),
            expectedCurrentPath: oldPath
        )

        #expect(updated.filePath == TrackPathNormalizer.normalizedAbsolutePath(newPath))
        #expect(updated.fileName == "New.wav")
        #expect(updated.contentHash == "new-hash")
        #expect(updated.embeddingProfileID == EmbeddingProfile.googleGeminiEmbedding2Preview.id)
        #expect(try database.fetchSegments(trackID: track.id).first?.vector == [1.0, 0.0])
        #expect(try database.fetchAnalysisSummary(trackID: track.id)?.trackEmbedding == [1.0, 0.0])
    }

    @Test
    func fileOrganizerRollsBackMoveWhenDatabaseUpdateFails() async throws {
        let directory = try makeOrganizationTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("Source.wav")
        let targetURL = directory.appendingPathComponent("Organized/Source.wav")
        try Data("audio".utf8).write(to: sourceURL)
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        let move = makeOrganizationMove(
            trackID: UUID(),
            sourcePath: sourceURL.path,
            targetPath: targetURL.path
        )
        let plan = makeOrganizationPlan(root: directory.path, moves: [move])
        let service = LibraryFileOrganizerService(database: database) { _, _, _ in }

        let result = await service.apply(plan: plan)

        #expect(result.movedCount == 0)
        #expect(result.failedCount == 1)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(!FileManager.default.fileExists(atPath: targetURL.path))
    }

    @Test
    func fileOrganizerMovesTrackAndWarnsWhenVectorRefreshFails() async throws {
        let directory = try makeOrganizationTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("Source.wav")
        let targetURL = directory.appendingPathComponent("Organized/Source.wav")
        try Data("audio".utf8).write(to: sourceURL)
        let database = try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
        let track = makeOrganizationTrack(path: sourceURL.path, title: "Source")
        let segment = makeOrganizationSegment(trackID: track.id, vector: [1.0, 0.0])
        let summary = makeOrganizationSummary(trackID: track.id, segments: [segment], trackEmbedding: [1.0, 0.0])

        try database.upsertTrack(track)
        try database.replaceSegments(trackID: track.id, segments: [segment], analysisSummary: summary)
        try database.markTrackEmbeddingIndexed(
            trackID: track.id,
            embeddingProfileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id,
            embeddingPipelineID: EmbeddingPipeline.audioSegmentsV1.id
        )

        let move = makeOrganizationMove(trackID: track.id, sourcePath: sourceURL.path, targetPath: targetURL.path)
        let plan = makeOrganizationPlan(root: directory.path, moves: [move])
        let service = LibraryFileOrganizerService(database: database) { _, _, _ in
            throw NSError(domain: "TestVector", code: 1, userInfo: [NSLocalizedDescriptionKey: "Vector down"])
        }

        let result = await service.apply(plan: plan)
        let updated = try database.fetchTrack(id: track.id)

        #expect(result.movedCount == 1)
        #expect(result.failedCount == 0)
        #expect(result.warnings.contains { $0.contains("vector metadata refresh failed") })
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(FileManager.default.fileExists(atPath: targetURL.path))
        #expect(updated?.filePath == TrackPathNormalizer.normalizedAbsolutePath(targetURL))
    }
}

private func makeOrganizationTrack(
    id: UUID = UUID(),
    path: String,
    title: String,
    artist: String = "DJ",
    album: String = "",
    genre: String = "",
    duration: TimeInterval = 300
) -> Track {
    Track(
        id: id,
        filePath: TrackPathNormalizer.normalizedAbsolutePath(path),
        fileName: URL(fileURLWithPath: path).lastPathComponent,
        title: title,
        artist: artist,
        album: album,
        genre: genre,
        duration: duration,
        sampleRate: 44_100,
        bpm: nil,
        musicalKey: nil,
        modifiedTime: Date(),
        contentHash: title,
        analyzedAt: Date(),
        embeddingProfileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id,
        embeddingPipelineID: EmbeddingPipeline.audioSegmentsV1.id,
        embeddingUpdatedAt: Date(),
        hasSeratoMetadata: false,
        hasRekordboxMetadata: false,
        lastSeenInLocalScanAt: Date()
    )
}

private func makeOrganizationSegment(trackID: UUID, vector: [Double]) -> TrackSegment {
    TrackSegment(
        id: UUID(),
        trackID: trackID,
        type: .middle,
        startSec: 0,
        endSec: 30,
        energyScore: 0.5,
        descriptorText: "middle",
        vector: vector
    )
}

private func makeOrganizationSummary(
    trackID: UUID,
    segments: [TrackSegment],
    trackEmbedding: [Double]
) -> TrackAnalysisSummary {
    TrackAnalysisSummary(
        trackID: trackID,
        segments: segments,
        trackEmbedding: trackEmbedding,
        estimatedBPM: 124,
        estimatedKey: "8A",
        brightness: 0.5,
        onsetDensity: 0.5,
        rhythmicDensity: 0.5,
        lowMidHighBalance: [0.3, 0.4, 0.3],
        waveformPreview: [0.1, 0.2]
    )
}

private func makeOrganizationMove(trackID: UUID, sourcePath: String, targetPath: String) -> LibraryOrganizationMove {
    LibraryOrganizationMove(
        id: trackID,
        trackID: trackID,
        title: "Source",
        artist: "DJ",
        fileName: URL(fileURLWithPath: sourcePath).lastPathComponent,
        sourcePath: TrackPathNormalizer.normalizedAbsolutePath(sourcePath),
        targetPath: TrackPathNormalizer.normalizedAbsolutePath(targetPath),
        genreID: "house",
        genreName: "House",
        genreScore: 1,
        clusterID: "house-1",
        clusterName: "Cluster 01 - DJ"
    )
}

private func makeOrganizationPlan(root: String, moves: [LibraryOrganizationMove]) -> LibraryOrganizationPlan {
    LibraryOrganizationPlan(
        id: UUID(),
        destinationRootPath: root,
        groups: [
            LibraryOrganizationGroup(
                id: "house-1",
                genreID: "house",
                genreName: "House",
                clusterID: "house-1",
                clusterName: "Cluster 01 - DJ",
                moves: moves
            )
        ],
        skippedTracks: [],
        warnings: [],
        createdAt: Date(),
        shouldAddDestinationRootToLibrary: false
    )
}

private func makeOrganizationTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
