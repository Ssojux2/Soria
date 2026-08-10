import Foundation
import Testing
@testable import Soria

/// Quarantine moves real files on a real filesystem, so these tests use a temp
/// directory rather than a fake FileManager — the failure modes worth catching
/// (occupied destinations, missing sources, rollback) are filesystem behaviour.
@Suite(.serialized)
struct LibraryQuarantineServiceTests {
    @Test
    func quarantineMovesTheFileAndHidesTheTrackFromTheLibrary() async throws {
        let context = try QuarantineTestContext()
        defer { context.cleanUp() }

        let track = try context.addTrack(named: "junk.mp3")
        #expect(try context.database.fetchScannedTracks().count == 1)

        let result = await context.service.quarantine(tracks: [track])

        #expect(result.movedTrackIDs == [track.id])
        #expect(result.failed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: track.filePath))

        let record = try #require(try context.database.fetchQuarantineRecords().first)
        #expect(record.originalPath == track.filePath)
        #expect(FileManager.default.fileExists(atPath: record.quarantinePath))
        // Nulling the scan mark is what removes it from the library list.
        #expect(try context.database.fetchScannedTracks().isEmpty)
        #expect(try context.database.fetchTrack(id: track.id) != nil)
    }

    @Test
    func restoreReturnsTheFileAndTheOriginalScanTimestamp() async throws {
        let context = try QuarantineTestContext()
        defer { context.cleanUp() }

        let lastSeen = Date(timeIntervalSince1970: 1_700_000_000)
        let track = try context.addTrack(named: "keep.mp3", lastSeenInLocalScanAt: lastSeen)

        _ = await context.service.quarantine(tracks: [track])
        let result = await context.service.restore(trackIDs: [track.id])

        #expect(result.restoredTrackIDs == [track.id])
        #expect(result.failed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: track.filePath))
        #expect(try context.database.fetchQuarantineRecords().isEmpty)

        let restored = try #require(try context.database.fetchTrack(id: track.id))
        #expect(restored.filePath == track.filePath)
        // Replaying the timestamp is what makes the track reappear without a rescan.
        #expect(Int(restored.lastSeenInLocalScanAt?.timeIntervalSince1970 ?? 0)
            == Int(lastSeen.timeIntervalSince1970))
        #expect(try context.database.fetchScannedTracks().count == 1)
    }

    @Test
    func restoreAllReturnsEveryQuarantinedTrack() async throws {
        let context = try QuarantineTestContext()
        defer { context.cleanUp() }

        let tracks = try (1...3).map { try context.addTrack(named: "t\($0).mp3", lastSeenInLocalScanAt: Date()) }
        _ = await context.service.quarantine(tracks: tracks)
        #expect(try context.database.fetchQuarantineRecords().count == 3)

        let result = await context.service.restoreAll()

        #expect(result.restoredCount == 3)
        #expect(try context.database.fetchQuarantineRecords().isEmpty)
        for track in tracks {
            #expect(FileManager.default.fileExists(atPath: track.filePath))
        }
    }

    @Test
    func restoreRefusesWhenAnotherFileTookTheOriginalPath() async throws {
        let context = try QuarantineTestContext()
        defer { context.cleanUp() }

        let track = try context.addTrack(named: "clash.mp3")
        _ = await context.service.quarantine(tracks: [track])

        // The user dropped a different file at the old location.
        try Data("different".utf8).write(to: URL(fileURLWithPath: track.filePath))

        let result = await context.service.restore(trackIDs: [track.id])

        #expect(result.restoredTrackIDs.isEmpty)
        #expect(result.failed.count == 1)
        // The quarantined copy must survive so nothing is lost.
        let record = try #require(try context.database.fetchQuarantineRecords().first)
        #expect(FileManager.default.fileExists(atPath: record.quarantinePath))
        #expect(try String(contentsOf: URL(fileURLWithPath: track.filePath), encoding: .utf8) == "different")
    }

    @Test
    func quarantineSkipsTracksWhoseFileIsAlreadyGone() async throws {
        let context = try QuarantineTestContext()
        defer { context.cleanUp() }

        let present = try context.addTrack(named: "here.mp3")
        let missing = try context.addTrack(named: "gone.mp3")
        try FileManager.default.removeItem(at: URL(fileURLWithPath: missing.filePath))

        let result = await context.service.quarantine(tracks: [present, missing])

        #expect(result.movedTrackIDs == [present.id])
        #expect(result.skipped.count == 1)
        #expect(result.skipped.first?.trackID == missing.id)
        #expect(result.failed.isEmpty)
    }

    @Test
    func quarantiningTwoTracksWithTheSameNameDoesNotOverwriteEither() async throws {
        let context = try QuarantineTestContext()
        defer { context.cleanUp() }

        let first = try context.addTrack(named: "Intro.mp3", inSubdirectory: "A", contents: "first")
        let second = try context.addTrack(named: "Intro.mp3", inSubdirectory: "B", contents: "second")

        let result = await context.service.quarantine(tracks: [first, second])
        #expect(result.movedCount == 2)

        let records = try context.database.fetchQuarantineRecords()
        let quarantinePaths = Set(records.map(\.quarantinePath))
        #expect(quarantinePaths.count == 2)
        let contents = try quarantinePaths
            .map { try String(contentsOf: URL(fileURLWithPath: $0), encoding: .utf8) }
            .sorted()
        #expect(contents == ["first", "second"])
    }

    @Test
    func purgeUsesTheInjectedTrashOperationAndNeverDeletesOutright() async throws {
        let context = try QuarantineTestContext()
        defer { context.cleanUp() }

        let trashed = TrashRecorder()
        let service = context.makeService(trashOperation: { _, url in
            trashed.record(url)
            return url
        })

        let track = try context.addTrack(named: "delete-me.mp3")
        _ = await service.quarantine(tracks: [track])
        let record = try #require(try context.database.fetchQuarantineRecords().first)

        let result = await service.purge(trackIDs: [track.id])

        #expect(result.restoredTrackIDs == [track.id])
        #expect(trashed.paths == [record.quarantinePath])
        #expect(try context.database.fetchQuarantineRecords().isEmpty)
        // The track row survives as soft-deleted, matching a removed-file scan.
        #expect(try context.database.fetchTrack(id: track.id) != nil)
        #expect(try context.database.fetchScannedTracks().isEmpty)
    }

    @Test
    func purgeReportsTrashFailuresInsteadOfCrashing() async throws {
        struct TrashDenied: Error {}
        let context = try QuarantineTestContext()
        defer { context.cleanUp() }

        let service = context.makeService(trashOperation: { _, _ in throw TrashDenied() })
        let track = try context.addTrack(named: "stubborn.mp3")
        _ = await service.quarantine(tracks: [track])

        let result = await service.purge(trackIDs: [track.id])

        #expect(result.restoredTrackIDs.isEmpty)
        #expect(result.failed.count == 1)
        // The record stays so the user can retry or restore.
        #expect(try context.database.fetchQuarantineRecords().count == 1)
    }

    @Test
    func quarantinePrefersTheContainingLibraryRoot() {
        let resolver = LibraryQuarantineService.defaultRootResolver(
            libraryRoots: { ["/Volumes/Crate/Music", "/Volumes/Crate"] }
        )
        let destination = resolver(URL(fileURLWithPath: "/Volumes/Crate/Music/House/a.mp3"))

        // Deepest matching root wins, and the folder is on the track's own volume
        // so the move stays a rename rather than a copy.
        #expect(destination.path == "/Volumes/Crate/Music/\(AppPaths.quarantineFolderName)")
    }

    @Test
    func excludedScanPathsCoverEveryRootPlusTheFallback() {
        let paths = LibraryQuarantineService.excludedScanPaths(
            libraryRoots: ["/Users/dj/Music", "/Volumes/Crate", ""]
        )

        #expect(paths.contains("/Users/dj/Music/\(AppPaths.quarantineFolderName)"))
        #expect(paths.contains("/Volumes/Crate/\(AppPaths.quarantineFolderName)"))
        #expect(paths.contains(TrackPathNormalizer.normalizedAbsolutePath(AppPaths.quarantineDirectory)))
        #expect(paths.count == 3)
    }

    @Test
    func scannerExclusionIsComponentAware() {
        let excluded: Set<String> = ["/Users/dj/Music/Soria Quarantine"]

        #expect(LibraryScannerService.isExcluded(
            "/Users/dj/Music/Soria Quarantine", excludedDirectoryPaths: excluded
        ))
        #expect(LibraryScannerService.isExcluded(
            "/Users/dj/Music/Soria Quarantine/2026-08-10 10-00-00", excludedDirectoryPaths: excluded
        ))
        // A sibling folder whose name merely starts the same must still be scanned.
        #expect(!LibraryScannerService.isExcluded(
            "/Users/dj/Music/Soria Quarantine Archive", excludedDirectoryPaths: excluded
        ))
        #expect(!LibraryScannerService.isExcluded("/Users/dj/Music", excludedDirectoryPaths: excluded))
        #expect(!LibraryScannerService.isExcluded("/Users/dj/Music", excludedDirectoryPaths: []))
    }

    @Test
    func rescanningLeavesQuarantinedTracksOutOfTheLibrary() async throws {
        let context = try QuarantineTestContext()
        defer { context.cleanUp() }

        let kept = try context.addTrack(named: "kept.mp3", lastSeenInLocalScanAt: Date())
        let discarded = try context.addTrack(named: "discarded.mp3", lastSeenInLocalScanAt: Date())
        _ = await context.service.quarantine(tracks: [discarded])

        let scanner = LibraryScannerService(
            database: context.database,
            excludedDirectoryPaths: {
                LibraryQuarantineService.excludedScanPaths(libraryRoots: [context.root.path])
            }
        )
        await scanner.scan(roots: [context.root]) { _ in }

        let scanned = try context.database.fetchScannedTracks()
        #expect(scanned.map(\.id) == [kept.id])
        // The record survives the scan, so the file is still restorable.
        #expect(try context.database.fetchQuarantineRecords().count == 1)
    }
}

