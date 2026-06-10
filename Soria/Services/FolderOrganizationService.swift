import Foundation

final class FolderOrganizationService: @unchecked Sendable {
    typealias ProgressHandler = @Sendable (FolderOrganizationProgress) -> Void
    typealias VectorReindexer = @Sendable (Track, [TrackSegment], [Double]) async throws -> Void

    private let database: LibraryDatabase
    private let fileManager: FileManager
    private let vectorReindexer: VectorReindexer

    init(
        database: LibraryDatabase,
        fileManager: FileManager = .default,
        vectorReindexer: @escaping VectorReindexer = { _, _, _ in }
    ) {
        self.database = database
        self.fileManager = fileManager
        self.vectorReindexer = vectorReindexer
    }

    func generatePlan(
        intent: FolderOrganizationIntent,
        tracks: [Track],
        libraryRoots: [String]
    ) -> FolderOrganizationPlan {
        let normalizedRoots = libraryRoots
            .map(TrackPathNormalizer.normalizedAbsolutePath)
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        let trimmedPrompt = intent.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = Self.safePathComponent(Self.intentSlug(prompt: trimmedPrompt, preset: intent.preset))
        var warnings: [String] = [
            "Moving source files can break existing Serato or rekordbox references until those libraries are refreshed or playlists are re-exported."
        ]
        var usedDestinationPaths = Set<String>()
        var moves: [ProposedTrackMove] = []
        var conflictCount = 0
        var affectedRoots = Set<String>()

        if normalizedRoots.isEmpty {
            warnings.append("No Music Folders are configured, so Soria cannot safely choose destination roots.")
        }

        for track in tracks {
            let sourcePath = TrackPathNormalizer.normalizedAbsolutePath(track.filePath)
            let sourceURL = URL(fileURLWithPath: sourcePath)
            guard fileManager.fileExists(atPath: sourcePath) else {
                moves.append(
                    ProposedTrackMove(
                        id: UUID(),
                        trackID: track.id,
                        title: track.title,
                        artist: track.artist,
                        sourcePath: sourcePath,
                        destinationPath: sourcePath,
                        bucket: "Missing",
                        state: .missingSource,
                        warnings: ["Source file is missing."]
                    )
                )
                continue
            }

            guard let containingRoot = containingRoot(for: sourcePath, roots: normalizedRoots) else {
                moves.append(
                    ProposedTrackMove(
                        id: UUID(),
                        trackID: track.id,
                        title: track.title,
                        artist: track.artist,
                        sourcePath: sourcePath,
                        destinationPath: sourcePath,
                        bucket: "Outside Music Folders",
                        state: .outsideLibraryRoot,
                        warnings: ["Source file is outside the configured Music Folders."]
                    )
                )
                continue
            }

            let requestedRoot = resolvedDestinationRoot(intent.destinationRoot, fallbackRoot: containingRoot)
            guard isPath(requestedRoot, containedInAny: normalizedRoots) else {
                moves.append(
                    ProposedTrackMove(
                        id: UUID(),
                        trackID: track.id,
                        title: track.title,
                        artist: track.artist,
                        sourcePath: sourcePath,
                        destinationPath: sourcePath,
                        bucket: "Outside Music Folders",
                        state: .outsideLibraryRoot,
                        warnings: ["Destination root must be inside a configured Music Folder."]
                    )
                )
                continue
            }

            affectedRoots.insert(requestedRoot)
            let bucket = bucketName(for: track, preset: intent.preset, prompt: trimmedPrompt)
            let baseDestinationURL = URL(fileURLWithPath: requestedRoot, isDirectory: true)
                .appendingPathComponent("Soria Organized", isDirectory: true)
                .appendingPathComponent(slug, isDirectory: true)
                .appendingPathComponent(Self.safePathComponent(bucket), isDirectory: true)
                .appendingPathComponent(sourceURL.lastPathComponent)
            let resolved = resolvedDestination(
                requestedURL: baseDestinationURL,
                sourcePath: sourcePath,
                track: track,
                usedDestinationPaths: &usedDestinationPaths
            )
            if resolved.didAdjustForConflict {
                conflictCount += 1
            }

            let destinationPath = TrackPathNormalizer.normalizedAbsolutePath(resolved.url)
            let state: ProposedTrackMove.State
            if destinationPath == sourcePath {
                state = .noOp
            } else if resolved.didAdjustForConflict {
                state = .conflictAdjusted
            } else {
                state = .ready
            }

            moves.append(
                ProposedTrackMove(
                    id: UUID(),
                    trackID: track.id,
                    title: track.title,
                    artist: track.artist,
                    sourcePath: sourcePath,
                    destinationPath: destinationPath,
                    bucket: bucket,
                    state: state,
                    warnings: resolved.didAdjustForConflict ? ["Destination filename was adjusted to avoid a conflict."] : []
                )
            )
        }

        return FolderOrganizationPlan(
            id: UUID(),
            intent: intent,
            moves: moves,
            warnings: warnings,
            conflictCount: conflictCount,
            affectedRoots: Array(affectedRoots).sorted(),
            createdAt: Date()
        )
    }

