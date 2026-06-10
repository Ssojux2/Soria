import Foundation
import Testing
@testable import Soria

@Suite(.serialized)
struct FolderOrganizationServiceTests {
    @Test
    func planGenerationBucketsByPresetAndDoesNotMoveFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("Music/Original.mp3")
        try createFile(at: sourceURL, contents: "original")
        let database = try makeDatabase(in: directory)
        let track = try makeTrack(
            url: sourceURL,
            title: "Original",
            artist: "Soria",
            genre: "House",
            bpm: 124,
            database: database
        )

        let service = FolderOrganizationService(database: database)
        let plan = service.generatePlan(
            intent: FolderOrganizationIntent(scope: .selectedTracks, preset: .genre, prompt: ""),
            tracks: [track],
            libraryRoots: [directory.path]
        )

        #expect(plan.moves.count == 1)
        #expect(plan.moves.first?.bucket == "House")
        #expect(plan.moves.first?.state == .ready)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(!FileManager.default.fileExists(atPath: plan.moves[0].destinationPath))
    }

    @Test
    func planGenerationAdjustsConflictingDestinationNames() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("Music/Collision.mp3")
        let conflictURL = directory
            .appendingPathComponent("Soria Organized/Genre/House", isDirectory: true)
            .appendingPathComponent("Collision.mp3")
        try createFile(at: sourceURL, contents: "source")
        try createFile(at: conflictURL, contents: "existing")
        let database = try makeDatabase(in: directory)
        let track = try makeTrack(
            url: sourceURL,
            title: "Collision",
            artist: "Soria",
            genre: "House",
            database: database
        )

        let service = FolderOrganizationService(database: database)
        let plan = service.generatePlan(
            intent: FolderOrganizationIntent(scope: .selectedTracks, preset: .genre, prompt: ""),
            tracks: [track],
            libraryRoots: [directory.path]
        )

        #expect(plan.conflictCount == 1)
        #expect(plan.moves.first?.state == .conflictAdjusted)
        #expect(plan.moves.first?.destinationPath.contains("-soria-") == true)
        #expect(plan.moves.first?.destinationPath != conflictURL.path)
    }

    @Test
    func applyMovesFileAndPreservesTrackAnalysis() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("Music/Analyzed.mp3")
        try createFile(at: sourceURL, contents: "analyzed")
        let database = try makeDatabase(in: directory)
        let track = try makeTrack(
            url: sourceURL,
            title: "Analyzed",
            artist: "Soria",
            genre: "Deep House",
            bpm: 118,
            database: database
        )
        try addAnalysis(to: track, database: database)

        let recorder = ReindexRecorder()
        let service = FolderOrganizationService(database: database) { track, _, _ in
            await recorder.record(track.filePath)
        }
        let plan = service.generatePlan(
            intent: FolderOrganizationIntent(
                scope: .selectedTracks,
                preset: .energyMood,
                prompt: "warmup deep"
            ),
            tracks: [track],
            libraryRoots: [directory.path]
        )

        let result = await service.apply(plan: plan)
        let updatedTrack = try #require(try database.fetchTrack(id: track.id))
        let summary = try database.fetchAnalysisSummary(trackID: track.id)
        let reindexedPaths = await recorder.paths()

        #expect(result.movedCount == 1)
        #expect(result.failedCount == 0)
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(FileManager.default.fileExists(atPath: updatedTrack.filePath))
        #expect(updatedTrack.id == track.id)
        #expect(updatedTrack.filePath.contains("Soria Organized"))
        #expect(summary != nil)
        #expect(reindexedPaths == [updatedTrack.filePath])
    }

    @MainActor
    @Test
    func viewModelUsesSelectedTracksBeforeVisibleTracksForOrganizationScope() {
        let viewModel = AppViewModel(skipAsyncBootstrap: true)
        let first = makeMemoryTrack(title: "First Warmup")
        let second = makeMemoryTrack(title: "Second Peak")
        viewModel.configureRecommendationSearchStateForTesting(
            tracks: [first, second],
            selectedTrackIDs: [first.id],
            readyTrackIDs: [],
            validationStatus: .validated(Date())
        )

        viewModel.folderOrganizationScope = .selectedTracks
        #expect(viewModel.folderOrganizationTargetCount == 1)

        viewModel.folderOrganizationScope = .visibleTracks
        #expect(viewModel.folderOrganizationTargetCount == 2)

        viewModel.librarySearchText = "Peak"
        #expect(viewModel.folderOrganizationTargetCount == 1)
    }
}

private actor ReindexRecorder {
    private var recordedPaths: [String] = []

    func record(_ path: String) {
        recordedPaths.append(path)
    }

    func paths() -> [String] {
        recordedPaths
    }
}

private func makeDatabase(in directory: URL) throws -> LibraryDatabase {
    try LibraryDatabase(databaseURL: directory.appendingPathComponent("library.sqlite"))
}

private func makeTrack(
    url: URL,
    title: String,
    artist: String,
    genre: String,
    bpm: Double? = nil,
    database: LibraryDatabase
) throws -> Track {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let modified = (attributes[.modificationDate] as? Date) ?? Date()
    let hash = FileHashingService.contentHash(for: url)
    var track = Track.empty(path: url.path, modifiedTime: modified, hash: hash)
    track.title = title
    track.artist = artist
    track.genre = genre
    track.bpm = bpm
    track.lastSeenInLocalScanAt = Date()
    try database.upsertTrack(track)
    return track
}

private func addAnalysis(to track: Track, database: LibraryDatabase) throws {
    let segment = TrackSegment(
        id: UUID(),
        trackID: track.id,
        type: .middle,
        startSec: 0,
        endSec: 30,
        energyScore: 0.3,
        descriptorText: "warm deep groove",
        vector: [0.2, 0.8]
    )
    let summary = TrackAnalysisSummary(
        trackID: track.id,
        segments: [segment],
        trackEmbedding: [0.2, 0.8],
        estimatedBPM: track.bpm,
        estimatedKey: nil,
        brightness: 0.2,
        onsetDensity: 0.3,
        rhythmicDensity: 0.4,
        lowMidHighBalance: [0.3, 0.4, 0.3],
        waveformPreview: [0.1, 0.3],
        energyArc: [0.25, 0.35],
        mixabilityTags: ["warmup", "deep"],
        confidence: 0.8
    )
    try database.replaceSegments(trackID: track.id, segments: [segment], analysisSummary: summary)
}

private func makeMemoryTrack(title: String) -> Track {
    Track(
        id: UUID(),
        filePath: "/tmp/\(title).mp3",
        fileName: "\(title).mp3",
        title: title,
        artist: "Soria",
        album: "",
        genre: "",
        duration: 180,
        sampleRate: 44_100,
        bpm: nil,
        musicalKey: nil,
        modifiedTime: Date(),
        contentHash: UUID().uuidString,
        analyzedAt: nil,
        embeddingProfileID: nil,
        embeddingPipelineID: nil,
        embeddingUpdatedAt: nil,
        hasSeratoMetadata: false,
        hasRekordboxMetadata: false,
        lastSeenInLocalScanAt: Date()
    )
}

private func createFile(at url: URL, contents: String) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: url)
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
