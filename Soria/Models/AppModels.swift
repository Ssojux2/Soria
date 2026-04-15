import Foundation

enum SidebarSection: String, CaseIterable, Identifiable {
    case library = "Library"
    case mixAssistant = "Mix Assistant"
    case exports = "Exports"
    case settings = "Settings"

    var id: String { rawValue }
}

enum MixAssistantMode: String, CaseIterable, Identifiable {
    case similarTracks = "similar_tracks"
    case buildMixset = "build_mixset"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .similarTracks:
            return "Similar Tracks"
        case .buildMixset:
            return "Build Mixset"
        }
    }

    var helperText: String {
        switch self {
        case .similarTracks:
            return "Use selected library tracks, text, or both together to find matching records."
        case .buildMixset:
            return "Use the current selection as the seed for next-track picks and automatic mix paths."
        }
    }
}

enum ScopeFilterTarget: String, Codable, Hashable, Identifiable {
    case library
    case search
    case recommendation

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .library:
            return "Library"
        case .search:
            return "Search"
        case .recommendation:
            return "Mix Assistant"
        }
    }
}

struct LibraryScopeFilter: Codable, Hashable {
    var seratoMembershipPaths: [String] = []
    var rekordboxMembershipPaths: [String] = []

    var isEmpty: Bool {
        seratoMembershipPaths.isEmpty && rekordboxMembershipPaths.isEmpty
    }

    func selectedPaths(for source: ExternalDJMetadata.Source) -> [String] {
        switch source {
        case .serato:
            return seratoMembershipPaths
        case .rekordbox:
            return rekordboxMembershipPaths
        }
    }

    mutating func setSelectedPaths(_ paths: [String], for source: ExternalDJMetadata.Source) {
        let normalized = Array(Set(paths)).sorted()
        switch source {
        case .serato:
            seratoMembershipPaths = normalized
        case .rekordbox:
            rekordboxMembershipPaths = normalized
        }
    }
}

struct MembershipFacet: Identifiable, Codable, Hashable {
    let source: ExternalDJMetadata.Source
    let membershipPath: String
    let displayName: String
    let parentPath: String?
    let depth: Int
    let trackCount: Int

    var id: String {
        "\(source.rawValue)::\(membershipPath)"
    }
}

struct TrackMembershipSnapshot: Codable, Hashable {
    var seratoMembershipPaths: [String] = []
    var rekordboxMembershipPaths: [String] = []

    var isEmpty: Bool {
        seratoMembershipPaths.isEmpty && rekordboxMembershipPaths.isEmpty
    }

    var allMembershipPaths: [String] {
        Array(Set(seratoMembershipPaths + rekordboxMembershipPaths)).sorted()
    }

    func memberships(for source: ExternalDJMetadata.Source) -> [String] {
        switch source {
        case .serato:
            return seratoMembershipPaths
        case .rekordbox:
            return rekordboxMembershipPaths
        }
    }

    func matchedPaths(scopeFilter: LibraryScopeFilter) -> [String] {
        let seratoMatches = Set(seratoMembershipPaths).intersection(scopeFilter.seratoMembershipPaths)
        let rekordboxMatches = Set(rekordboxMembershipPaths).intersection(scopeFilter.rekordboxMembershipPaths)
        return Array(seratoMatches.union(rekordboxMatches)).sorted()
    }
}

enum ScoreSessionKind: String, Codable, Hashable {
    case search
    case recommendation
    case playlistPath = "playlist_path"
}

struct VectorScoreBreakdown: Codable, Hashable {
    var fusedScore: Double
    var trackScore: Double
    var introScore: Double
    var middleScore: Double
    var outroScore: Double
    var bestMatchedCollection: String

    static let zero = VectorScoreBreakdown(
        fusedScore: 0,
        trackScore: 0,
        introScore: 0,
        middleScore: 0,
        outroScore: 0,
        bestMatchedCollection: "tracks"
    )
}

struct ScoreSessionCandidateSnapshot: Codable, Hashable {
    var vectorBreakdown: VectorScoreBreakdown
    var matchedMemberships: [String]
    var matchReasons: [String]
    var analysisFocus: AnalysisFocus?
    var mixabilityTags: [String]
    var queryMode: String?
}

struct ScoreSession: Identifiable, Codable, Hashable {
    let id: UUID
    let kind: ScoreSessionKind
    let embeddingProfileID: String
    let searchMode: String?
    let queryText: String?
    let seedTrackID: UUID?
    let referenceTrackIDs: [UUID]
    let scopeFilter: LibraryScopeFilter
    let candidateCountBeforeScope: Int
    let candidateCountAfterScope: Int
    let resultLimit: Int
    let createdAt: Date
}