    func apply(
        plan: FolderOrganizationPlan,
        onProgress: ProgressHandler? = nil
    ) async -> FolderOrganizationResult {
        var moved: [FolderOrganizationMovedTrack] = []
        var skipped: [FolderOrganizationSkippedTrack] = []
        var failed: [FolderOrganizationFailedTrack] = []
        let total = plan.moves.count

        for (index, proposedMove) in plan.moves.enumerated() {
            onProgress?(
                FolderOrganizationProgress(
                    completed: index,
                    total: total,
                    currentFileName: URL(fileURLWithPath: proposedMove.sourcePath).lastPathComponent,
                    message: "Organizing \(proposedMove.title)"
                )
            )

            guard proposedMove.canMove else {
                skipped.append(
                    FolderOrganizationSkippedTrack(
                        id: UUID(),
                        trackID: proposedMove.trackID,
                        title: proposedMove.title,
                        path: proposedMove.sourcePath,
                        reason: proposedMove.state.displayName
                    )
                )
                continue
            }

            let sourceURL = URL(fileURLWithPath: proposedMove.sourcePath)
            let destinationURL = URL(fileURLWithPath: proposedMove.destinationPath)

            do {
                try moveFile(from: sourceURL, to: destinationURL)
                let updatedTrack: Track
                do {
                    updatedTrack = try updateDatabaseLocation(trackID: proposedMove.trackID, destinationURL: destinationURL)
                } catch {
                    try? restoreMovedFile(from: destinationURL, to: sourceURL)
                    throw error
                }
                var itemWarnings = proposedMove.warnings
                do {
                    try await reindexVectorsIfPossible(for: updatedTrack)
                } catch {
                    itemWarnings.append("Vector index refresh failed: \(error.localizedDescription)")
                    AppLogger.shared.error(
                        "Folder organization vector refresh failed | trackID=\(updatedTrack.id.uuidString) | error=\(error.localizedDescription)"
                    )
                }
                moved.append(
                    FolderOrganizationMovedTrack(
                        id: UUID(),
                        trackID: proposedMove.trackID,
                        title: proposedMove.title,
                        oldPath: proposedMove.sourcePath,
                        newPath: proposedMove.destinationPath,
                        warnings: itemWarnings
                    )
                )
            } catch {
                failed.append(
                    FolderOrganizationFailedTrack(
                        id: UUID(),
                        trackID: proposedMove.trackID,
                        title: proposedMove.title,
                        sourcePath: proposedMove.sourcePath,
                        destinationPath: proposedMove.destinationPath,
                        message: error.localizedDescription
                    )
                )
                AppLogger.shared.error(
                    "Folder organization failed | source=\(proposedMove.sourcePath) | destination=\(proposedMove.destinationPath) | error=\(error.localizedDescription)"
                )
            }
        }

        onProgress?(
            FolderOrganizationProgress(
                completed: total,
                total: total,
                currentFileName: nil,
                message: "Organization finished."
            )
        )

        return FolderOrganizationResult(
            moved: moved,
            skipped: skipped,
            failed: failed,
            completedAt: Date()
        )
    }

    private func updateDatabaseLocation(trackID: UUID, destinationURL: URL) throws -> Track {
        let attributes = try fileManager.attributesOfItem(atPath: destinationURL.path)
        let modified = (attributes[.modificationDate] as? Date) ?? Date()
        let contentHash = FileHashingService.contentHash(for: destinationURL)
        return try database.updateTrackFileLocation(
            trackID: trackID,
            fileURL: destinationURL,
            modifiedTime: modified,
            contentHash: contentHash,
            lastSeenInLocalScanAt: Date()
        )
    }

