import Foundation

final class LibraryScannerService: @unchecked Sendable {
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let database: LibraryDatabase
    private let invalidateVectorIndex: @Sendable (Track) async -> Void
    private let supportedExtensions: Set<String> = ["mp3", "wav", "aiff", "aif", "m4a", "aac", "flac"]

    init(
        database: LibraryDatabase,
        invalidateVectorIndex: @escaping @Sendable (Track) async -> Void = { _ in }
    ) {
        self.database = database
        self.invalidateVectorIndex = invalidateVectorIndex
    }

    func refreshTrack(at fileURL: URL) async throws -> Track {
        let normalizedURL = fileURL.standardizedFileURL
        let normalizedPath = TrackPathNormalizer.normalizedAbsolutePath(normalizedURL)
        let fileExtension = normalizedURL.pathExtension.lowercased()
        guard supportedExtensions.contains(fileExtension) else {
            throw NSError(
                domain: "LibraryScannerService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported audio format: .\(fileExtension)"]
            )
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: normalizedURL.path)
        let modified = Self.normalizedTimestamp((attributes[.modificationDate] as? Date) ?? .distantPast)
        let previous = try database.fetchTrack(path: normalizedPath)
        let contentHash = FileHashingService.contentHash(for: normalizedURL)

        return try await upsertTrackRecord(
            fileURL: normalizedURL,
            normalizedPath: normalizedPath,
            modified: modified,
            contentHash: contentHash,
            previous: previous,
            isUnchanged: previous.map { $0.modifiedTime >= modified && $0.contentHash == contentHash } ?? false,
            lastSeenInLocalScanAt: previous?.lastSeenInLocalScanAt ?? Date()
        )
    }

    func scan(
        roots: [URL],
        onProgress: @escaping @Sendable (ScanJobProgress) -> Void
    ) async {
        await Task.yield()
        var progress = ScanJobProgress()
        progress.isRunning = true
        onProgress(progress)

        let fm = FileManager.default
        let files = discoverFiles(in: roots)

        progress.totalFiles = files.count
        onProgress(progress)

        do {
            let existingTracks = try database.fetchAllTracks()
            var hashIndex = Dictionary(
                grouping: existingTracks.filter { $0.lastSeenInLocalScanAt != nil },
                by: { $0.contentHash }
            )
            var pathIndex = Dictionary(uniqueKeysWithValues: existingTracks.map { ($0.filePath, $0) })
            var seenPaths = Set<String>()
            let scanTimestamp = Date()

            for fileURL in files {
                let normalizedPath = TrackPathNormalizer.normalizedAbsolutePath(fileURL)
                seenPaths.insert(normalizedPath)
                progress.scannedFiles += 1
                progress.currentFile = fileURL.lastPathComponent
                onProgress(progress)

                do {
                    let attrs = try fm.attributesOfItem(atPath: fileURL.path)
                    let modified = Self.normalizedTimestamp((attrs[.modificationDate] as? Date) ?? .distantPast)
                    let previous = pathIndex[normalizedPath]
                    let isLocallyScanned = previous?.lastSeenInLocalScanAt != nil
                    let isUnchanged = previous.map { $0.modifiedTime >= modified } ?? false

                    if let previous, isLocallyScanned, isUnchanged {
                        var refreshedTrack = previous
                        refreshedTrack.lastSeenInLocalScanAt = scanTimestamp
                        try database.upsertTrack(refreshedTrack)
                        pathIndex[normalizedPath] = refreshedTrack
                        progress.skippedFiles += 1
                        onProgress(progress)
                        continue
                    }

                    let hash = FileHashingService.contentHash(for: fileURL)
                    if let dupes = hashIndex[hash], dupes.contains(where: { $0.filePath != normalizedPath }) {
                        progress.duplicateFiles += 1
                        onProgress(progress)
                        continue
                    }

                    let track = try await upsertTrackRecord(
                        fileURL: fileURL,
                        normalizedPath: normalizedPath,
                        modified: modified,
                        contentHash: hash,
                        previous: previous,
                        isUnchanged: isUnchanged,
                        lastSeenInLocalScanAt: scanTimestamp
                    )
                    pathIndex[normalizedPath] = track
                    hashIndex[hash, default: []].append(track)
                    progress.indexedFiles += 1
                } catch {
                    AppLogger.shared.error("Scan failure for \(fileURL.path): \(error.localizedDescription)")
                }
                onProgress(progress)
            }

            try database.clearLocalScanMarks(excludingPaths: Array(seenPaths))
            try database.refreshMembershipIndexes()
        } catch {
            AppLogger.shared.error("Failed to prime index: \(error.localizedDescription)")
        }

        progress.isRunning = false
        onProgress(progress)
    }

    private static func normalizedTimestamp(_ date: Date) -> Date {
        let persistedValue = timestampFormatter.string(from: date)
        return timestampFormatter.date(from: persistedValue) ?? date
    }

    private func discoverFiles(in roots: [URL]) -> [URL] {
        let fm = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isHiddenKey,
            .isSymbolicLinkKey
        ]
        var files: [URL] = []
        var directoriesToVisit = roots.map(\.standardizedFileURL)
        var visitedDirectories = Set<String>()

        while let directory = directoriesToVisit.popLast() {
            let normalizedDirectory = TrackPathNormalizer.normalizedAbsolutePath(directory)
            guard visitedDirectories.insert(normalizedDirectory).inserted else {
                continue
            }

            guard let children = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for childURL in children {
                let values = try? childURL.resourceValues(forKeys: resourceKeys)
                let isHidden = values?.isHidden == true || childURL.lastPathComponent.hasPrefix(".")
                if isHidden {
                    continue
                }

                if values?.isDirectory == true {
                    if values?.isSymbolicLink == true {
                        continue
                    }
                    directoriesToVisit.append(childURL)
                    continue
                }

                guard values?.isRegularFile == true else { continue }
                if supportedExtensions.contains(childURL.pathExtension.lowercased()) {
                    files.append(childURL)
                }
            }
        }

        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func upsertTrackRecord(
        fileURL: URL,
        normalizedPath: String,
        modified: Date,
        contentHash: String,
        previous: Track?,
        isUnchanged: Bool,
        lastSeenInLocalScanAt: Date?
    ) async throws -> Track {
        let metadata = await AudioMetadataReader.readMetadata(for: fileURL)
        var track = previous ?? Track.empty(path: normalizedPath, modifiedTime: modified, hash: contentHash)
        let fileChanged = previous != nil && (!isUnchanged || previous?.contentHash != contentHash)

        if fileChanged, let previous, previous.analyzedAt != nil {
            try database.clearAnalysis(trackID: previous.id)
            await invalidateVectorIndex(previous)
            if track.bpmSource == .soriaAnalysis {
                track.bpm = nil
                track.bpmSource = nil
            }
            if track.keySource == .soriaAnalysis {
                track.musicalKey = nil
                track.keySource = nil
            }
        }

        track = Track(
            id: track.id,
            filePath: normalizedPath,
            fileName: fileURL.lastPathComponent,
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            genre: metadata.genre.isEmpty ? track.genre : metadata.genre,
            comment: track.comment,
            duration: metadata.duration,
            sampleRate: metadata.sampleRate,
            bpm: metadata.bpm,
            musicalKey: metadata.musicalKey,
            modifiedTime: modified,
            contentHash: contentHash,
            analyzedAt: fileChanged ? nil : track.analyzedAt,
            embeddingProfileID: fileChanged ? nil : track.embeddingProfileID,
            embeddingPipelineID: fileChanged ? nil : track.embeddingPipelineID,
            embeddingUpdatedAt: fileChanged ? nil : track.embeddingUpdatedAt,
            hasSeratoMetadata: track.hasSeratoMetadata,
            hasRekordboxMetadata: track.hasRekordboxMetadata,
            genreSource: metadata.genre.isEmpty ? track.genreSource : .audioTags,
            bpmSource: metadata.bpm == nil ? track.bpmSource : .audioTags,
            keySource: metadata.musicalKey == nil ? track.keySource : .audioTags,
            lastSeenInLocalScanAt: lastSeenInLocalScanAt
        )
        try database.upsertTrack(track)
        return track
    }
}
