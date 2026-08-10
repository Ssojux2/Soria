import Foundation

/// A folder Soria itself created, as opposed to a crate or playlist imported from
/// Serato or rekordbox.
///
/// Vendor memberships live in `membership_catalog` / `track_memberships`, which are
/// caches rebuilt from vendor metadata on every launch. Collections are authored
/// data with no vendor source to re-derive from, so they get their own tables.
///
/// Hierarchy is expressed with `parentID` rather than a path string, so renaming a
/// parent is a single row update. Export names are derived by walking to the root
/// and joining with `/`, which is exactly what `VendorPlaylistNaming` expects.
struct SoriaCollection: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        /// A folder that exists on disk because the organizer moved files into it.
        case organizedFolder = "organized_folder"
        /// A grouping from a natural-language prompt; may have no folder on disk.
        case promptFolder = "prompt_folder"
        /// A container node used only to nest other collections.
        case group = "group"
    }

    enum Origin: String, Codable, CaseIterable {
        case organizer
        case user
    }

    let id: UUID
    var parentID: UUID?
    var name: String
    var kind: Kind
    var origin: Origin
    /// Absolute path of the on-disk folder, when the collection has one.
    var folderPath: String?
    var genreFamilyID: String?
    var clusterID: String?
    var promptText: String?
    var sortIndex: Int
    var createdAt: Date
    var updatedAt: Date
    /// Last time this collection was written out as a crate or playlist. Compared
    /// against organization move timestamps to warn about stale vendor references.
    var lastExportedAt: Date?

    init(
        id: UUID = UUID(),
        parentID: UUID? = nil,
        name: String,
        kind: Kind = .organizedFolder,
        origin: Origin = .organizer,
        folderPath: String? = nil,
        genreFamilyID: String? = nil,
        clusterID: String? = nil,
        promptText: String? = nil,
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastExportedAt: Date? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.kind = kind
        self.origin = origin
        self.folderPath = folderPath
        self.genreFamilyID = genreFamilyID
        self.clusterID = clusterID
        self.promptText = promptText
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastExportedAt = lastExportedAt
    }
}

extension SoriaCollection {
    /// The `/`-separated path from the root of the collection tree down to
    /// `collectionID`, which is the playlist name both vendor writers consume.
    ///
    /// Pure so it can be tested without a database. Cycles (which the schema
    /// permits but the app never creates) terminate instead of hanging.
    static func hierarchicalName(
        for collectionID: UUID,
        in collections: [UUID: SoriaCollection]
    ) -> String {
        var components: [String] = []
        var visited: Set<UUID> = []
        var cursor: UUID? = collectionID

        while let currentID = cursor, visited.insert(currentID).inserted {
            guard let collection = collections[currentID] else { break }
            components.append(collection.name)
            cursor = collection.parentID
        }

        return components.reversed().joined(separator: "/")
    }
}

/// A track moved out of the active library into the Soria quarantine folder.
///
/// The row is the source of truth for quarantine state — never infer it from
/// `tracks.last_seen_in_local_scan_at`, which the scanner nulls out once the
/// quarantine folder is excluded from traversal.
struct TrackQuarantineRecord: Identifiable, Codable, Hashable {
    enum Reason: String, Codable, CaseIterable {
        case userDiscard = "user_discard"
        case duplicate
        case unreadable
    }

    var id: UUID { trackID }

    let trackID: UUID
    var originalPath: String
    var quarantinePath: String
    /// The value of `tracks.last_seen_in_local_scan_at` before quarantining, so
    /// restore can put the track back without forcing a full rescan.
    var originalLastSeenInLocalScanAt: Date?
    var reason: Reason
    var batchID: UUID?
    var quarantinedAt: Date

    init(
        trackID: UUID,
        originalPath: String,
        quarantinePath: String,
        originalLastSeenInLocalScanAt: Date? = nil,
        reason: Reason = .userDiscard,
        batchID: UUID? = nil,
        quarantinedAt: Date = Date()
    ) {
        self.trackID = trackID
        self.originalPath = originalPath
        self.quarantinePath = quarantinePath
        self.originalLastSeenInLocalScanAt = originalLastSeenInLocalScanAt
        self.reason = reason
        self.batchID = batchID
        self.quarantinedAt = quarantinedAt
    }
}

/// One run of the organizer, recorded so a partially applied batch can be
/// understood — and eventually undone — after the fact.
struct OrganizationBatchRecord: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case genreClusters = "genre_clusters"
        case promptFolders = "prompt_folders"
        case quarantine
    }

    let id: UUID
    var kind: Kind
    var destinationRoot: String?
    var embeddingProfileID: String
    var configJSON: String
    var summaryJSON: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: Kind,
        destinationRoot: String? = nil,
        embeddingProfileID: String,
        configJSON: String = "{}",
        summaryJSON: String = "{}",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.destinationRoot = destinationRoot
        self.embeddingProfileID = embeddingProfileID
        self.configJSON = configJSON
        self.summaryJSON = summaryJSON
        self.createdAt = createdAt
    }
}

/// A single file move inside an `OrganizationBatchRecord`.
struct OrganizationMoveRecord: Identifiable, Codable, Hashable {
    enum State: String, Codable, CaseIterable {
        case applied
        case rolledBack = "rolled_back"
        case failed
    }

    let id: UUID
    var batchID: UUID
    var trackID: UUID
    var sourcePath: String
    var targetPath: String
    var collectionID: UUID?
    var state: State
    var appliedAt: Date

    init(
        id: UUID = UUID(),
        batchID: UUID,
        trackID: UUID,
        sourcePath: String,
        targetPath: String,
        collectionID: UUID? = nil,
        state: State = .applied,
        appliedAt: Date = Date()
    ) {
        self.id = id
        self.batchID = batchID
        self.trackID = trackID
        self.sourcePath = sourcePath
        self.targetPath = targetPath
        self.collectionID = collectionID
        self.state = state
        self.appliedAt = appliedAt
    }
}
