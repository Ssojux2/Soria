import Foundation

final class LibraryScannerService {
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

                    let metadata = await AudioMetadataReader.readMetadata(for: fileURL)
                    var track = previous ?? Track.empty(path: normalizedPath, modifiedTime: modified, hash: hash)
                    let fileChanged = previous != nil && !isUnchanged
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
                        genre: metadata.genre,
                        duration: metadata.duration,
                        sampleRate: metadata.sampleRate,
                        bpm: metadata.bpm,
                        musicalKey: metadata.musicalKey,
                        modifiedTime: modified,
                        contentHash: hash,
                        analyzedAt: fileChanged ? nil : track.analyzedAt,
                        embeddingProfileID: fileChanged ? nil : track.embeddingProfileID,
                        embeddingPipelineID: fileChanged ? nil : track.embeddingPipelineID,
                        embeddingUpdatedAt: fileChanged ? nil : track.embeddingUpdatedAt,
                        hasSeratoMetadata: track.hasSeratoMetadata,
                        hasRekordboxMetadata: track.hasRekordboxMetadata,
                        bpmSource: metadata.bpm == nil ? track.bpmSource : .audioTags,
                        keySource: metadata.musicalKey == nil ? track.keySource : .audioTags,
                        lastSeenInLocalScanAt: scanTimestamp
                    )
                    try database.upsertTrack(track)
                    pathIndex[normalizedPath] = track
                    hashIndex[hash, default: []].append(track)
                    progress.indexedFiles += 1
                } catch {
                    AppLogger.shared.error("Scan failure for \(fileURL.path): \(error.localizedDescription)")
                }
                onProgress(progress)
            }

            let normalizedRoots = roots.map(TrackPathNormalizer.normalizedAbsolutePath)
            try database.clearLocalScanMarks(
                underRoots: normalizedRoots,
                excludingPaths: Array(seenPaths)
            )
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
}