struct ScoreSessionCandidateRecord: Codable, Hashable {
    let trackID: UUID
    let rank: Int
    let finalScore: Double
    let vectorBreakdown: VectorScoreBreakdown
    let embeddingSimilarity: Double?
    let bpmCompatibility: Double?
    let harmonicCompatibility: Double?
    let energyFlow: Double?
    let transitionRegionMatch: Double?
    let externalMetadataScore: Double?
    let matchedMemberships: [String]
    let matchReasons: [String]
    let snapshot: ScoreSessionCandidateSnapshot
}

enum LibraryTrackFilter: String, CaseIterable, Identifiable {
    case all = "all"
    case ready = "ready"
    case needsAnalysis = "needs_analysis"
    case needsRefresh = "needs_refresh"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:
            return "All"
        case .ready:
            return "Ready"
        case .needsAnalysis:
            return "Needs Analysis"
        case .needsRefresh:
            return "Needs Refresh"
        }
    }

    func matches(_ status: TrackWorkflowStatus) -> Bool {
        switch self {
        case .all:
            return true
        case .ready:
            return status == .ready
        case .needsAnalysis:
            return status == .needsAnalysis
        case .needsRefresh:
            return status == .needsRefresh
        }
    }
}

enum TrackWorkflowStatus: String, Codable, Hashable {
    case ready = "ready"
    case needsAnalysis = "needs_analysis"
    case needsRefresh = "needs_refresh"

    var displayName: String {
        switch self {
        case .ready:
            return "Ready"
        case .needsAnalysis:
            return "Needs Analysis"
        case .needsRefresh:
            return "Needs Refresh"
        }
    }

    var helperText: String {
        switch self {
        case .ready:
            return "This track can be used right away in similarity and mixset flows."
        case .needsAnalysis:
            return "This track has not been analyzed yet."
        case .needsRefresh:
            return "This track needs to be prepared again for the current similarity setup."
        }
    }
}

struct SelectionReadiness: Equatable {
    let signature: String
    let selectedCount: Int
    let readyCount: Int
    let needsAnalysisCount: Int
    let needsRefreshCount: Int

    var pendingCount: Int {
        needsAnalysisCount + needsRefreshCount
    }

    var hasSelection: Bool {
        selectedCount > 0
    }

    var hasReadyTracks: Bool {
        readyCount > 0
    }

    var hasPendingTracks: Bool {
        pendingCount > 0
    }

    var isPartiallyReady: Bool {
        hasReadyTracks && hasPendingTracks
    }

    var referenceSummaryText: String {
        guard hasSelection else {
            return "Select tracks from the library to start."
        }
        if selectedCount == 1 {
            return hasReadyTracks
                ? "1 selected track is ready to use."
                : "1 selected track needs preparation before it can drive similarity."
        }
        if hasPendingTracks {
            return "\(selectedCount)-track blend reference: \(readyCount) ready, \(pendingCount) still need preparation."
        }
        return "\(selectedCount)-track blend reference is ready."
    }

    var bannerTitle: String {
        if isPartiallyReady {
            return "Finish Preparing This Selection"
        }
        return "Prepare This Selection"
    }

    var bannerMessage: String {
        if !hasSelection {
            return "Select one or more tracks in the library first."
        }
        if isPartiallyReady {
            return "\(readyCount) selected track(s) are ready now. \(pendingCount) more need analysis or a refresh for the current setup."
        }
        if hasPendingTracks {
            return "\(pendingCount) selected track(s) need analysis or a refresh before they can be used together."
        }
        return "Everything in the current selection is ready."
    }
}

struct ScopedTrackStatistics: Equatable {
    var total: Int = 0
    var ready: Int = 0
    var needsAnalysis: Int = 0
    var needsRefresh: Int = 0
    var seratoCoverage: Int = 0
    var rekordboxCoverage: Int = 0

