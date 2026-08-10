import Foundation

/// Moves unwanted tracks into a Soria-managed quarantine folder and back again.
///
/// Deliberately not the system Trash: a DJ culling a library wants to review what
/// they discarded and put some of it back, and macOS gives an app no way to list
/// or selectively restore its own trashed items. Quarantined files stay on their
/// original volume, the database keeps the row, and `track_quarantine` records
/// everything needed to undo the move. "Delete Permanently" is the one operation
/// that hands files to the system Trash, and it never calls `removeItem`.
final class LibraryQuarantineService: @unchecked Sendable {
    typealias TrashOperation = @Sendable (FileManager, URL) throws -> URL?
    typealias QuarantineRootResolver = @Sendable (URL) -> URL

    private let database: LibraryDatabase
    private let fileManager: FileManager
    private let quarantineRootResolver: QuarantineRootResolver
    private let trashOperation: TrashOperation

    init(
        database: LibraryDatabase,
        fileManager: FileManager = .default,
        quarantineRootResolver: @escaping QuarantineRootResolver,
        trashOperation: @escaping TrashOperation = { fileManager, url in
            var trashedURL: NSURL?
            try fileManager.trashItem(at: url, resultingItemURL: &trashedURL)
            return trashedURL as URL?
        }
    ) {
        self.database = database
        self.fileManager = fileManager
        self.quarantineRootResolver = quarantineRootResolver
        self.trashOperation = trashOperation
    }

    // MARK: - Quarantine

    func quarantine(
        tracks: [Track],
        reason: TrackQuarantineRecord.Reason = .userDiscard,
        batchID: UUID = UUID()
    ) async -> QuarantineMoveResult {
        var result = QuarantineMoveResult(batchID: batchID)
        guard !tracks.isEmpty else { return result }

        let batchFolderName = Self.batchFolderName(for: Date())
        var reservedPaths = Set<String>()

        for track in tracks {
            let sourceURL = URL(fileURLWithPath: track.filePath)
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                result.skipped.append(
                    .init(trackID: track.id, path: track.filePath, reason: "File is already missing from disk.")
                )
                continue
            }

            let destinationDirectory = quarantineRootResolver(sourceURL)
                .appendingPathComponent(batchFolderName, isDirectory: true)
            let destinationURL = uniqueDestination(
                for: sourceURL.lastPathComponent,
                in: destinationDirectory,
                reserved: reservedPaths
            )
            reservedPaths.insert(destinationURL.standardizedFileURL.path)

            do {
                try SecurityScopedBookmarkStore.withAccess(
                    toPaths: [sourceURL.path, destinationDirectory.path]
                ) {
                    try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                    try fileManager.moveItem(at: sourceURL, to: destinationURL)
                }
            } catch {
                result.failed.append(
                    .init(trackID: track.id, path: track.filePath, message: error.localizedDescription)
                )
                continue
            }

            do {
                try database.insertQuarantineRecord(
                    TrackQuarantineRecord(
                        trackID: track.id,
                        originalPath: track.filePath,
                        quarantinePath: TrackPathNormalizer.normalizedAbsolutePath(destinationURL),
                        originalLastSeenInLocalScanAt: track.lastSeenInLocalScanAt,
                        reason: reason,
                        batchID: batchID
                    )
                )
                _ = try database.updateTrackFileLocation(
                    trackID: track.id,
                    fileURL: destinationURL,
                    modifiedTime: track.modifiedTime,
                    contentHash: track.contentHash,
                    lastSeenInLocalScanAt: nil,
                    expectedCurrentPath: track.filePath,
                    aliasSource: "quarantine_move"
                )
                result.movedTrackIDs.append(track.id)
            } catch {
                // 한국어: DB 기록에 실패하면 파일을 제자리로 되돌립니다.
                // 되돌리지 못하면 사용자가 직접 찾을 수 있도록 경로를 알려줍니다.
                if restoreFile(from: destinationURL, to: sourceURL) {
                    result.failed.append(
                        .init(trackID: track.id, path: track.filePath, message: error.localizedDescription)
                    )
                } else {
                    result.failed.append(
                        .init(
                            trackID: track.id,
                            path: track.filePath,
                            message: "\(error.localizedDescription) The file is at \(destinationURL.path)."
                        )
                    )
                }
            }
        }

