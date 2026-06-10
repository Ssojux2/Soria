import Foundation

enum FolderOrganizationScope: String, Codable, CaseIterable, Identifiable {
    case selectedTracks
    case visibleTracks

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .selectedTracks:
            return "Selected"
        case .visibleTracks:
            return "Visible"
        }
    }
}

enum FolderOrganizationPreset: String, Codable, CaseIterable, Identifiable {
    case genre
    case artist
    case bpmRange
    case musicalKey
    case energyMood
    case vendorMembership

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .genre:
            return "Genre"
        case .artist:
            return "Artist"
        case .bpmRange:
            return "BPM"
        case .musicalKey:
            return "Key"
        case .energyMood:
            return "Energy / Mood"
        case .vendorMembership:
            return "Vendor Playlist"
        }
    }
}

struct FolderOrganizationIntent: Codable, Hashable {
    var scope: FolderOrganizationScope
    var preset: FolderOrganizationPreset
    var prompt: String
    var destinationRoot: String?
    var groupingRules: [String]

    init(
        scope: FolderOrganizationScope = .selectedTracks,
        preset: FolderOrganizationPreset = .energyMood,
        prompt: String = "",
        destinationRoot: String? = nil,
        groupingRules: [String] = []
    ) {
        self.scope = scope
        self.preset = preset
        self.prompt = prompt
        self.destinationRoot = destinationRoot
        self.groupingRules = groupingRules
    }
}

struct FolderOrganizationPlan: Codable, Hashable {
    let id: UUID
    let intent: FolderOrganizationIntent
    let moves: [ProposedTrackMove]
    let warnings: [String]
    let conflictCount: Int
    let affectedRoots: [String]
    let createdAt: Date

    var movableCount: Int {
        moves.filter(\.canMove).count
    }

    var skippedCount: Int {
        moves.filter { !$0.canMove }.count
    }
}

struct ProposedTrackMove: Codable, Hashable, Identifiable {
    enum State: String, Codable, Hashable {
        case ready
        case conflictAdjusted
        case noOp
        case missingSource
        case outsideLibraryRoot

        var displayName: String {
            switch self {
            case .ready:
                return "Ready"
            case .conflictAdjusted:
                return "Renamed"
            case .noOp:
                return "Already Organized"
            case .missingSource:
                return "Missing"
            case .outsideLibraryRoot:
                return "Outside Root"
            }
        }
    }

    let id: UUID
    let trackID: UUID
    let title: String
    let artist: String
    let sourcePath: String
    let destinationPath: String
    let bucket: String
    let state: State
    let warnings: [String]

    var canMove: Bool {
        state == .ready || state == .conflictAdjusted
    }
}

struct FolderOrganizationMovedTrack: Codable, Hashable, Identifiable {
    let id: UUID
    let trackID: UUID
    let title: String
    let oldPath: String
    let newPath: String
    let warnings: [String]
}

struct FolderOrganizationSkippedTrack: Codable, Hashable, Identifiable {
    let id: UUID
    let trackID: UUID
    let title: String
    let path: String
    let reason: String
}

struct FolderOrganizationFailedTrack: Codable, Hashable, Identifiable {
    let id: UUID
    let trackID: UUID
    let title: String
    let sourcePath: String
    let destinationPath: String
    let message: String
}

struct FolderOrganizationResult: Codable, Hashable {
    let moved: [FolderOrganizationMovedTrack]
    let skipped: [FolderOrganizationSkippedTrack]
    let failed: [FolderOrganizationFailedTrack]
    let completedAt: Date

    var movedCount: Int { moved.count }
    var skippedCount: Int { skipped.count }
    var failedCount: Int { failed.count }

    var summaryText: String {
        "Moved \(movedCount), skipped \(skippedCount), failed \(failedCount)."
    }
}

struct FolderOrganizationProgress: Codable, Hashable {
    var completed: Int = 0
    var total: Int = 0
    var currentFileName: String?
    var message: String = "Preparing organization."

    var fractionCompleted: Double? {
        guard total > 0 else { return nil }
        return Double(completed) / Double(total)
    }
}