    var needsPreparation: Int {
        needsAnalysis + needsRefresh
    }
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
            return "Selected Tracks"
        case .unanalyzedTracks:
            return "Needs Prep"
        case .allIndexedTracks:
            return "Re-prepare Library"
        }
    }

    var helperText: String {
        switch self {
        case .selectedTrack:
            return "Analyze the track or tracks you selected in the library."
        case .unanalyzedTracks:
            return "Process tracks that have never been analyzed or need fresh preparation for the current setup."
        case .allIndexedTracks:
            return "Rebuild preparation data for the whole indexed library. This can take time and consume API quota."
        }
    }

    func resolveTracks(
        from tracks: [Track],
        selectedTrackID: UUID?,
        readyTrackIDs: Set<UUID>,
        activeProfileID: String
    ) -> [Track] {
        return resolveTracks(
            from: tracks,
            selectedTrackIDs: selectedTrackID == nil ? [] : [selectedTrackID!],
            readyTrackIDs: readyTrackIDs,
            activeProfileID: activeProfileID
        )
    }

    func resolveTracks(
        from tracks: [Track],
        selectedTrackIDs: Set<UUID>,
        readyTrackIDs: Set<UUID>,
        activeProfileID: String
    ) -> [Track] {
        switch self {
        case .selectedTrack:
            guard !selectedTrackIDs.isEmpty else { return [] }
            return tracks.filter { selectedTrackIDs.contains($0.id) }
        case .unanalyzedTracks:
            return tracks.filter { $0.analyzedAt == nil || !readyTrackIDs.contains($0.id) || $0.embeddingProfileID != activeProfileID }
        case .allIndexedTracks:
            return tracks
        }
    }

    func canRun(
        validationStatus: ValidationStatus,
        isBusy: Bool,
        tracks: [Track],
        selectedTrackID: UUID?,
        readyTrackIDs: Set<UUID>,
        activeProfileID: String
    ) -> Bool {
        guard validationStatus.allowsSemanticActions(isBusy: isBusy) else { return false }
        return !resolveTracks(
            from: tracks,
            selectedTrackID: selectedTrackID,
            readyTrackIDs: readyTrackIDs,
            activeProfileID: activeProfileID
        ).isEmpty
    }

    func canRun(
        validationStatus: ValidationStatus,
        isBusy: Bool,
        tracks: [Track],
        selectedTrackIDs: Set<UUID>,
        readyTrackIDs: Set<UUID>,
        activeProfileID: String
    ) -> Bool {
        guard validationStatus.allowsSemanticActions(isBusy: isBusy) else { return false }
        return !resolveTracks(
            from: tracks,
            selectedTrackIDs: selectedTrackIDs,
            readyTrackIDs: readyTrackIDs,
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

enum RecommendationInputMode: String, Codable, Equatable {
    case text
    case reference
    case hybrid
}

enum RecommendationSeedSource: Equatable {
    case selectedReference
    case semanticMatch
}

struct RecommendationInputState: Equatable {
    static let minimumResultLimit = 10
    static let maximumResultLimit = 100

    let mode: RecommendationInputMode
    let queryText: String
    let readyReferenceCount: Int

    var trimmedQueryText: String {
        queryText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasTextInput: Bool {
        !trimmedQueryText.isEmpty
    }

    var seedSource: RecommendationSeedSource {
        if mode == .reference, readyReferenceCount == 1 {
            return .selectedReference
        }
        return .semanticMatch
    }

    var requiresSemanticSeed: Bool {
        seedSource == .semanticMatch
    }

    static func resolve(queryText: String, readyReferenceCount: Int) -> RecommendationInputState? {
        let trimmedQueryText = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTextInput = !trimmedQueryText.isEmpty
        let hasReadyReference = readyReferenceCount > 0

        let mode: RecommendationInputMode
        switch (hasTextInput, hasReadyReference) {
        case (true, true):
            mode = .hybrid
        case (true, false):
            mode = .text
        case (false, true):
            mode = .reference
        case (false, false):
            return nil
        }

        return RecommendationInputState(
            mode: mode,
            queryText: trimmedQueryText,
            readyReferenceCount: readyReferenceCount
        )
    }

    static func clampedResultLimit(_ value: Int) -> Int {
        min(max(value, minimumResultLimit), maximumResultLimit)
    }
}

enum EmbeddingBackendKind: String, Codable, Hashable {
    case googleAI = "google_ai"
    case clap = "clap"
}

struct EmbeddingProfile: Codable, Hashable, Identifiable {
    static let legacyGoogleTextEmbedding004ID = "google/text-embedding-004"
    static let legacyGeminiEmbeddingPreviewID = "google/gemini-embedding-2-preview"

    let id: String
    let displayName: String
    let modelName: String
    let backendKind: EmbeddingBackendKind
    let requiresAPIKey: Bool

    static let googleGeminiEmbedding001 = EmbeddingProfile(
        id: "google/gemini-embedding-001",
        displayName: "Google AI gemini-embedding-001",
        modelName: "gemini-embedding-001",
        backendKind: .googleAI,
        requiresAPIKey: true
    )

    static let googleGeminiEmbedding2Preview = EmbeddingProfile(
        id: legacyGeminiEmbeddingPreviewID,
        displayName: "Google AI gemini-embedding-2-preview (Experimental)",
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
        .googleGeminiEmbedding001,
        .googleGeminiEmbedding2Preview,
        .clapHTSATUnfused
    ]

    static func resolve(id: String?) -> EmbeddingProfile {
        guard let id else { return .googleGeminiEmbedding001 }
        if id == legacyGoogleTextEmbedding004ID {
            return .googleGeminiEmbedding001
        }
        return all.first(where: { $0.id == id }) ?? .googleGeminiEmbedding001
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
    let analysisFocus: AnalysisFocus?
    let mixabilityTags: [String]
    let matchReasons: [String]
    let scoreSessionID: UUID?
    let matchedMemberships: [String]
    let vectorBreakdown: VectorScoreBreakdown

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