    private func moveFile(from sourceURL: URL, to destinationURL: URL) throws {
        let normalizedSource = TrackPathNormalizer.normalizedAbsolutePath(sourceURL)
        let normalizedDestination = TrackPathNormalizer.normalizedAbsolutePath(destinationURL)
        guard normalizedSource != normalizedDestination else { return }

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            throw FolderOrganizationError.moveFailed(error.localizedDescription)
        }
    }

    private func restoreMovedFile(from destinationURL: URL, to sourceURL: URL) throws {
        guard fileManager.fileExists(atPath: destinationURL.path),
              !fileManager.fileExists(atPath: sourceURL.path) else {
            return
        }
        try fileManager.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: destinationURL, to: sourceURL)
    }

    private func reindexVectorsIfPossible(for track: Track) async throws {
        guard let trackEmbedding = try database.fetchTrackEmbedding(trackID: track.id), !trackEmbedding.isEmpty else {
            return
        }
        let segments = try database.fetchSegments(trackID: track.id)
        guard !segments.isEmpty else { return }
        try await vectorReindexer(track, segments, trackEmbedding)
    }

    private func resolvedDestinationRoot(_ destinationRoot: String?, fallbackRoot: String) -> String {
        guard let destinationRoot else { return fallbackRoot }
        let normalized = TrackPathNormalizer.normalizedAbsolutePath(destinationRoot)
        return normalized.isEmpty ? fallbackRoot : normalized
    }

    private func containingRoot(for path: String, roots: [String]) -> String? {
        roots.first { isPath(path, containedIn: $0) }
    }

    private func isPath(_ path: String, containedInAny roots: [String]) -> Bool {
        roots.contains { isPath(path, containedIn: $0) }
    }

    private func isPath(_ path: String, containedIn root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private func resolvedDestination(
        requestedURL: URL,
        sourcePath: String,
        track: Track,
        usedDestinationPaths: inout Set<String>
    ) -> (url: URL, didAdjustForConflict: Bool) {
        let requestedPath = TrackPathNormalizer.normalizedAbsolutePath(requestedURL)
        if requestedPath == sourcePath {
            usedDestinationPaths.insert(requestedPath)
            return (requestedURL, false)
        }

        if !destinationConflicts(path: requestedPath, usedDestinationPaths: usedDestinationPaths) {
            usedDestinationPaths.insert(requestedPath)
            return (requestedURL, false)
        }

        let suffixBase = String((track.contentHash.isEmpty ? track.id.uuidString : track.contentHash).prefix(8))
        let directory = requestedURL.deletingLastPathComponent()
        let extensionSuffix = requestedURL.pathExtension.isEmpty ? "" : ".\(requestedURL.pathExtension)"
        let baseName = requestedURL.deletingPathExtension().lastPathComponent

        for index in 0..<100 {
            let suffix = index == 0 ? "-soria-\(suffixBase)" : "-soria-\(suffixBase)-\(index + 1)"
            let candidate = directory.appendingPathComponent("\(baseName)\(suffix)\(extensionSuffix)")
            let candidatePath = TrackPathNormalizer.normalizedAbsolutePath(candidate)
            if candidatePath == sourcePath || !destinationConflicts(path: candidatePath, usedDestinationPaths: usedDestinationPaths) {
                usedDestinationPaths.insert(candidatePath)
                return (candidate, true)
            }
        }

        usedDestinationPaths.insert(requestedPath)
        return (requestedURL, true)
    }

    private func destinationConflicts(path: String, usedDestinationPaths: Set<String>) -> Bool {
        usedDestinationPaths.contains(path)
            || fileManager.fileExists(atPath: path)
            || ((try? database.fetchTrack(path: path)) != nil)
    }

    private func bucketName(for track: Track, preset: FolderOrganizationPreset, prompt: String) -> String {
        switch preset {
        case .genre:
            return nonEmpty(track.genre, fallback: "Unknown Genre")
        case .artist:
            return nonEmpty(track.artist, fallback: "Unknown Artist")
        case .bpmRange:
            guard let bpm = track.bpm, bpm.isFinite, bpm > 0 else { return "BPM Unknown" }
            let lower = Int(floor(bpm / 10) * 10)
            return "\(lower)-\(lower + 9) BPM"
        case .musicalKey:
            return nonEmpty(track.musicalKey ?? "", fallback: "Key Unknown")
        case .energyMood:
            return energyMoodBucket(for: track, prompt: prompt)
        case .vendorMembership:
            return vendorMembershipBucket(for: track)
        }
    }

    private func energyMoodBucket(for track: Track, prompt: String) -> String {
        let summary = try? database.fetchAnalysisSummary(trackID: track.id)
        let externalMetadata = (try? database.fetchExternalMetadata(trackID: track.id)) ?? []
        let searchableText = [
            track.title,
            track.artist,
            track.album,
            track.genre,
            track.comment,
            externalMetadata.flatMap(\.tags).joined(separator: " "),
            externalMetadata.compactMap(\.comment).joined(separator: " "),
            summary?.segments.map(\.descriptorText).joined(separator: " ") ?? "",
            summary?.mixabilityTags.joined(separator: " ") ?? ""
        ]
        .joined(separator: " ")
        .lowercased()
        let normalizedPrompt = prompt.lowercased()
        let averageEnergy = averageEnergyScore(summary)

        if normalizedPrompt.contains("vocal") {
            return searchableText.contains("vocal") || searchableText.contains("vox") ? "Vocal" : "Instrumental or Unsure"
        }
        if normalizedPrompt.contains("deep") || normalizedPrompt.contains("warm") {
            if searchableText.contains("deep") || searchableText.contains("ambient") || searchableText.contains("warm") {
                return "Warmup Deep"
            }
            if let averageEnergy, averageEnergy < 0.5 {
                return "Warmup Deep"
            }
            if let bpm = track.bpm, bpm < 122 {
                return "Warmup Deep"
            }
            return "Main Room"
        }
        if normalizedPrompt.contains("peak") || normalizedPrompt.contains("festival") {
            if searchableText.contains("peak") || searchableText.contains("festival") {
                return "Peak Time"
            }
            if let averageEnergy, averageEnergy >= 0.68 {
                return "Peak Time"
            }
            if let bpm = track.bpm, bpm >= 126 {
                return "Peak Time"
            }
            return "Support"
        }

        if let averageEnergy {
            if averageEnergy < 0.42 {
                return "Low Energy"
            }
            if averageEnergy > 0.68 {
                return "High Energy"
            }
            return "Mid Energy"
        }

        if let bpm = track.bpm {
            if bpm < 118 {
                return "Low Energy"
            }
            if bpm >= 126 {
                return "High Energy"
            }
            return "Mid Energy"
        }

        return "Mood Unsorted"
    }

    private func averageEnergyScore(_ summary: TrackAnalysisSummary?) -> Double? {
        guard let summary else { return nil }
        if !summary.energyArc.isEmpty {
            return summary.energyArc.reduce(0, +) / Double(summary.energyArc.count)
        }
        let segmentScores = summary.segments.map(\.energyScore)
        guard !segmentScores.isEmpty else { return nil }
        return segmentScores.reduce(0, +) / Double(segmentScores.count)
    }

    private func vendorMembershipBucket(for track: Track) -> String {
        let metadata = (try? database.fetchExternalMetadata(trackID: track.id)) ?? []
        let memberships = metadata
            .flatMap(\.playlistMemberships)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        guard let membership = memberships.first else { return "No Vendor Membership" }
        let parts = membership
            .replacingOccurrences(of: " / ", with: "/")
            .split(separator: "/")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.last ?? membership
    }

    private func nonEmpty(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func intentSlug(prompt: String, preset: FolderOrganizationPreset) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return preset.displayName }
        return String(trimmed.prefix(48))
    }

    static func safePathComponent(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
            .union(.newlines)
            .union(.controlCharacters)
        let parts = value
            .components(separatedBy: invalid)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let joined = parts.joined(separator: " ")
        return joined.isEmpty ? "Unsorted" : String(joined.prefix(80))
    }
}

enum FolderOrganizationError: LocalizedError {
    case moveFailed(String)

    var errorDescription: String? {
        switch self {
        case let .moveFailed(message):
            return "Move failed: \(message)"
        }
    }
}
