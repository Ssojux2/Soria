import Foundation

struct LibraryOrganizationPlanner {
    private struct PlanningTrack {
        let track: Track
        let embedding: [Double]
        let genreID: String
        let genreName: String
        let genreScore: Double
    }

    private struct Cluster {
        var members: [PlanningTrack]
        var centroid: [Double]

        var representative: PlanningTrack {
            members.sorted {
                let left = "\($0.track.artist) \($0.track.title)"
                let right = "\($1.track.artist) \($1.track.title)"
                return left.localizedStandardCompare(right) == .orderedAscending
            }.first ?? members[0]
        }
    }

    let config: LibraryOrganizationClusterConfig

    init(config: LibraryOrganizationClusterConfig = .defaults) {
        self.config = config
    }

    /// Builds a folder plan without touching the filesystem.
    ///
    /// Pure: label and track embeddings come in as parameters, so the whole
    /// planner is testable with no worker, no network, and no disk. The caller is
    /// responsible for fetching embeddings and, for `.promptFolders`, for
    /// embedding the user's prompts through the same model.
    ///
    /// - Parameters:
    ///   - labelEmbeddingsByFamilyID: label vectors keyed by genre family id for
    ///     `.genreClusters`, or by prompt slug for `.promptFolders`.
    ///   - labelDisplayNames: overrides for folder names, used by prompt folders
    ///     where the slug is not what the user should see.
    func makePlan(
        tracks: [Track],
        readyTrackIDs: Set<UUID>,
        embeddingsByTrackID: [UUID: [Double]],
        labelEmbeddingsByFamilyID: [String: [Double]],
        destinationRootPath: String,
        libraryRoots: [String],
        kind: LibraryOrganizationKind = .genreClusters,
        labelDisplayNames: [String: String] = [:]
    ) -> LibraryOrganizationPlan {
        let normalizedRoot = TrackPathNormalizer.normalizedAbsolutePath(destinationRootPath)
        var skipped: [LibraryOrganizationSkippedTrack] = []
        var planningTracks: [PlanningTrack] = []
        let isPromptMode: Bool
        if case .promptFolders = kind { isPromptMode = true } else { isPromptMode = false }

        for track in tracks {
            guard readyTrackIDs.contains(track.id) else {
                skipped.append(skippedTrack(track, reason: "Needs Prep"))
                continue
            }
            guard let embedding = embeddingsByTrackID[track.id], !embedding.isEmpty else {
                skipped.append(skippedTrack(track, reason: "Missing embedding"))
                continue
            }

            let assignment = isPromptMode
                ? assignedPrompt(
                    trackEmbedding: embedding,
                    labelEmbeddingsByFamilyID: labelEmbeddingsByFamilyID,
                    labelDisplayNames: labelDisplayNames
                )
                : assignedGenre(
                    for: track,
                    trackEmbedding: embedding,
                    labelEmbeddingsByFamilyID: labelEmbeddingsByFamilyID,
                    libraryRoots: libraryRoots
                )

            planningTracks.append(
                PlanningTrack(
                    track: track,
                    embedding: normalizedVector(embedding),
                    genreID: assignment.id,
                    genreName: assignment.name,
                    genreScore: assignment.score
                )
            )
        }

        let groups = makeGroups(
            from: planningTracks,
            destinationRootPath: normalizedRoot,
            clusterWithinGroups: !isPromptMode,
            skipped: &skipped
        )
        let normalizedLibraryRoots = libraryRoots
            .map(TrackPathNormalizer.normalizedAbsolutePath)
            .filter { !$0.isEmpty }
        let shouldAddDestinationRoot = !normalizedRoot.isEmpty &&
            !normalizedLibraryRoots.contains(where: { normalizedRoot.hasPrefix($0) })
        var warnings: [String] = []
        if shouldAddDestinationRoot {
            warnings.append(
                "The destination folder will be added to Music Folders after Apply so future scans keep these tracks active."
            )
        }
        if let confidenceWarning = lowConfidenceWarning(
            genreIDs: planningTracks.map(\.genreID),
            isPromptMode: isPromptMode
        ) {
            warnings.append(confidenceWarning)
        }
        warnings.append(
            "Moving files leaves existing Serato crates and rekordbox playlists pointing at the old paths until you export again."
        )

        return LibraryOrganizationPlan(
            id: UUID(),
            destinationRootPath: normalizedRoot,
            groups: groups,
            skippedTracks: skipped.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending },
            warnings: warnings,
            createdAt: Date(),
            shouldAddDestinationRootToLibrary: shouldAddDestinationRoot
        )
    }

    /// Flags a plan whose assignments look like noise rather than signal.
    ///
    /// Comparing a text label vector against an audio vector is only meaningful in
    /// a shared embedding space. A model that does not provide one still returns
    /// numbers, and they pile everything into one bucket — which is exactly what
    /// this detects.
    func lowConfidenceWarning(genreIDs: [String], isPromptMode: Bool) -> String? {
        guard genreIDs.count >= 8 else { return nil }

        let counts = Dictionary(grouping: genreIDs, by: { $0 }).mapValues(\.count)
        let largestShare = Double(counts.values.max() ?? 0) / Double(genreIDs.count)
        guard largestShare > config.degenerateGenreShare else { return nil }

        let bucket = isPromptMode ? "prompt" : "genre"
        return "Low confidence: \(Int(largestShare * 100))% of tracks landed in one \(bucket) folder. "
            + "Review the preview before applying — this usually means the current embedding model "
            + "does not compare text labels against audio well."
    }

    /// Picks the best-scoring prompt for a track, or the Unmatched bucket when no
    /// prompt clears `minimumPromptScore`.
    private func assignedPrompt(
        trackEmbedding: [Double],
        labelEmbeddingsByFamilyID: [String: [Double]],
        labelDisplayNames: [String: String]
    ) -> (id: String, name: String, score: Double) {
        var scored: [(promptID: String, score: Double)] = []
        for (promptID, labelEmbedding) in labelEmbeddingsByFamilyID {
            scored.append((promptID, cosineSimilarity(trackEmbedding, labelEmbedding)))
        }
        scored.sort { left, right in
            left.score == right.score ? left.promptID < right.promptID : left.score > right.score
        }

        guard let best = scored.first, best.score >= config.minimumPromptScore else {
            return (
                LibraryOrganizationBuckets.unmatchedID,
                LibraryOrganizationBuckets.unmatchedName,
                scored.first?.score ?? 0
            )
        }
        return (best.promptID, labelDisplayNames[best.promptID] ?? best.promptID, best.score)
    }

    private func makeGroups(
        from planningTracks: [PlanningTrack],
        destinationRootPath: String,
        clusterWithinGroups: Bool,
        skipped: inout [LibraryOrganizationSkippedTrack]
    ) -> [LibraryOrganizationGroup] {
        var reservedTargetPaths = Set<String>()
        var output: [LibraryOrganizationGroup] = []
        let byGenre = Dictionary(grouping: planningTracks, by: \.genreID)

        for genreID in byGenre.keys.sorted() {
            let tracks = (byGenre[genreID] ?? []).sorted {
                "\($0.track.artist) \($0.track.title)".localizedStandardCompare("\($1.track.artist) \($1.track.title)") == .orderedAscending
            }
            // Prompt folders carry their own display name; genre folders look
            // theirs up in the taxonomy.
            let genreName = clusterWithinGroups
                ? GenreTaxonomy.displayName(for: genreID)
                : (tracks.first?.genreName ?? genreID)
            // A prompt is already the grouping — subdividing it into clusters
            // would bury the folder the user asked for.
            let clusters = clusterWithinGroups
                ? clusteredTracks(tracks)
                : [Cluster(members: tracks, centroid: centroid(for: tracks))]

            for (index, cluster) in clusters.enumerated() where !cluster.members.isEmpty {
                let clusterNumber = index + 1
                let representative = cluster.representative
                let representativeLabel = representative.track.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? representative.track.title
                    : representative.track.artist
                let clusterName = clusterWithinGroups
                    ? sanitizedPathComponent(
                        "Cluster \(String(format: "%02d", clusterNumber)) - \(representativeLabel)"
                    )
                    : sanitizedPathComponent(genreName)
                let clusterID = clusterWithinGroups ? "\(genreID)-\(clusterNumber)" : genreID
                var moves: [LibraryOrganizationMove] = []

                for member in cluster.members.sorted(by: {
                    $0.track.fileName.localizedStandardCompare($1.track.fileName) == .orderedAscending
                }) {
                    let targetPath = uniqueTargetPath(
                        rootPath: destinationRootPath,
                        genreName: genreName,
                        clusterName: clusterName,
                        fileName: member.track.fileName,
                        trackID: member.track.id,
                        reservedTargetPaths: &reservedTargetPaths,
                        // Prompt folders are one level deep: <root>/<prompt>/file
                        flattenClusterFolder: !clusterWithinGroups
                    )
                    let sourcePath = TrackPathNormalizer.normalizedAbsolutePath(member.track.filePath)
                    if sourcePath == targetPath {
                        skipped.append(skippedTrack(member.track, reason: "Already organized"))
                        continue
                    }
                    moves.append(
                        LibraryOrganizationMove(
                            id: member.track.id,
                            trackID: member.track.id,
                            title: member.track.title,
                            artist: member.track.artist,
                            fileName: member.track.fileName,
                            sourcePath: sourcePath,
                            targetPath: targetPath,
                            genreID: member.genreID,
                            genreName: member.genreName,
                            genreScore: member.genreScore,
                            clusterID: clusterID,
                            clusterName: clusterName
                        )
                    )
                }

                if !moves.isEmpty {
                    output.append(
                        LibraryOrganizationGroup(
                            id: clusterID,
                            genreID: genreID,
                            genreName: genreName,
                            clusterID: clusterID,
                            clusterName: clusterName,
                            moves: moves
                        )
                    )
                }
            }
        }

        return output
    }

    private func assignedGenre(
        for track: Track,
        trackEmbedding: [Double],
        labelEmbeddingsByFamilyID: [String: [Double]],
        libraryRoots: [String]
    ) -> (id: String, name: String, score: Double) {
        let scored = labelEmbeddingsByFamilyID.map { familyID, labelEmbedding in
            (familyID, cosineSimilarity(trackEmbedding, labelEmbedding))
        }
        .sorted {
            if $0.1 == $1.1 {
                return $0.0 < $1.0
            }
            return $0.1 > $1.1
        }

        let best = scored.first ?? ("unknown", 0)
        let secondScore = scored.dropFirst().first?.1 ?? -1
        let metadataFamilyID = metadataFamilyID(for: track, libraryRoots: libraryRoots)
        let resolvedID: String
        if
            let metadataFamilyID,
            abs(best.1 - secondScore) <= 0.025,
            scored.contains(where: { $0.0 == metadataFamilyID })
        {
            resolvedID = metadataFamilyID
        } else {
            resolvedID = best.0
        }

        return (
            resolvedID,
            GenreTaxonomy.displayName(for: resolvedID),
            scored.first(where: { $0.0 == resolvedID })?.1 ?? best.1
        )
    }

    private func metadataFamilyID(for track: Track, libraryRoots: [String]) -> String? {
        let values = [track.genre] + folderPathHints(for: track.filePath, libraryRoots: libraryRoots)
        return values
            .map(GenreTaxonomy.normalizeGenreText)
            .compactMap(GenreTaxonomy.familyID(forNormalizedValue:))
            .first
    }

    private func folderPathHints(for filePath: String, libraryRoots: [String]) -> [String] {
        let normalizedPath = TrackPathNormalizer.normalizedAbsolutePath(filePath)
        let normalizedRoots = libraryRoots
            .map(TrackPathNormalizer.normalizedAbsolutePath)
            .filter { !$0.isEmpty && normalizedPath.hasPrefix($0) }
            .sorted { $0.count > $1.count }
        guard let bestRoot = normalizedRoots.first else { return [] }

        let rootComponents = URL(fileURLWithPath: bestRoot).pathComponents
        let pathComponents = URL(fileURLWithPath: normalizedPath).pathComponents
        guard pathComponents.count > rootComponents.count else { return [] }
        let relativeComponents = Array(pathComponents.dropFirst(rootComponents.count).dropLast())
        return Array(relativeComponents.prefix(2))
    }

    private func clusteredTracks(_ tracks: [PlanningTrack]) -> [Cluster] {
        guard !tracks.isEmpty else { return [] }
        var clusters: [Cluster] = []

        for track in tracks {
            let bestIndex = clusters.indices.max { left, right in
                cosineSimilarity(track.embedding, clusters[left].centroid) < cosineSimilarity(track.embedding, clusters[right].centroid)
            }
            if
                let bestIndex,
                clusters[bestIndex].members.count < max(1, config.maxClusterSize),
                cosineSimilarity(track.embedding, clusters[bestIndex].centroid) >= config.assignThreshold
            {
                clusters[bestIndex].members.append(track)
                clusters[bestIndex].centroid = centroid(for: clusters[bestIndex].members)
            } else {
                clusters.append(Cluster(members: [track], centroid: track.embedding))
            }
        }

        clusters = mergeClusters(clusters)
        clusters = foldSingletonClusters(clusters)
        return clusters.sorted {
            $0.representative.track.title.localizedStandardCompare($1.representative.track.title) == .orderedAscending
        }
    }

    private func mergeClusters(_ input: [Cluster]) -> [Cluster] {
        var clusters = input
        var didMerge = true
        while didMerge {
            didMerge = false
            outer: for leftIndex in clusters.indices {
                for rightIndex in clusters.indices where leftIndex < rightIndex {
                    let combinedCount = clusters[leftIndex].members.count + clusters[rightIndex].members.count
                    guard combinedCount <= max(1, config.maxClusterSize) else { continue }
                    guard cosineSimilarity(clusters[leftIndex].centroid, clusters[rightIndex].centroid) >= config.mergeThreshold else {
                        continue
                    }
                    clusters[leftIndex].members.append(contentsOf: clusters[rightIndex].members)
                    clusters[leftIndex].centroid = centroid(for: clusters[leftIndex].members)
                    clusters.remove(at: rightIndex)
                    didMerge = true
                    break outer
                }
            }
        }
        return clusters
    }

    private func foldSingletonClusters(_ input: [Cluster]) -> [Cluster] {
        var clusters = input
        var index = 0
        while index < clusters.count {
            guard clusters[index].members.count == 1, clusters.count > 1 else {
                index += 1
                continue
            }
            let singleton = clusters[index]
            let targetIndex = clusters.indices
                .filter { $0 != index && clusters[$0].members.count < max(1, config.maxClusterSize) }
                .max { left, right in
                    cosineSimilarity(singleton.centroid, clusters[left].centroid) < cosineSimilarity(singleton.centroid, clusters[right].centroid)
                }
            if
                let targetIndex,
                cosineSimilarity(singleton.centroid, clusters[targetIndex].centroid) >= config.smallClusterFoldThreshold
            {
                clusters[targetIndex].members.append(contentsOf: singleton.members)
                clusters[targetIndex].centroid = centroid(for: clusters[targetIndex].members)
                clusters.remove(at: index)
            } else {
                index += 1
            }
        }
        return clusters
    }

    private func centroid(for tracks: [PlanningTrack]) -> [Double] {
        guard let first = tracks.first, !first.embedding.isEmpty else { return [] }
        var values = Array(repeating: 0.0, count: first.embedding.count)
        for track in tracks where track.embedding.count == values.count {
            for index in values.indices {
                values[index] += track.embedding[index]
            }
        }
        return normalizedVector(values.map { $0 / Double(max(tracks.count, 1)) })
    }

    private func uniqueTargetPath(
        rootPath: String,
        genreName: String,
        clusterName: String,
        fileName: String,
        trackID: UUID,
        reservedTargetPaths: inout Set<String>,
        flattenClusterFolder: Bool = false
    ) -> String {
        var folderURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent(sanitizedPathComponent(genreName), isDirectory: true)
        if !flattenClusterFolder {
            folderURL = folderURL.appendingPathComponent(sanitizedPathComponent(clusterName), isDirectory: true)
        }
        let safeFileName = sanitizedFileName(fileName)
        let baseURL = folderURL.appendingPathComponent(safeFileName)
        let normalizedBase = TrackPathNormalizer.normalizedAbsolutePath(baseURL)
        if reservedTargetPaths.insert(normalizedBase).inserted {
            return normalizedBase
        }

        let fileURL = URL(fileURLWithPath: safeFileName)
        let ext = fileURL.pathExtension
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let suffix = String(trackID.uuidString.prefix(8)).lowercased()
        let suffixedName = ext.isEmpty ? "\(stem) - \(suffix)" : "\(stem) - \(suffix).\(ext)"
        let suffixedPath = TrackPathNormalizer.normalizedAbsolutePath(folderURL.appendingPathComponent(suffixedName))
        reservedTargetPaths.insert(suffixedPath)
        return suffixedPath
    }

    private func skippedTrack(_ track: Track, reason: String) -> LibraryOrganizationSkippedTrack {
        LibraryOrganizationSkippedTrack(
            id: track.id,
            trackID: track.id,
            title: track.title,
            fileName: track.fileName,
            reason: reason
        )
    }

    static func sanitizedPathComponent(_ value: String, maxLength: Int = 80) -> String {
        let replaced = value.map { character -> Character in
            if character == "/" || character == ":" || character == "\0" {
                return "-"
            }
            return character
        }
        let collapsed = String(replaced)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let safe = collapsed.isEmpty ? "Untitled" : collapsed
        if safe.count <= maxLength {
            return safe
        }
        return String(safe.prefix(maxLength)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    static func sanitizedFileName(_ value: String) -> String {
        let safe = sanitizedPathComponent(value, maxLength: 160)
        return safe.isEmpty ? "Untitled" : safe
    }

    static func cosineSimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return 0 }
        let left = normalizedVector(lhs)
        let right = normalizedVector(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let dot = zip(left, right).reduce(0) { $0 + $1.0 * $1.1 }
        return max(0, min(1, dot))
    }

    static func normalizedVector(_ vector: [Double]) -> [Double] {
        let magnitude = sqrt(vector.reduce(0) { $0 + ($1 * $1) })
        guard magnitude > 0 else { return [] }
        return vector.map { $0 / magnitude }
    }

    private func sanitizedPathComponent(_ value: String) -> String {
        Self.sanitizedPathComponent(value)
    }

    private func sanitizedFileName(_ value: String) -> String {
        Self.sanitizedFileName(value)
    }

    private func cosineSimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double {
        Self.cosineSimilarity(lhs, rhs)
    }

    private func normalizedVector(_ vector: [Double]) -> [Double] {
        Self.normalizedVector(vector)
    }
}
