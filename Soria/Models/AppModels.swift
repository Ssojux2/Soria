import Foundation

enum SidebarSection: String, CaseIterable, Identifiable {
    case library = "Library"
    case search = "Search"
    case recommendations = "Recommendations"
    case exports = "Exports"
    case settings = "Settings"

    var id: String { rawValue }
}

struct ScanJobProgress {
    var scannedFiles: Int = 0
    var totalFiles: Int = 0
    var indexedFiles: Int = 0
    var skippedFiles: Int = 0
    var duplicateFiles: Int = 0
    var isRunning: Bool = false
    var currentFile: String = ""
}

struct ExportJobResult {
    var outputPaths: [String]
    var message: String
}

enum ValidationStatus: Equatable {
    case unvalidated
    case validating
    case validated(Date)
    case failed(String)

    var isValidated: Bool {
        if case .validated = self {
            return true
        }
        return false
    }

    func allowsSemanticActions(isBusy: Bool) -> Bool {
        isValidated && !isBusy
    }

    var summaryText: String {
        switch self {
        case .unvalidated:
            return "Not validated"
        case .validating:
            return "Validating..."
        case .validated(let date):
            return "Validated \(LibraryDatabase.iso8601.string(from: date))"
        case .failed(let message):
            return message.isEmpty ? "Validation failed" : message
        }
    }
}

enum AnalysisScope: String, CaseIterable, Identifiable {
    case selectedTrack = "selected_track"
    case unanalyzedTracks = "unanalyzed_tracks"
    case allIndexedTracks = "all_indexed_tracks"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .selectedTrack:
            return "Selected Track"
        case .unanalyzedTracks:
            return "Unanalyzed / Stale"
        case .allIndexedTracks:
            return "All Indexed Tracks"
        }
    }

    var helperText: String {
        switch self {
        case .selectedTrack:
            return "Analyze currently selected track(s)."
        case .unanalyzedTracks:
            return "Process tracks that have never been analyzed or need fresh embeddings for the active profile."
        case .allIndexedTracks:
            return "Rebuild embeddings for the whole indexed library. This can take time and consume API quota."
        }
    }

    func resolveTracks(from tracks: [Track], selectedTrackID: UUID?, activeProfileID: String) -> [Track] {
        return resolveTracks(
            from: tracks,
            selectedTrackIDs: selectedTrackID == nil ? [] : [selectedTrackID!],
            activeProfileID: activeProfileID
        )
    }

    func resolveTracks(
        from tracks: [Track],
        selectedTrackIDs: Set<UUID>,
        activeProfileID: String
    ) -> [Track] {
        switch self {
        case .selectedTrack:
            guard !selectedTrackIDs.isEmpty else { return [] }
            return tracks.filter { selectedTrackIDs.contains($0.id) }
        case .unanalyzedTracks:
            return tracks.filter { $0.analyzedAt == nil || !$0.hasCurrentEmbedding(profileID: activeProfileID) }
        case .allIndexedTracks:
            return tracks
        }
    }

    func canRun(
        validationStatus: ValidationStatus,
        isBusy: Bool,
        tracks: [Track],
        selectedTrackID: UUID?,
        activeProfileID: String
    ) -> Bool {
        guard validationStatus.allowsSemanticActions(isBusy: isBusy) else { return false }
        return !resolveTracks(
            from: tracks,
            selectedTrackID: selectedTrackID,
            activeProfileID: activeProfileID
        ).isEmpty
    }

    func canRun(
        validationStatus: ValidationStatus,
        isBusy: Bool,
        tracks: [Track],
        selectedTrackIDs: Set<UUID>,
        activeProfileID: String
    ) -> Bool {
        guard validationStatus.allowsSemanticActions(isBusy: isBusy) else { return false }
        return !resolveTracks(
            from: tracks,
            selectedTrackIDs: selectedTrackIDs,
            activeProfileID: activeProfileID
        ).isEmpty
    }
}

