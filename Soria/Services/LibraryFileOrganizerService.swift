import Foundation

/// Applies a `LibraryOrganizationPlan` to disk.
///
/// Every move is preflighted and individually reversible: the target must not
/// already exist (no silent renaming over a user's file), the source must be
/// readable, and a failed database write rolls the file back — unless something
/// reappeared at the source path, in which case rollback is refused rather than
/// overwriting it. A failed move degrades to a warning and the batch continues.
final class LibraryFileOrganizerService: @unchecked Sendable {
    typealias ProgressHandler = @Sendable (LibraryOrganizationProgress) async -> Void
    typealias VectorUpdater = @Sendable (Track, [TrackSegment], [Double]) async throws -> Void

    private let database: LibraryDatabase
    private let fileManager: FileManager
    private let vectorUpdater: VectorUpdater

    init(
        database: LibraryDatabase,
        fileManager: FileManager = .default,
        worker: PythonWorkerClient
    ) {
        self.database = database
        self.fileManager = fileManager
        self.vectorUpdater = { track, segments, trackEmbedding in
            try await worker.upsertTrackVectors(track: track, segments: segments, trackEmbedding: trackEmbedding)
        }
    }

    init(
        database: LibraryDatabase,
        fileManager: FileManager = .default,
        vectorUpdater: @escaping VectorUpdater
    ) {
        self.database = database
        self.fileManager = fileManager
        self.vectorUpdater = vectorUpdater
    }

    func apply(
        plan: LibraryOrganizationPlan,
        excludedMoveIDs: Set<UUID> = [],
        kind: LibraryOrganizationKind = .genreClusters,
        embeddingProfileID: String = "",
        onProgress: ProgressHandler? = nil
    ) async -> LibraryOrganizationResult {
        let moves = plan.includedMoves(excluding: excludedMoveIDs)
        guard !moves.isEmpty else {
            return LibraryOrganizationResult(
                movedCount: 0,
                failedCount: 0,
                warnings: ["No organizer moves were selected."]
            )
        }

        var movedCount = 0
        var failedCount = 0
        var warnings = plan.warnings
        var appliedMoveRecords: [OrganizationMoveRecord] = []
        var movedTrackIDsByGroupID: [String: [UUID]] = [:]

        let batchID = UUID()
        let groupIDByMoveID = Dictionary(
            uniqueKeysWithValues: plan.groups.flatMap { group in group.moves.map { ($0.id, group.id) } }
        )
        let collectionIDByGroupID = Dictionary(
            uniqueKeysWithValues: plan.groups.map { ($0.id, $0.collectionID) }
        )

        await onProgress?(
            LibraryOrganizationProgress(
                stage: .moving,
                completedCount: 0,
                totalCount: moves.count,
                currentFileName: "",
                message: "Preparing to move \(moves.count) tracks."
            )
        )

        // One access scope for the whole batch: reacquiring per file would be both
        // slower and more likely to hit a transient denial mid-run.
        let scopePaths = moves.flatMap { [$0.sourcePath, $0.targetFolderPath] } + [plan.destinationRootPath]

        await withSecurityScopedAccess(toPaths: scopePaths) {
            for (index, move) in moves.enumerated() {
                await onProgress?(
                    LibraryOrganizationProgress(
                        stage: .moving,
                        completedCount: index,
                        totalCount: moves.count,
                        currentFileName: move.fileName,
                        message: "Moving \(move.fileName)"
                    )
                )

                do {
                    let moveWarnings = try await apply(move: move)
                    warnings.append(contentsOf: moveWarnings)
                    movedCount += 1
                    appliedMoveRecords.append(
                        OrganizationMoveRecord(
                            batchID: batchID,
                            trackID: move.trackID,
                            sourcePath: move.sourcePath,
                            targetPath: move.targetPath,
                            collectionID: groupIDByMoveID[move.id].flatMap { collectionIDByGroupID[$0] }
                        )
                    )
                    if let groupID = groupIDByMoveID[move.id] {
                        movedTrackIDsByGroupID[groupID, default: []].append(move.trackID)
                    }
                } catch {
                    failedCount += 1
                    warnings.append("Organizer failed for \(move.fileName): \(error.localizedDescription)")
                    AppLogger.shared.error(
                        "Organizer failed for \(move.sourcePath) -> \(move.targetPath): \(error.localizedDescription)"
                    )
                }

                await onProgress?(
                    LibraryOrganizationProgress(
                        stage: .moving,
                        completedCount: index + 1,
                        totalCount: moves.count,
                        currentFileName: move.fileName,
                        message: "Processed \(index + 1)/\(moves.count) tracks."
                    )
                )
            }
        }

        if !appliedMoveRecords.isEmpty {
            do {
                try recordBatch(
                    batchID: batchID,
                    plan: plan,
                    kind: kind,
                    embeddingProfileID: embeddingProfileID,
                    moveRecords: appliedMoveRecords,
                    movedTrackIDsByGroupID: movedTrackIDsByGroupID
                )
            } catch {
                // The files did move; only the bookkeeping failed. Say so rather
                // than implying the organize itself went wrong.
                warnings.append(
                    "Files were organized, but Soria could not record the collections: \(error.localizedDescription)"
                )
                AppLogger.shared.error("organizer_batch_record_failed error=\(error.localizedDescription)")
            }
        }

        await onProgress?(
            LibraryOrganizationProgress(
                stage: failedCount == 0 ? .completed : .failed,
                completedCount: moves.count,
                totalCount: moves.count,
                currentFileName: "",
                message: failedCount == 0
                    ? "Moved \(movedCount) tracks."
                    : "Moved \(movedCount) tracks with \(failedCount) failures."
            )
        )

        return LibraryOrganizationResult(
            movedCount: movedCount,
            failedCount: failedCount,
            warnings: warnings
        )
    }

