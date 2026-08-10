import Foundation

enum LibraryOrganizationScope: String, CaseIterable, Identifiable {
    case visibleReadyTracks = "visible_ready_tracks"
    case selectedReadyTracks = "selected_ready_tracks"
    case allReadyTracks = "all_ready_tracks"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .visibleReadyTracks:
            return "Visible Ready Tracks"
        case .selectedReadyTracks:
            return "Selected Ready Tracks"
        case .allReadyTracks:
            return "All Ready Tracks"
        }
    }
}

struct LibraryOrganizationMove: Identifiable, Hashable {
    let id: UUID
    let trackID: UUID
    let title: String
    let artist: String
    let fileName: String
    let sourcePath: String
    let targetPath: String
    let genreID: String
    let genreName: String
    let genreScore: Double
    let clusterID: String
    let clusterName: String

    var targetFolderPath: String {
        URL(fileURLWithPath: targetPath).deletingLastPathComponent().path
    }
}

struct LibraryOrganizationSkippedTrack: Identifiable, Hashable {
    let id: UUID
    let trackID: UUID
    let title: String
    let fileName: String
    let reason: String
}

struct LibraryOrganizationGroup: Identifiable, Hashable {
    let id: String
    let genreID: String
    let genreName: String
    let clusterID: String
    let clusterName: String
    let moves: [LibraryOrganizationMove]
    /// Identity this group takes when it becomes a `SoriaCollection` on apply.
    /// Minted at planning time so preview rows and persisted collections agree.
    let collectionID: UUID

    init(
        id: String,
        genreID: String,
        genreName: String,
        clusterID: String,
        clusterName: String,
        moves: [LibraryOrganizationMove],
        collectionID: UUID = UUID()
    ) {
        self.id = id
        self.genreID = genreID
        self.genreName = genreName
        self.clusterID = clusterID
        self.clusterName = clusterName
        self.moves = moves
        self.collectionID = collectionID
    }

    var displayName: String {
        "\(genreName) / \(clusterName)"
    }
}

/// How the planner decides which folder a track belongs in.
enum LibraryOrganizationKind: Hashable {
    /// Detect a genre family per track from its embedding, then cluster by
    /// similarity inside each family. Works with any embedding profile.
    case genreClusters
    /// One folder per natural-language prompt, assigned by text-to-audio
    /// similarity. Only meaningful with a shared text/audio embedding space,
    /// so the UI restricts this to CLAP.
    case promptFolders(prompts: [String])

    var batchKind: OrganizationBatchRecord.Kind {
        switch self {
        case .genreClusters: return .genreClusters
        case .promptFolders: return .promptFolders
        }
    }
}

struct LibraryOrganizationPlan: Identifiable, Hashable {
    let id: UUID
    let destinationRootPath: String
    let groups: [LibraryOrganizationGroup]
    let skippedTracks: [LibraryOrganizationSkippedTrack]
    let warnings: [String]
    let createdAt: Date
    let shouldAddDestinationRootToLibrary: Bool

    init(
        id: UUID,
        destinationRootPath: String,
        groups: [LibraryOrganizationGroup],
        skippedTracks: [LibraryOrganizationSkippedTrack],
        warnings: [String],
        createdAt: Date,
        shouldAddDestinationRootToLibrary: Bool
    ) {
        self.id = id
        self.destinationRootPath = destinationRootPath
        self.groups = groups
        self.skippedTracks = skippedTracks
        self.warnings = warnings
        self.createdAt = createdAt
        self.shouldAddDestinationRootToLibrary = shouldAddDestinationRootToLibrary
    }

    var moves: [LibraryOrganizationMove] {
        groups.flatMap(\.moves)
    }

    var moveCount: Int {
        moves.count
    }

    func includedMoves(excluding excludedMoveIDs: Set<UUID>) -> [LibraryOrganizationMove] {
        moves.filter { !excludedMoveIDs.contains($0.id) }
    }
}

enum LibraryOrganizationStage: String, Hashable {
    case idle
    case planning
    case moving
    case completed
    case failed

    var displayName: String {
        switch self {
        case .idle:
            return "Idle"
        case .planning:
            return "Planning"
        case .moving:
            return "Moving"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        }
    }
}

struct LibraryOrganizationProgress: Hashable {
    var stage: LibraryOrganizationStage = .idle
    var completedCount: Int = 0
    var totalCount: Int = 0
    var currentFileName: String = ""
    var message: String = ""

    var fraction: Double? {
        guard totalCount > 0 else { return nil }
        return min(max(Double(completedCount) / Double(totalCount), 0), 1)
    }
}

struct LibraryOrganizationResult: Hashable {
    let movedCount: Int
    let failedCount: Int
    let warnings: [String]
}

struct LibraryOrganizationClusterConfig: Hashable {
    var assignThreshold: Double = 0.82
    var mergeThreshold: Double = 0.90
    var smallClusterFoldThreshold: Double = 0.76
    var maxClusterSize: Int = 35
    /// Below this similarity a prompt folder does not claim the track; it lands
    /// in "Unmatched" instead of being forced into the least-bad prompt.
    var minimumPromptScore: Double = 0.20
    /// When more than this share of tracks land in one genre, the plan carries a
    /// low-confidence warning. Cross-modal text/audio similarity is only
    /// well-defined in a shared embedding space, so a lopsided result usually
    /// means the current profile is not one.
    var degenerateGenreShare: Double = 0.85

    static let defaults = LibraryOrganizationClusterConfig()
}

/// Folder name used when no prompt claims a track.
enum LibraryOrganizationBuckets {
    static let unmatchedName = "Unmatched"
    static let unmatchedID = "unmatched"
}