        return result
    }

    // MARK: - Restore

    func restore(trackIDs: [UUID]) async -> QuarantineRestoreResult {
        let wanted = Set(trackIDs)
        return await restore(matching: { wanted.contains($0.trackID) })
    }

    func restoreAll(batchID: UUID? = nil) async -> QuarantineRestoreResult {
        await restore(matching: { batchID == nil || $0.batchID == batchID })
    }

    private func restore(
        matching predicate: (TrackQuarantineRecord) -> Bool
    ) async -> QuarantineRestoreResult {
        var result = QuarantineRestoreResult()

        let records: [TrackQuarantineRecord]
        do {
            records = try database.fetchQuarantineRecords().filter(predicate)
        } catch {
            result.warnings.append("Could not read the Soria Trash: \(error.localizedDescription)")
            return result
        }

        for record in records {
            let quarantineURL = URL(fileURLWithPath: record.quarantinePath)
            let originalURL = URL(fileURLWithPath: record.originalPath)

            guard fileManager.fileExists(atPath: quarantineURL.path) else {
                result.failed.append(
                    .init(
                        trackID: record.trackID,
                        path: record.quarantinePath,
                        message: "The file is no longer in the Soria Trash folder."
                    )
                )
                continue
            }

            // Same guard as AudioNormalizationService.restoreOriginalFromTrashIfPossible:
            // never overwrite whatever now occupies the original path.
            guard !fileManager.fileExists(atPath: originalURL.path) else {
                result.failed.append(
                    .init(
                        trackID: record.trackID,
                        path: record.originalPath,
                        message: "Another file already occupies the original location."
                    )
                )
                continue
            }

            do {
                try SecurityScopedBookmarkStore.withAccess(
                    toPaths: [quarantineURL.path, originalURL.deletingLastPathComponent().path]
                ) {
                    try fileManager.createDirectory(
                        at: originalURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.moveItem(at: quarantineURL, to: originalURL)
                }
            } catch {
                result.failed.append(
                    .init(trackID: record.trackID, path: record.quarantinePath, message: error.localizedDescription)
                )
                continue
            }

            do {
                let track = try database.fetchTrack(id: record.trackID)
                _ = try database.updateTrackFileLocation(
                    trackID: record.trackID,
                    fileURL: originalURL,
                    modifiedTime: track?.modifiedTime ?? Date(),
                    contentHash: track?.contentHash ?? "",
                    // Replaying the pre-quarantine timestamp is what makes restore
                    // immediate instead of requiring a full rescan.
                    lastSeenInLocalScanAt: record.originalLastSeenInLocalScanAt,
                    expectedCurrentPath: record.quarantinePath,
                    aliasSource: "quarantine_restore"
                )
                try database.deleteQuarantineRecord(trackID: record.trackID)
                result.restoredTrackIDs.append(record.trackID)
            } catch {
                _ = restoreFile(from: originalURL, to: quarantineURL)
                result.failed.append(
                    .init(trackID: record.trackID, path: record.originalPath, message: error.localizedDescription)
                )
            }
        }

        return result
    }

    // MARK: - Purge

    /// Hands quarantined files to the system Trash and drops their quarantine rows.
    ///
    /// The track rows stay in the database with a null local-scan timestamp, the
    /// same soft-deleted state a removed file ends up in after a scan.
    func purge(trackIDs: [UUID]) async -> QuarantineRestoreResult {
        var result = QuarantineRestoreResult()
        let wanted = Set(trackIDs)

        let records: [TrackQuarantineRecord]
        do {
            records = try database.fetchQuarantineRecords().filter { wanted.contains($0.trackID) }
        } catch {
            result.warnings.append("Could not read the Soria Trash: \(error.localizedDescription)")
            return result
        }

        for record in records {
            let quarantineURL = URL(fileURLWithPath: record.quarantinePath)

            if fileManager.fileExists(atPath: quarantineURL.path) {
                do {
                    try SecurityScopedBookmarkStore.withAccess(toPaths: [quarantineURL.path]) {
                        _ = try trashOperation(fileManager, quarantineURL)
                    }
                } catch {
                    result.failed.append(
                        .init(
                            trackID: record.trackID,
                            path: record.quarantinePath,
                            message: error.localizedDescription
                        )
                    )
                    continue
                }
            } else {
                result.warnings.append(
                    "\(quarantineURL.lastPathComponent) was already gone from the Soria Trash folder."
                )
            }

            do {
                try database.deleteQuarantineRecord(trackID: record.trackID)
                result.restoredTrackIDs.append(record.trackID)
            } catch {
                result.failed.append(
                    .init(trackID: record.trackID, path: record.quarantinePath, message: error.localizedDescription)
                )
            }
        }

        return result
    }

    // MARK: - Rows

    func quarantineRows(tracksByID: [UUID: Track]) throws -> [QuarantineRow] {
        try database.fetchQuarantineRecords().map { record in
            let track = tracksByID[record.trackID]
            return QuarantineRow(
                record: record,
                title: track?.title.isEmpty == false
                    ? track!.title
                    : URL(fileURLWithPath: record.originalPath).lastPathComponent,
                artist: track?.artist ?? "",
                fileExists: fileManager.fileExists(atPath: record.quarantinePath)
            )
        }
    }

    // MARK: - Destination resolution

    /// Picks the quarantine folder for a track, preferring the same volume so the
    /// move is a rename rather than a copy of a potentially huge file.
    ///
    /// Pure apart from the writability probe, so the resolver can be substituted
    /// wholesale in tests.
    static func defaultRootResolver(
        libraryRoots: @escaping @Sendable () -> [String],
        fileManager: FileManager = .default
    ) -> QuarantineRootResolver {
        { sourceURL in
            let sourcePath = TrackPathNormalizer.normalizedAbsolutePath(sourceURL)

            if let root = deepestContainingRoot(for: sourcePath, roots: libraryRoots()) {
                return URL(fileURLWithPath: root, isDirectory: true)
                    .appendingPathComponent(AppPaths.quarantineFolderName, isDirectory: true)
            }

            if let volumeRoot = try? sourceURL.resourceValues(forKeys: [.volumeURLKey]).volume,
               fileManager.isWritableFile(atPath: volumeRoot.path) {
                return volumeRoot.appendingPathComponent(AppPaths.quarantineFolderName, isDirectory: true)
            }

            return AppPaths.quarantineDirectory
        }
    }

    /// The most specific configured library root containing `path`.
    static func deepestContainingRoot(for path: String, roots: [String]) -> String? {
        var best: String?
        for root in roots.map(TrackPathNormalizer.normalizedAbsolutePath) where !root.isEmpty {
            guard path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { continue }
            if best == nil || root.count > (best?.count ?? 0) {
                best = root
            }
        }
        return best
    }

    /// Quarantine folders the scanner must skip: one per configured library root.
    static func excludedScanPaths(libraryRoots: [String]) -> Set<String> {
        var paths = Set(
            libraryRoots
                .map(TrackPathNormalizer.normalizedAbsolutePath)
                .filter { !$0.isEmpty }
                .map { root in
                    TrackPathNormalizer.normalizedAbsolutePath(
                        URL(fileURLWithPath: root, isDirectory: true)
                            .appendingPathComponent(AppPaths.quarantineFolderName, isDirectory: true)
                    )
                }
        )
        paths.insert(TrackPathNormalizer.normalizedAbsolutePath(AppPaths.quarantineDirectory))
        return paths
    }

    static func batchFolderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.string(from: date)
    }

    // MARK: - Private

    private func uniqueDestination(
        for fileName: String,
        in directory: URL,
        reserved: Set<String>
    ) -> URL {
        let candidate = directory.appendingPathComponent(fileName)
        let isTaken: (URL) -> Bool = { url in
            reserved.contains(url.standardizedFileURL.path) || self.fileManager.fileExists(atPath: url.path)
        }
        guard isTaken(candidate) else { return candidate }

        let base = candidate.deletingPathExtension().lastPathComponent
        let pathExtension = candidate.pathExtension
        for suffix in 2...100 {
            let name = pathExtension.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(pathExtension)"
            let next = directory.appendingPathComponent(name)
            if !isTaken(next) { return next }
        }

        let fallbackName = pathExtension.isEmpty
            ? "\(base)-\(UUID().uuidString)"
            : "\(base)-\(UUID().uuidString).\(pathExtension)"
        return directory.appendingPathComponent(fallbackName)
    }

    /// Best-effort undo of a file move. Returns false when the destination is
    /// occupied or the move fails, so callers can tell the user where the file is.
    private func restoreFile(from movedURL: URL, to originalURL: URL) -> Bool {
        guard fileManager.fileExists(atPath: movedURL.path),
              !fileManager.fileExists(atPath: originalURL.path) else {
            return false
        }
        do {
            try fileManager.moveItem(at: movedURL, to: originalURL)
            return true
        } catch {
            AppLogger.shared.error(
                "quarantine_rollback_failed from=\(movedURL.path) to=\(originalURL.path) "
                    + "error=\(error.localizedDescription)"
            )
            return false
        }
    }
}