    // MARK: - Collections

    /// Mirrors the on-disk folder tree into `soria_collections` so the organized
    /// folders can be exported as crates and playlists later.
    private func recordBatch(
        batchID: UUID,
        plan: LibraryOrganizationPlan,
        kind: LibraryOrganizationKind,
        embeddingProfileID: String,
        moveRecords: [OrganizationMoveRecord],
        movedTrackIDsByGroupID: [String: [UUID]]
    ) throws {
        try database.insertOrganizationBatch(
            OrganizationBatchRecord(
                id: batchID,
                kind: kind.batchKind,
                destinationRoot: plan.destinationRootPath,
                embeddingProfileID: embeddingProfileID
            ),
            moves: moveRecords
        )

        let isPromptMode: Bool
        if case .promptFolders = kind { isPromptMode = true } else { isPromptMode = false }

        var genreCollectionIDByName: [String: UUID] = [:]
        var sortIndex = 0

        for group in plan.groups {
            guard let trackIDs = movedTrackIDsByGroupID[group.id], !trackIDs.isEmpty else { continue }

            // Prompt folders are one level deep, so they have no parent node.
            var parentID: UUID?
            if !isPromptMode {
                if let existing = genreCollectionIDByName[group.genreName] {
                    parentID = existing
                } else {
                    let genreCollection = SoriaCollection(
                        name: group.genreName,
                        kind: .group,
                        folderPath: URL(fileURLWithPath: plan.destinationRootPath, isDirectory: true)
                            .appendingPathComponent(group.genreName, isDirectory: true).path,
                        genreFamilyID: group.genreID,
                        sortIndex: sortIndex
                    )
                    try database.upsertCollection(genreCollection)
                    genreCollectionIDByName[group.genreName] = genreCollection.id
                    parentID = genreCollection.id
                    sortIndex += 1
                }
            }

            let folderPath = group.moves.first?.targetFolderPath
            try database.upsertCollection(
                SoriaCollection(
                    id: group.collectionID,
                    parentID: parentID,
                    name: isPromptMode ? group.genreName : group.clusterName,
                    kind: isPromptMode ? .promptFolder : .organizedFolder,
                    folderPath: folderPath,
                    genreFamilyID: group.genreID,
                    clusterID: group.clusterID,
                    promptText: isPromptMode ? group.genreName : nil,
                    sortIndex: sortIndex
                )
            )
            try database.replaceCollectionTracks(collectionID: group.collectionID, trackIDs: trackIDs)
            sortIndex += 1
        }
    }

