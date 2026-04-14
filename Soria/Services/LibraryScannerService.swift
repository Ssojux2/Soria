import Foundation

final class LibraryScannerService {
    private let database: LibraryDatabase
    private let supportedExtensions: Set<String> = ["mp3", "wav", "aiff", "m4a", "flac"]

    init(database: LibraryDatabase) {
        self.database = database
    }

    func scan(
        roots: [URL],
        onProgress: @escaping @Sendable (ScanJobProgress) -> Void
    ) async {
        var progress = ScanJobProgress()
        progress.isRunning = true
        onProgress(progress)

        let fm = FileManager.default
        let files = discoverFiles(in: roots)

        progress.totalFiles = files.count
        onProgress(progress)

        do {
            let existingTracks = try database.fetchAllTracks()
            var hashIndex = Dictionary(grouping: existingTracks, by: { $0.contentHash })
            var pathIndex = Dictionary(uniqueKeysWithValues: existingTracks.map { ($0.filePath, $0) })

            for fileURL in files {
                progress.scannedFiles += 1
                progress.currentFile = fileURL.lastPathComponent
                onProgress(progress)

                do {
                    let attrs = try fm.attributesOfItem(atPath: fileURL.path)
                    let modified = (attrs[.modificationDate] as? Date) ?? .distantPast
                    let previous = pathIndex[fileURL.path]
                    if let previous, previous.modifiedTime >= modified {
                        progress.skippedFiles += 1
                        onProgress(progress)
                        continue
                    }

                    let hash = FileHashingService.contentHash(for: fileURL)
                    if let dupes = hashIndex[hash], dupes.contains(where: { $0.filePath != fileURL.path }) {
                        progress.duplicateFiles += 1
                        onProgress(progress)
                        continue
                    }

                    let metadata = await AudioMetadataReader.readMetadata(for: fileURL)
                    var track = previous ?? Track.empty(path: fileURL.path, modifiedTime: modified, hash: hash)
                    track = Track(
                        id: track.id,
                        filePath: fileURL.path,
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
                        analyzedAt: track.analyzedAt,
                        hasSeratoMetadata: track.hasSeratoMetadata,
                        hasRekordboxMetadata: track.hasRekordboxMetadata
                    )
                    try database.upsertTrack(track)
                    pathIndex[fileURL.path] = track
                    hashIndex[hash, default: []].append(track)
                    progress.indexedFiles += 1
                } catch {
                    AppLogger.shared.error("Scan failure for \(fileURL.path): \(error.localizedDescription)")
                }
                onProgress(progress)
            }
        } catch {
            AppLogger.shared.error("Failed to prime index: \(error.localizedDescription)")
        }

        progress.isRunning = false
        onProgress(progress)
    }

    private func discoverFiles(in roots: [URL]) -> [URL] {
        let fm = FileManager.default
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        var files: [URL] = []

        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: options
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                if supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                    files.append(fileURL)
                }
            }
        }

        return files
    }
}