enum SearchMode: String, CaseIterable, Identifiable {
    case text = "text"
    case referenceTrack = "reference_track"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .text:
            return "Text"
        case .referenceTrack:
            return "Reference Tracks"
        }
    }

    var queryPlaceholder: String {
        switch self {
        case .text:
            return "Describe the sound or transition you want"
        case .referenceTrack:
            return "Reference track mode uses selected tracks"
        }
    }

    var isQueryEditable: Bool {
        self == .text
    }

    func canSubmit(
        validationStatus: ValidationStatus,
        isBusy: Bool,
        queryText: String,
        hasReferenceTrackEmbedding: Bool
    ) -> Bool {
        guard validationStatus.allowsSemanticActions(isBusy: isBusy) else { return false }

        switch self {
        case .text:
            return !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .referenceTrack:
            return hasReferenceTrackEmbedding
        }
    }
}

enum EmbeddingBackendKind: String, Codable, Hashable {
    case googleAI = "google_ai"
    case clap = "clap"
}

struct EmbeddingProfile: Codable, Hashable, Identifiable {
    let id: String
    let displayName: String
    let modelName: String
    let backendKind: EmbeddingBackendKind
    let requiresAPIKey: Bool

    static let googleTextEmbedding004 = EmbeddingProfile(
        id: "google/text-embedding-004",
        displayName: "Google AI text-embedding-004",
        modelName: "text-embedding-004",
        backendKind: .googleAI,
        requiresAPIKey: true
    )

    static let googleGeminiEmbedding2Preview = EmbeddingProfile(
        id: "google/gemini-embedding-2-preview",
        displayName: "Google AI gemini-embedding-2-preview",
        modelName: "gemini-embedding-2-preview",
        backendKind: .googleAI,
        requiresAPIKey: true
    )

    static let clapHTSATUnfused = EmbeddingProfile(
        id: "local/clap-htsat-unfused",
        displayName: "CLAP HTSAT Unfused",
        modelName: "laion/clap-htsat-unfused",
        backendKind: .clap,
        requiresAPIKey: false
    )

    static let all: [EmbeddingProfile] = [
        .googleTextEmbedding004,
        .googleGeminiEmbedding2Preview,
        .clapHTSATUnfused
    ]

    static func resolve(id: String?) -> EmbeddingProfile {
        guard let id else { return .googleGeminiEmbedding2Preview }
        return all.first(where: { $0.id == id }) ?? .googleGeminiEmbedding2Preview
    }
}

struct TrackSearchResult: Identifiable, Hashable {
    let track: Track
    let score: Double
    let trackScore: Double
    let introScore: Double
    let middleScore: Double
    let outroScore: Double
    let bestMatchedCollection: String

    var id: UUID { track.id }
}

enum LibrarySourceKind: String, CaseIterable, Codable, Hashable {
    case serato
    case rekordbox
    case folderFallback

    var displayName: String {
        switch self {
        case .serato:
            return "Serato"
        case .rekordbox:
            return "rekordbox"
        case .folderFallback:
            return "Manual Folder Fallback"
        }
    }

    var iconName: String {
        switch self {
        case .serato:
            return "waveform.path.badge.plus"
        case .rekordbox:
            return "square.stack.3d.up"
        case .folderFallback:
            return "folder"
        }
    }
}

enum LibrarySourceStatus: String, Codable, Hashable {
    case disabled
    case missing
    case available
    case syncing
    case error

    var displayText: String {
        switch self {
        case .disabled:
            return "Disabled"
        case .missing:
            return "Missing"
        case .available:
            return "Ready"
        case .syncing:
            return "Syncing"
        case .error:
            return "Error"
        }
    }
}

struct LibrarySourceRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let kind: LibrarySourceKind
    var enabled: Bool
    var resolvedPath: String?
    var lastSyncAt: Date?
    var status: LibrarySourceStatus
    var lastError: String?

    static func `default`(for kind: LibrarySourceKind) -> LibrarySourceRecord {
        LibrarySourceRecord(
            id: UUID(),
            kind: kind,
            enabled: false,
            resolvedPath: nil,
            lastSyncAt: nil,
            status: .disabled,
            lastError: nil
        )
    }
}