    // MARK: - Single move

    private func apply(move: LibraryOrganizationMove) async throws -> [String] {
        let sourceURL = URL(fileURLWithPath: move.sourcePath).standardizedFileURL
        let targetURL = URL(fileURLWithPath: move.targetPath).standardizedFileURL

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw organizerError("File not found at \(sourceURL.path).")
        }
        guard fileManager.isReadableFile(atPath: sourceURL.path) else {
            throw organizerError("File is not readable at \(sourceURL.path).")
        }
        if fileManager.fileExists(atPath: targetURL.path) {
            throw organizerError("Target already exists at \(targetURL.path).")
        }

        try fileManager.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: sourceURL, to: targetURL)

        let updatedTrack: Track
        do {
            let attributes = try fileManager.attributesOfItem(atPath: targetURL.path)
            let modifiedTime = (attributes[.modificationDate] as? Date) ?? Date()
            let contentHash = FileHashingService.contentHash(for: targetURL)
            updatedTrack = try database.updateTrackFileLocation(
                trackID: move.trackID,
                fileURL: targetURL,
                modifiedTime: modifiedTime,
                contentHash: contentHash,
                lastSeenInLocalScanAt: Date(),
                // Fails the write if a concurrent scan or a second organize pass
                // already relocated this track, instead of clobbering it.
                expectedCurrentPath: move.sourcePath
            )
        } catch {
            try rollbackMove(from: targetURL, to: sourceURL)
            throw error
        }

        do {
            return try await refreshVectorIndex(for: updatedTrack)
        } catch {
            return ["Moved \(updatedTrack.fileName), but vector metadata refresh failed: \(error.localizedDescription)"]
        }
    }

    private func refreshVectorIndex(for track: Track) async throws -> [String] {
        guard
            let trackEmbedding = try database.fetchTrackEmbedding(trackID: track.id),
            !trackEmbedding.isEmpty
        else {
            return ["Moved \(track.fileName), but no stored track embedding was available for vector refresh."]
        }
        let segments = try database.fetchSegments(trackID: track.id).filter { segment in
            guard let vector = segment.vector else { return false }
            return !vector.isEmpty
        }
        guard !segments.isEmpty else {
            return ["Moved \(track.fileName), but no stored segment embeddings were available for vector refresh."]
        }

        do {
            try await vectorUpdater(track, segments, trackEmbedding)
            return []
        } catch {
            return ["Moved \(track.fileName), but vector metadata refresh failed: \(error.localizedDescription)"]
        }
    }

    private func rollbackMove(from targetURL: URL, to sourceURL: URL) throws {
        guard fileManager.fileExists(atPath: targetURL.path) else { return }
        try fileManager.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: sourceURL.path) {
            throw organizerError("Database update failed and rollback could not restore because the source path already exists.")
        }
        try fileManager.moveItem(at: targetURL, to: sourceURL)
    }

    /// `SecurityScopedBookmarkStore.withAccess` is synchronous, so hold the scope
    /// around an async body by starting and stopping it explicitly.
    private func withSecurityScopedAccess(toPaths paths: [String], _ body: () async -> Void) async {
        guard SecurityScopedBookmarkStore.isSandboxed else {
            await body()
            return
        }

        let scopePaths = SecurityScopedBookmarkStore.accessScopePaths(
            for: paths,
            storedPaths: SecurityScopedBookmarkStore.storedBookmarkPaths()
        )
        var startedURLs: [URL] = []
        for scopePath in scopePaths {
            guard let url = SecurityScopedBookmarkStore.resolveURL(forPath: scopePath) else { continue }
            if url.startAccessingSecurityScopedResource() {
                startedURLs.append(url)
            }
        }
        defer {
            for url in startedURLs.reversed() {
                url.stopAccessingSecurityScopedResource()
            }
        }

        await body()
    }

    private func organizerError(_ message: String) -> NSError {
        NSError(
            domain: "LibraryFileOrganizerService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
