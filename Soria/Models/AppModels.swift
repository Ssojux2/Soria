import Combine
import Foundation

enum SidebarSection: String, CaseIterable, Identifiable {
    case library = "Library"
    case mixAssistant = "Mix Assistant"
    case exports = "Exports"
    case settings = "Settings"

    var id: String { rawValue }
}

enum MixAssistantMode: String, CaseIterable, Identifiable {
    case buildMixset = "build_mixset"

    var id: String { rawValue }

    var displayName: String { "Build Mixset" }

    var helperText: String {
        "Use selected library tracks, text, or both together as the seed for next-track picks and automatic mix paths."
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

    var selectedFacetCount: Int {
        seratoMembershipPaths.count + rekordboxMembershipPaths.count
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
    var normalizedFinalWeights: RecommendationWeights
    var normalizedVectorWeights: MixsetVectorWeights
    var effectiveConstraints: RecommendationConstraints

    init(
        vectorBreakdown: VectorScoreBreakdown,
        matchedMemberships: [String],
        matchReasons: [String],
        analysisFocus: AnalysisFocus?,
        mixabilityTags: [String],
        queryMode: String?,
        normalizedFinalWeights: RecommendationWeights = .defaults.normalized(),
        normalizedVectorWeights: MixsetVectorWeights = .defaults.normalized(),
        effectiveConstraints: RecommendationConstraints = .defaults.normalizedForScoring()
    ) {
        self.vectorBreakdown = vectorBreakdown
        self.matchedMemberships = matchedMemberships
        self.matchReasons = matchReasons
        self.analysisFocus = analysisFocus
        self.mixabilityTags = mixabilityTags
        self.queryMode = queryMode
        self.normalizedFinalWeights = normalizedFinalWeights
        self.normalizedVectorWeights = normalizedVectorWeights
        self.effectiveConstraints = effectiveConstraints
    }

    init(from decoder: Decoder) throws {
        enum CodingKeys: String, CodingKey {
            case vectorBreakdown
            case matchedMemberships
            case matchReasons
            case analysisFocus
            case mixabilityTags
            case queryMode
            case normalizedFinalWeights
            case normalizedVectorWeights
            case effectiveConstraints
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        vectorBreakdown = try container.decode(VectorScoreBreakdown.self, forKey: .vectorBreakdown)
        matchedMemberships = try container.decodeIfPresent([String].self, forKey: .matchedMemberships) ?? []
        matchReasons = try container.decodeIfPresent([String].self, forKey: .matchReasons) ?? []
        analysisFocus = try container.decodeIfPresent(AnalysisFocus.self, forKey: .analysisFocus)
        mixabilityTags = try container.decodeIfPresent([String].self, forKey: .mixabilityTags) ?? []
        queryMode = try container.decodeIfPresent(String.self, forKey: .queryMode)
        normalizedFinalWeights =
            try container.decodeIfPresent(RecommendationWeights.self, forKey: .normalizedFinalWeights)
            ?? .defaults.normalized()
        normalizedVectorWeights =
            try container.decodeIfPresent(MixsetVectorWeights.self, forKey: .normalizedVectorWeights)
            ?? .defaults.normalized()
        effectiveConstraints =
            try container.decodeIfPresent(RecommendationConstraints.self, forKey: .effectiveConstraints)
            ?? .defaults.normalizedForScoring()
    }
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
    case needsPreparation = "needs_preparation"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:
            return "All"
        case .ready:
            return "Ready"
        case .needsPreparation:
            return "Needs Prep"
        }
    }

    func matches(_ status: TrackWorkflowStatus) -> Bool {
        switch self {
        case .all:
            return true
        case .ready:
            return status == .ready
        case .needsPreparation:
            return status == .needsAnalysis || status == .needsRefresh
        }
    }
}

enum LibraryTrackSortColumn: String, Equatable {
    case title
    case artist
    case genre
    case comment
    case bpm
    case status
}

struct LibraryTrackSortState: Equatable {
    let column: LibraryTrackSortColumn
    let direction: SortOrder
}

struct LibraryPreviewState: Equatable {
    var trackID: UUID?
    var isAvailable: Bool
    var isPrepared: Bool
    var isWarm: Bool
    var isPlaying: Bool
    var currentTimeSec: Double
    var totalDurationSec: Double
    var defaultStartSec: Double
    var progress: Double
    var message: String

    static let hidden = LibraryPreviewState(
        trackID: nil,
        isAvailable: false,
        isPrepared: false,
        isWarm: false,
        isPlaying: false,
        currentTimeSec: 0,
        totalDurationSec: 0,
        defaultStartSec: 0,
        progress: 0,
        message: ""
    )
}

@MainActor
final class LibraryPreviewUIState: ObservableObject {
    enum Delivery {
        case immediate
        case throttledPlayback
    }