// MARK: - Helpers

private final class TrashRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(TrackPathNormalizer.normalizedAbsolutePath(url))
    }

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private struct QuarantineTestContext {
    let root: URL
    let database: LibraryDatabase
    let service: LibraryQuarantineService

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Soria-Quarantine-Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try LibraryDatabase(databaseURL: root.appendingPathComponent("library.sqlite"))

        let rootPath = root.path
        service = LibraryQuarantineService(
            database: database,
            quarantineRootResolver: LibraryQuarantineService.defaultRootResolver(
                libraryRoots: { [rootPath] }
            )
        )
    }

    func makeService(
        trashOperation: @escaping LibraryQuarantineService.TrashOperation
    ) -> LibraryQuarantineService {
        let rootPath = root.path
        return LibraryQuarantineService(
            database: database,
            quarantineRootResolver: LibraryQuarantineService.defaultRootResolver(
                libraryRoots: { [rootPath] }
            ),
            trashOperation: trashOperation
        )
    }

    @discardableResult
    func addTrack(
        named fileName: String,
        inSubdirectory subdirectory: String? = nil,
        contents: String = "audio",
        lastSeenInLocalScanAt: Date? = Date()
    ) throws -> Track {
        let directory = subdirectory.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(fileName)
        try Data(contents.utf8).write(to: fileURL)

        var track = Track.empty(
            path: TrackPathNormalizer.normalizedAbsolutePath(fileURL),
            modifiedTime: Date(),
            hash: UUID().uuidString
        )
        track.title = fileURL.deletingPathExtension().lastPathComponent
        track.lastSeenInLocalScanAt = lastSeenInLocalScanAt
        try database.upsertTrack(track)
        return try #require(try database.fetchTrack(id: track.id))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