    @Published private(set) var renderedState = LibraryPreviewState.hidden
    private(set) var snapshot = LibraryPreviewState.hidden

    private let minimumPlaybackRenderIntervalSec: TimeInterval
    private let immediatePlaybackProgressDelta: Double
    private var lastPlaybackRenderTimestamp: TimeInterval?

    init(
        minimumPlaybackRenderIntervalSec: TimeInterval = 1.0 / 12.0,
        immediatePlaybackProgressDelta: Double = 0.045
    ) {
        self.minimumPlaybackRenderIntervalSec = max(minimumPlaybackRenderIntervalSec, 0)
        self.immediatePlaybackProgressDelta = max(immediatePlaybackProgressDelta, 0)
    }

    func apply(_ newState: LibraryPreviewState, delivery: Delivery = .immediate) {
        let previousSnapshot = snapshot
        snapshot = newState

        guard shouldRender(newState, previousSnapshot: previousSnapshot, delivery: delivery) else {
            return
        }

        if renderedState != newState {
            renderedState = newState
        }
        if delivery == .throttledPlayback {
            lastPlaybackRenderTimestamp = ProcessInfo.processInfo.systemUptime
        } else {
            lastPlaybackRenderTimestamp = nil
        }
    }

    private func shouldRender(
        _ newState: LibraryPreviewState,
        previousSnapshot: LibraryPreviewState,
        delivery: Delivery
    ) -> Bool {
        switch delivery {
        case .immediate:
            return true
        case .throttledPlayback:
            if renderedState.trackID != newState.trackID ||
                renderedState.isAvailable != newState.isAvailable ||
                renderedState.isPrepared != newState.isPrepared ||
                renderedState.isWarm != newState.isWarm ||
                renderedState.isPlaying != newState.isPlaying ||
                renderedState.totalDurationSec != newState.totalDurationSec ||
                renderedState.defaultStartSec != newState.defaultStartSec ||
                renderedState.message != newState.message
            {
                return true
            }
            if !newState.isPlaying {
                return true
            }

            let progressDelta = abs(newState.progress - renderedState.progress)
            if progressDelta >= immediatePlaybackProgressDelta {
                return true
            }

            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - (lastPlaybackRenderTimestamp ?? 0)
            if lastPlaybackRenderTimestamp == nil || elapsed >= minimumPlaybackRenderIntervalSec {
                return true
            }

            // Keep local seek commits responsive even if playback ticks are throttled.
            return abs(newState.currentTimeSec - previousSnapshot.currentTimeSec) > 0.35
        }
    }
}

struct LibraryTrackSortComparator: SortComparator {
    let column: LibraryTrackSortColumn
    var order: SortOrder = .forward
    var statusValues: [UUID: String] = [:]

    func compare(_ lhs: Track, _ rhs: Track) -> ComparisonResult {
        switch column {
        case .title:
            return reordered(lhs.title.localizedStandardCompare(rhs.title))
        case .artist:
            return reordered(lhs.artist.localizedStandardCompare(rhs.artist))
        case .genre:
            return reordered(lhs.genre.localizedStandardCompare(rhs.genre))
        case .comment:
            return reordered(lhs.comment.localizedStandardCompare(rhs.comment))
        case .bpm:
            return compareBPM(lhs.bpm, rhs.bpm)
        case .status:
            let lhsStatus = statusValues[lhs.id] ?? ""
            let rhsStatus = statusValues[rhs.id] ?? ""
            return reordered(lhsStatus.localizedStandardCompare(rhsStatus))
        }
    }

    private func reordered(_ comparison: ComparisonResult) -> ComparisonResult {
        guard order == .reverse else { return comparison }

        switch comparison {
        case .orderedAscending:
            return .orderedDescending
        case .orderedDescending:
            return .orderedAscending
        case .orderedSame:
            return .orderedSame
        }
    }

    private func compareBPM(_ lhs: Double?, _ rhs: Double?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (left?, right?):
            if left == right {
                return .orderedSame
            }
            if order == .forward {
                return left < right ? .orderedAscending : .orderedDescending
            }
            return left > right ? .orderedAscending : .orderedDescending
        case (nil, nil):
            return .orderedSame
        case (nil, _?):
            return .orderedDescending
        case (_?, nil):
            return .orderedAscending
        }
    }
}

enum PreparationOverviewPhase: String, Equatable {
    case idle
    case syncing
    case analyzing
    case completed
    case failed

    var badgeTitle: String {
        switch self {
        case .idle:
            return "Needs Prep"
        case .syncing:
            return "Syncing"
        case .analyzing:
            return "Preparing"
        case .completed:
            return "Ready"
        case .failed:
            return "Attention"
        }
    }
}

enum PreparationOverviewAction: String, Equatable {
    case prepareSelection
    case prepareVisible
    case syncLibrary
}

enum PreparationNoticeKind: String, Equatable {
    case canceled
    case failed
    case success
}

struct PreparationNotice: Equatable {
    let kind: PreparationNoticeKind
    let message: String
}

struct PreparationOverviewState: Equatable {
    let phase: PreparationOverviewPhase
    let title: String
    let message: String
    let progress: Double?
    let primaryAction: PreparationOverviewAction?
    let primaryActionTitleOverride: String?
    let isPrimaryActionDisabled: Bool
    let secondaryAction: PreparationOverviewAction?
    let isCancellable: Bool
    let showSuccess: Bool
}

struct PreparationOverviewContext: Equatable {
    var selectionReadiness = SelectionReadiness(
        signature: "",
        selectedCount: 0,
        readyCount: 0,
        needsAnalysisCount: 0,
        needsRefreshCount: 0
    )
    var filteredTrackCount: Int = 0
    var filteredNeedsPreparationCount: Int = 0
    var totalTrackCount: Int = 0
    var hasSourceSetupIssue: Bool = false
    var hasSyncableSource: Bool = false
    var canPrepareSelection: Bool = false
    var canPrepareVisible: Bool = false
    var preparationBlockedMessage: String?
    var isAnalyzing: Bool = false
    var isCancellingAnalysis: Bool = false
    var analysisSessionProgress: AnalysisSessionProgress?
    var analysisActivity: AnalysisActivity?
    var preparationNotice: PreparationNotice?
    var analysisErrorMessage: String = ""
    var scanProgress = ScanJobProgress()
    var syncingSourceNames: [String] = []
    var libraryStatusMessage: String = ""
}

enum LibrarySyncPresentationPhase: String, Equatable {
    case running
    case failed
}

struct LibrarySyncPresentationState: Equatable {
    var isPresented: Bool = true
    var phase: LibrarySyncPresentationPhase = .running
    var title: String = "Refreshing Library"
    var message: String = "Preparing library update."
    var progress: Double?
    var isIndeterminate: Bool = true
    var sourceNames: [String] = []
    var startedAt = Date()
    var result: String?
    var currentFile: String = ""
    var stats = ScanJobProgress()
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

struct ScanJobProgress: Equatable {
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
    var destinationDescription: String
    var warnings: [String]
}

struct DetectedVendorTargets: Equatable {
    var rekordboxLibraryDirectory: String?
    var rekordboxSettingsPath: String?
    var seratoDatabasePath: String?
    var seratoCratesRoot: String?

    var hasRekordboxInstallation: Bool {
        rekordboxLibraryDirectory != nil || rekordboxSettingsPath != nil
    }

    var hasSeratoCratesRoot: Bool {
        seratoCratesRoot != nil
    }
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
    static let supportedResultLimits = [30, 60, 90, 120]
    static let defaultResultLimit = supportedResultLimits[0]

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
        supportedResultLimits.min { lhs, rhs in
            let leftDistance = abs(lhs - value)
            let rightDistance = abs(rhs - value)
            if leftDistance == rightDistance {
                return lhs < rhs
            }
            return leftDistance < rightDistance
        } ?? defaultResultLimit
    }
}

enum EmbeddingBackendKind: String, Codable, Hashable {
    case googleAI = "google_ai"
    case clap = "clap"
}

struct EmbeddingPipeline: Codable, Hashable, Identifiable {
    let id: String
    let displayName: String

    static let audioSegmentsV1 = EmbeddingPipeline(
        id: "audio_segments_v1",
        displayName: "Audio Segments v1"
    )

    static func resolve(id: String?) -> EmbeddingPipeline {
        switch id {
        case audioSegmentsV1.id:
            return .audioSegmentsV1
        default:
            return .audioSegmentsV1
        }
    }
}

struct EmbeddingProfile: Codable, Hashable, Identifiable {
    static let legacyGoogleTextEmbedding004ID = "google/text-embedding-004"
    static let legacyGeminiEmbedding001ID = "google/gemini-embedding-001"
    static let googleGeminiEmbedding2PreviewID = "google/gemini-embedding-2-preview"

    let id: String
    let displayName: String
    let modelName: String
    let backendKind: EmbeddingBackendKind
    let requiresAPIKey: Bool

    static let googleGeminiEmbedding2Preview = EmbeddingProfile(
        id: googleGeminiEmbedding2PreviewID,
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
        .googleGeminiEmbedding2Preview,
        .clapHTSATUnfused
    ]

    var pipelineID: String {
        EmbeddingPipeline.audioSegmentsV1.id
    }

    static func resolve(id: String?) -> EmbeddingProfile {
        guard let id else { return .googleGeminiEmbedding2Preview }
        if id == legacyGoogleTextEmbedding004ID || id == legacyGeminiEmbedding001ID {
            return .googleGeminiEmbedding2Preview
        }
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
            return "Music Folders"
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
