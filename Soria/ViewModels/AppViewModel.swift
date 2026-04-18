import AppKit
import Combine
import CryptoKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppViewModel: ObservableObject {
    private static let uiTestMixAssistantArgument = "UITEST_START_IN_MIX_ASSISTANT"
    private static let uiTestLibraryStatePrefix = "UITEST_LIBRARY_STATE="
    private static let uiTestForceInitialSetupArgument = "UITEST_FORCE_INITIAL_SETUP"

    private enum UITestLibraryState: String {
        case empty
        case prepared
        case readySelection = "ready_selection"
        case analyzing
        case generated
        case generating
        case buildingPlaylist = "building_playlist"
    }

    enum AnalysisSessionResult: Equatable {
        case succeeded
        case canceled
        case failed(String?)
    }

    enum LibraryRecommendationSearchEntryAction: Equatable {
        case navigateOnly
        case reuseExistingResults
        case autoGenerate
    }

    enum RecommendationGenerationTrigger {
        case manual
        case librarySelection

        var inProgressMessage: String {
            switch self {
            case .manual:
                return "Generating matches..."
            case .librarySelection:
                return "Generating matches from current library selection..."
            }
        }
    }

    private struct RecommendationGenerationStub {
        let results: [RecommendationCandidate]
        let delayNanoseconds: UInt64
        let completionStatusMessage: String?
    }

    @Published var selectedSection: SidebarSection = .library {
        didSet {
            if !allowsScopeInspector(for: activeScopeInspectorTarget, in: selectedSection) {
                closeScopeInspector()
            }
        }
    }
    @Published var tracks: [Track] = []
    @Published var selectedTrackIDs: Set<UUID> = []
    @Published var mixAssistantMode: MixAssistantMode = .buildMixset
    @Published var libraryTrackFilter: LibraryTrackFilter = .all {
        didSet {
            guard libraryTrackFilter != oldValue else { return }
            reconcileLibrarySelectionToVisibleTracks()
        }
    }
    @Published var libraryScopeFilter = LibraryScopeFilter() {
        didSet {
            guard libraryScopeFilter != oldValue else { return }
            reconcileLibrarySelectionToVisibleTracks()
        }
    }
    @Published var recommendationScopeFilter = LibraryScopeFilter() {
        didSet {
            guard recommendationScopeFilter != oldValue else { return }
            invalidateGeneratedRecommendationResults(
                message: "Mix scope changed. Generate again to rebuild the curated list."
            )
        }
    }
    @Published var selectedTrackSegments: [TrackSegment] = []
    @Published var selectedTrackAnalysis: TrackAnalysisSummary?
    @Published var selectedTrackExternalMetadata: [ExternalDJMetadata] = []
    @Published var selectedTrackWaveformPreview: [Double] = []
    @Published var selectedRecommendationID: UUID?
    @Published var scanProgress = ScanJobProgress()
    @Published var libraryRoots: [String] = LibraryRootsStore.loadRoots().map(TrackPathNormalizer.normalizedAbsolutePath)
    @Published var librarySources: [LibrarySourceRecord] = []
    @Published private(set) var seratoMembershipFacets: [MembershipFacet] = []
    @Published private(set) var rekordboxMembershipFacets: [MembershipFacet] = []
    @Published var isAnalyzing = false
    @Published var recommendations: [RecommendationCandidate] = []
    @Published private(set) var generatedRecommendations: [RecommendationCandidate] = []
    @Published private(set) var excludedGeneratedTrackIDs: Set<UUID> = []
    @Published var curationSelectionTrackIDs: Set<UUID> = []
    @Published private(set) var playlistBuildProgress: PlaylistBuildProgress?
    @Published private(set) var isBuildingPlaylist = false
    @Published private(set) var isGeneratingRecommendations = false
    @Published var recommendationStatusMessage: String = ""
    @Published var recommendationQueryText: String = "" {
        didSet {
            guard recommendationQueryText != oldValue else { return }
            if isSuppressingRecommendationResultInvalidation {
                return
            }
            invalidateGeneratedRecommendationResults(
                message: "Recommendation text changed. Generate again to rebuild the curated list."
            )
        }
    }
    @Published var librarySearchText: String = "" {
        didSet {
            guard librarySearchText != oldValue else { return }
            reconcileLibrarySelectionToVisibleTracks()
        }
    }
    @Published var recommendationResultLimit: Int = RecommendationInputState.defaultResultLimit {
        didSet {
            let clamped = RecommendationInputState.clampedResultLimit(recommendationResultLimit)
            if recommendationResultLimit != clamped {
                recommendationResultLimit = clamped
                return
            }
            guard recommendationResultLimit != oldValue else { return }
            invalidateGeneratedRecommendationResults(
                message: "Result count changed. Generate again to rebuild the curated list."
            )
        }
    }
    @Published var libraryStatusMessage: String = ""
    @Published var exportMessage: String = ""
    @Published var exportWarnings: [String] = []
    @Published var exportDestinationDescription: String = ""
    @Published var weights = RecommendationWeights() {
        didSet {
            guard weights != oldValue else { return }
            persistRecommendationScoringSettings()
            invalidateGeneratedRecommendationResults(
                message: "Scoring weights changed. Generate again to rebuild the curated list."
            )
        }
    }
    @Published var vectorWeights = MixsetVectorWeights() {
        didSet {
            guard vectorWeights != oldValue else { return }
            persistRecommendationScoringSettings()
            invalidateGeneratedRecommendationResults(
                message: "Embedding weights changed. Generate again to rebuild the curated list."
            )
        }
    }
    @Published var constraints = RecommendationConstraints() {
        didSet {
            guard constraints != oldValue else { return }
            persistRecommendationScoringSettings()
            invalidateGeneratedRecommendationResults(
                message: "Mix constraints changed. Generate again to rebuild the curated list."
            )
        }
    }
    @Published var playlistTracks: [Track] = []
    @Published var selectedExportTarget: ExportTarget = .rekordboxPlaylistM3U8
    @Published var analysisQueueProgressText: String = ""
    @Published var analysisStateByTrackID: [UUID: TrackAnalysisState] = [:]
    @Published var analysisActivity: AnalysisActivity?
    @Published var isAnalysisActivityPanelExpanded = true
    @Published var analysisFocus: AnalysisFocus = .balanced
    @Published var googleAIAPIKey: String {
        didSet { refreshValidationStatus() }
    }
    @Published var pythonExecutablePath: String
    @Published var workerScriptPath: String
    @Published var analysisConcurrencyProfile: AnalysisConcurrencyProfile
    @Published var embeddingProfile: EmbeddingProfile {
        didSet {
            refreshValidationStatus()
            invalidateGeneratedRecommendationResults(
                message: "Analysis setup changed. Generate again to rebuild the curated list."
            )
            scheduleWorkerHealthRefresh()
        }
    }
    @Published var validationStatus: ValidationStatus
    @Published var settingsStatusMessage: String = ""
    @Published var analysisErrorMessage: String = ""
    @Published var preparationNotice: PreparationNotice?
    @Published var isShowingAnalyzeAllConfirmation = false
    @Published var analyzeAllConfirmationMessage: String = ""
    @Published var isShowingInitialSetupSheet = false
    @Published var initialSetupLibraryRoot: String = ""
    @Published var initialSetupRekordboxPath: String = ""
    @Published var initialSetupSeratoPath: String = ""
    @Published var initialSetupStatusMessage: String = ""
    @Published var isRunningInitialSetup = false
    @Published var analysisScope: AnalysisScope = .selectedTrack
    @Published var isCancellingAnalysis: Bool = false
    @Published var isScopeInspectorPresented = false
    @Published var activeScopeInspectorTarget: ScopeFilterTarget?
    @Published private(set) var workerProfileStatuses: [String: WorkerProfileStatus] = [:]
    @Published private(set) var detectedVendorTargets = DetectedVendorTargets()
    @Published private(set) var librarySyncPresentationState: LibrarySyncPresentationState?
    @Published private(set) var analysisSessionProgress: AnalysisSessionProgress?

    private let database: LibraryDatabase
    private let recommendationEngine = RecommendationEngine()
    private let exporter = PlaylistExportService()
    private let externalMetadataImporter = ExternalMetadataService()
    private let externalVisualizationResolver = ExternalVisualizationResolver()
    private var pendingAnalyzeAllTrackIDs: [UUID] = []
    private var analysisTask: Task<Void, Never>?
    private var analysisWatchdogTasks: [UUID: Task<Void, Never>] = [:]
    private var librarySyncDismissTask: Task<Void, Never>?
    private var workerHealthTask: Task<Void, Never>?
    private var validationTask: Task<Void, Never>?
    private var readyTrackIDs: Set<UUID> = []
    private var pendingAnalysisTrackIDs: [UUID] = []
    private var analysisActivitiesByTrackID: [UUID: AnalysisActivity] = [:]
    private var analysisProgressFractionByTrackID: [UUID: Double] = [:]
    private var membershipSnapshotsByTrackID: [UUID: TrackMembershipSnapshot] = [:]
    private var scopeTrackCache: [LibraryScopeFilter: Set<UUID>] = [:]
    private var isSuppressingRecommendationResultInvalidation = false
    private var recommendationGenerationStub: RecommendationGenerationStub?
    private let workerTimeoutSec = PythonWorkerClient.defaultWorkerTimeoutSec
    private let analysisWatchdogDelaySec =
        max(Double(ProcessInfo.processInfo.environment["SORIA_ANALYSIS_WATCHDOG_SEC"] ?? "") ?? 12, 5)
    private lazy var worker: PythonWorkerClient = PythonWorkerClient(
        configProvider: { [unowned self] in
            PythonWorkerClient.WorkerConfig(
                pythonExecutable: self.pythonExecutablePath,
                workerScriptPath: self.workerScriptPath,
                googleAIAPIKey: self.googleAIAPIKey,
                embeddingProfile: self.embeddingProfile
            )
        }
    )
    private lazy var scanner: LibraryScannerService = LibraryScannerService(database: database) { [weak self] track in
        await self?.invalidateTrackVectors(for: track)
    }
    private lazy var librarySyncService: DJLibrarySyncService = DJLibrarySyncService(database: database) { [weak self] track in
        await self?.invalidateTrackVectors(for: track)
    }

    init(skipAsyncBootstrap: Bool = false) {
        AppPaths.ensureDirectories()
        let processInfo = ProcessInfo.processInfo
        let processArguments = processInfo.arguments
        let processEnvironment = processInfo.environment
        let uiTestLibraryState = Self.uiTestLibraryState(from: processArguments)
        let forceInitialSetupPrompt = processArguments.contains(Self.uiTestForceInitialSetupArgument)

        if processArguments.contains(Self.uiTestMixAssistantArgument) {
            selectedSection = .mixAssistant
        }

        let loadedAPIKey = AppSettingsStore.loadGoogleAIAPIKey(
            arguments: processArguments,
            environment: processEnvironment
        )
        let loadedPythonPath = AppSettingsStore.loadPythonExecutablePath()
        let loadedWorkerPath = AppSettingsStore.loadWorkerScriptPath()
        let loadedAnalysisConcurrencyProfile = AppSettingsStore.loadAnalysisConcurrencyProfile()
        let loadedProfile = AppSettingsStore.loadEmbeddingProfile()
        let loadedWeights = AppSettingsStore.loadRecommendationWeights()
        let loadedVectorWeights = AppSettingsStore.loadMixsetVectorWeights()
        let loadedConstraints = AppSettingsStore.loadRecommendationConstraints()

        self.googleAIAPIKey = loadedAPIKey
        self.pythonExecutablePath = loadedPythonPath
        self.workerScriptPath = loadedWorkerPath
        self.analysisConcurrencyProfile = loadedAnalysisConcurrencyProfile
        self.embeddingProfile = loadedProfile
        self.validationStatus = AppSettingsStore.currentValidationStatus(apiKey: loadedAPIKey, profile: loadedProfile)
        self.weights = loadedWeights
        self.vectorWeights = loadedVectorWeights
        self.constraints = loadedConstraints

        let databaseBootstrap = Self.bootstrapDatabase()
        self.database = databaseBootstrap.database
        self.librarySources = databaseBootstrap.sources
        self.libraryStatusMessage = databaseBootstrap.statusMessage ?? ""

        let hasExistingRoots = !libraryRoots.isEmpty
        if hasExistingRoots {
            initialSetupLibraryRoot = libraryRoots[0]
            LibraryRootsStore.markInitialSetupCompleted()
        }

        persistFolderFallbackSource()
        refreshDetectedVendorTargets()

        if let uiTestLibraryState {
            applyUITestLibraryState(uiTestLibraryState)
            if forceInitialSetupPrompt {
                refreshValidationStatus()
                isShowingInitialSetupSheet = true
            }
            AppLogger.shared.info("Loaded UI test library state: \(uiTestLibraryState.rawValue)")
            return
        }

        if skipAsyncBootstrap {
            return
        }

        Task {
            await detectLibrarySources()
            await refreshTracks()
            await refreshWorkerHealthAndRepairIfNeeded()
            if shouldShowInitialSetup(hasExistingRoots: hasExistingRoots) {
                isShowingInitialSetupSheet = true
            }
        }
    }

    var selectedTrack: Track? {
        selectedTracks.first
    }

    var isSelectedExportTargetAvailable: Bool {
        switch selectedExportTarget {
        case .seratoCrate:
            return detectedVendorTargets.hasSeratoCratesRoot
        case .rekordboxPlaylistM3U8, .rekordboxLibraryXML:
            return true
        }
    }

    var selectedExportTargetStatusText: String {
        switch selectedExportTarget {
        case .rekordboxPlaylistM3U8, .rekordboxLibraryXML:
            if let libraryDirectory = detectedVendorTargets.rekordboxLibraryDirectory {
                return "Detected rekordbox library: \(libraryDirectory)"
            }
            if let settingsPath = detectedVendorTargets.rekordboxSettingsPath {
                return "Detected rekordbox settings: \(settingsPath)"
            }
            return "rekordbox 6/7 was not detected. Export files can still be imported manually."
        case .seratoCrate:
            if let cratesRoot = detectedVendorTargets.seratoCratesRoot {
                return "Detected Serato crate root: \(cratesRoot)"
            }
            return "No writable _Serato_ root was detected for direct crate export."
        }
    }

    var libraryTableSelection: Binding<Set<UUID>> {
        Binding(
            get: { self.selectedTrackIDs },
            set: { [weak self] newValue in
                self?.updateSelectedTrackIDs(newValue, deferSideEffects: true)
            }
        )
    }

    var selectedTrackIDsInOrder: [UUID] {
        selectedTracks.map(\.id)
    }

    var selectedTrackID: UUID? {
        selectedTracks.first?.id
    }

    var selectedTracks: [Track] {
        tracks.filter { selectedTrackIDs.contains($0.id) }
    }

    var filteredTracks: [Track] {
        libraryTracksMatchingCurrentFilters(trackFilter: libraryTrackFilter)
    }

    var trimmedLibrarySearchText: String {
        librarySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedRecommendationQueryText: String {
        recommendationQueryText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var selectedTrackSummaryLabel: String {
        selectedTracks.map { "\($0.title) - \($0.artist)" }.joined(separator: ", ")
    }

    var selectedRecommendation: RecommendationCandidate? {
        guard let selectedRecommendationID else { return nil }
        return recommendations.first(where: { $0.id == selectedRecommendationID })
    }

    var excludedGeneratedRecommendationCount: Int {
        excludedGeneratedTrackIDs.count
    }

    var canRemoveSelectedGeneratedRecommendations: Bool {
        !recommendationInteractionDisabled && !curationSelectionTrackIDs.isEmpty
    }

    var canRestoreGeneratedRecommendations: Bool {
        !recommendationInteractionDisabled && !excludedGeneratedTrackIDs.isEmpty
    }

    var hasGeneratedRecommendationResults: Bool {
        !generatedRecommendations.isEmpty
    }

    var hasVisibleGeneratedRecommendations: Bool {
        !recommendations.isEmpty
    }

    var curatedRecommendationsSummaryText: String {
        guard hasGeneratedRecommendationResults else {
            return "Generate matches to curate the build pool."
        }

        let visibleCount = recommendations.count
        let totalCount = generatedRecommendations.count
        if excludedGeneratedTrackIDs.isEmpty {
            return "Showing \(visibleCount) generated matches."
        }
        return "Showing \(visibleCount) of \(totalCount) generated matches (\(excludedGeneratedTrackIDs.count) hidden)."
    }

    var nativeLibrarySources: [LibrarySourceRecord] {
        librarySources.filter { $0.kind != .folderFallback }
    }

    var hasValidatedEmbeddingProfile: Bool {
        validationStatus.isValidated
    }

    var analyzedTrackCount: Int {
        tracks.filter { $0.analyzedAt != nil }.count
    }

    var libraryScopedTrackCount: Int {
        libraryScopeFilter.isEmpty ? tracks.count : scopedTrackIDs(for: libraryScopeFilter).count
    }

    var libraryScopedReadyCount: Int {
        filteredTrackCounts(for: libraryScopeFilter).ready
    }

    var libraryScopedNeedsAnalysisCount: Int {
        filteredTrackCounts(for: libraryScopeFilter).needsAnalysis + filteredTrackCounts(for: libraryScopeFilter).needsRefresh
    }

    var libraryScopeSourceCoverageText: String {
        let counts = filteredTrackCounts(for: libraryScopeFilter)
        return "Serato \(counts.seratoCoverage) • rekordbox \(counts.rekordboxCoverage)"
    }

    var hasSyncableLibrarySource: Bool {
        librarySources.contains { $0.kind == .folderFallback && $0.enabled && $0.resolvedPath != nil }
    }

    var hasGoogleAIAPIKeyConfigured: Bool {
        !googleAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasConfiguredPreparationCredentials: Bool {
        !embeddingProfile.requiresAPIKey || hasGoogleAIAPIKeyConfigured
    }

    var initialSetupRequiresLibrarySelection: Bool {
        tracks.isEmpty && !LibraryRootsStore.isInitialSetupCompleted()
    }

    var initialSetupNeedsGoogleAIAPIKey: Bool {
        embeddingProfile.requiresAPIKey && !hasGoogleAIAPIKeyConfigured
    }

    var hasSourceSetupIssue: Bool {
        tracks.isEmpty && !hasSyncableLibrarySource
    }

    var preparationBlockedMessage: String? {
        if let dependencyMessage = selectedEmbeddingProfileDependencyMessage {
            return dependencyMessage
        }
        if validationStatus == .validating {
            return "Validating the active analysis setup..."
        }
        if !hasConfiguredPreparationCredentials {
            return "Enter a Google AI API Key in Settings before preparing tracks."
        }
        return nil
    }

    var friendlyPreparationError: String? {
        if isAnalyzing || isCancellingAnalysis {
            return nil
        }

        let candidates: [String?] = [
            analysisErrorMessage,
            analysisActivity?.lastErrorMessage,
            librarySources.first(where: { $0.status == .error })?.lastError
        ]

        for candidate in candidates {
            let compact = Self.friendlyPreparationMessage(from: candidate)
            if let compact, !compact.isEmpty {
                return compact
            }
        }

        if libraryStatusMessage.localizedCaseInsensitiveContains("failed") {
            return "Library sync could not finish. Check Settings or the logs for details."
        }

        return nil
    }

    var preparationOverviewContext: PreparationOverviewContext {
        PreparationOverviewContext(
            selectionReadiness: selectionReadiness,
            filteredTrackCount: filteredTracks.count,
            filteredNeedsPreparationCount: filteredTracks.filter { trackWorkflowStatus(for: $0) != .ready }.count,
            totalTrackCount: tracks.count,
            hasSourceSetupIssue: hasSourceSetupIssue,
            hasSyncableSource: hasSyncableLibrarySource,
            canPrepareSelection: canAnalyzePendingSelection,
            canPrepareVisible: canAnalyzeVisibleTracks,
            preparationBlockedMessage: preparationBlockedMessage,
            isAnalyzing: isAnalyzing,
            isCancellingAnalysis: isCancellingAnalysis,
            analysisSessionProgress: analysisSessionProgress,
            analysisActivity: analysisActivity,
            preparationNotice: preparationNotice,
            analysisErrorMessage: friendlyPreparationError ?? "",
            scanProgress: scanProgress,
            syncingSourceNames: librarySources.filter { $0.status == .syncing }.map { $0.kind.displayName },
            libraryStatusMessage: libraryStatusMessage
        )
    }

    var preparationOverview: PreparationOverviewState {
        Self.makePreparationOverview(from: preparationOverviewContext)
    }

    var selectionReadiness: SelectionReadiness {
        let selected = selectedTracks
        let counts = selected.reduce(
            into: (ready: 0, needsAnalysis: 0, needsRefresh: 0)
        ) { counts, track in
            switch trackWorkflowStatus(for: track) {
            case .ready:
                counts.ready += 1
            case .needsAnalysis:
                counts.needsAnalysis += 1
            case .needsRefresh:
                counts.needsRefresh += 1
            }
        }
        let signature = selected
            .map(\.id.uuidString)
            .sorted()
            .joined(separator: "|")
        return SelectionReadiness(
            signature: signature,
            selectedCount: selected.count,
            readyCount: counts.ready,
            needsAnalysisCount: counts.needsAnalysis,
            needsRefreshCount: counts.needsRefresh
        )
    }

    var activeEmbeddingTrackCount: Int {
        readyTrackIDs.count
    }

    var staleEmbeddingTrackCount: Int {
        tracks.filter { $0.analyzedAt != nil && !readyTrackIDs.contains($0.id) }.count
    }

    var readySelectedReferenceTracks: [Track] {
        selectedTracks.filter { readyTrackIDs.contains($0.id) }
    }

    var canRunReferenceTrackFeatures: Bool {
        guard hasValidatedEmbeddingProfile else { return false }
        return !readySelectedReferenceTracks.isEmpty
    }

    var recommendationInputState: RecommendationInputState? {
        RecommendationInputState.resolve(
            queryText: recommendationQueryText,
            readyReferenceCount: readySelectedReferenceTracks.count
        )
    }

    var playlistPathTargetCount: Int {
        RecommendationInputState.clampedResultLimit(recommendationResultLimit)
    }

    var canRunRecommendationActions: Bool {
        guard
            hasValidatedEmbeddingProfile,
            isSelectedEmbeddingProfileSupported,
            !isBuildingPlaylist,
            !isGeneratingRecommendations
        else {
            return false
        }
        return recommendationInputState != nil
    }

    var canBuildGeneratedPlaylistPath: Bool {
        canRunRecommendationActions && hasVisibleGeneratedRecommendations
    }

    var normalizedRecommendationWeights: RecommendationWeights {
        weights.normalized()
    }

    var normalizedMixsetVectorWeights: MixsetVectorWeights {
        vectorWeights.normalized()
    }

    var effectiveRecommendationConstraints: RecommendationConstraints {
        constraints.normalizedForScoring()
    }

    var selectedReferenceTracksMissingEmbeddingCount: Int {
        selectedTracks.filter { !readyTrackIDs.contains($0.id) }.count
    }

    var recommendationReferenceSummary: String {
        selectedTracks
            .prefix(3)
            .map { "\($0.title) - \($0.artist)" }
            .joined(separator: ", ")
    }

    var mixAssistantReferenceLabel: String {
        let count = selectionReadiness.selectedCount
        switch count {
        case 0:
            return "No reference tracks selected"
        case 1:
            return "1-track reference"
        default:
            return "\(count)-track blend reference"
        }
    }

    var mixAssistantSelectionChips: [String] {
        selectedTracks.prefix(6).map { track in
            let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            return artist.isEmpty ? track.title : "\(track.title) - \(artist)"
        }
    }

    var canAnalyzeSelectionFromLibrary: Bool {
        selectionReadiness.pendingCount > 0
            && !isAnalyzing
            && !isCancellingAnalysis
    }

    var canOpenRecommendationSearchFromLibrary: Bool {
        selectionReadiness.hasSelection
    }

    var recommendationInteractionDisabled: Bool {
        isBuildingPlaylist || isGeneratingRecommendations
    }

    var recommendationGenerateButtonTitle: String {
        if isBuildingPlaylist {
            return "Building..."
        }
        if isGeneratingRecommendations {
            return "Generating..."
        }
        return "Generate"
    }

    var shouldShowLibraryAnalysisProgress: Bool {
        isAnalyzing || isCancellingAnalysis
    }

    var shouldShowLibrarySetupPrompt: Bool {
        tracks.isEmpty
    }

    var librarySelectionStatusText: String {
        if !selectionReadiness.hasSelection {
            return "Select tracks in the library to analyze them or move them into recommendation search."
        }
        if let blockedMessage = preparationBlockedMessage, selectionReadiness.hasPendingTracks {
            return blockedMessage
        }
        if selectionReadiness.pendingCount == 0 {
            return "Selected tracks are ready. Move into recommendation search whenever you are ready."
        }
        return selectionReadiness.bannerMessage
    }

    var librarySetupPromptTitle: String {
        libraryRoots.isEmpty ? "Library Setup Needed" : "Scan Music Folders"
    }

    var librarySetupPromptMessage: String {
        if libraryRoots.isEmpty {
            return "Choose at least one Music Folder so Soria can load tracks into the library."
        }
        return "Scan your Music Folders to load tracks into the library before starting analysis."
    }

    var librarySetupPromptActionTitle: String {
        libraryRoots.isEmpty ? "Library Setup" : "Scan Music Folders"
    }

    var canAnalyzePendingSelection: Bool {
        selectionReadiness.pendingCount > 0 && !isAnalyzing && !isCancellingAnalysis
    }

    var canAnalyzeVisibleTracks: Bool {
        filteredTracks.contains { trackWorkflowStatus(for: $0) != .ready } && !isAnalyzing && !isCancellingAnalysis
    }

    var canRunAnalysis: Bool {
        analysisScope.canRun(
            validationStatus: validationStatus,
            isBusy: isAnalyzing || isCancellingAnalysis,
            tracks: tracks,
            selectedTrackIDs: selectedTrackIDs,
            readyTrackIDs: readyTrackIDs,
            activeProfileID: embeddingProfile.id
        )
    }

    var hasSelectedTrackForSearchReference: Bool {
        hasValidatedEmbeddingProfile && !selectedTracks.isEmpty
    }

    var isSelectedEmbeddingProfileSupported: Bool {
        workerProfileStatuses[embeddingProfile.id]?.supported ?? true
    }

    var selectedEmbeddingProfileDependencyMessage: String? {
        guard let status = workerProfileStatuses[embeddingProfile.id], !status.supported else { return nil }
        let detail = status.dependencyErrors.joined(separator: " ")
        return detail.isEmpty ? "This analysis setup is currently unavailable." : detail
    }

    func isTrackReadyForActiveProfile(_ track: Track) -> Bool {
        readyTrackIDs.contains(track.id)
    }

    func trackWorkflowStatus(for track: Track) -> TrackWorkflowStatus {
        if readyTrackIDs.contains(track.id) {
            return .ready
        }
        if track.analyzedAt == nil {
            return .needsAnalysis
        }
        return .needsRefresh
    }

    func libraryTrackCount(for filter: LibraryTrackFilter) -> Int {
        libraryTracksMatchingCurrentFilters(trackFilter: filter).count
    }

    static func librarySearchTokens(from queryText: String) -> [String] {
        queryText
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
    }

    static func libraryTrackMatchesSearch(_ track: Track, queryText: String) -> Bool {
        libraryTrackMatchesSearch(track, searchTokens: librarySearchTokens(from: queryText))
    }

    func analysisState(for track: Track) -> TrackAnalysisState {
        analysisStateByTrackID[track.id] ?? TrackAnalysisState.idle()
    }

    func analysisStatusText(for track: Track) -> String {
        let state = analysisState(for: track)
        if state.state != .idle {
            return state.message?.isEmpty == false ? state.message! : state.state.displayName
        }
        if readyTrackIDs.contains(track.id) {
            return "Ready"
        }
        return trackWorkflowStatus(for: track).displayName
    }

    func analysisStatusIsTransient(for track: Track) -> Bool {
        let state = analysisState(for: track).state
        return state == .queued || state == .running
    }

    private func startAnalysisActivity(
        for track: Track,
        queueIndex: Int,
        totalCount: Int,
        stage: AnalysisStage
    ) {
        let startedAt = Date()
        var activity = AnalysisActivity.started(
            trackTitle: track.title,
            trackPath: track.filePath,
            queueIndex: queueIndex,
            totalCount: totalCount,
            timeoutSec: workerTimeoutSec,
            startedAt: startedAt
        )
        if stage != .queued {
            activity.recordProgress(
                WorkerProgressEvent(
                    stage: stage,
                    message: stage.displayName,
                    fraction: 0.02,
                    trackPath: track.filePath,
                    timestamp: startedAt
                ),
                trackTitle: track.title,
                fallbackTrackPath: track.filePath,
                queueIndex: queueIndex,
                totalCount: totalCount
            )
        }
        analysisActivitiesByTrackID[track.id] = activity
        analysisActivity = activity
        isAnalysisActivityPanelExpanded = true
        analysisProgressFractionByTrackID[track.id] = activity.stageFraction ?? 0
        refreshAnalysisSessionProgress(latestTrackTitle: track.title, latestMessage: activity.currentMessage)
    }

    private func recordAnalysisProgress(
        _ event: WorkerProgressEvent,
        trackID: UUID,
        trackTitle: String,
        trackPath: String,
        queueIndex: Int,
        totalCount: Int
    ) {
        var activity = analysisActivitiesByTrackID[trackID]
        if activity == nil {
            activity = AnalysisActivity.started(
                trackTitle: trackTitle,
                trackPath: trackPath,
                queueIndex: queueIndex,
                totalCount: totalCount,
                timeoutSec: workerTimeoutSec
            )
            isAnalysisActivityPanelExpanded = true
        }

        activity?.recordProgress(
            event,
            trackTitle: trackTitle,
            fallbackTrackPath: trackPath,
            queueIndex: queueIndex,
            totalCount: totalCount
        )
        if let activity {
            analysisActivitiesByTrackID[trackID] = activity
            analysisActivity = activity
        }
        AppLogger.shared.info(
            "Analysis progress | stage=\(event.stage.rawValue) | queue=\(queueIndex)/\(totalCount) | trackPath=\(trackPath) | message=\(event.message)"
        )
        analysisProgressFractionByTrackID[trackID] = max(0, min(1, event.fraction ?? analysisProgressFractionByTrackID[trackID] ?? 0))
        updateAnalysisState(trackID: trackID, state: .running, message: event.stage.displayName, updatedAt: event.timestamp)
        refreshAnalysisSessionProgress(latestTrackTitle: trackTitle, latestMessage: event.message)
        scheduleAnalysisProgressWatchdog(
            trackID: trackID,
            trackTitle: trackTitle,
            trackPath: trackPath,
            queueIndex: queueIndex,
            totalCount: totalCount
        )
    }

    private func finishAnalysisActivity(
        state: AnalysisTaskState,
        for track: Track,
        queueIndex: Int,
        totalCount: Int,
        errorMessage: String? = nil
    ) {
        var activity = analysisActivitiesByTrackID[track.id]
        if activity == nil {
            activity = AnalysisActivity.started(
                trackTitle: track.title,
                trackPath: track.filePath,
                queueIndex: queueIndex,
                totalCount: totalCount,
                timeoutSec: workerTimeoutSec
            )
        }

        let message: String
        switch state {
        case .succeeded:
            message = "Completed \(track.title)"
        case .failed:
            message = "Failed \(track.title)"
        case .canceled:
            message = "Canceled \(track.title)"
        default:
            message = state.displayName
        }
        activity?.markFinished(state: state, errorMessage: errorMessage, message: message)
        if let activity {
            analysisActivitiesByTrackID[track.id] = activity
            analysisActivity = activity
        }
        analysisProgressFractionByTrackID[track.id] = 1
        refreshAnalysisSessionProgress(latestTrackTitle: track.title, latestMessage: message)
    }

    private func refreshAnalysisQueueText() {
        if let sessionProgress = analysisSessionProgress {
            analysisQueueProgressText = sessionProgress.statusLine
            return
        }
        guard let activity = analysisActivity else { return }
        let queueText = "\(activity.queueIndex) / \(activity.totalCount)"
        if activity.isFinished {
            analysisQueueProgressText = "\(activity.headlineText) • \(activity.currentTrackTitle) (\(queueText))"
        } else {
            analysisQueueProgressText = "\(activity.currentMessage) • \(activity.currentTrackTitle) (\(queueText))"
        }
    }

    private func prepareAnalysisSession(for tracks: [Track]) {
        cancelAllAnalysisProgressWatchdogs()
        analysisActivitiesByTrackID = [:]
        analysisProgressFractionByTrackID = [:]
        guard let firstTrack = tracks.first else {
            analysisSessionProgress = nil
            analysisActivity = nil
            analysisQueueProgressText = "Preparing analysis queue..."
            return
        }

        analysisActivity = AnalysisActivity.started(
            trackTitle: firstTrack.title,
            trackPath: firstTrack.filePath,
            queueIndex: 1,
            totalCount: tracks.count,
            timeoutSec: workerTimeoutSec
        )
        if let activity = analysisActivity {
            analysisActivitiesByTrackID[firstTrack.id] = activity
        }
        isAnalysisActivityPanelExpanded = true
        analysisSessionProgress = .queued(totalCount: tracks.count, latestTrackTitle: firstTrack.title)
        refreshAnalysisQueueText()
    }

    private func refreshAnalysisSessionProgress(
        latestTrackTitle: String? = nil,
        latestMessage: String? = nil
    ) {
        guard !pendingAnalysisTrackIDs.isEmpty else {
            analysisSessionProgress = nil
            refreshAnalysisQueueText()
            return
        }

        let totalCount = pendingAnalysisTrackIDs.count
        let states = pendingAnalysisTrackIDs.map { analysisStateByTrackID[$0]?.state ?? .idle }
        let queuedCount = states.filter { $0 == .queued }.count
        let runningCount = states.filter { $0 == .running }.count
        let completedCount = states.filter { $0 == .succeeded }.count
        let failedCount = states.filter { $0 == .failed }.count
        let canceledCount = states.filter { $0 == .canceled }.count
        let completedProgress = Double(completedCount + failedCount + canceledCount)
        let runningProgress = pendingAnalysisTrackIDs.reduce(0.0) { partialResult, trackID in
            let state = analysisStateByTrackID[trackID]?.state ?? .idle
            guard state == .running else { return partialResult }
            return partialResult + max(0, min(1, analysisProgressFractionByTrackID[trackID] ?? 0))
        }

        let previousProgress = analysisSessionProgress
        analysisSessionProgress = AnalysisSessionProgress(
            totalCount: totalCount,
            runningCount: runningCount,
            queuedCount: queuedCount,
            completedCount: completedCount,
            failedCount: failedCount,
            canceledCount: canceledCount,
            overallProgress: min(1, (completedProgress + runningProgress) / Double(max(totalCount, 1))),
            latestTrackTitle: latestTrackTitle ?? previousProgress?.latestTrackTitle ?? analysisActivity?.currentTrackTitle ?? "",
            latestMessage: latestMessage ?? previousProgress?.latestMessage ?? analysisActivity?.currentMessage ?? ""
        )
        refreshAnalysisQueueText()
    }

    private func scheduleAnalysisProgressWatchdog(
        trackID: UUID,
        trackTitle: String,
        trackPath: String,
        queueIndex: Int,
        totalCount: Int
    ) {
        analysisWatchdogTasks[trackID]?.cancel()
        let thresholdSec = analysisWatchdogDelaySec
        analysisWatchdogTasks[trackID] = Task { [weak self] in
            let delayNs = UInt64(max(thresholdSec, 1) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                guard
                    self.isAnalyzing,
                    !self.isCancellingAnalysis,
                    let activity = self.analysisActivitiesByTrackID[trackID],
                    activity.currentTrackPath == trackPath,
                    activity.queueIndex == queueIndex
                else {
                    return
                }

                guard let event = Self.makeAnalysisWatchdogEvent(
                    activity: activity,
                    thresholdSec: thresholdSec
                ) else {
                    return
                }

                self.recordAnalysisProgress(
                    event,
                    trackID: trackID,
                    trackTitle: trackTitle,
                    trackPath: trackPath,
                    queueIndex: queueIndex,
                    totalCount: totalCount
                )
                AppLogger.shared.info(
                    "Analysis watchdog triggered | trackPath=\(trackPath) | queue=\(queueIndex)/\(totalCount) | message=\(event.message)"
                )
            }
        }
    }

    private func cancelAnalysisProgressWatchdog(trackID: UUID) {
        analysisWatchdogTasks.removeValue(forKey: trackID)?.cancel()
    }

    private func cancelAllAnalysisProgressWatchdogs() {
        for task in analysisWatchdogTasks.values {
            task.cancel()
        }
        analysisWatchdogTasks.removeAll()
    }

    nonisolated static func makeAnalysisWatchdogEvent(
        activity: AnalysisActivity,
        thresholdSec: Double,
        now: Date = Date()
    ) -> WorkerProgressEvent? {
        guard thresholdSec > 0, !activity.isFinished else { return nil }
        guard !activity.currentMessage.hasPrefix("No new worker progress") else { return nil }

        let idleSec = now.timeIntervalSince(activity.updatedAt)
        guard idleSec >= thresholdSec else { return nil }

        let roundedThreshold = max(Int(thresholdSec.rounded()), 1)
        return WorkerProgressEvent(
            stage: activity.stage,
            message: "No new worker progress for \(roundedThreshold)s (last stage: \(activity.stage.displayName))",
            fraction: activity.stageFraction,
            trackPath: activity.currentTrackPath,
            timestamp: now
        )
    }

    static func friendlyPreparationMessage(from raw: String?) -> String? {
        guard let raw else { return nil }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let compact = trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.hasPrefix("Last stage:") && !$0.hasPrefix("Last event:") }

        guard let compact else { return nil }

        if compact.localizedCaseInsensitiveContains("timed out") {
            return "Preparation is taking longer than expected. Check the logs if this keeps happening."
        }
        if compact.localizedCaseInsensitiveContains("canceled") {
            return "Preparation was canceled."
        }
        if compact.localizedCaseInsensitiveContains("Library sync failed") {
            return "Library sync could not finish. Check Settings or the logs for details."
        }
        if compact.localizedCaseInsensitiveContains("validate the current analysis setup") {
            return "Validate the active analysis setup in Settings before preparing tracks."
        }
        return compact
    }

    private static func uiTestLibraryState(from arguments: [String]) -> UITestLibraryState? {
        guard let argument = arguments.first(where: { $0.hasPrefix(uiTestLibraryStatePrefix) }) else {
            return nil
        }
        let rawValue = String(argument.dropFirst(uiTestLibraryStatePrefix.count))
        return UITestLibraryState(rawValue: rawValue)
    }

    private func applyUITestLibraryState(_ state: UITestLibraryState) {
        let fixture = Self.uiTestFixture(for: state)

        tracks = fixture.tracks
        selectedTrackIDs = fixture.selectedTrackIDs
        selectedTrackSegments = []
        selectedTrackAnalysis = nil
        selectedTrackExternalMetadata = []
        selectedTrackWaveformPreview = []
        selectedRecommendationID = nil
        resetGeneratedRecommendationResults(clearStatusMessage: true)
        recommendationStatusMessage = fixture.recommendationStatusMessage
        recommendationQueryText = fixture.recommendationQueryText
        librarySearchText = ""
        recommendationResultLimit = RecommendationInputState.defaultResultLimit
        weights = .defaults
        vectorWeights = .defaults
        constraints = .defaults
        libraryTrackFilter = .all
        libraryScopeFilter = LibraryScopeFilter()
        recommendationScopeFilter = LibraryScopeFilter()
        exportMessage = ""
        playlistTracks = []
        analysisQueueProgressText = ""
        analysisStateByTrackID = fixture.analysisStateByTrackID
        analysisSessionProgress = fixture.analysisSessionProgress
        analysisActivity = fixture.analysisActivity
        analysisActivitiesByTrackID = fixture.analysisActivity.map { [fixture.pendingAnalysisTrackIDs.first ?? UUID(): $0] } ?? [:]
        analysisProgressFractionByTrackID = fixture.pendingAnalysisTrackIDs.reduce(into: [:]) { partialResult, trackID in
            partialResult[trackID] = fixture.analysisActivity?.stageFraction ?? 0
        }
        scanProgress = ScanJobProgress()
        librarySources = fixture.librarySources
        libraryStatusMessage = fixture.libraryStatusMessage
        seratoMembershipFacets = fixture.seratoMembershipFacets
        rekordboxMembershipFacets = fixture.rekordboxMembershipFacets
        readyTrackIDs = fixture.readyTrackIDs
        recommendationGenerationStub = fixture.recommendationGenerationStub
        membershipSnapshotsByTrackID = [:]
        scopeTrackCache.removeAll()
        pendingAnalyzeAllTrackIDs = []
        pendingAnalysisTrackIDs = fixture.pendingAnalysisTrackIDs
        isAnalyzing = fixture.isAnalyzing
        isGeneratingRecommendations = fixture.isGeneratingRecommendations
        isCancellingAnalysis = false
        analysisErrorMessage = ""
        preparationNotice = nil
        isScopeInspectorPresented = false
        activeScopeInspectorTarget = nil
        librarySyncDismissTask?.cancel()
        librarySyncDismissTask = nil
        librarySyncPresentationState = nil
        validationStatus = fixture.validationStatus
        workerProfileStatuses = [:]
        settingsStatusMessage = ""
        libraryRoots = []
        isShowingInitialSetupSheet = false
        isRunningInitialSetup = false
        initialSetupStatusMessage = ""
        if !fixture.generatedRecommendations.isEmpty {
            replaceGeneratedRecommendations(fixture.generatedRecommendations)
            playlistBuildProgress = fixture.playlistBuildProgress
            isBuildingPlaylist = fixture.isBuildingPlaylist
        }
        if analysisSessionProgress != nil || analysisActivity != nil {
            refreshAnalysisQueueText()
        }
    }

    private static func uiTestFixture(
        for state: UITestLibraryState
    ) -> (
        tracks: [Track],
        readyTrackIDs: Set<UUID>,
        librarySources: [LibrarySourceRecord],
        libraryStatusMessage: String,
        selectedTrackIDs: Set<UUID>,
        analysisStateByTrackID: [UUID: TrackAnalysisState],
        analysisSessionProgress: AnalysisSessionProgress?,
        analysisActivity: AnalysisActivity?,
        pendingAnalysisTrackIDs: [UUID],
        isAnalyzing: Bool,
        isGeneratingRecommendations: Bool,
        validationStatus: ValidationStatus,
        recommendationQueryText: String,
        recommendationStatusMessage: String,
        generatedRecommendations: [RecommendationCandidate],
        playlistBuildProgress: PlaylistBuildProgress?,
        isBuildingPlaylist: Bool,
        recommendationGenerationStub: RecommendationGenerationStub?,
        seratoMembershipFacets: [MembershipFacet],
        rekordboxMembershipFacets: [MembershipFacet]
    ) {
        let now = Date()
        let facets = uiTestMembershipFacets()

        let seratoSource = LibrarySourceRecord(
            id: UUID(),
            kind: .serato,
            enabled: true,
            resolvedPath: "/UITests/Serato",
            lastSyncAt: now,
            status: .available,
            lastError: nil
        )
        let rekordboxSource = LibrarySourceRecord(
            id: UUID(),
            kind: .rekordbox,
            enabled: true,
            resolvedPath: "/UITests/rekordbox/master.db",
            lastSyncAt: now,
            status: .available,
            lastError: nil
        )
        let fallbackSource = LibrarySourceRecord(
            id: UUID(),
            kind: .folderFallback,
            enabled: false,
            resolvedPath: nil,
            lastSyncAt: nil,
            status: .disabled,
            lastError: nil
        )

        switch state {
        case .empty:
            return (
                tracks: [],
                readyTrackIDs: Set<UUID>(),
                librarySources: [seratoSource, rekordboxSource, fallbackSource],
                libraryStatusMessage: "",
                selectedTrackIDs: [],
                analysisStateByTrackID: [:],
                analysisSessionProgress: nil,
                analysisActivity: nil,
                pendingAnalysisTrackIDs: [],
                isAnalyzing: false,
                isGeneratingRecommendations: false,
                validationStatus: .unvalidated,
                recommendationQueryText: "",
                recommendationStatusMessage: "",
                generatedRecommendations: [],
                playlistBuildProgress: nil,
                isBuildingPlaylist: false,
                recommendationGenerationStub: nil,
                seratoMembershipFacets: facets.serato,
                rekordboxMembershipFacets: facets.rekordbox
            )
        case .prepared, .readySelection, .analyzing, .generated, .generating, .buildingPlaylist:
            let readyTrackID = UUID()
            let pendingTrackID = UUID()
            let curatedTrackID = UUID()
            let backupTrackID = UUID()

            let readyTrack = Track(
                id: readyTrackID,
                filePath: "/UITests/Library/ready-track.wav",
                fileName: "ready-track.wav",
                title: "Ready Track",
                artist: "Fixture Artist",
                album: "Fixture Album",
                genre: "House",
                duration: 243,
                sampleRate: 44100,
                bpm: 124.0,
                musicalKey: "8A",
                modifiedTime: now,
                contentHash: "ready-track-hash",
                analyzedAt: now,
                embeddingProfileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id,
                embeddingPipelineID: EmbeddingPipeline.audioSegmentsV1.id,
                embeddingUpdatedAt: now,
                hasSeratoMetadata: true,
                hasRekordboxMetadata: true,
                bpmSource: .serato,
                keySource: .rekordbox
            )

            let pendingTrack = Track(
                id: pendingTrackID,
                filePath: "/UITests/Library/pending-track.wav",
                fileName: "pending-track.wav",
                title: "Pending Track",
                artist: "Fixture Artist",
                album: "Fixture Album",
                genre: "Tech House",
                duration: 255,
                sampleRate: 44100,
                bpm: 126.0,
                musicalKey: "9A",
                modifiedTime: now,
                contentHash: "pending-track-hash",
                analyzedAt: state == .generated || state == .buildingPlaylist ? now : nil,
                embeddingProfileID: state == .generated || state == .buildingPlaylist
                    ? EmbeddingProfile.googleGeminiEmbedding2Preview.id
                    : nil,
                embeddingPipelineID: state == .generated || state == .buildingPlaylist
                    ? EmbeddingPipeline.audioSegmentsV1.id
                    : nil,
                embeddingUpdatedAt: state == .generated || state == .buildingPlaylist ? now : nil,
                hasSeratoMetadata: true,
                hasRekordboxMetadata: false,
                bpmSource: .audioTags,
                keySource: .audioTags
            )

            let curatedTrack = Track(
                id: curatedTrackID,
                filePath: "/UITests/Library/curated-track.wav",
                fileName: "curated-track.wav",
                title: "Curated Track",
                artist: "Fixture Artist",
                album: "Fixture Album",
                genre: "House",
                duration: 248,
                sampleRate: 44100,
                bpm: 125.0,
                musicalKey: "9A",
                modifiedTime: now,
                contentHash: "curated-track-hash",
                analyzedAt: now,
                embeddingProfileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id,
                embeddingPipelineID: EmbeddingPipeline.audioSegmentsV1.id,
                embeddingUpdatedAt: now,
                hasSeratoMetadata: true,
                hasRekordboxMetadata: true,
                bpmSource: .serato,
                keySource: .rekordbox
            )

            let backupTrack = Track(
                id: backupTrackID,
                filePath: "/UITests/Library/backup-track.wav",
                fileName: "backup-track.wav",
                title: "Backup Track",
                artist: "Fixture Artist",
                album: "Fixture Album",
                genre: "House",
                duration: 252,
                sampleRate: 44100,
                bpm: 126.0,
                musicalKey: "10A",
                modifiedTime: now,
                contentHash: "backup-track-hash",
                analyzedAt: now,
                embeddingProfileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id,
                embeddingPipelineID: EmbeddingPipeline.audioSegmentsV1.id,
                embeddingUpdatedAt: now,
                hasSeratoMetadata: true,
                hasRekordboxMetadata: true,
                bpmSource: .serato,
                keySource: .rekordbox
            )

            let generatedFixtureCandidates = [
                RecommendationCandidate(
                    id: curatedTrackID,
                    track: curatedTrack,
                    score: 0.88,
                    breakdown: ScoreBreakdown(
                        embeddingSimilarity: 0.86,
                        bpmCompatibility: 0.82,
                        harmonicCompatibility: 0.80,
                        energyFlow: 0.77,
                        transitionRegionMatch: 0.75,
                        externalMetadataScore: 0.66
                    ),
                    vectorBreakdown: VectorScoreBreakdown(
                        fusedScore: 0.86,
                        trackScore: 0.83,
                        introScore: 0.82,
                        middleScore: 0.79,
                        outroScore: 0.80,
                        bestMatchedCollection: "middle"
                    ),
                    analysisFocus: .balanced,
                    mixabilityTags: ["clean_outro"],
                    matchReasons: ["Blend-friendly intro/outro"],
                    matchedMemberships: ["Festival / Day 1 / Mainstage"],
                    scoreSessionID: nil
                ),
                RecommendationCandidate(
                    id: backupTrackID,
                    track: backupTrack,
                    score: 0.84,
                    breakdown: ScoreBreakdown(
                        embeddingSimilarity: 0.81,
                        bpmCompatibility: 0.80,
                        harmonicCompatibility: 0.76,
                        energyFlow: 0.74,
                        transitionRegionMatch: 0.73,
                        externalMetadataScore: 0.64
                    ),
                    vectorBreakdown: VectorScoreBreakdown(
                        fusedScore: 0.82,
                        trackScore: 0.80,
                        introScore: 0.76,
                        middleScore: 0.77,
                        outroScore: 0.74,
                        bestMatchedCollection: "outro"
                    ),
                    analysisFocus: .balanced,
                    mixabilityTags: ["rolling"],
                    matchReasons: ["House family"],
                    matchedMemberships: ["Club / Friday / Peak"],
                    scoreSessionID: nil
                )
            ]

            let analysisActivity: AnalysisActivity? = {
                guard state == .analyzing else { return nil }
                return AnalysisActivity.started(
                    trackTitle: pendingTrack.title,
                    trackPath: pendingTrack.filePath,
                    queueIndex: 1,
                    totalCount: 1,
                    timeoutSec: 120,
                    startedAt: now
                )
            }()

            let fixtureGeneratedRecommendations: [RecommendationCandidate] = if state == .generated || state == .buildingPlaylist {
                [
                    RecommendationCandidate(
                        id: pendingTrackID,
                        track: pendingTrack,
                        score: 0.91,
                        breakdown: ScoreBreakdown(
                            embeddingSimilarity: 0.91,
                            bpmCompatibility: 0.84,
                            harmonicCompatibility: 0.78,
                            energyFlow: 0.81,
                            transitionRegionMatch: 0.80,
                            externalMetadataScore: 0.62
                        ),
                        vectorBreakdown: VectorScoreBreakdown(
                            fusedScore: 0.89,
                            trackScore: 0.87,
                            introScore: 0.84,
                            middleScore: 0.85,
                            outroScore: 0.82,
                            bestMatchedCollection: "tracks"
                        ),
                        analysisFocus: .balanced,
                        mixabilityTags: ["long_intro"],
                        matchReasons: ["High embedding match"],
                        matchedMemberships: ["Disco / Edits"],
                        scoreSessionID: nil
                    ),
                    generatedFixtureCandidates[0],
                    generatedFixtureCandidates[1]
                ]
            } else {
                []
            }

            let fixtureReadyTrackIDs: Set<UUID>
            switch state {
            case .prepared, .analyzing:
                fixtureReadyTrackIDs = [readyTrackID]
            case .readySelection, .generating:
                fixtureReadyTrackIDs = [readyTrackID, curatedTrackID, backupTrackID]
            case .generated, .buildingPlaylist:
                fixtureReadyTrackIDs = [readyTrackID, pendingTrackID, curatedTrackID, backupTrackID]
            case .empty:
                fixtureReadyTrackIDs = []
            }

            return (
                tracks: [readyTrack, pendingTrack, curatedTrack, backupTrack],
                readyTrackIDs: fixtureReadyTrackIDs,
                librarySources: [seratoSource, rekordboxSource, fallbackSource],
                libraryStatusMessage: "",
                selectedTrackIDs: state == .analyzing
                    ? Set([pendingTrackID])
                    : (state == .readySelection || state == .generated || state == .generating || state == .buildingPlaylist
                        ? Set([readyTrackID])
                        : []),
                analysisStateByTrackID: state == .analyzing
                    ? [
                        pendingTrackID: TrackAnalysisState(
                            state: .running,
                            message: AnalysisStage.launching.displayName,
                            updatedAt: now
                        )
                    ]
                    : [:],
                analysisSessionProgress: state == .analyzing
                    ? AnalysisSessionProgress(
                        totalCount: 1,
                        runningCount: 1,
                        queuedCount: 0,
                        completedCount: 0,
                        failedCount: 0,
                        canceledCount: 0,
                        overallProgress: 0.02,
                        latestTrackTitle: pendingTrack.title,
                        latestMessage: AnalysisStage.launching.displayName
                    )
                    : nil,
                analysisActivity: analysisActivity,
                pendingAnalysisTrackIDs: state == .analyzing ? [pendingTrackID] : [],
                isAnalyzing: state == .analyzing,
                isGeneratingRecommendations: state == .generating,
                validationStatus: state == .prepared ? .unvalidated : .validated(now),
                recommendationQueryText: state == .generated || state == .buildingPlaylist ? "Warmup journey" : "",
                recommendationStatusMessage: state == .generated
                    ? "Generated 3 matches. Curate the list before building the playlist."
                    : (state == .generating
                        ? RecommendationGenerationTrigger.librarySelection.inProgressMessage
                        : (state == .buildingPlaylist ? "Built 3-track path from seed: Ready Track" : "")),
                generatedRecommendations: fixtureGeneratedRecommendations,
                playlistBuildProgress: state == .buildingPlaylist
                    ? PlaylistBuildProgress(
                        stage: .orderingTrack,
                        completedCount: 1,
                        totalCount: 3,
                        progress: 0.45,
                        currentSeedTitle: readyTrack.title,
                        latestTrackTitle: curatedTrack.title,
                        message: "Evaluating 2 remaining curated matches from \(readyTrack.title)."
                    )
                    : nil,
                isBuildingPlaylist: state == .buildingPlaylist,
                recommendationGenerationStub: state == .readySelection || state == .generated
                    ? RecommendationGenerationStub(
                        results: generatedFixtureCandidates,
                        delayNanoseconds: 50_000_000,
                        completionStatusMessage: "Generated 2 matches. Curate the list before building the playlist."
                    )
                    : nil,
                seratoMembershipFacets: facets.serato,
                rekordboxMembershipFacets: facets.rekordbox
            )
        }
    }

    private static func uiTestMembershipFacets() -> (serato: [MembershipFacet], rekordbox: [MembershipFacet]) {
        let seratoPaths = [
            "Warmup / Deep",
            "Warmup / Rollers",
            "Peak / Tools",
            "Peak / Anthems",
            "Peak / Vocal Hits",
            "Closing / Melodic",
            "Closing / Euphoria",
            "Afro / Percussive",
            "House / Classics",
            "House / New Heat",
            "Minimal / Rollers",
            "Techno / Driving",
            "Techno / Hypnotic",
            "Breaks / Leftfield",
            "Garage / UKG",
            "Disco / Edits"
        ]
        let rekordboxPaths = [
            "Festival / Day 1 / Sunrise",
            "Festival / Day 1 / Mainstage",
            "Club / Friday / Peak",
            "Club / Saturday / Closing"
        ]

        return (
            serato: seratoPaths.enumerated().map { index, path in
                uiTestMembershipFacet(source: .serato, path: path, trackCount: index % 2 == 0 ? 1 : 2)
            },
            rekordbox: rekordboxPaths.enumerated().map { index, path in
                uiTestMembershipFacet(source: .rekordbox, path: path, trackCount: index % 2 == 0 ? 1 : 2)
            }
        )
    }

    private static func uiTestMembershipFacet(
        source: ExternalDJMetadata.Source,
        path: String,
        trackCount: Int
    ) -> MembershipFacet {
        let segments = path.split(separator: "/").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let displayName = segments.last ?? path
        let parentPath = segments.dropLast().isEmpty ? nil : segments.dropLast().joined(separator: " / ")

        return MembershipFacet(
            source: source,
            membershipPath: path,
            displayName: displayName,
            parentPath: parentPath,
            depth: max(segments.count - 1, 0),
            trackCount: trackCount
        )
    }

    static func makePreparationOverview(from context: PreparationOverviewContext) -> PreparationOverviewState {
        let syncAction: PreparationOverviewAction? = .syncLibrary
        let preferredPreparationAction: PreparationOverviewAction? = if context.selectionReadiness.hasPendingTracks {
            .prepareSelection
        } else if context.filteredNeedsPreparationCount > 0 {
            .prepareVisible
        } else {
            nil
        }
        let isPreferredPreparationActionEnabled: Bool = switch preferredPreparationAction {
        case .prepareSelection:
            context.canPrepareSelection
        case .prepareVisible:
            context.canPrepareVisible
        case .syncLibrary, .none:
            false
        }

        if context.isAnalyzing || context.isCancellingAnalysis {
            let progress = context.analysisSessionProgress?.overallProgress ?? context.analysisActivity?.overallProgress
            let trackSummary =
                context.analysisSessionProgress?.statusLine
                ?? context.analysisActivity.map { activity in
                    activity.totalCount > 1
                        ? "\(activity.queueIndex) of \(activity.totalCount) • \(activity.currentTrackTitle)"
                        : activity.currentTrackTitle
                }
                ?? "Preparing tracks for the active analysis setup."
            return PreparationOverviewState(
                phase: .analyzing,
                title: context.isCancellingAnalysis ? "Stopping Preparation" : "Preparing Tracks",
                message: trackSummary,
                progress: progress,
                primaryAction: nil,
                primaryActionTitleOverride: nil,
                isPrimaryActionDisabled: false,
                secondaryAction: nil,
                isCancellable: true,
                showSuccess: false
            )
        }

        if context.scanProgress.isRunning || !context.syncingSourceNames.isEmpty {
            let sourceSummary = if context.syncingSourceNames.isEmpty {
                "Updating scanned local tracks."
            } else {
                "Updating \(context.syncingSourceNames.joined(separator: ", "))."
            }
            let progress = context.scanProgress.totalFiles > 0
                ? Double(context.scanProgress.scannedFiles) / Double(max(context.scanProgress.totalFiles, 1))
                : nil
            let detail = context.scanProgress.currentFile.isEmpty
                ? sourceSummary
                : "\(sourceSummary) Current: \(context.scanProgress.currentFile)"
            return PreparationOverviewState(
                phase: .syncing,
                title: "Refreshing Library",
                message: detail,
                progress: progress,
                primaryAction: syncAction,
                primaryActionTitleOverride: "Refreshing Library",
                isPrimaryActionDisabled: true,
                secondaryAction: nil,
                isCancellable: false,
                showSuccess: false
            )
        }

        if let notice = context.preparationNotice, notice.kind == .failed {
            return PreparationOverviewState(
                phase: .failed,
                title: "Preparation Needs Attention",
                message: notice.message,
                progress: nil,
                primaryAction: preferredPreparationAction ?? syncAction,
                primaryActionTitleOverride: nil,
                isPrimaryActionDisabled: preferredPreparationAction != nil && !isPreferredPreparationActionEnabled,
                secondaryAction: preferredPreparationAction == nil ? nil : syncAction,
                isCancellable: false,
                showSuccess: false
            )
        }

        if !context.analysisErrorMessage.isEmpty {
            return PreparationOverviewState(
                phase: .failed,
                title: "Preparation Needs Attention",
                message: context.analysisErrorMessage,
                progress: nil,
                primaryAction: preferredPreparationAction ?? syncAction,
                primaryActionTitleOverride: nil,
                isPrimaryActionDisabled: preferredPreparationAction != nil && !isPreferredPreparationActionEnabled,
                secondaryAction: preferredPreparationAction == nil ? nil : syncAction,
                isCancellable: false,
                showSuccess: false
            )
        }

        if context.hasSourceSetupIssue {
            return PreparationOverviewState(
                phase: .idle,
                title: "Settings Check Needed",
                message: "Connect or enable a library in Settings to start preparing tracks.",
                progress: nil,
                primaryAction: nil,
                primaryActionTitleOverride: nil,
                isPrimaryActionDisabled: false,
                secondaryAction: nil,
                isCancellable: false,
                showSuccess: false
            )
        }

        if context.selectionReadiness.hasPendingTracks {
            let message = context.preparationBlockedMessage ?? context.selectionReadiness.bannerMessage
            return PreparationOverviewState(
                phase: .idle,
                title: "Tracks Need Preparation",
                message: message,
                progress: nil,
                primaryAction: .prepareSelection,
                primaryActionTitleOverride: nil,
                isPrimaryActionDisabled: !context.canPrepareSelection,
                secondaryAction: syncAction,
                isCancellable: false,
                showSuccess: false
            )
        }

        if context.selectionReadiness.hasSelection {
            return PreparationOverviewState(
                phase: .completed,
                title: "Selection Ready",
                message: "Everything in the current selection is ready to use.",
                progress: 1,
                primaryAction: syncAction,
                primaryActionTitleOverride: nil,
                isPrimaryActionDisabled: false,
                secondaryAction: nil,
                isCancellable: false,
                showSuccess: true
            )
        }

        if context.filteredNeedsPreparationCount > 0 {
            let blockedMessage = context.preparationBlockedMessage
            let message = blockedMessage
                ?? "\(context.filteredNeedsPreparationCount) visible track(s) still need preparation."
            return PreparationOverviewState(
                phase: .idle,
                title: "Prepare Visible Tracks",
                message: message,
                progress: nil,
                primaryAction: .prepareVisible,
                primaryActionTitleOverride: nil,
                isPrimaryActionDisabled: !context.canPrepareVisible,
                secondaryAction: syncAction,
                isCancellable: false,
                showSuccess: false
            )
        }

        if context.filteredTrackCount > 0 || context.totalTrackCount > 0 {
            return PreparationOverviewState(
                phase: .completed,
                title: "Library Ready",
                message: "Visible tracks are ready to use.",
                progress: 1,
                primaryAction: syncAction,
                primaryActionTitleOverride: nil,
                isPrimaryActionDisabled: false,
                secondaryAction: nil,
                isCancellable: false,
                showSuccess: true
            )
        }

        let emptyMessage = context.preparationBlockedMessage ?? "Sync your DJ libraries to load tracks into Soria."
        return PreparationOverviewState(
            phase: .idle,
            title: "Sync Your Library",
            message: emptyMessage,
            progress: nil,
            primaryAction: syncAction,
            primaryActionTitleOverride: nil,
            isPrimaryActionDisabled: false,
            secondaryAction: nil,
            isCancellable: false,
            showSuccess: false
        )
    }

    private func logAnalysisEvent(
        _ event: String,
        track: Track,
        queueIndex: Int,
        totalCount: Int,
        elapsedMs: Int? = nil,
        extra: [String: String] = [:]
    ) {
        var parts: [String] = [
            "Analysis \(event)",
            "trackPath=\(track.filePath)",
            "queue=\(queueIndex)/\(totalCount)",
            "profile=\(embeddingProfile.id)",
            "focus=\(analysisFocus.rawValue)"
        ]
        if let elapsedMs {
            parts.append("elapsedMs=\(elapsedMs)")
        }
        for key in extra.keys.sorted() {
            if let value = extra[key], !value.isEmpty {
                parts.append("\(key)=\(value)")
            }
        }
        AppLogger.shared.info(parts.joined(separator: " | "))
    }

    private func decoratedAnalysisError(_ rawMessage: String, trackID: UUID) -> String {
        var segments: [String] = []
        let baseMessage = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !baseMessage.isEmpty {
            segments.append(baseMessage)
        }
        if let activity = analysisActivitiesByTrackID[trackID] ?? analysisActivity {
            let lastStage = activity.stage.displayName
            if !lastStage.isEmpty {
                segments.append("Last stage: \(lastStage)")
            }
            let lastEvent = activity.displayedEvents.first?.message.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !lastEvent.isEmpty, lastEvent != lastStage {
                segments.append("Last event: \(lastEvent)")
            }
        }
        return segments.isEmpty ? "Analysis failed." : segments.joined(separator: "\n")
    }

    func addLibraryRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let path = panel.url?.path {
            addLibraryRoots([path])
        }
    }

    func removeLibraryRoot(_ path: String) {
        libraryRoots.removeAll(where: { $0 == path })
        persistLibraryRoots()
    }

    func chooseInitialSetupLibraryRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            initialSetupLibraryRoot = TrackPathNormalizer.normalizedAbsolutePath(url)
        }
    }

    func clearInitialSetupLibraryRoot() {
        initialSetupLibraryRoot = ""
    }

    func dismissInitialSetup() {
        guard !isRunningInitialSetup else { return }
        initialSetupStatusMessage = ""
        isShowingInitialSetupSheet = false
    }

    func openInitialSetup() {
        initialSetupStatusMessage = ""
        if initialSetupLibraryRoot.isEmpty, let existingRoot = libraryRoots.first {
            initialSetupLibraryRoot = existingRoot
        }

        Task {
            await detectLibrarySources()
            isShowingInitialSetupSheet = true
        }
    }

    func completeInitialSetup() {
        let hasFallbackFolder = !initialSetupLibraryRoot.isEmpty
        let shouldRunLibrarySetup = hasFallbackFolder || !libraryRoots.isEmpty

        guard !initialSetupNeedsGoogleAIAPIKey else {
            initialSetupStatusMessage = "Enter your Google AI API Key to continue."
            validationStatus = .failed("Enter a Google AI API Key first.")
            return
        }

        guard !initialSetupRequiresLibrarySelection || shouldRunLibrarySetup else {
            initialSetupStatusMessage = "Choose a Music Folder first."
            return
        }

        isRunningInitialSetup = true
        initialSetupStatusMessage = validationStatus.isValidated
            ? "Finishing setup..."
            : "Validating \(embeddingProfile.displayName)..."

        Task {
            let validated = await validateInitialSetupEmbeddingProfileIfNeeded()
            guard validated else {
                isRunningInitialSetup = false
                if initialSetupStatusMessage.isEmpty {
                    initialSetupStatusMessage = settingsStatusMessage.isEmpty
                        ? validationStatus.summaryText
                        : settingsStatusMessage
                }
                return
            }

            guard shouldRunLibrarySetup else {
                initialSetupStatusMessage = "Setup complete."
                isRunningInitialSetup = false
                isShowingInitialSetupSheet = false
                return
            }

            if hasFallbackFolder {
                addLibraryRoots([initialSetupLibraryRoot])
            }
            selectedSection = .library
            initialSetupStatusMessage = "Scanning Music Folders..."
            await detectLibrarySources()

            do {
                let roots = libraryRoots.map { URL(fileURLWithPath: $0, isDirectory: true) }
                if !roots.isEmpty {
                    markFallbackSourceSyncing(rootPath: roots.first?.path)
                }
                let fallbackSummary = await Self.runFallbackScanInternal(
                    scanner: scanner,
                    roots: roots
                ) { progress in
                    Task { @MainActor [weak self, progress] in
                        self?.scanProgress = progress
                    }
                }
                if !roots.isEmpty {
                    var folderFallbackSource = librarySources.first(where: { $0.kind == .folderFallback }) ?? .default(for: .folderFallback)
                    folderFallbackSource.enabled = true
                    folderFallbackSource.resolvedPath = roots.first?.path
                    folderFallbackSource.lastSyncAt = Date()
                    folderFallbackSource.status = .available
                    folderFallbackSource.lastError = nil
                    persistLibrarySource(folderFallbackSource)
                }
                await refreshTracks()

                let enabledNativeSources = librarySources.filter {
                    $0.kind != .folderFallback && $0.enabled && $0.resolvedPath != nil
                }
                let canRefreshVendorMetadata = !tracks.isEmpty
                if !enabledNativeSources.isEmpty {
                    markLibrarySourcesSyncing(enabledNativeSources)
                }
                let nativeSummary = canRefreshVendorMetadata
                    ? try await Self.syncLibrariesInternal(
                        service: librarySyncService,
                        sources: enabledNativeSources
                    ) { progress in
                        Task { @MainActor [weak self, progress] in
                            self?.scanProgress = progress
                        }
                    }
                    : "Vendor metadata refresh skipped because no scanned local tracks are available yet."
                if !enabledNativeSources.isEmpty {
                    let now = Date()
                    for source in enabledNativeSources {
                        var updatedSource = source
                        updatedSource.lastSyncAt = now
                        updatedSource.status = .available
                        updatedSource.lastError = nil
                        persistLibrarySource(updatedSource)
                    }
                }
                LibraryRootsStore.markInitialSetupCompleted()
                initialSetupStatusMessage = [
                    "Initial library setup finished.",
                    nativeSummary,
                    fallbackSummary,
                    "Indexed \(tracks.count) tracks."
                ]
                .compactMap { item in
                    guard let item, !item.isEmpty else { return nil }
                    return item
                }
                .joined(separator: " ")
                isRunningInitialSetup = false
                isShowingInitialSetupSheet = false
                selectedSection = .library
            } catch {
                isRunningInitialSetup = false
                initialSetupStatusMessage = "Setup failed: \(error.localizedDescription)"
                AppLogger.shared.error("Initial setup failed: \(error.localizedDescription)")
            }
        }
    }

    func refreshLibrarySourceDetection() {
        Task {
            await detectLibrarySources()
        }
    }

    func setLibrarySourceEnabled(_ kind: LibrarySourceKind, enabled: Bool) {
        guard var source = librarySources.first(where: { $0.kind == kind }) else { return }
        if kind != .folderFallback, source.resolvedPath == nil, enabled {
            libraryStatusMessage = "\(kind.displayName) was not detected on this Mac."
            return
        }

        source.enabled = enabled
        source.status = source.resolvedPath == nil ? .missing : (enabled ? .available : .disabled)
        source.lastError = nil
        persistLibrarySource(source)
    }

    func syncLibraries() {
        refreshVendorMetadata()
    }

    func refreshVendorMetadata() {
        preparationNotice = nil
        revealLibraryPreparationPane()
        guard librarySyncPresentationState?.phase != .running else { return }

        guard !tracks.isEmpty else {
            publishNoSyncSourceNotice(
                "Scan Music Folders before refreshing vendor metadata."
            )
            return
        }

        let enabledNativeSources = librarySources.filter {
            $0.kind != .folderFallback && $0.enabled && $0.resolvedPath != nil
        }
        guard !enabledNativeSources.isEmpty else {
            publishNoSyncSourceNotice(
                "Enable Serato or rekordbox metadata sources in Settings before refreshing vendor metadata."
            )
            return
        }

        let sourceNames = enabledNativeSources.map(\.kind.displayName)
        AppLogger.shared.info("Vendor metadata refresh started | sources=\(sourceNames.joined(separator: ","))")
        presentLibrarySyncSheet(
            title: "Refreshing Vendor Metadata",
            actionVerb: "Refreshing vendor metadata for",
            sourceNames: sourceNames
        )
        markLibrarySourcesSyncing(enabledNativeSources)
        let progressHandler: @Sendable (ScanJobProgress) -> Void = { [weak self, sourceNames] progress in
            Task { @MainActor [weak self, progress, sourceNames] in
                self?.updateLibrarySyncProgress(
                    progress,
                    title: "Refreshing Vendor Metadata",
                    actionVerb: "Refreshing vendor metadata for",
                    sourceNames: sourceNames
                )
            }
        }

        let service = librarySyncService
        DispatchQueue.global(qos: .userInitiated).async { [weak self, enabledNativeSources, service] in
            Task {
                do {
                    let summary = try await Self.syncLibrariesInternal(
                        service: service,
                        sources: enabledNativeSources,
                        onProgress: progressHandler
                    )
                    await self?.completeNativeLibrarySync(
                        summary: summary ?? "No vendor metadata sources were refreshed.",
                        sources: enabledNativeSources
                    )
                } catch {
                    await self?.failNativeLibrarySync(error, sources: enabledNativeSources)
                }
            }
        }
    }

    func runFallbackScan() {
        scanMusicFolders()
    }

    func scanMusicFolders() {
        preparationNotice = nil
        revealLibraryPreparationPane()
        guard librarySyncPresentationState?.phase != .running else { return }

        let roots = libraryRoots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard !roots.isEmpty else {
            publishNoSyncSourceNotice(
                "Choose a Music Folder in Settings before scanning."
            )
            return
        }

        let sourceNames = [LibrarySourceKind.folderFallback.displayName]
        AppLogger.shared.info(
            "Fallback scan started | rootCount=\(roots.count) | roots=\(roots.map(\.path).joined(separator: ","))"
        )
        presentLibrarySyncSheet(
            title: "Scanning Music Folders",
            actionVerb: "Scanning",
            sourceNames: sourceNames
        )
        markFallbackSourceSyncing(rootPath: roots.first?.path)
        let progressHandler: @Sendable (ScanJobProgress) -> Void = { [weak self, sourceNames] progress in
            Task { @MainActor [weak self, progress, sourceNames] in
                self?.updateLibrarySyncProgress(
                    progress,
                    title: "Scanning Music Folders",
                    actionVerb: "Scanning",
                    sourceNames: sourceNames
                )
            }
        }

        let scanner = self.scanner
        DispatchQueue.global(qos: .userInitiated).async { [weak self, roots, scanner] in
            Task {
                let summary = await Self.runFallbackScanInternal(scanner: scanner, roots: roots, onProgress: progressHandler)
                await self?.completeFallbackScan(summary: summary ?? "Scanned Music Folders.")
            }
        }
    }

    func preparationActionTitle(_ action: PreparationOverviewAction) -> String {
        switch action {
        case .prepareSelection:
            return selectionReadiness.selectedCount == 1 ? "Prepare Track" : "Prepare Selection"
        case .prepareVisible:
            return "Prepare Visible"
        case .syncLibrary:
            return "Scan Music Folders"
        }
    }

    func performPreparationAction(_ action: PreparationOverviewAction) {
        switch action {
        case .prepareSelection:
            analyzePendingSelection()
        case .prepareVisible:
            analyzeVisibleUnpreparedTracks()
        case .syncLibrary:
            syncLibraryFromOverview()
        }
    }

    private func syncLibraryFromOverview() {
        let hasEnabledFallbackSource = librarySources.contains {
            $0.kind == .folderFallback && $0.enabled && $0.resolvedPath != nil
        }

        if hasEnabledFallbackSource {
            scanMusicFolders()
            return
        }

        let hasEnabledNativeSource = librarySources.contains {
            $0.kind != .folderFallback && $0.enabled && $0.resolvedPath != nil
        }

        if hasEnabledNativeSource {
            refreshVendorMetadata()
            return
        }

        publishNoSyncSourceNotice(
            "Choose a Music Folder, or enable Serato/rekordbox metadata sources in Settings."
        )
    }

    func choosePythonExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            pythonExecutablePath = url.path
        }
    }

    func chooseWorkerScript() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            workerScriptPath = url.path
        }
    }

    func useDetectedAnalysisDefaults() {
        if let detectedPython = AppSettingsStore.detectedPythonExecutablePath() {
            pythonExecutablePath = detectedPython
        }
        if let detectedScript = AppSettingsStore.detectedWorkerScriptPath() {
            workerScriptPath = detectedScript
        }
        settingsStatusMessage = "Detected local worker defaults."
    }

    func saveAnalysisSettings() {
        do {
            let savedKeyBefore = AppSettingsStore.loadGoogleAIAPIKey()
            let savedProfileBefore = AppSettingsStore.loadEmbeddingProfile()
            try persistAnalysisSettings()
            if savedKeyBefore.trimmingCharacters(in: .whitespacesAndNewlines) != googleAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                || savedProfileBefore.id != embeddingProfile.id
            {
                AppSettingsStore.clearValidationMetadata()
                validationStatus = .unvalidated
                invalidateGeneratedRecommendationResults()
            }
            settingsStatusMessage = "Analysis settings saved."
            scheduleWorkerHealthRefresh()
        } catch {
            settingsStatusMessage = "Failed to save settings: \(error.localizedDescription)"
            AppLogger.shared.error("Settings save failed: \(error.localizedDescription)")
        }
    }

    func validateEmbeddingProfile() {
        startRuntimeValidation(userInitiated: true)
    }

    func runScan() {
        runFallbackScan()
    }

    func openMixAssistant(mode: MixAssistantMode) {
        mixAssistantMode = mode
        selectedSection = .mixAssistant
    }

    @discardableResult
    func prepareRecommendationSearchFromLibrary() -> LibraryRecommendationSearchEntryAction {
        guard canOpenRecommendationSearchFromLibrary else { return .navigateOnly }

        let action = recommendationSearchEntryActionFromLibrary()
        openMixAssistant(mode: .buildMixset)
        clearRecommendationQueryTextForLibraryEntry(preservingGeneratedResults: action == .reuseExistingResults)
        return action
    }

    func openRecommendationSearchFromLibrary() {
        guard canOpenRecommendationSearchFromLibrary else { return }

        switch prepareRecommendationSearchFromLibrary() {
        case .navigateOnly, .reuseExistingResults:
            return
        case .autoGenerate:
            generateRecommendations(trigger: .librarySelection)
        }
    }

    func handleLibrarySetupPromptAction() {
        if libraryRoots.isEmpty {
            openInitialSetup()
        } else {
            runScan()
        }
    }

    func resetMixsetScoringControls() {
        weights = .defaults
        vectorWeights = .defaults
        constraints = .defaults
    }

    func analyzeSelectedTracksFromLibrary() {
        analysisScope = .selectedTrack
        requestAnalysis()
    }

    func analyzePendingSelection() {
        guard preparationBlockedMessage == nil else {
            analysisErrorMessage = preparationBlockedMessage ?? "The current analysis setup is unavailable."
            return
        }
        let targets = selectedTracks.filter { trackWorkflowStatus(for: $0) != .ready }
        guard !targets.isEmpty else {
            analysisQueueProgressText = "Everything in the current selection is already ready."
            return
        }
        analysisScope = .selectedTrack
        startAnalysis(for: targets)
    }

    func reviewSelectedTracks() {
        libraryTrackFilter = .all
        selectedSection = .library
    }

    func selectTrackFromLibrary(_ trackID: UUID) {
        updateSelectedTrackIDs([trackID], deferSideEffects: true)
    }

    func setRecommendationSelectedForCuration(_ trackID: UUID, isSelected: Bool) {
        if isSelected {
            curationSelectionTrackIDs.insert(trackID)
        } else {
            curationSelectionTrackIDs.remove(trackID)
        }
    }

    func isRecommendationSelectedForCuration(_ trackID: UUID) -> Bool {
        curationSelectionTrackIDs.contains(trackID)
    }

    func removeSelectedGeneratedRecommendations() {
        guard !curationSelectionTrackIDs.isEmpty else { return }
        excludedGeneratedTrackIDs.formUnion(curationSelectionTrackIDs)
        let removedCount = curationSelectionTrackIDs.count
        curationSelectionTrackIDs.removeAll()
        refreshVisibleRecommendations()
        recommendationStatusMessage = "Hidden \(removedCount) generated matches from the current build pool."
    }

    func restoreGeneratedRecommendations() {
        guard !excludedGeneratedTrackIDs.isEmpty else { return }
        let restoredCount = excludedGeneratedTrackIDs.count
        excludedGeneratedTrackIDs.removeAll()
        curationSelectionTrackIDs.removeAll()
        refreshVisibleRecommendations()
        recommendationStatusMessage = "Restored \(restoredCount) hidden generated matches."
    }

    func applyGeneratedRecommendationsForTesting(_ candidates: [RecommendationCandidate]) {
        replaceGeneratedRecommendations(candidates)
    }

    func configureRecommendationSearchStateForTesting(
        tracks: [Track],
        selectedTrackIDs: Set<UUID>,
        readyTrackIDs: Set<UUID>,
        validationStatus: ValidationStatus,
        recommendationQueryText: String = "",
        recommendationStatusMessage: String = "",
        generatedRecommendations: [RecommendationCandidate] = []
    ) {
        self.tracks = tracks
        self.selectedTrackIDs = selectedTrackIDs
        self.readyTrackIDs = readyTrackIDs
        self.validationStatus = validationStatus
        workerProfileStatuses = [:]
        selectedSection = .library
        mixAssistantMode = .buildMixset
        recommendationGenerationStub = nil
        isGeneratingRecommendations = false
        isBuildingPlaylist = false
        playlistBuildProgress = nil
        excludedGeneratedTrackIDs.removeAll()
        curationSelectionTrackIDs.removeAll()
        selectedRecommendationID = nil
        recommendations = []
        self.generatedRecommendations = []
        self.recommendationStatusMessage = ""
        self.recommendationQueryText = recommendationQueryText
        if !generatedRecommendations.isEmpty {
            replaceGeneratedRecommendations(generatedRecommendations)
        }
        self.recommendationStatusMessage = recommendationStatusMessage
    }

    func setRecommendationGenerationStubForTesting(
        results: [RecommendationCandidate],
        delayNanoseconds: UInt64 = 0,
        completionStatusMessage: String? = nil
    ) {
        recommendationGenerationStub = RecommendationGenerationStub(
            results: results,
            delayNanoseconds: delayNanoseconds,
            completionStatusMessage: completionStatusMessage
        )
    }

    func clearRecommendationGenerationStubForTesting() {
        recommendationGenerationStub = nil
    }

    func dismissPreparationNotice() {
        preparationNotice = nil
    }

    var isLibrarySyncSheetPresented: Bool {
        librarySyncPresentationState?.isPresented == true
    }

    func dismissLibrarySyncSheetIfPossible() {
        guard let state = librarySyncPresentationState, state.phase != .running else { return }
        librarySyncDismissTask?.cancel()
        librarySyncDismissTask = nil
        librarySyncPresentationState = nil
    }

    private func revealLibraryPreparationPane() {
        selectedSection = .library
    }

    private func publishNoSyncSourceNotice(_ message: String) {
        dismissLibrarySyncSheetIfPossible()
        scanProgress = ScanJobProgress()
        libraryStatusMessage = message
        preparationNotice = PreparationNotice(kind: .failed, message: message)
        AppLogger.shared.info("Library sync skipped | reason=no_enabled_sources")
    }

    func presentLibrarySyncSheet(title: String, actionVerb: String, sourceNames: [String]) {
        var progress = ScanJobProgress()
        progress.isRunning = true
        scanProgress = progress
        librarySyncPresentationState = LibrarySyncPresentationState(
            isPresented: true,
            phase: .running,
            title: title,
            message: runningLibrarySyncMessage(actionVerb: actionVerb, sourceNames: sourceNames, currentFile: ""),
            progress: nil,
            isIndeterminate: true,
            sourceNames: sourceNames,
            startedAt: Date(),
            result: nil,
            currentFile: "",
            stats: progress
        )
    }

    private func updateLibrarySyncProgress(
        _ progress: ScanJobProgress,
        title: String,
        actionVerb: String,
        sourceNames: [String]
    ) {
        scanProgress = progress
        guard var state = librarySyncPresentationState else { return }
        state.phase = .running
        state.title = title
        state.sourceNames = sourceNames
        state.currentFile = progress.currentFile
        state.stats = progress
        state.progress = progress.totalFiles > 0
            ? Double(progress.scannedFiles) / Double(max(progress.totalFiles, 1))
            : nil
        state.isIndeterminate = progress.totalFiles == 0
        state.message = runningLibrarySyncMessage(
            actionVerb: actionVerb,
            sourceNames: sourceNames,
            currentFile: progress.currentFile
        )
        librarySyncPresentationState = state
    }

    private func completeNativeLibrarySync(summary: String, sources: [LibrarySourceRecord]) async {
        let now = Date()
        for source in sources {
            var updatedSource = source
            updatedSource.lastSyncAt = now
            updatedSource.status = .available
            updatedSource.lastError = nil
            persistLibrarySource(updatedSource)
        }
        AppLogger.shared.info("Library sync completed | summary=\(summary)")
        finishSuccessfulLibrarySync(summary: summary)
        await refreshTracks()
        revealPostSyncPreparationState()
    }

    private func failNativeLibrarySync(_ error: Error, sources: [LibrarySourceRecord]) async {
        for source in sources {
            var failedSource = source
            failedSource.status = .error
            failedSource.lastError = error.localizedDescription
            persistLibrarySource(failedSource)
        }

        var progress = scanProgress
        progress.isRunning = false
        progress.currentFile = ""
        scanProgress = progress

        let message = "Library sync failed: \(error.localizedDescription)"
        libraryStatusMessage = message
        preparationNotice = PreparationNotice(
            kind: .failed,
            message: "Library sync could not finish. Check Settings or the logs for details."
        )
        AppLogger.shared.error(message)
        presentFailedLibrarySyncSheet(message: message)
    }

    private func completeFallbackScan(summary: String) async {
        var folderFallbackSource = librarySources.first(where: { $0.kind == .folderFallback }) ?? .default(for: .folderFallback)
        folderFallbackSource.enabled = true
        folderFallbackSource.resolvedPath = libraryRoots.first
        folderFallbackSource.lastSyncAt = Date()
        folderFallbackSource.status = .available
        folderFallbackSource.lastError = nil
        persistLibrarySource(folderFallbackSource)
        AppLogger.shared.info(
            "Fallback scan completed | summary=\(summary) | scanned=\(scanProgress.scannedFiles) | indexed=\(scanProgress.indexedFiles) | skipped=\(scanProgress.skippedFiles) | duplicates=\(scanProgress.duplicateFiles)"
        )
        finishSuccessfulLibrarySync(summary: summary)
        await refreshTracks()
        revealPostSyncPreparationState()
    }

    private func presentFailedLibrarySyncSheet(message: String) {
        guard var state = librarySyncPresentationState else {
            librarySyncPresentationState = LibrarySyncPresentationState(
                isPresented: true,
                phase: .failed,
                title: "Sync Failed",
                message: message,
                progress: nil,
                isIndeterminate: false,
                sourceNames: [],
                startedAt: Date(),
                result: nil,
                currentFile: "",
                stats: scanProgress
            )
            return
        }

        state.phase = .failed
        state.title = "Sync Failed"
        state.message = message
        state.result = nil
        state.progress = nil
        state.isIndeterminate = false
        state.stats = scanProgress
        librarySyncPresentationState = state
    }

    func finishSuccessfulLibrarySync(summary: String) {
        var progress = scanProgress
        progress.isRunning = false
        progress.currentFile = ""
        scanProgress = progress
        libraryStatusMessage = summary
        preparationNotice = nil
        librarySyncDismissTask?.cancel()
        librarySyncDismissTask = nil
        librarySyncPresentationState = nil
    }

    private func revealPostSyncPreparationState() {
        revealLibraryPreparationPane()
        guard tracks.contains(where: { trackWorkflowStatus(for: $0) != .ready }) else { return }
        libraryTrackFilter = .needsPreparation
    }

    private func markLibrarySourcesSyncing(_ sources: [LibrarySourceRecord]) {
        for source in sources {
            var syncingSource = source
            syncingSource.status = .syncing
            syncingSource.lastError = nil
            persistLibrarySource(syncingSource)
        }
    }

    private func markFallbackSourceSyncing(rootPath: String?) {
        var folderFallbackSource = librarySources.first(where: { $0.kind == .folderFallback }) ?? .default(for: .folderFallback)
        folderFallbackSource.enabled = true
        folderFallbackSource.resolvedPath = rootPath
        folderFallbackSource.status = .syncing
        folderFallbackSource.lastError = nil
        persistLibrarySource(folderFallbackSource)
    }

    private func runningLibrarySyncMessage(
        actionVerb: String,
        sourceNames: [String],
        currentFile: String
    ) -> String {
        let summary = sourceNames.isEmpty ? "library sources" : sourceNames.joined(separator: ", ")
        guard !currentFile.isEmpty else {
            return "\(actionVerb) \(summary)."
        }
        return "\(actionVerb) \(summary). Current: \(currentFile)"
    }

    func openScopeInspector(for target: ScopeFilterTarget) {
        guard allowsScopeInspector(for: target, in: selectedSection) else { return }
        if isScopeInspectorPresented, activeScopeInspectorTarget == target {
            closeScopeInspector()
            return
        }
        activeScopeInspectorTarget = target
        isScopeInspectorPresented = true
    }

    func closeScopeInspector() {
        isScopeInspectorPresented = false
        activeScopeInspectorTarget = nil
    }

    func selectedFacetCount(for target: ScopeFilterTarget) -> Int {
        scopeFilter(for: target).selectedFacetCount
    }

    func scopeSummary(for target: ScopeFilterTarget) -> String {
        Self.scopeSummary(
            target: target,
            filter: scopeFilter(for: target),
            statistics: scopeStatistics(for: target)
        )
    }

    func selectedScopeChipLabels(for target: ScopeFilterTarget, limit: Int? = nil) -> [String] {
        let filter = scopeFilter(for: target)
        let labels = filter.seratoMembershipPaths.map { membershipChipLabel(for: $0, source: .serato) }
            + filter.rekordboxMembershipPaths.map { membershipChipLabel(for: $0, source: .rekordbox) }
        if let limit {
            return Array(labels.prefix(limit))
        }
        return labels
    }

    static func scopeSummary(
        target: ScopeFilterTarget,
        filter: LibraryScopeFilter,
        statistics: ScopedTrackStatistics
    ) -> String {
        if filter.isEmpty {
            switch target {
            case .library:
                return "All scanned local tracks"
            case .search, .recommendation:
                return "All ready local tracks"
            }
        }

        let filterLabel = filter.selectedFacetCount == 1 ? "reference" : "references"
        return "\(filter.selectedFacetCount) \(filterLabel) • \(statistics.total) tracks in scope"
    }

    func copyLibraryScope(to target: ScopeFilterTarget) {
        switch target {
        case .library:
            return
        case .search, .recommendation:
            recommendationScopeFilter = libraryScopeFilter
        }
    }

    func clearScope(for target: ScopeFilterTarget) {
        switch target {
        case .library:
            libraryScopeFilter = LibraryScopeFilter()
        case .search, .recommendation:
            recommendationScopeFilter = LibraryScopeFilter()
        }
    }

    func setMembershipSelection(
        _ isSelected: Bool,
        membershipPath: String,
        source: ExternalDJMetadata.Source,
        target: ScopeFilterTarget
    ) {
        var filter = scopeFilter(for: target)
        var values = Set(filter.selectedPaths(for: source))
        if isSelected {
            values.insert(membershipPath)
        } else {
            values.remove(membershipPath)
        }
        filter.setSelectedPaths(Array(values), for: source)
        applyScopeFilter(filter, to: target)
    }

    private func membershipChipLabel(for membershipPath: String, source: ExternalDJMetadata.Source) -> String {
        let displayName = membershipFacets(for: source)
            .first(where: { $0.membershipPath == membershipPath })?
            .displayName
            ?? membershipPath
                .split(separator: "/")
                .last
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            ?? membershipPath
        let sourceName = source == .serato ? "Serato" : "rekordbox"
        return "\(sourceName): \(displayName)"
    }

    private func allowsScopeInspector(
        for target: ScopeFilterTarget?,
        in section: SidebarSection
    ) -> Bool {
        guard let target else { return false }
        switch section {
        case .library:
            return target == .library
        case .mixAssistant:
            return target == .recommendation
        case .exports, .settings:
            return false
        }
    }

    func selectVisibleTracks() {
        updateSelectedTrackIDs(Set(filteredTracks.map(\.id)))
    }

    func analyzeVisibleUnpreparedTracks() {
        guard preparationBlockedMessage == nil else {
            analysisErrorMessage = preparationBlockedMessage ?? "The current analysis setup is unavailable."
            return
        }
        let targets = filteredTracks.filter { trackWorkflowStatus(for: $0) != .ready }
        guard !targets.isEmpty else {
            analysisQueueProgressText = "Everything visible in the current library scope is already ready."
            return
        }
        analysisScope = .selectedTrack
        startAnalysis(for: targets)
    }

    func analyzeScopedTracks(for target: ScopeFilterTarget) {
        guard preparationBlockedMessage == nil else {
            let message = preparationBlockedMessage ?? "The current analysis setup is unavailable."
            switch target {
            case .library:
                analysisErrorMessage = message
            case .search, .recommendation:
                recommendationStatusMessage = message
            }
            return
        }
        let scopeFilter = scopeFilter(for: target)
        let scopedTracks = tracksMatchingScope(scopeFilter).filter { trackWorkflowStatus(for: $0) != .ready }
        guard !scopedTracks.isEmpty else {
            switch target {
            case .library:
                analysisQueueProgressText = "No tracks in the current library scope need preparation."
            case .search, .recommendation:
                recommendationStatusMessage = "No tracks in the current mix scope need preparation."
            }
            return
        }
        analysisScope = .selectedTrack
        startAnalysis(for: scopedTracks)
    }

    private func requestAnalysisTargets() -> [Track] {
        analysisScope.resolveTracks(
            from: tracks,
            selectedTrackIDs: selectedTrackIDs,
            readyTrackIDs: readyTrackIDs,
            activeProfileID: embeddingProfile.id
        )
    }

    func requestAnalysis() {
        preparationNotice = nil
        guard isSelectedEmbeddingProfileSupported else {
            analysisErrorMessage = selectedEmbeddingProfileDependencyMessage ?? "The current analysis setup is unavailable."
            return
        }
        guard preparationBlockedMessage == nil else {
            analysisErrorMessage = preparationBlockedMessage ?? "The current analysis setup is unavailable."
            return
        }
        if isAnalyzing {
            analysisErrorMessage = "Analysis is running. Cancel it first."
            return
        }

        let targets = requestAnalysisTargets()
        guard !targets.isEmpty else {
            analysisQueueProgressText = "No tracks match the selected analysis scope."
            return
        }

        if analysisScope == .allIndexedTracks {
            pendingAnalyzeAllTrackIDs = targets.map(\.id)
            analyzeAllConfirmationMessage =
                "Prepare \(targets.count) indexed tracks for the current similarity setup? " +
                "Estimated vector updates: up to \(targets.count * 4)."
            isShowingAnalyzeAllConfirmation = true
            return
        }

        startAnalysis(for: targets)
    }

    func confirmAnalyzeAllTracks() {
        let targets = tracks.filter { pendingAnalyzeAllTrackIDs.contains($0.id) }
        pendingAnalyzeAllTrackIDs = []
        isShowingAnalyzeAllConfirmation = false
        startAnalysis(for: targets)
    }

    private func startAnalysis(for targets: [Track]) {
        guard !targets.isEmpty else {
            analysisQueueProgressText = "No tracks are ready to analyze."
            return
        }

        preparationNotice = nil
        pendingAnalysisTrackIDs = targets.map(\.id)
        for trackID in pendingAnalysisTrackIDs {
            updateAnalysisState(trackID: trackID, state: .queued, message: "Queued")
        }
        analysisSessionProgress = .queued(totalCount: targets.count, latestTrackTitle: targets.first?.title ?? "")
        refreshAnalysisQueueText()
        analysisTask?.cancel()
        analysisTask = Task {
            await analyzeTracks(targets, mode: .batch)
        }
    }

    func cancelAnalyzeAllTracks() {
        pendingAnalyzeAllTrackIDs = []
        isShowingAnalyzeAllConfirmation = false
        cancelAnalysis()
    }

    func cancelAnalysis() {
        guard isAnalyzing, !isCancellingAnalysis else { return }
        preparationNotice = nil
        analysisErrorMessage = ""
        isCancellingAnalysis = true
        analysisTask?.cancel()
        cancelAllAnalysisProgressWatchdogs()

        if analysisTask == nil {
            finalizeAnalysisSession(result: .canceled)
        }
    }

    func finalizeAnalysisSession(result: AnalysisSessionResult) {
        let pendingTrackIDs = pendingAnalysisTrackIDs

        cancelAllAnalysisProgressWatchdogs()
        isAnalyzing = false
        isCancellingAnalysis = false
        analysisTask = nil

        switch result {
        case .succeeded:
            analysisErrorMessage = ""
            preparationNotice = nil
        case .canceled:
            analysisErrorMessage = ""
            preparationNotice = PreparationNotice(kind: .canceled, message: "Preparation was canceled.")
            for trackID in pendingTrackIDs {
                let currentState = analysisStateByTrackID[trackID]?.state
                if currentState == .queued || currentState == .running {
                    updateAnalysisState(trackID: trackID, state: .canceled, message: "Canceled")
                    analysisProgressFractionByTrackID[trackID] = 1
                }
            }
            if let activity = analysisActivity, !activity.isFinished {
                var updatedActivity = activity
                updatedActivity.markFinished(state: AnalysisTaskState.canceled, message: "Canceled by user")
                analysisActivity = updatedActivity
            }
        case let .failed(message):
            let failureMessage = Self.friendlyPreparationMessage(from: message) ?? "Preparation needs attention."
            analysisErrorMessage = ""
            preparationNotice = PreparationNotice(kind: .failed, message: failureMessage)
            if let activity = analysisActivity, !activity.isFinished {
                var updatedActivity = activity
                updatedActivity.markFinished(
                    state: AnalysisTaskState.failed,
                    errorMessage: failureMessage,
                    message: "Failed \(activity.currentTrackTitle)"
                )
                analysisActivity = updatedActivity
            }
        }

        refreshAnalysisSessionProgress(
            latestTrackTitle: analysisActivity?.currentTrackTitle,
            latestMessage: analysisActivity?.currentMessage
        )
        pendingAnalysisTrackIDs = []
        analysisSessionProgress = nil
        analysisActivitiesByTrackID.removeAll()
        analysisProgressFractionByTrackID.removeAll()
        if analysisActivity == nil {
            analysisQueueProgressText = ""
        } else {
            refreshAnalysisQueueText()
        }
    }

    func generateRecommendations(limit: Int? = nil, trigger: RecommendationGenerationTrigger = .manual) {
        guard !isBuildingPlaylist else {
            recommendationStatusMessage = "Wait for the current playlist build to finish."
            return
        }
        guard !isGeneratingRecommendations else {
            recommendationStatusMessage = "Recommendation search is already running."
            return
        }
        guard isSelectedEmbeddingProfileSupported else {
            recommendationStatusMessage = selectedEmbeddingProfileDependencyMessage ?? "The current analysis setup is unavailable."
            return
        }
        guard hasValidatedEmbeddingProfile else {
            recommendationStatusMessage = "Validate the current analysis setup first."
            return
        }
        let effectiveLimit = RecommendationInputState.clampedResultLimit(limit ?? recommendationResultLimit)
        guard let input = resolveRecommendationInput() else {
            recommendationStatusMessage = recommendationInputValidationMessage()
            return
        }

        isGeneratingRecommendations = true
        recommendationStatusMessage = trigger.inProgressMessage

        Task {
            defer {
                isGeneratingRecommendations = false
            }

            do {
                if let stub = recommendationGenerationStub {
                    if stub.delayNanoseconds > 0 {
                        try await Task.sleep(nanoseconds: stub.delayNanoseconds)
                    }
                    replaceGeneratedRecommendations(stub.results)
                    recommendationStatusMessage = stub.completionStatusMessage
                        ?? recommendationGenerationCompletionMessage(
                            resultCount: stub.results.count,
                            inputState: input.state
                        )
                    return
                }

                let embeddingsByTrackID = try loadTrackEmbeddings()
                let summariesByTrackID = try loadAnalysisSummaries(trackIDs: Array(readyTrackIDs))
                let excludedReferenceTrackIDs = Set(input.readyReferenceTracks.map(\.id))
                let seedContext = try await resolveRecommendationSeedContext(
                    input: input,
                    embeddingsByTrackID: embeddingsByTrackID,
                    summariesByTrackID: summariesByTrackID,
                    limit: max(effectiveLimit, 25),
                    excludedPaths: Set(playlistTracks.map(\.filePath))
                )
                let recs = recommendationEngine.recommendNextTracks(
                    seed: seedContext.seed,
                    candidates: tracks.filter { readyTrackIDs.contains($0.id) },
                    embeddingsByTrackID: embeddingsByTrackID,
                    summariesByTrackID: summariesByTrackID,
                    vectorSimilarityByPath: seedContext.similarityMap,
                    vectorBreakdownByPath: seedContext.vectorBreakdownByPath,
                    libraryRoots: libraryRoots,
                    constraints: constraints,
                    weights: weights,
                    vectorWeights: vectorWeights,
                    limit: effectiveLimit,
                    excludeTrackIDs: Set(playlistTracks.map(\.id)).union(excludedReferenceTrackIDs)
                )
                let sessionID = try persistRecommendationSession(
                    kind: .recommendation,
                    queryText: input.state.trimmedQueryText,
                    seedTrackID: seedContext.seed.id,
                    referenceTrackIDs: input.readyReferenceTracks.map(\.id),
                    candidates: recs,
                    candidateCountBeforeScope: seedContext.candidateCountBeforeScope,
                    candidateCountAfterScope: seedContext.candidateCountAfterScope,
                    resultLimit: effectiveLimit
                )
                let generated = recs.map { candidate in
                    let matchedMemberships = membershipSnapshotsByTrackID[candidate.track.id]?
                        .matchedPaths(scopeFilter: recommendationScopeFilter) ?? []
                    return RecommendationCandidate(
                        id: candidate.id,
                        track: candidate.track,
                        score: candidate.score,
                        breakdown: candidate.breakdown,
                        vectorBreakdown: candidate.vectorBreakdown,
                        analysisFocus: candidate.analysisFocus,
                        mixabilityTags: candidate.mixabilityTags,
                        matchReasons: candidate.matchReasons,
                        matchedMemberships: matchedMemberships,
                        scoreSessionID: sessionID
                    )
                }

                replaceGeneratedRecommendations(generated)
                recommendationStatusMessage = recommendationGenerationCompletionMessage(
                    resultCount: generated.count,
                    inputState: input.state,
                    semanticSeedTitle: input.state.requiresSemanticSeed ? seedContext.seed.title : nil
                )
            } catch {
                resetGeneratedRecommendationResults()
                recommendationStatusMessage = "Recommendation failed: \(error.localizedDescription)"
                AppLogger.shared.error("Recommendation failed: \(error.localizedDescription)")
            }
        }
    }

    func buildPlaylistPath() {
        guard !isBuildingPlaylist else {
            recommendationStatusMessage = "A playlist build is already running."
            return
        }
        guard !isGeneratingRecommendations else {
            recommendationStatusMessage = "Wait for the current recommendation search to finish."
            return
        }
        guard isSelectedEmbeddingProfileSupported else {
            recommendationStatusMessage = selectedEmbeddingProfileDependencyMessage ?? "The current analysis setup is unavailable."
            return
        }
        guard hasValidatedEmbeddingProfile else {
            recommendationStatusMessage = "Validate the current analysis setup first."
            return
        }
        guard let input = resolveRecommendationInput() else {
            recommendationStatusMessage = recommendationInputValidationMessage()
            return
        }
        guard hasGeneratedRecommendationResults else {
            recommendationStatusMessage = "Generate matches first to create a curated build pool."
            return
        }

        let curatedPool = recommendations
        guard !curatedPool.isEmpty else {
            recommendationStatusMessage = "All generated matches are hidden. Restore tracks or generate again."
            return
        }

        isBuildingPlaylist = true
        updatePlaylistBuildProgress(
            stage: .resolvingSeed,
            completedCount: 0,
            totalCount: curatedPool.count,
            progress: 0.02,
            currentSeedTitle: input.readyReferenceTracks.first?.title ?? "",
            message: "Resolving the current mix seed."
        )

        Task {
            do {
                let relevantTrackIDs = Set(curatedPool.map(\.track.id)).union(input.readyReferenceTracks.map(\.id))
                let embeddingsByTrackID = try loadTrackEmbeddings(trackIDs: relevantTrackIDs)
                let summariesByTrackID = try loadAnalysisSummaries(trackIDs: Array(relevantTrackIDs))
                let seedContext = try await resolveRecommendationSeedContext(
                    input: input,
                    embeddingsByTrackID: embeddingsByTrackID,
                    summariesByTrackID: summariesByTrackID,
                    limit: max(curatedPool.count, 25),
                    excludedPaths: []
                )
                updatePlaylistBuildProgress(
                    stage: .preparingCuratedPool,
                    completedCount: 0,
                    totalCount: curatedPool.count,
                    progress: 0.10,
                    currentSeedTitle: seedContext.seed.title,
                    message: "Preparing \(curatedPool.count) curated matches for playlist ordering."
                )

                let orderedCandidates = try Self.buildCuratedPlaylistCandidates(
                    seed: seedContext.seed,
                    curatedCandidates: curatedPool,
                    embeddingsByTrackID: embeddingsByTrackID,
                    summariesByTrackID: summariesByTrackID,
                    libraryRoots: libraryRoots,
                    constraints: constraints,
                    weights: weights,
                    vectorWeights: vectorWeights
                ) { [weak self] currentSeed, remainingTracks in
                    guard let self else { return [:] }

                    let completedCount = curatedPool.count - remainingTracks.count
                    let normalizedProgress = 0.12 + (0.76 * Double(completedCount) / Double(max(curatedPool.count, 1)))
                    self.updatePlaylistBuildProgress(
                        stage: .orderingTrack,
                        completedCount: completedCount,
                        totalCount: curatedPool.count,
                        progress: normalizedProgress,
                        currentSeedTitle: currentSeed.title,
                        latestTrackTitle: remainingTracks.first?.title,
                        message: "Evaluating \(remainingTracks.count) remaining curated matches from \(currentSeed.title)."
                    )
                    return try self.curatedVectorBreakdowns(seed: currentSeed, candidates: remainingTracks)
                }

                let orderedTracks = orderedCandidates.map(\.track)
                updatePlaylistBuildProgress(
                    stage: .finalizingQueue,
                    completedCount: orderedTracks.count,
                    totalCount: curatedPool.count,
                    progress: 0.94,
                    currentSeedTitle: seedContext.seed.title,
                    latestTrackTitle: orderedTracks.last?.title,
                    message: "Finalizing the playlist queue from curated matches."
                )

                playlistTracks = orderedTracks
                _ = try persistRecommendationSession(
                    kind: .playlistPath,
                    queryText: input.state.trimmedQueryText,
                    seedTrackID: seedContext.seed.id,
                    referenceTrackIDs: input.readyReferenceTracks.map(\.id),
                    candidates: orderedCandidates,
                    candidateCountBeforeScope: seedContext.candidateCountBeforeScope,
                    candidateCountAfterScope: seedContext.candidateCountAfterScope,
                    resultLimit: curatedPool.count
                )
                isBuildingPlaylist = false
                updatePlaylistBuildProgress(
                    stage: .completed,
                    completedCount: orderedTracks.count,
                    totalCount: curatedPool.count,
                    progress: 1,
                    currentSeedTitle: seedContext.seed.title,
                    latestTrackTitle: orderedTracks.last?.title,
                    message: "Added \(orderedTracks.count) curated tracks to the playlist queue."
                )
                recommendationStatusMessage = Self.playlistPathStatusMessage(
                    builtCount: orderedTracks.count,
                    requestedCount: curatedPool.count,
                    seedTitle: seedContext.seed.title
                )
            } catch {
                let failedTrackTitle = playlistBuildProgress?.latestTrackTitle
                let failedSeedTitle = playlistBuildProgress?.currentSeedTitle ?? ""
                isBuildingPlaylist = false
                updatePlaylistBuildProgress(
                    stage: .failed,
                    completedCount: playlistBuildProgress?.completedCount ?? 0,
                    totalCount: curatedPool.count,
                    progress: playlistBuildProgress?.clampedProgress ?? 0,
                    currentSeedTitle: failedSeedTitle,
                    latestTrackTitle: failedTrackTitle,
                    message: error.localizedDescription
                )
                recommendationStatusMessage = "Playlist path build failed: \(error.localizedDescription)"
                AppLogger.shared.error("Playlist path build failed: \(error.localizedDescription)")
            }
        }
    }

    func appendToPlaylist(_ track: Track) {
        if !playlistTracks.contains(where: { $0.id == track.id }) {
            playlistTracks.append(track)
        }
    }

    func removeFromPlaylist(_ trackID: UUID) {
        playlistTracks.removeAll(where: { $0.id == trackID })
    }

    func clearPlaylist() {
        playlistTracks.removeAll()
    }

    func exportPlaylist() {
        guard !playlistTracks.isEmpty else { return }
        guard isSelectedExportTargetAvailable else {
            exportMessage = "Export failed: \(selectedExportTargetStatusText)"
            exportWarnings = []
            exportDestinationDescription = ""
            return
        }

        let panel = configuredExportSavePanel()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        exportWarnings = []
        exportDestinationDescription = ""

        let playlistName = url.deletingPathExtension().lastPathComponent
        let outputDirectory = selectedExportTarget.requiresExplicitOutputDirectory ? url.deletingLastPathComponent() : nil

        Task {
            do {
                let result = try exporter.export(
                    playlistName: playlistName,
                    tracks: playlistTracks,
                    target: selectedExportTarget,
                    outputDirectory: outputDirectory,
                    librarySources: librarySources
                )
                exportDestinationDescription = result.destinationDescription
                exportWarnings = result.warnings
                exportMessage = "\(result.message): \(result.outputPaths.joined(separator: ", "))"
                refreshDetectedVendorTargets()
            } catch {
                exportMessage = "Export failed: \(error.localizedDescription)"
                exportWarnings = []
                exportDestinationDescription = ""
            }
        }
    }

    private func configuredExportSavePanel() -> NSSavePanel {
        let panel = NSSavePanel()
        panel.title = selectedExportTarget == .seratoCrate ? "Create Serato Crate" : "Export Playlist"
        panel.nameFieldStringValue = "Soria-Recommendation.\(selectedExportTarget.defaultFileExtension)"
        panel.canCreateDirectories = selectedExportTarget.requiresExplicitOutputDirectory
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = false

        if let contentType = UTType(filenameExtension: selectedExportTarget.defaultFileExtension) {
            panel.allowedContentTypes = [contentType]
        }

        switch selectedExportTarget {
        case .rekordboxPlaylistM3U8, .rekordboxLibraryXML:
            panel.message = selectedExportTarget.helperText
        case .seratoCrate:
            if let cratesRoot = detectedVendorTargets.seratoCratesRoot {
                panel.directoryURL = URL(fileURLWithPath: cratesRoot, isDirectory: true)
                    .appendingPathComponent("Subcrates", isDirectory: true)
            }
            panel.message = "Choose the Serato crate name. Soria writes the file directly into the detected _Serato_/Subcrates folder."
        }

        return panel
    }

    func loadExternalMetadata() {
        guard let urls = chooseMetadataFiles(
            allowedContentTypes: [.xml, .commaSeparatedText],
            allowsMultipleSelection: true
        ) else {
            return
        }

        Task {
            do {
                let summaries = try await importExternalMetadataFiles(urls)
                let message = Self.metadataImportStatusMessage(for: summaries)
                libraryStatusMessage = message
                settingsStatusMessage = message
            } catch {
                let message = "Metadata import failed: \(error.localizedDescription)"
                libraryStatusMessage = message
                settingsStatusMessage = message
                AppLogger.shared.error("Metadata import failed: \(error.localizedDescription)")
            }
        }
    }

    func autoImportRekordboxXML() {
        let candidateURL: URL
        if let candidate = externalMetadataImporter.detectRekordboxXMLCandidate() {
            candidateURL = candidate.url
        } else {
            guard let selectedURL = chooseMetadataFiles(
                allowedContentTypes: [.xml],
                allowsMultipleSelection: false
            )?.first else {
                return
            }
            candidateURL = selectedURL
        }

        Task {
            do {
                let summary = try await importExternalMetadataFile(candidateURL)
                let summaryText = Self.metadataImportStatusMessage(for: [summary])
                let message = "Imported Rekordbox XML from \(candidateURL.path). \(summaryText)"
                libraryStatusMessage = message
                settingsStatusMessage = message
            } catch {
                let message = "Metadata import failed: \(error.localizedDescription)"
                libraryStatusMessage = message
                settingsStatusMessage = message
                AppLogger.shared.error("Metadata import failed: \(error.localizedDescription)")
            }
        }
    }

    private func chooseMetadataFiles(
        allowedContentTypes: [UTType],
        allowsMultipleSelection: Bool
    ) -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.allowedContentTypes = allowedContentTypes
        return panel.runModal() == .OK ? panel.urls : nil
    }

    func analyzeSelectedTracksForRecommendations() {
        analyzePendingSelection()
    }

    func refreshTracks() async {
        do {
            tracks = try database.fetchScannedTracks()
            readyTrackIDs = try database.fetchReadyTrackIDs(
                profileID: embeddingProfile.id,
                pipelineID: embeddingProfile.pipelineID,
                requireLocalScan: true
            )
            membershipSnapshotsByTrackID = try database.fetchTrackMembershipSnapshots(trackIDs: tracks.map(\.id))
            scopeTrackCache.removeAll()
            try refreshMembershipFacets()
            let availableIDs = Set(tracks.map(\.id))
            analysisStateByTrackID = analysisStateByTrackID.filter { availableIDs.contains($0.key) }
            let reconciledSelection = resolvedSelection(for: availableIDs)
            if reconciledSelection != selectedTrackIDs {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let currentAvailableIDs = Set(self.tracks.map(\.id))
                    let validSelection = reconciledSelection.intersection(currentAvailableIDs)
                    guard self.selectedTrackIDs != validSelection else { return }
                    self.updateSelectedTrackIDs(validSelection)
                }
            } else {
                await loadSelectedTrackDetails()
            }
        } catch {
            AppLogger.shared.error("Track reload failed: \(error.localizedDescription)")
        }
    }

    func fetchSegments(for trackID: UUID) async -> [TrackSegment] {
        (try? database.fetchSegments(trackID: trackID)) ?? []
    }

    private func analyzeTracks(_ tracksToAnalyze: [Track], mode: AnalysisMode) async {
        guard !tracksToAnalyze.isEmpty else { return }

        isAnalyzing = true
        analysisErrorMessage = ""
        preparationNotice = nil
        prepareAnalysisSession(for: tracksToAnalyze)
        isCancellingAnalysis = false
        let batchStartedAt = Date()
        let workerConfig = currentAnalysisWorkerConfig()
        var sessionResult: AnalysisSessionResult = .succeeded
        defer {
            finalizeAnalysisSession(result: sessionResult)
        }

        let workItems: [AnalysisWorkItem]
        do {
            workItems = try makeAnalysisWorkItems(from: tracksToAnalyze)
        } catch {
            sessionResult = .failed(Self.friendlyPreparationMessage(from: error.localizedDescription) ?? error.localizedDescription)
            return
        }

        let maxConcurrentJobs = analysisConcurrencyProfile.resolvedMaxConcurrentJobs(
            processorCount: ProcessInfo.processInfo.processorCount,
            backendKind: workerConfig.embeddingProfile.backendKind
        )

        let commitActor: AnalysisCommitActor
        do {
            commitActor = try AnalysisCommitActor(databaseURL: database.fileURL, workerConfig: workerConfig)
        } catch {
            sessionResult = .failed(Self.friendlyPreparationMessage(from: error.localizedDescription) ?? error.localizedDescription)
            return
        }

        await withTaskGroup(of: AnalysisWorkerOutcome.self) { group in
            var nextIndex = 0

            @MainActor
            func launch(_ workItem: AnalysisWorkItem) {
                startAnalysisActivity(
                    for: workItem.track,
                    queueIndex: workItem.queueIndex,
                    totalCount: workItem.totalCount,
                    stage: .launching
                )
                updateAnalysisState(
                    trackID: workItem.track.id,
                    state: .running,
                    message: AnalysisStage.launching.displayName
                )
                scheduleAnalysisProgressWatchdog(
                    trackID: workItem.track.id,
                    trackTitle: workItem.track.title,
                    trackPath: workItem.track.filePath,
                    queueIndex: workItem.queueIndex,
                    totalCount: workItem.totalCount
                )
                logAnalysisEvent(
                    "track_started",
                    track: workItem.track,
                    queueIndex: workItem.queueIndex,
                    totalCount: workItem.totalCount,
                    extra: ["mode": "\(mode)"]
                )

                let progressHandler = makeAnalysisProgressHandler(for: workItem)
                group.addTask {
                    await Self.executeAnalysisWorkItem(
                        workItem,
                        workerConfig: workerConfig,
                        progress: progressHandler
                    )
                }
            }

            while nextIndex < min(maxConcurrentJobs, workItems.count) {
                launch(workItems[nextIndex])
                nextIndex += 1
            }

            while let outcome = await group.next() {
                switch outcome {
                case let .succeeded(output):
                    logWorkerCompletion(for: output)
                    markEmbeddingProfileValidatedIfNeeded()
                    do {
                        try await commitActor.commit(output)
                        updateAnalysisState(trackID: output.workItem.track.id, state: .succeeded, message: "Done")
                        cancelAnalysisProgressWatchdog(trackID: output.workItem.track.id)
                        finishAnalysisActivity(
                            state: .succeeded,
                            for: output.workItem.track,
                            queueIndex: output.workItem.queueIndex,
                            totalCount: output.workItem.totalCount
                        )
                        logAnalysisEvent(
                            "track_finished",
                            track: output.workItem.track,
                            queueIndex: output.workItem.queueIndex,
                            totalCount: output.workItem.totalCount,
                            elapsedMs: output.elapsedMs
                        )
                    } catch {
                        let decoratedError = decoratedAnalysisError(error.localizedDescription, trackID: output.workItem.track.id)
                        if Task.isCancelled || Self.isWorkerCancellation(error) {
                            sessionResult = .canceled
                            updateAnalysisState(trackID: output.workItem.track.id, state: .canceled, message: "Canceled")
                            cancelAnalysisProgressWatchdog(trackID: output.workItem.track.id)
                            finishAnalysisActivity(
                                state: .canceled,
                                for: output.workItem.track,
                                queueIndex: output.workItem.queueIndex,
                                totalCount: output.workItem.totalCount
                            )
                            logAnalysisEvent(
                                "track_finished",
                                track: output.workItem.track,
                                queueIndex: output.workItem.queueIndex,
                                totalCount: output.workItem.totalCount,
                                elapsedMs: output.elapsedMs,
                                extra: ["result": "canceled"]
                            )
                        } else {
                            if sessionResult != .canceled {
                                sessionResult = .failed(decoratedError)
                            }
                            updateAnalysisState(
                                trackID: output.workItem.track.id,
                                state: .failed,
                                message: analysisActivitiesByTrackID[output.workItem.track.id]?.stage.displayName ?? "Failed"
                            )
                            finishAnalysisActivity(
                                state: .failed,
                                for: output.workItem.track,
                                queueIndex: output.workItem.queueIndex,
                                totalCount: output.workItem.totalCount,
                                errorMessage: decoratedError
                            )
                            cancelAnalysisProgressWatchdog(trackID: output.workItem.track.id)
                            AppLogger.shared.error("Analyze failed for \(output.workItem.track.filePath): \(decoratedError)")
                            logAnalysisEvent(
                                "track_finished",
                                track: output.workItem.track,
                                queueIndex: output.workItem.queueIndex,
                                totalCount: output.workItem.totalCount,
                                elapsedMs: output.elapsedMs,
                                extra: ["result": "failed"]
                            )
                        }
                    }
                case let .failed(failure):
                    if failure.wasCancelled {
                        sessionResult = .canceled
                        updateAnalysisState(trackID: failure.workItem.track.id, state: .canceled, message: "Canceled")
                        cancelAnalysisProgressWatchdog(trackID: failure.workItem.track.id)
                        finishAnalysisActivity(
                            state: .canceled,
                            for: failure.workItem.track,
                            queueIndex: failure.workItem.queueIndex,
                            totalCount: failure.workItem.totalCount
                        )
                        logAnalysisEvent(
                            "track_finished",
                            track: failure.workItem.track,
                            queueIndex: failure.workItem.queueIndex,
                            totalCount: failure.workItem.totalCount,
                            elapsedMs: failure.elapsedMs,
                            extra: ["result": "canceled"]
                        )
                    } else {
                        let decoratedError = decoratedAnalysisError(failure.errorMessage, trackID: failure.workItem.track.id)
                        if sessionResult != .canceled {
                            sessionResult = .failed(decoratedError)
                        }
                        updateAnalysisState(
                            trackID: failure.workItem.track.id,
                            state: .failed,
                            message: analysisActivitiesByTrackID[failure.workItem.track.id]?.stage.displayName ?? "Failed"
                        )
                        finishAnalysisActivity(
                            state: .failed,
                            for: failure.workItem.track,
                            queueIndex: failure.workItem.queueIndex,
                            totalCount: failure.workItem.totalCount,
                            errorMessage: decoratedError
                        )
                        cancelAnalysisProgressWatchdog(trackID: failure.workItem.track.id)
                        AppLogger.shared.error("Analyze failed for \(failure.workItem.track.filePath): \(decoratedError)")
                        logAnalysisEvent(
                            "track_finished",
                            track: failure.workItem.track,
                            queueIndex: failure.workItem.queueIndex,
                            totalCount: failure.workItem.totalCount,
                            elapsedMs: failure.elapsedMs,
                            extra: ["result": "failed"]
                        )
                    }
                }

                guard !Task.isCancelled else { continue }
                if nextIndex < workItems.count {
                    launch(workItems[nextIndex])
                    nextIndex += 1
                }
            }
        }

        if Task.isCancelled, sessionResult == .succeeded {
            sessionResult = .canceled
        }

        let refreshStartedAt = Date()
        await refreshTracks()
        AppLogger.shared.info(
            "Analysis refresh_tracks_completed | trackCount=\(tracksToAnalyze.count) | elapsedMs=\(max(Int(Date().timeIntervalSince(refreshStartedAt) * 1000), 0)) | batchElapsedMs=\(max(Int(Date().timeIntervalSince(batchStartedAt) * 1000), 0))"
        )
    }

    private func currentAnalysisWorkerConfig() -> PythonWorkerClient.WorkerConfig {
        PythonWorkerClient.WorkerConfig(
            pythonExecutable: pythonExecutablePath,
            workerScriptPath: workerScriptPath,
            googleAIAPIKey: googleAIAPIKey,
            embeddingProfile: embeddingProfile
        )
    }

    private func makeAnalysisWorkItems(from tracksToAnalyze: [Track]) throws -> [AnalysisWorkItem] {
        try tracksToAnalyze.enumerated().map { index, track in
            let existingSegments = try database.fetchSegments(trackID: track.id)
            let existingSummary = try database.fetchAnalysisSummary(trackID: track.id)
            let canReembed = track.analyzedAt != nil
                && !readyTrackIDs.contains(track.id)
                && !existingSegments.isEmpty
                && existingSummary != nil
                && existingSummary?.analysisFocus == analysisFocus

            return AnalysisWorkItem(
                track: track,
                queueIndex: index + 1,
                totalCount: tracksToAnalyze.count,
                externalMetadata: try database.fetchExternalMetadata(trackID: track.id),
                existingSegments: existingSegments,
                shouldReembed: canReembed,
                analysisFocus: analysisFocus
            )
        }
    }

    private func makeAnalysisProgressHandler(
        for workItem: AnalysisWorkItem
    ) -> PythonWorkerClient.WorkerProgressHandler {
        let trackID = workItem.track.id
        let trackTitle = workItem.track.title
        let trackPath = workItem.track.filePath
        let queueIndex = workItem.queueIndex
        let totalCount = workItem.totalCount
        return { [weak self] event in
            Task { @MainActor [weak self] in
                self?.recordAnalysisProgress(
                    event,
                    trackID: trackID,
                    trackTitle: trackTitle,
                    trackPath: trackPath,
                    queueIndex: queueIndex,
                    totalCount: totalCount
                )
            }
        }
    }

    private func logWorkerCompletion(for output: AnalysisTaskOutput) {
        let extra: [String: String]
        let event: String
        switch output.payload {
        case let .analyzed(result):
            event = "worker_analyze_completed"
            extra = [
                "embeddingProfileID": result.embeddingProfileID,
                "embeddingPipelineID": result.embeddingPipelineID,
                "segmentCount": "\(result.segments.count)"
            ]
        case let .reembedded(result):
            event = "worker_embed_audio_segments_completed"
            extra = [
                "embeddingProfileID": result.embeddingProfileID,
                "embeddingPipelineID": result.embeddingPipelineID,
                "segmentCount": "\(result.segments.count)"
            ]
        }

        logAnalysisEvent(
            event,
            track: output.workItem.track,
            queueIndex: output.workItem.queueIndex,
            totalCount: output.workItem.totalCount,
            elapsedMs: output.elapsedMs,
            extra: extra
        )
    }

    private static func executeAnalysisWorkItem(
        _ workItem: AnalysisWorkItem,
        workerConfig: PythonWorkerClient.WorkerConfig,
        progress: @escaping PythonWorkerClient.WorkerProgressHandler
    ) async -> AnalysisWorkerOutcome {
        let worker = PythonWorkerClient(configProvider: { workerConfig })
        let startedAt = Date()

        do {
            let payload: AnalysisTaskOutput.Payload
            if workItem.shouldReembed {
                let result = try await worker.embedAudioSegments(
                    track: workItem.track,
                    segments: workItem.existingSegments,
                    externalMetadata: workItem.externalMetadata,
                    progress: progress
                )
                payload = .reembedded(result)
            } else {
                let result = try await worker.analyze(
                    filePath: workItem.track.filePath,
                    track: workItem.track,
                    analysisFocus: workItem.analysisFocus,
                    externalMetadata: workItem.externalMetadata,
                    progress: progress
                )
                payload = .analyzed(result)
            }

            return .succeeded(
                AnalysisTaskOutput(
                    workItem: workItem,
                    payload: payload,
                    elapsedMs: max(Int(Date().timeIntervalSince(startedAt) * 1000), 0)
                )
            )
        } catch {
            return .failed(
                AnalysisFailedTask(
                    workItem: workItem,
                    errorMessage: error.localizedDescription,
                    wasCancelled: Task.isCancelled || isWorkerCancellation(error),
                    elapsedMs: max(Int(Date().timeIntervalSince(startedAt) * 1000), 0)
                )
            )
        }
    }

    private static func isWorkerCancellation(_ error: Error) -> Bool {
        guard let workerError = error as? WorkerError else { return false }
        if case .cancelled = workerError {
            return true
        }
        return false
    }

    private func loadSelectedTrackDetails() async {
        guard let track = selectedTrack else {
            selectedTrackSegments = []
            selectedTrackAnalysis = nil
            selectedTrackExternalMetadata = []
            selectedTrackWaveformPreview = []
            return
        }

        do {
            selectedTrackSegments = try database.fetchSegments(trackID: track.id)
            selectedTrackAnalysis = try database.fetchAnalysisSummary(trackID: track.id)
            selectedTrackExternalMetadata = try database.fetchExternalMetadata(trackID: track.id)
            selectedTrackWaveformPreview = selectedTrackAnalysis?.waveformPreview ?? []

            let metadataSnapshot = selectedTrackExternalMetadata
            let shouldResolveExternalPreview =
                selectedTrackWaveformPreview.isEmpty ||
                metadataSnapshot.contains(where: { $0.cuePoints.isEmpty })

            guard shouldResolveExternalPreview, !metadataSnapshot.isEmpty else { return }
            let selectedTrackID = track.id
            let trackPath = track.filePath
            let resolver = externalVisualizationResolver
            let resolution = await Task.detached(priority: .userInitiated) {
                resolver.enrich(trackPath: trackPath, metadata: metadataSnapshot)
            }.value

            guard selectedTrack?.id == selectedTrackID else { return }

            if selectedTrackWaveformPreview.isEmpty, !resolution.waveformPreview.isEmpty {
                selectedTrackWaveformPreview = resolution.waveformPreview
            }

            if resolution.metadata != metadataSnapshot {
                selectedTrackExternalMetadata = resolution.metadata
                for source in Set(resolution.metadata.map(\.source)) {
                    let entries = resolution.metadata.filter { $0.source == source }
                    try database.replaceExternalMetadata(trackID: selectedTrackID, source: source, entries: entries)
                }
                membershipSnapshotsByTrackID[selectedTrackID] = (
                    try? database.fetchTrackMembershipSnapshots(trackIDs: [selectedTrackID])
                )?[selectedTrackID] ?? membershipSnapshotsByTrackID[selectedTrackID]
                scopeTrackCache.removeAll()
                try? refreshMembershipFacets()
            }
        } catch {
            AppLogger.shared.error("Track detail load failed: \(error.localizedDescription)")
        }
    }

    private func resolvedSelection(for availableIDs: Set<UUID>) -> Set<UUID> {
        if selectedTrackIDs.isEmpty {
            return []
        }

        let preservedIDs = selectedTrackIDs.intersection(availableIDs)
        if preservedIDs.isEmpty {
            return []
        }
        return preservedIDs
    }

    private func updateSelectedTrackIDs(_ newValue: Set<UUID>, deferSideEffects: Bool = false) {
        guard selectedTrackIDs != newValue else { return }
        selectedTrackIDs = newValue

        if deferSideEffects {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectedTrackIDs == newValue else { return }
                self.handleSelectedTrackIDsChange()
            }
        } else {
            handleSelectedTrackIDsChange()
        }
    }

    private func handleSelectedTrackIDsChange() {
        invalidateGeneratedRecommendationResults(
            message: "Reference selection changed. Generate again to rebuild the curated list."
        )
        Task { await loadSelectedTrackDetails() }
    }

    private func recommendationSearchEntryActionFromLibrary() -> LibraryRecommendationSearchEntryAction {
        guard !readySelectedReferenceTracks.isEmpty else { return .navigateOnly }
        guard
            hasValidatedEmbeddingProfile,
            isSelectedEmbeddingProfileSupported,
            !isBuildingPlaylist,
            !isGeneratingRecommendations
        else {
            return .navigateOnly
        }
        if trimmedRecommendationQueryText.isEmpty, hasGeneratedRecommendationResults {
            return .reuseExistingResults
        }
        return .autoGenerate
    }

    private func clearRecommendationQueryTextForLibraryEntry(preservingGeneratedResults: Bool) {
        guard !recommendationQueryText.isEmpty else { return }

        let shouldPreserveGeneratedResults = preservingGeneratedResults && trimmedRecommendationQueryText.isEmpty
        if shouldPreserveGeneratedResults {
            isSuppressingRecommendationResultInvalidation = true
        }
        recommendationQueryText = ""
        if shouldPreserveGeneratedResults {
            isSuppressingRecommendationResultInvalidation = false
        }
    }

    private func replaceGeneratedRecommendations(_ candidates: [RecommendationCandidate]) {
        generatedRecommendations = candidates
        excludedGeneratedTrackIDs.removeAll()
        curationSelectionTrackIDs.removeAll()
        playlistBuildProgress = nil
        isBuildingPlaylist = false
        refreshVisibleRecommendations()
    }

    private func resetGeneratedRecommendationResults(clearStatusMessage: Bool = false) {
        recommendations = []
        generatedRecommendations = []
        excludedGeneratedTrackIDs.removeAll()
        curationSelectionTrackIDs.removeAll()
        selectedRecommendationID = nil
        playlistBuildProgress = nil
        isBuildingPlaylist = false
        if clearStatusMessage {
            recommendationStatusMessage = ""
        }
    }

    private func invalidateGeneratedRecommendationResults(message: String? = nil) {
        guard !isBuildingPlaylist else {
            if let message {
                recommendationStatusMessage = message
            }
            return
        }

        let hadCuratedState =
            !generatedRecommendations.isEmpty
            || !excludedGeneratedTrackIDs.isEmpty
            || !curationSelectionTrackIDs.isEmpty
            || playlistBuildProgress != nil
            || isBuildingPlaylist

        resetGeneratedRecommendationResults(clearStatusMessage: message == nil)

        if let message, hadCuratedState {
            recommendationStatusMessage = message
        } else if message == nil {
            recommendationStatusMessage = ""
        }
    }

    private func recommendationGenerationCompletionMessage(
        resultCount: Int,
        inputState: RecommendationInputState,
        semanticSeedTitle: String? = nil
    ) -> String {
        if resultCount == 0 {
            return "No recommendations found for the current inputs."
        }
        if inputState.requiresSemanticSeed, let semanticSeedTitle, !semanticSeedTitle.isEmpty {
            return "Generated \(resultCount) matches from semantic seed: \(semanticSeedTitle). Curate the list before building the playlist."
        }
        return "Generated \(resultCount) matches. Curate the list before building the playlist."
    }

    private func refreshVisibleRecommendations() {
        let visibleRecommendations = generatedRecommendations.filter { candidate in
            !excludedGeneratedTrackIDs.contains(candidate.track.id)
        }
        recommendations = visibleRecommendations

        let visibleTrackIDs = Set(visibleRecommendations.map { $0.track.id })
        curationSelectionTrackIDs = curationSelectionTrackIDs.intersection(visibleTrackIDs)

        if let selectedRecommendationID, !visibleTrackIDs.contains(selectedRecommendationID) {
            self.selectedRecommendationID = visibleRecommendations.first?.id
        } else if self.selectedRecommendationID == nil {
            self.selectedRecommendationID = visibleRecommendations.first?.id
        }
    }

    private func updatePlaylistBuildProgress(
        stage: PlaylistBuildStage,
        completedCount: Int,
        totalCount: Int,
        progress: Double,
        currentSeedTitle: String,
        latestTrackTitle: String? = nil,
        message: String
    ) {
        playlistBuildProgress = PlaylistBuildProgress(
            stage: stage,
            completedCount: completedCount,
            totalCount: totalCount,
            progress: progress,
            currentSeedTitle: currentSeedTitle,
            latestTrackTitle: latestTrackTitle,
            message: message
        )
    }

    private func referenceQueryEmbeddings(
        trackEmbedding: [Double],
        segments: [TrackSegment]
    ) -> [String: [Double]] {
        var output: [String: [Double]] = [:]
        if !trackEmbedding.isEmpty {
            let normalizedTrackEmbedding = normalizedVector(trackEmbedding)
            if !normalizedTrackEmbedding.isEmpty {
                output["tracks"] = normalizedTrackEmbedding
            }
        }

        for segment in segments {
            guard
                let vector = segment.vector,
                !vector.isEmpty,
                segment.type == .intro || segment.type == .middle || segment.type == .outro
            else {
                continue
            }

            let normalizedSegmentVector = normalizedVector(vector)
            guard !normalizedSegmentVector.isEmpty else { continue }
            output[segment.type.rawValue] = normalizedSegmentVector
        }

        return output
    }

    private func curatedVectorBreakdowns(
        seed: Track,
        candidates: [Track]
    ) throws -> [String: VectorScoreBreakdown] {
        guard let referencePayload = buildReferenceTrackSearchPayload(from: [seed]) else {
            return [:]
        }

        let queryEmbeddings = referenceQueryEmbeddings(
            trackEmbedding: referencePayload.trackEmbedding,
            segments: referencePayload.segments
        )
        guard !queryEmbeddings.isEmpty else { return [:] }

        return try Dictionary(uniqueKeysWithValues: candidates.compactMap { track in
            guard let breakdown = try exactVectorBreakdown(
                for: track,
                queryEmbeddings: queryEmbeddings,
                vectorWeights: normalizedMixsetVectorWeights
            ) else {
                return nil
            }
            return (track.filePath, breakdown)
        })
    }

    private static func bootstrapDatabase() -> (
        database: LibraryDatabase,
        sources: [LibrarySourceRecord],
        statusMessage: String?
    ) {
        do {
            let database = try LibraryDatabase()
            return (database, try database.fetchLibrarySources(), nil)
        } catch {
            AppLogger.shared.error(
                "Primary database init failed | path=\(AppPaths.databaseURL.path) | error=\(error.localizedDescription)"
            )

            let recoveryURL = AppPaths.makeRecoveryDatabaseURL()
            do {
                let recoveryDatabase = try LibraryDatabase(databaseURL: recoveryURL)
                let recoverySources = try recoveryDatabase.fetchLibrarySources()
                let message = "Could not open the existing library database. Soria started with a temporary empty library instead."
                AppLogger.shared.error(
                    "Recovery database activated | path=\(recoveryURL.path) | reason=\(error.localizedDescription)"
                )
                return (recoveryDatabase, recoverySources, message)
            } catch {
                fatalError("Database init failed: \(error.localizedDescription)")
            }
        }
    }

    private func buildReferenceTrackSearchPayload(from tracks: [Track]) -> (
        trackEmbedding: [Double],
        segments: [TrackSegment],
        excludeTrackPaths: Set<String>
    )? {
        var embeddings: [[Double]] = []
        var segments: [TrackSegment] = []
        var excludeTrackPaths: Set<String> = []

        for track in tracks {
            excludeTrackPaths.insert(track.filePath)
            if let embedding = (try? database.fetchTrackEmbedding(trackID: track.id)), !embedding.isEmpty {
                embeddings.append(embedding)
            }
            if let trackSegments = try? database.fetchSegments(trackID: track.id) {
                segments.append(contentsOf: trackSegments.compactMap { segment in
                    guard let vector = segment.vector, !vector.isEmpty else { return nil }
                    return TrackSegment(
                        id: segment.id,
                        trackID: segment.trackID,
                        type: segment.type,
                        startSec: segment.startSec,
                        endSec: segment.endSec,
                        energyScore: segment.energyScore,
                        descriptorText: segment.descriptorText,
                        vector: vector
                    )
                })
            }
        }

        guard let targetDimension = embeddings.first?.count, targetDimension > 0 else {
            return nil
        }

        let alignedEmbeddings = embeddings.filter { $0.count == targetDimension }
        guard !alignedEmbeddings.isEmpty else { return nil }

        var merged = Array(repeating: 0.0, count: targetDimension)
        for vector in alignedEmbeddings {
            for index in 0..<targetDimension {
                merged[index] += vector[index]
            }
        }
        let scale = Double(alignedEmbeddings.count)
        for index in 0..<targetDimension {
            merged[index] /= scale
        }
        return (trackEmbedding: merged, segments: segments, excludeTrackPaths: excludeTrackPaths)
    }

    private func executeVectorSearch(
        mode: WorkerTrackSearchMode,
        queryText: String?,
        referencePayload: (
            trackEmbedding: [Double],
            segments: [TrackSegment],
            excludeTrackPaths: Set<String>
        )?,
        filters: WorkerSimilarityFilters,
        limit: Int,
        scopeFilter: LibraryScopeFilter
    ) async throws -> VectorSearchExecution {
        let workerWeights = normalizedMixsetVectorWeights.asWorkerWeights()
        let excludedPaths = referencePayload?.excludeTrackPaths ?? []
        let baseCandidates = tracks.filter { track in
            readyTrackIDs.contains(track.id)
                && !excludedPaths.contains(track.filePath)
                && trackMatchesSimilarityFilters(track: track, filters: filters)
        }

        let candidateCountBeforeScope = baseCandidates.count
        if scopeFilter.isEmpty {
            let response: WorkerTrackSearchResponse
            switch mode {
            case .text:
                response = try await worker.searchTracksText(
                    query: queryText ?? "",
                    limit: limit,
                    excludeTrackPaths: Array(excludedPaths),
                    filters: filters,
                    weights: workerWeights
                )
            case .reference:
                guard let referencePayload else {
                    return VectorSearchExecution(candidates: [], candidateCountBeforeScope: candidateCountBeforeScope, candidateCountAfterScope: 0)
                }
                response = try await worker.searchTracksReference(
                    track: selectedTracks.first ?? tracks.first ?? Track.empty(path: "", modifiedTime: .distantPast, hash: ""),
                    segments: referencePayload.segments,
                    trackEmbedding: referencePayload.trackEmbedding,
                    limit: limit,
                    excludeTrackPaths: Array(excludedPaths),
                    filters: filters,
                    weights: workerWeights
                )
            case .hybrid:
                guard let referencePayload else {
                    return VectorSearchExecution(candidates: [], candidateCountBeforeScope: candidateCountBeforeScope, candidateCountAfterScope: 0)
                }
                response = try await worker.searchTracksHybrid(
                    query: queryText ?? "",
                    segments: referencePayload.segments,
                    trackEmbedding: referencePayload.trackEmbedding,
                    limit: limit,
                    excludeTrackPaths: Array(excludedPaths),
                    filters: filters,
                    weights: workerWeights
                )
            }

            let trackIndex = Dictionary(uniqueKeysWithValues: tracks.map { ($0.filePath, $0) })
            let candidates = response.results.compactMap { item -> VectorSearchCandidate? in
                guard let track = trackIndex[item.filePath] else { return nil }
                return VectorSearchCandidate(
                    track: track,
                    vectorBreakdown: vectorBreakdown(from: item),
                    matchedMemberships: []
                )
            }
            return VectorSearchExecution(
                candidates: candidates,
                candidateCountBeforeScope: candidateCountBeforeScope,
                candidateCountAfterScope: candidateCountBeforeScope
            )
        }

        let scopedIDs = scopedTrackIDs(for: scopeFilter)
        let scopedCandidates = baseCandidates.filter { scopedIDs.contains($0.id) }
        let candidateCountAfterScope = scopedCandidates.count
        guard !scopedCandidates.isEmpty else {
            return VectorSearchExecution(candidates: [], candidateCountBeforeScope: candidateCountBeforeScope, candidateCountAfterScope: 0)
        }

        let queryResponse = try await worker.buildQueryEmbeddings(
            mode: mode,
            queryText: queryText,
            trackEmbedding: referencePayload?.trackEmbedding,
            segments: referencePayload?.segments ?? []
        )
        let exactCandidates = try scopedCandidates.compactMap { track -> VectorSearchCandidate? in
            guard let vectorBreakdown = try exactVectorBreakdown(
                for: track,
                queryEmbeddings: queryResponse.queryEmbeddings,
                vectorWeights: normalizedMixsetVectorWeights
            ) else {
                return nil
            }
            return VectorSearchCandidate(
                track: track,
                vectorBreakdown: vectorBreakdown,
                matchedMemberships: membershipSnapshotsByTrackID[track.id]?.matchedPaths(scopeFilter: scopeFilter) ?? []
            )
        }
        .sorted { $0.vectorBreakdown.fusedScore > $1.vectorBreakdown.fusedScore }

        return VectorSearchExecution(
            candidates: Array(exactCandidates.prefix(limit)),
            candidateCountBeforeScope: candidateCountBeforeScope,
            candidateCountAfterScope: candidateCountAfterScope
        )
    }

    private func trackMatchesSimilarityFilters(track: Track, filters: WorkerSimilarityFilters) -> Bool {
        let bpmValue = track.bpm ?? -1
        if let bpmMin = filters.bpmMin, bpmValue < bpmMin { return false }
        if let bpmMax = filters.bpmMax, bpmValue > bpmMax { return false }
        if let durationMaxSec = filters.durationMaxSec, track.duration > durationMaxSec { return false }
        if let musicalKey = filters.musicalKey, !musicalKey.isEmpty, track.musicalKey != musicalKey { return false }
        if let genre = filters.genre, !genre.isEmpty, track.genre != genre { return false }
        return true
    }

    private func exactVectorBreakdown(
        for track: Track,
        queryEmbeddings: [String: [Double]],
        vectorWeights: MixsetVectorWeights
    ) throws -> VectorScoreBreakdown? {
        let trackEmbedding = try database.fetchTrackEmbedding(trackID: track.id)
        let segments = try database.fetchSegments(trackID: track.id).filter { segment in
            guard let vector = segment.vector else { return false }
            return !vector.isEmpty
        }

        let trackScore = similarityScore(queryEmbeddings["tracks"], trackEmbedding)
        let introScore = bestSegmentSimilarity(queryEmbeddings["intro"], type: .intro, segments: segments)
        let middleScore = bestSegmentSimilarity(queryEmbeddings["middle"], type: .middle, segments: segments)
        let outroScore = bestSegmentSimilarity(queryEmbeddings["outro"], type: .outro, segments: segments)
        let fusedScore = vectorWeights.fusedScore(
            trackScore: trackScore,
            introScore: introScore,
            middleScore: middleScore,
            outroScore: outroScore
        )

        let components = [
            ("tracks", trackScore),
            ("intro", introScore),
            ("middle", middleScore),
            ("outro", outroScore)
        ]
        let best = components.max(by: { $0.1 < $1.1 }) ?? ("tracks", trackScore)

        if trackScore == 0, introScore == 0, middleScore == 0, outroScore == 0 {
            return nil
        }

        return VectorScoreBreakdown(
            fusedScore: fusedScore,
            trackScore: trackScore,
            introScore: introScore,
            middleScore: middleScore,
            outroScore: outroScore,
            bestMatchedCollection: best.0
        )
    }

    private func bestSegmentSimilarity(
        _ queryEmbedding: [Double]?,
        type: TrackSegment.SegmentType,
        segments: [TrackSegment]
    ) -> Double {
        let matchingSegments = segments.filter { $0.type == type }
        guard !matchingSegments.isEmpty else { return 0 }
        return matchingSegments.reduce(0) { currentBest, segment in
            max(currentBest, similarityScore(queryEmbedding, segment.vector))
        }
    }

    private func similarityScore(_ lhs: [Double]?, _ rhs: [Double]?) -> Double {
        guard
            let lhs, let rhs,
            !lhs.isEmpty, !rhs.isEmpty,
            lhs.count == rhs.count
        else {
            return 0
        }

        let normalizedLHS = normalizedVector(lhs)
        let normalizedRHS = normalizedVector(rhs)
        guard !normalizedLHS.isEmpty, !normalizedRHS.isEmpty else { return 0 }
        let squaredDistance = zip(normalizedLHS, normalizedRHS).reduce(0.0) { partial, pair in
            let diff = pair.0 - pair.1
            return partial + diff * diff
        }
        return 1.0 / (1.0 + sqrt(squaredDistance))
    }

    private func normalizedVector(_ vector: [Double]) -> [Double] {
        let magnitude = sqrt(vector.reduce(0.0) { $0 + ($1 * $1) })
        guard magnitude > 0 else { return [] }
        return vector.map { $0 / magnitude }
    }

    private func vectorBreakdown(from result: WorkerTrackSearchResult) -> VectorScoreBreakdown {
        VectorScoreBreakdown(
            fusedScore: result.fusedScore,
            trackScore: result.trackScore,
            introScore: result.introScore,
            middleScore: result.middleScore,
            outroScore: result.outroScore,
            bestMatchedCollection: result.bestMatchedCollection
        )
    }

    private func loadTrackEmbeddings(trackIDs: Set<UUID>? = nil) throws -> [UUID: [Double]] {
        var output: [UUID: [Double]] = [:]
        for track in tracks where readyTrackIDs.contains(track.id) {
            if let trackIDs, !trackIDs.contains(track.id) {
                continue
            }
            if let embedding = try database.fetchTrackEmbedding(trackID: track.id), !embedding.isEmpty {
                output[track.id] = embedding
            }
        }
        return output
    }

    private func loadAnalysisSummaries(trackIDs: [UUID]) throws -> [UUID: TrackAnalysisSummary] {
        var output: [UUID: TrackAnalysisSummary] = [:]
        for trackID in trackIDs {
            if let summary = try database.fetchAnalysisSummary(trackID: trackID) {
                output[trackID] = summary
            }
        }
        return output
    }

    private func resolveRecommendationInput() -> RecommendationResolvedInput? {
        guard let state = recommendationInputState else { return nil }
        let readyReferenceTracks = readySelectedReferenceTracks
        return RecommendationResolvedInput(
            state: state,
            readyReferenceTracks: readyReferenceTracks,
            referencePayload: readyReferenceTracks.isEmpty
                ? nil
                : buildReferenceTrackSearchPayload(from: readyReferenceTracks)
        )
    }

    private func recommendationInputValidationMessage() -> String {
        let trimmedQueryText = recommendationQueryText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQueryText.isEmpty, selectedTracks.isEmpty {
            return "Enter text or select one or more library tracks first."
        }
        if trimmedQueryText.isEmpty, !selectedTracks.isEmpty, readySelectedReferenceTracks.isEmpty {
            return "Prepare at least one selected track first, or enter text."
        }
        return "No seed track matched the current recommendation inputs."
    }

    private func resolveRecommendationSeedContext(
        input: RecommendationResolvedInput,
        embeddingsByTrackID: [UUID: [Double]],
        summariesByTrackID: [UUID: TrackAnalysisSummary],
        limit: Int,
        excludedPaths: Set<String>
    ) async throws -> RecommendationSeedContext {
        let effectiveConstraints = effectiveRecommendationConstraints
        switch input.state.seedSource {
        case .selectedReference:
            guard let seed = input.readyReferenceTracks.first else {
                throw RecommendationResolutionError.missingReferenceTrack
            }
            let similarityState = try await similarityState(
                seed: seed,
                filters: WorkerSimilarityFilters(
                    bpmMin: effectiveConstraints.targetBPMMin,
                    bpmMax: effectiveConstraints.targetBPMMax,
                    durationMaxSec: effectiveConstraints.maxDurationMinutes.map { $0 * 60 },
                    musicalKey: effectiveConstraints.keyStrictness > 0.85 ? seed.musicalKey : nil,
                    genre: nil
                ),
                limit: max(limit, 1),
                excludedPaths: excludedPaths,
                scopeFilter: recommendationScopeFilter
            )
            return RecommendationSeedContext(
                seed: seed,
                similarityMap: similarityState.similarityMap,
                vectorBreakdownByPath: similarityState.vectorBreakdownByPath,
                candidateCountBeforeScope: similarityState.candidateCountBeforeScope,
                candidateCountAfterScope: similarityState.candidateCountAfterScope
            )

        case .semanticMatch:
            let execution = try await searchRecommendationMatches(
                input: input,
                limit: max(limit, 1),
                excludedPaths: excludedPaths
            )
            let rankedMatches = execution.candidates.compactMap { item -> (Track, VectorScoreBreakdown)? in
                let track = item.track
                guard recommendationEngine.matchesConstraints(
                    track: track,
                    summary: summariesByTrackID[track.id],
                    constraints: effectiveConstraints
                ) else {
                    return nil
                }
                return (track, item.vectorBreakdown)
            }
            guard let seed = rankedMatches.first?.0 else {
                throw RecommendationResolutionError.noSemanticSeed
            }
            return RecommendationSeedContext(
                seed: seed,
                similarityMap: Dictionary(uniqueKeysWithValues: rankedMatches.map { ($0.0.filePath, $0.1.fusedScore) }),
                vectorBreakdownByPath: Dictionary(uniqueKeysWithValues: rankedMatches.map { ($0.0.filePath, $0.1) }),
                candidateCountBeforeScope: execution.candidateCountBeforeScope,
                candidateCountAfterScope: execution.candidateCountAfterScope
            )
        }
    }

    private func searchRecommendationMatches(
        input: RecommendationResolvedInput,
        limit: Int,
        excludedPaths: Set<String>
    ) async throws -> VectorSearchExecution {
        let filters = recommendationWorkerFilters()
        let effectiveExcludedPaths = excludedPaths.union(input.referencePayload?.excludeTrackPaths ?? [])

        switch input.state.mode {
        case .text:
            return try await executeVectorSearch(
                mode: .text,
                queryText: input.state.trimmedQueryText,
                referencePayload: nil,
                filters: filters,
                limit: limit,
                scopeFilter: recommendationScopeFilter
            )

        case .reference:
            guard let referencePayload = input.referencePayload else {
                throw RecommendationResolutionError.missingReferencePayload
            }
            return try await executeVectorSearch(
                mode: .reference,
                queryText: nil,
                referencePayload: (
                    trackEmbedding: referencePayload.trackEmbedding,
                    segments: referencePayload.segments,
                    excludeTrackPaths: effectiveExcludedPaths
                ),
                filters: filters,
                limit: limit,
                scopeFilter: recommendationScopeFilter
            )

        case .hybrid:
            guard let referencePayload = input.referencePayload else {
                throw RecommendationResolutionError.missingReferencePayload
            }
            return try await executeVectorSearch(
                mode: .hybrid,
                queryText: input.state.trimmedQueryText,
                referencePayload: (
                    trackEmbedding: referencePayload.trackEmbedding,
                    segments: referencePayload.segments,
                    excludeTrackPaths: effectiveExcludedPaths
                ),
                filters: filters,
                limit: limit,
                scopeFilter: recommendationScopeFilter
            )
        }
    }

    private func recommendationWorkerFilters() -> WorkerSimilarityFilters {
        let effectiveConstraints = effectiveRecommendationConstraints
        return WorkerSimilarityFilters(
            bpmMin: effectiveConstraints.targetBPMMin,
            bpmMax: effectiveConstraints.targetBPMMax,
            durationMaxSec: effectiveConstraints.maxDurationMinutes.map { $0 * 60 },
            musicalKey: nil,
            genre: nil
        )
    }

    private func invalidateTrackVectors(for track: Track) async {
        do {
            try await worker.deleteTrackVectors(trackID: track.id, deleteAllProfiles: true)
        } catch {
            AppLogger.shared.error("Failed to delete stale vectors for \(track.filePath): \(error.localizedDescription)")
        }
    }

    private func similarityState(
        seed: Track,
        filters: WorkerSimilarityFilters,
        limit: Int,
        excludedPaths: Set<String>,
        scopeFilter: LibraryScopeFilter
    ) async throws -> SimilarityState {
        guard let referencePayload = buildReferenceTrackSearchPayload(from: [seed]) else {
            return SimilarityState(
                similarityMap: [:],
                vectorBreakdownByPath: [:],
                candidateCountBeforeScope: 0,
                candidateCountAfterScope: 0
            )
        }
        let execution = try await executeVectorSearch(
            mode: .reference,
            queryText: nil,
            referencePayload: (
                trackEmbedding: referencePayload.trackEmbedding,
                segments: referencePayload.segments,
                excludeTrackPaths: excludedPaths.union(referencePayload.excludeTrackPaths)
            ),
            filters: filters,
            limit: limit,
            scopeFilter: scopeFilter
        )
        return SimilarityState(
            similarityMap: Dictionary(uniqueKeysWithValues: execution.candidates.map { ($0.track.filePath, $0.vectorBreakdown.fusedScore) }),
            vectorBreakdownByPath: Dictionary(uniqueKeysWithValues: execution.candidates.map { ($0.track.filePath, $0.vectorBreakdown) }),
            candidateCountBeforeScope: execution.candidateCountBeforeScope,
            candidateCountAfterScope: execution.candidateCountAfterScope
        )
    }

    private func persistRecommendationSession(
        kind: ScoreSessionKind,
        queryText: String?,
        seedTrackID: UUID?,
        referenceTrackIDs: [UUID],
        candidates: [RecommendationCandidate],
        candidateCountBeforeScope: Int,
        candidateCountAfterScope: Int,
        resultLimit: Int
    ) throws -> UUID {
        let session = ScoreSession(
            id: UUID(),
            kind: kind,
            embeddingProfileID: embeddingProfile.id,
            searchMode: recommendationInputState?.mode.rawValue,
            queryText: queryText?.trimmingCharacters(in: .whitespacesAndNewlines),
            seedTrackID: seedTrackID,
            referenceTrackIDs: referenceTrackIDs,
            scopeFilter: recommendationScopeFilter,
            candidateCountBeforeScope: candidateCountBeforeScope,
            candidateCountAfterScope: candidateCountAfterScope,
            resultLimit: resultLimit,
            createdAt: Date()
        )
        let normalizedFinalWeights = normalizedRecommendationWeights
        let normalizedVectorWeights = normalizedMixsetVectorWeights
        let effectiveConstraints = effectiveRecommendationConstraints
        let sessionCandidates = candidates.enumerated().map { index, candidate in
            let matchedMemberships = candidate.matchedMemberships.isEmpty
                ? membershipSnapshotsByTrackID[candidate.track.id]?.matchedPaths(scopeFilter: recommendationScopeFilter) ?? []
                : candidate.matchedMemberships
            return ScoreSessionCandidateRecord(
                trackID: candidate.track.id,
                rank: index + 1,
                finalScore: candidate.score,
                vectorBreakdown: candidate.vectorBreakdown,
                embeddingSimilarity: candidate.breakdown.embeddingSimilarity,
                bpmCompatibility: candidate.breakdown.bpmCompatibility,
                harmonicCompatibility: candidate.breakdown.harmonicCompatibility,
                energyFlow: candidate.breakdown.energyFlow,
                transitionRegionMatch: candidate.breakdown.transitionRegionMatch,
                externalMetadataScore: candidate.breakdown.externalMetadataScore,
                matchedMemberships: matchedMemberships,
                matchReasons: candidate.matchReasons,
                snapshot: ScoreSessionCandidateSnapshot(
                    vectorBreakdown: candidate.vectorBreakdown,
                    matchedMemberships: matchedMemberships,
                    matchReasons: candidate.matchReasons,
                    analysisFocus: candidate.analysisFocus,
                    mixabilityTags: candidate.mixabilityTags,
                    queryMode: recommendationInputState?.mode.rawValue,
                    normalizedFinalWeights: normalizedFinalWeights,
                    normalizedVectorWeights: normalizedVectorWeights,
                    effectiveConstraints: effectiveConstraints
                )
            )
        }
        return try database.insertScoreSession(session: session, candidates: sessionCandidates)
    }

    private func persistAnalysisSettings() throws {
        pythonExecutablePath = AppSettingsStore.savePythonExecutablePath(pythonExecutablePath)
        workerScriptPath = AppSettingsStore.saveWorkerScriptPath(workerScriptPath)
        AppSettingsStore.saveAnalysisConcurrencyProfile(analysisConcurrencyProfile)
        AppSettingsStore.saveEmbeddingProfile(embeddingProfile)
        try AppSettingsStore.saveGoogleAIAPIKey(googleAIAPIKey)
    }

    private func persistRecommendationScoringSettings() {
        AppSettingsStore.saveRecommendationWeights(weights)
        AppSettingsStore.saveMixsetVectorWeights(vectorWeights)
        AppSettingsStore.saveRecommendationConstraints(constraints)
    }

    private func addLibraryRoots(_ paths: [String]) {
        guard let firstPath = paths.first else { return }
        libraryRoots = [TrackPathNormalizer.normalizedAbsolutePath(firstPath)]
        LibraryRootsStore.saveRoots(libraryRoots)
        if !libraryRoots.isEmpty {
            LibraryRootsStore.markInitialSetupCompleted()
        }
        initialSetupLibraryRoot = libraryRoots.first ?? ""
        persistFolderFallbackSource()
    }

    private func importExternalMetadataFiles(_ urls: [URL]) async throws -> [MetadataImportSummary] {
        var summaries: [MetadataImportSummary] = []
        for fileURL in urls {
            let summary = try await importExternalMetadataFile(fileURL)
            summaries.append(summary)
        }
        return summaries
    }

    private func importExternalMetadataFile(_ fileURL: URL) async throws -> MetadataImportSummary {
        let imported: [ExternalDJMetadata]
        let source: ExternalDJMetadata.Source
        if fileURL.pathExtension.lowercased() == "xml" {
            source = .rekordbox
            imported = try externalMetadataImporter.importRekordboxXML(from: fileURL)
            AppSettingsStore.saveLastRekordboxXMLPath(fileURL.path)
        } else {
            source = .serato
            imported = try externalMetadataImporter.importSeratoCSV(from: fileURL)
        }

        let localTracks = tracks
        guard !localTracks.isEmpty else {
            return MetadataImportSummary(
                source: source,
                importedEntries: imported.count,
                matchedLocalTracks: 0,
                unmatchedEntries: imported.count,
                referenceAttachmentCount: 0
            )
        }

        let localTracksByPath = Dictionary(uniqueKeysWithValues: localTracks.map { ($0.filePath, $0) })
        let localTracksByHash = Dictionary(
            grouping: localTracks,
            by: \.contentHash
        ).compactMapValues { matches in
            matches.sorted { lhs, rhs in
                let lhsDate = lhs.lastSeenInLocalScanAt ?? .distantPast
                let rhsDate = rhs.lastSeenInLocalScanAt ?? .distantPast
                if lhsDate == rhsDate {
                    return lhs.filePath.localizedStandardCompare(rhs.filePath) == .orderedAscending
                }
                return lhsDate > rhsDate
            }.first
        }
        var importHashCache: [String: String?] = [:]
        var entriesByTrackID: [UUID: [ExternalDJMetadata]] = [:]
        var updatedTracks = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        var matchedTrackIDs = Set<UUID>()
        var unmatchedEntries = 0
        var referenceAttachmentCount = 0

        for entry in imported {
            guard let localTrack = resolveLocalTrack(
                for: entry.trackPath,
                localTracksByPath: localTracksByPath,
                localTracksByHash: localTracksByHash,
                hashCache: &importHashCache
            ) else {
                unmatchedEntries += 1
                continue
            }
            entriesByTrackID[localTrack.id, default: []].append(entry)
            matchedTrackIDs.insert(localTrack.id)
            referenceAttachmentCount += entry.playlistMemberships.count
        }

        for (trackID, entries) in entriesByTrackID {
            guard var updatedTrack = updatedTracks[trackID] else { continue }
            if source == .serato { updatedTrack.hasSeratoMetadata = true }
            if source == .rekordbox { updatedTrack.hasRekordboxMetadata = true }

            let metadataSource: TrackMetadataSource = source == .serato ? .serato : .rekordbox
            let importedBPM = entries.compactMap(\.bpm).first
            let importedKey = entries.compactMap(\.musicalKey).first

            if shouldAdoptMetadataValue(importedBPM, from: metadataSource, over: updatedTrack.bpm, currentSource: updatedTrack.bpmSource) {
                updatedTrack.bpm = importedBPM
                updatedTrack.bpmSource = metadataSource
            }
            if shouldAdoptMetadataValue(importedKey, from: metadataSource, over: updatedTrack.musicalKey, currentSource: updatedTrack.keySource) {
                updatedTrack.musicalKey = importedKey
                updatedTrack.keySource = metadataSource
            }

            try database.upsertTrack(updatedTrack)
            try database.replaceExternalMetadata(trackID: trackID, source: source, entries: entries)
            updatedTracks[trackID] = updatedTrack
        }

        tracks = updatedTracks.values.sorted {
            let lhs = "\($0.artist) \($0.title)"
            let rhs = "\($1.artist) \($1.title)"
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        membershipSnapshotsByTrackID = (try? database.fetchTrackMembershipSnapshots(trackIDs: tracks.map(\.id))) ?? membershipSnapshotsByTrackID
        scopeTrackCache.removeAll()
        try? refreshMembershipFacets()
        await loadSelectedTrackDetails()

        return MetadataImportSummary(
            source: source,
            importedEntries: imported.count,
            matchedLocalTracks: matchedTrackIDs.count,
            unmatchedEntries: unmatchedEntries,
            referenceAttachmentCount: referenceAttachmentCount
        )
    }

    private func resolveLocalTrack(
        for trackPath: String,
        localTracksByPath: [String: Track],
        localTracksByHash: [String: Track],
        hashCache: inout [String: String?]
    ) -> Track? {
        if let exactMatch = localTracksByPath[trackPath] {
            return exactMatch
        }

        let contentHash = hashCache[trackPath] ?? {
            let pathHash: String?
            if FileManager.default.fileExists(atPath: trackPath) {
                pathHash = FileHashingService.contentHash(for: URL(fileURLWithPath: trackPath))
            } else {
                pathHash = nil
            }
            hashCache[trackPath] = pathHash
            return pathHash
        }()

        guard let contentHash else { return nil }
        return localTracksByHash[contentHash]
    }

    static func playlistPathStatusMessage(
        builtCount: Int,
        requestedCount: Int,
        seedTitle: String
    ) -> String {
        if builtCount < requestedCount {
            return "Built \(builtCount)/\(requestedCount)-track path from seed: \(seedTitle)"
        }
        return "Built \(builtCount)-track path from seed: \(seedTitle)"
    }

    static func buildCuratedPlaylistCandidates(
        seed: Track,
        curatedCandidates: [RecommendationCandidate],
        embeddingsByTrackID: [UUID: [Double]],
        summariesByTrackID: [UUID: TrackAnalysisSummary],
        libraryRoots: [String],
        constraints: RecommendationConstraints,
        weights: RecommendationWeights,
        vectorWeights: MixsetVectorWeights,
        vectorBreakdownProvider: (Track, [Track]) throws -> [String: VectorScoreBreakdown]
    ) throws -> [RecommendationCandidate] {
        let engine = RecommendationEngine()
        let originalCandidatesByTrackID = Dictionary(uniqueKeysWithValues: curatedCandidates.map { ($0.track.id, $0) })
        var orderedCandidates: [RecommendationCandidate] = []
        var remainingTracks = curatedCandidates.map(\.track)
        var currentSeed = seed

        while !remainingTracks.isEmpty {
            let vectorBreakdownByPath = try vectorBreakdownProvider(currentSeed, remainingTracks)
            let vectorSimilarityByPath = Dictionary(
                uniqueKeysWithValues: vectorBreakdownByPath.map { ($0.key, $0.value.fusedScore) }
            )

            let nextCandidate = engine.recommendNextTracks(
                seed: currentSeed,
                candidates: remainingTracks,
                embeddingsByTrackID: embeddingsByTrackID,
                summariesByTrackID: summariesByTrackID,
                vectorSimilarityByPath: vectorSimilarityByPath,
                vectorBreakdownByPath: vectorBreakdownByPath,
                libraryRoots: libraryRoots,
                constraints: constraints,
                weights: weights,
                vectorWeights: vectorWeights,
                limit: 1
            ).first ?? remainingTracks.first.flatMap { originalCandidatesByTrackID[$0.id] }

            guard let nextCandidate else { break }
            orderedCandidates.append(nextCandidate)
            remainingTracks.removeAll { $0.id == nextCandidate.track.id }
            currentSeed = nextCandidate.track
        }

        return orderedCandidates
    }

    private func refreshValidationStatus() {
        validationStatus = AppSettingsStore.currentValidationStatus(apiKey: googleAIAPIKey, profile: embeddingProfile)
        if !validationStatus.isValidated {
            invalidateGeneratedRecommendationResults()
        }
    }

    private func markEmbeddingProfileValidatedIfNeeded(at date: Date = Date()) {
        guard !validationStatus.isValidated else { return }
        AppSettingsStore.markValidationSuccess(
            apiKey: googleAIAPIKey,
            profile: embeddingProfile,
            date: date
        )
        validationStatus = .validated(date)
    }

    private func validateInitialSetupEmbeddingProfileIfNeeded() async -> Bool {
        guard !validationStatus.isValidated else { return true }
        validationTask?.cancel()
        let succeeded = await runRuntimeValidation(userInitiated: true)
        if !succeeded && initialSetupStatusMessage.isEmpty {
            initialSetupStatusMessage = settingsStatusMessage.isEmpty
                ? validationStatus.summaryText
                : settingsStatusMessage
        }
        return succeeded
    }

    private func startRuntimeValidation(userInitiated: Bool) {
        validationTask?.cancel()
        validationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.runRuntimeValidation(userInitiated: userInitiated)
        }
    }

    private func runRuntimeValidation(userInitiated: Bool) async -> Bool {
        guard isSelectedEmbeddingProfileSupported else {
            let message = selectedEmbeddingProfileDependencyMessage ?? "The selected embedding profile is unavailable."
            validationStatus = .failed(message)
            settingsStatusMessage = message
            return false
        }

        let trimmedKey = googleAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !embeddingProfile.requiresAPIKey || !trimmedKey.isEmpty else {
            if userInitiated {
                validationStatus = .failed("Enter a Google AI API Key first.")
                settingsStatusMessage = "Enter a Google AI API Key before validating."
            } else {
                validationStatus = .unvalidated
                settingsStatusMessage = "Enter a Google AI API Key to enable runtime validation."
            }
            return false
        }

        do {
            try persistAnalysisSettings()
        } catch {
            validationStatus = .failed(error.localizedDescription)
            settingsStatusMessage = "Failed to save settings before validation: \(error.localizedDescription)"
            return false
        }

        let validatingProfile = embeddingProfile
        validationStatus = .validating
        settingsStatusMessage = userInitiated
            ? "Validating \(validatingProfile.displayName)..."
            : "Checking \(validatingProfile.displayName)..."

        do {
            let response = try await worker.validateEmbeddingProfile()
            guard !Task.isCancelled, validatingProfile.id == embeddingProfile.id else { return false }
            let validatedAt = Date()
            AppSettingsStore.markValidationSuccess(
                apiKey: googleAIAPIKey,
                profile: validatingProfile,
                date: validatedAt
            )
            validationStatus = .validated(validatedAt)
            settingsStatusMessage = "Validated \(response.modelName)."
            return true
        } catch {
            guard !Task.isCancelled, validatingProfile.id == embeddingProfile.id else { return false }
            let failureSummary = PythonWorkerClient.failureSummary(
                for: "validate_embedding_profile",
                error: error
            )
            validationStatus = .failed(failureSummary)
            settingsStatusMessage = userInitiated
                ? "Validation failed: \(failureSummary)"
                : "Runtime validation failed: \(failureSummary)"
            AppLogger.shared.error("Embedding validation failed: \(failureSummary)")
            return false
        }
    }

    private func scheduleWorkerHealthRefresh() {
        workerHealthTask?.cancel()
        workerHealthTask = Task { @MainActor [weak self] in
            await self?.refreshWorkerHealthAndRepairIfNeeded()
        }
    }

    private func refreshWorkerHealthAndRepairIfNeeded() async {
        do {
            let healthcheck = try await worker.healthcheck()
            if Task.isCancelled {
                return
            }

            workerProfileStatuses = healthcheck.profileStatusByID
            readyTrackIDs = try database.fetchReadyTrackIDs(
                profileID: embeddingProfile.id,
                pipelineID: embeddingProfile.pipelineID
            )

            guard workerProfileStatuses[embeddingProfile.id]?.supported ?? true else {
                validationStatus = .failed(selectedEmbeddingProfileDependencyMessage ?? "The active embedding profile is unavailable.")
                return
            }

            try await repairVectorIndexIfNeeded(healthcheck: healthcheck)
            startRuntimeValidation(userInitiated: false)
        } catch {
            if Task.isCancelled {
                return
            }
            let failureSummary = PythonWorkerClient.failureSummary(for: "healthcheck", error: error)
            validationStatus = .failed(failureSummary)
            AppLogger.shared.error("Worker healthcheck failed: \(failureSummary)")
        }
    }

    private func repairVectorIndexIfNeeded(healthcheck: WorkerHealthcheckResponse) async throws {
        let readyTracks = tracks.filter { readyTrackIDs.contains($0.id) }
        let readyManifestHash = vectorIndexManifestHash(for: readyTracks)
        let indexedTrackCount = healthcheck.vectorIndexState?.trackCount ?? 0
        let indexedManifestHash = healthcheck.vectorIndexState?.manifestHash ?? ""
        let hasDrift = indexedTrackCount != readyTracks.count || indexedManifestHash != readyManifestHash

        if !hasDrift {
            AppSettingsStore.clearAutomaticVectorRepair(profileID: embeddingProfile.id)
            return
        }

        let repairSignature = vectorRepairSignature(
            profileID: embeddingProfile.id,
            pipelineID: embeddingProfile.pipelineID,
            manifestHash: readyManifestHash
        )
        if AppSettingsStore.automaticVectorRepairSignature(profileID: embeddingProfile.id) == repairSignature {
            return
        }

        var segmentsByTrackID: [UUID: [TrackSegment]] = [:]
        var trackEmbeddings: [UUID: [Double]] = [:]
        for track in readyTracks {
            guard let embedding = try database.fetchTrackEmbedding(trackID: track.id), !embedding.isEmpty else {
                continue
            }
            let segments = try database.fetchSegments(trackID: track.id).compactMap { segment -> TrackSegment? in
                guard let vector = segment.vector, !vector.isEmpty else { return nil }
                return segment
            }
            guard !segments.isEmpty else { continue }
            segmentsByTrackID[track.id] = segments
            trackEmbeddings[track.id] = embedding
        }

        try await worker.rebuildVectorIndex(
            tracks: readyTracks,
            segmentsByTrackID: segmentsByTrackID,
            trackEmbeddings: trackEmbeddings
        )
        AppSettingsStore.markAutomaticVectorRepair(profileID: embeddingProfile.id, signature: repairSignature)
        AppLogger.shared.info("Automatically rebuilt the \(embeddingProfile.id) vector index.")
    }

    private func vectorRepairSignature(profileID: String, pipelineID: String, manifestHash: String) -> String {
        let joined = [profileID, pipelineID, manifestHash].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func vectorIndexManifestHash(for tracks: [Track]) -> String {
        let lines = tracks.map {
            "\($0.id.uuidString)|\($0.filePath)|\($0.contentHash)|\(LibraryDatabase.iso8601.string(from: $0.modifiedTime))"
        }.sorted()
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func detectLibrarySources() async {
        let previousByKind = Dictionary(uniqueKeysWithValues: librarySources.map { ($0.kind, $0) })
        var detected = librarySyncService.detectAvailableSources(existing: librarySources, fallbackRoots: libraryRoots)
        detected = detected.map { source in
            var source = source
            if let previous = previousByKind[source.kind],
               previous.resolvedPath == nil,
               source.resolvedPath != nil,
               previous.lastSyncAt == nil,
               source.kind != .folderFallback
            {
                source.enabled = true
                source.status = .available
            }
            return source
        }

        librarySources = detected
        refreshDetectedVendorTargets()
        for source in detected {
            persistLibrarySource(source)
        }
    }

    private static func syncLibrariesInternal(
        service: DJLibrarySyncService,
        sources: [LibrarySourceRecord],
        onProgress: @escaping @Sendable (ScanJobProgress) -> Void
    ) async throws -> String? {
        guard !sources.isEmpty else { return nil }
        let summary = try await service.syncEnabledSources(sources, onProgress: onProgress)
        return summary.displayText
    }

    private static func runFallbackScanInternal(
        scanner: LibraryScannerService,
        roots: [URL],
        onProgress: @escaping @Sendable (ScanJobProgress) -> Void
    ) async -> String? {
        guard !roots.isEmpty else { return nil }
        await scanner.scan(roots: roots, onProgress: onProgress)
        return "Scanned Music Folders."
    }

    private func persistLibraryRoots() {
        LibraryRootsStore.saveRoots(libraryRoots)
        persistFolderFallbackSource()
        refreshDetectedVendorTargets()
    }

    private func persistFolderFallbackSource() {
        var folderFallbackSource = librarySources.first(where: { $0.kind == .folderFallback }) ?? .default(for: .folderFallback)
        folderFallbackSource.resolvedPath = libraryRoots.first
        folderFallbackSource.enabled = libraryRoots.first != nil
        folderFallbackSource.status = libraryRoots.first == nil ? .disabled : .available
        folderFallbackSource.lastError = nil
        persistLibrarySource(folderFallbackSource)
    }

    private func persistLibrarySource(_ source: LibrarySourceRecord) {
        if let index = librarySources.firstIndex(where: { $0.kind == source.kind }) {
            librarySources[index] = source
        } else {
            librarySources.append(source)
            librarySources.sort { $0.kind.rawValue < $1.kind.rawValue }
        }
        try? database.upsertLibrarySource(source)
    }

    private func refreshDetectedVendorTargets() {
        detectedVendorTargets = exporter.detectTargets(librarySources: librarySources)
    }

    private func refreshMembershipFacets() throws {
        seratoMembershipFacets = try database.fetchMembershipFacets(source: .serato)
        rekordboxMembershipFacets = try database.fetchMembershipFacets(source: .rekordbox)
    }

    nonisolated static func metadataImportStatusMessage(for summaries: [MetadataImportSummary]) -> String {
        guard !summaries.isEmpty else {
            return "No metadata files were imported."
        }

        let summaryText = summaries.map(\.displayText).joined(separator: " • ")
        let anyMatched = summaries.contains { $0.matchedLocalTracks > 0 }
        let anyUnmatched = summaries.contains { $0.unmatchedEntries > 0 }

        if !anyMatched {
            return "\(summaryText). No scanned local tracks matched the imported vendor metadata yet. Scan Music Folders first."
        }

        if anyUnmatched {
            return "\(summaryText). Some vendor entries did not match scanned local tracks yet."
        }

        return "\(summaryText)."
    }

    func membershipFacets(for source: ExternalDJMetadata.Source) -> [MembershipFacet] {
        switch source {
        case .serato:
            return seratoMembershipFacets
        case .rekordbox:
            return rekordboxMembershipFacets
        }
    }

    func selectedMembershipPaths(
        for source: ExternalDJMetadata.Source,
        target: ScopeFilterTarget
    ) -> Set<String> {
        Set(scopeFilter(for: target).selectedPaths(for: source))
    }

    func isMembershipSelected(
        _ membershipPath: String,
        source: ExternalDJMetadata.Source,
        target: ScopeFilterTarget
    ) -> Bool {
        selectedMembershipPaths(for: source, target: target).contains(membershipPath)
    }

    func scopeStatistics(for target: ScopeFilterTarget) -> ScopedTrackStatistics {
        filteredTrackCounts(for: scopeFilter(for: target))
    }

    func scopeFilter(for target: ScopeFilterTarget) -> LibraryScopeFilter {
        switch target {
        case .library:
            return libraryScopeFilter
        case .search, .recommendation:
            return recommendationScopeFilter
        }
    }

    private func applyScopeFilter(_ filter: LibraryScopeFilter, to target: ScopeFilterTarget) {
        switch target {
        case .library:
            libraryScopeFilter = filter
        case .search, .recommendation:
            recommendationScopeFilter = filter
        }
    }

    private func reconcileLibrarySelectionToVisibleTracks() {
        guard !selectedTrackIDs.isEmpty else { return }

        let visibleTrackIDs = Set(filteredTracks.map(\.id))
        let reconciledSelection = selectedTrackIDs.intersection(visibleTrackIDs)
        guard reconciledSelection != selectedTrackIDs else { return }

        updateSelectedTrackIDs(reconciledSelection, deferSideEffects: true)
    }

    private func filteredTrackCounts(for filter: LibraryScopeFilter) -> ScopedTrackStatistics {
        let scopedIDs = scopedTrackIDs(for: filter)
        let scopedTracks = tracks.filter { filter.isEmpty || scopedIDs.contains($0.id) }

        return scopedTracks.reduce(into: ScopedTrackStatistics(total: scopedTracks.count)) { counts, track in
            switch trackWorkflowStatus(for: track) {
            case .ready:
                counts.ready += 1
            case .needsAnalysis:
                counts.needsAnalysis += 1
            case .needsRefresh:
                counts.needsRefresh += 1
            }
            if track.hasSeratoMetadata {
                counts.seratoCoverage += 1
            }
            if track.hasRekordboxMetadata {
                counts.rekordboxCoverage += 1
            }
        }
    }

    private func scopedTrackIDs(for filter: LibraryScopeFilter) -> Set<UUID> {
        if filter.isEmpty {
            return Set(tracks.map(\.id))
        }
        if let cached = scopeTrackCache[filter] {
            return cached
        }
        let resolved = (try? database.fetchTrackIDs(matching: filter)) ?? []
        scopeTrackCache[filter] = resolved
        return resolved
    }

    private func tracksMatchingScope(_ filter: LibraryScopeFilter) -> [Track] {
        let scopedIDs = scopedTrackIDs(for: filter)
        return tracks.filter { filter.isEmpty || scopedIDs.contains($0.id) }
    }

    private func libraryTracksMatchingCurrentFilters(trackFilter: LibraryTrackFilter) -> [Track] {
        let scopedIDs = scopedTrackIDs(for: libraryScopeFilter)
        let searchTokens = Self.librarySearchTokens(from: librarySearchText)

        return tracks.filter { track in
            (libraryScopeFilter.isEmpty || scopedIDs.contains(track.id))
                && Self.libraryTrackMatchesSearch(track, searchTokens: searchTokens)
                && trackFilter.matches(trackWorkflowStatus(for: track))
        }
    }

    private static func libraryTrackMatchesSearch(_ track: Track, searchTokens: [String]) -> Bool {
        guard !searchTokens.isEmpty else { return true }

        let searchableText = [track.title, track.artist]
            .joined(separator: " ")
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return searchTokens.allSatisfy { searchableText.contains($0) }
    }

    static func shouldShowInitialSetup(
        hasTracks: Bool,
        initialSetupCompleted: Bool,
        hasNativeLibraries: Bool,
        hasExistingRoots: Bool,
        requiresGoogleAPIKeyPrompt: Bool
    ) -> Bool {
        let needsLibrarySetup = !hasTracks && !initialSetupCompleted && (hasNativeLibraries || !hasExistingRoots)
        return needsLibrarySetup || requiresGoogleAPIKeyPrompt
    }

    private func shouldShowInitialSetup(hasExistingRoots: Bool) -> Bool {
        let hasNativeLibraries = librarySources.contains { $0.kind != .folderFallback && $0.resolvedPath != nil }
        return Self.shouldShowInitialSetup(
            hasTracks: !tracks.isEmpty,
            initialSetupCompleted: LibraryRootsStore.isInitialSetupCompleted(),
            hasNativeLibraries: hasNativeLibraries,
            hasExistingRoots: hasExistingRoots,
            requiresGoogleAPIKeyPrompt: initialSetupNeedsGoogleAIAPIKey
        )
    }

    private func mergedReembeddedSegments(
        trackID: UUID,
        existingSegments: [TrackSegment],
        workerSegments: [WorkerSegmentResult]
    ) -> [TrackSegment]? {
        guard existingSegments.count == workerSegments.count else { return nil }

        var refreshed: [TrackSegment] = []
        for (existing, workerSegment) in zip(existingSegments, workerSegments) {
            guard
                let type = TrackSegment.SegmentType(rawValue: workerSegment.segmentType),
                type == existing.type
            else {
                return nil
            }

            refreshed.append(
                TrackSegment(
                    id: existing.id,
                    trackID: trackID,
                    type: existing.type,
                    startSec: existing.startSec,
                    endSec: existing.endSec,
                    energyScore: existing.energyScore,
                    descriptorText: existing.descriptorText,
                    vector: workerSegment.embedding
                )
            )
        }
        return refreshed
    }

    private func updateAnalysisState(
        trackID: UUID,
        state: AnalysisTaskState,
        message: String? = nil,
        updatedAt: Date = Date()
    ) {
        analysisStateByTrackID[trackID] = TrackAnalysisState(
            state: state,
            message: message,
            updatedAt: updatedAt
        )
    }

    private func collectionDisplayName(_ collection: String) -> String {
        switch collection {
        case "tracks":
            return "Track"
        case "intro":
            return "Intro"
        case "middle":
            return "Middle"
        case "outro":
            return "Outro"
        default:
            return collection.capitalized
        }
    }

}

private enum AnalysisMode {
    case batch
}

private enum AnalysisWorkerOutcome: Sendable {
    case succeeded(AnalysisTaskOutput)
    case failed(AnalysisFailedTask)
}

private struct AnalysisFailedTask: Sendable {
    let workItem: AnalysisWorkItem
    let errorMessage: String
    let wasCancelled: Bool
    let elapsedMs: Int
}

private struct RecommendationResolvedInput {
    let state: RecommendationInputState
    let readyReferenceTracks: [Track]
    let referencePayload: (
        trackEmbedding: [Double],
        segments: [TrackSegment],
        excludeTrackPaths: Set<String>
    )?
}

private struct RecommendationSeedContext {
    let seed: Track
    let similarityMap: [String: Double]
    let vectorBreakdownByPath: [String: VectorScoreBreakdown]
    let candidateCountBeforeScope: Int
    let candidateCountAfterScope: Int
}

private struct VectorSearchCandidate {
    let track: Track
    let vectorBreakdown: VectorScoreBreakdown
    let matchedMemberships: [String]
}

private struct VectorSearchExecution {
    let candidates: [VectorSearchCandidate]
    let candidateCountBeforeScope: Int
    let candidateCountAfterScope: Int
}

private struct SimilarityState {
    let similarityMap: [String: Double]
    let vectorBreakdownByPath: [String: VectorScoreBreakdown]
    let candidateCountBeforeScope: Int
    let candidateCountAfterScope: Int
}

private enum RecommendationResolutionError: LocalizedError {
    case missingReferenceTrack
    case missingReferencePayload
    case noSemanticSeed

    var errorDescription: String? {
        switch self {
        case .missingReferenceTrack:
            return "Select a ready reference track first."
        case .missingReferencePayload:
            return "Selected reference track data is not ready for recommendations yet."
        case .noSemanticSeed:
            return "No seed track matched the current recommendation filters."
        }
    }
}

struct MetadataImportSummary {
    let source: ExternalDJMetadata.Source
    let importedEntries: Int
    let matchedLocalTracks: Int
    let unmatchedEntries: Int
    let referenceAttachmentCount: Int

    nonisolated var displayText: String {
        let sourceName = source == .rekordbox ? "rekordbox" : "Serato"
        return "\(sourceName): \(matchedLocalTracks) matched local tracks / \(unmatchedEntries) unmatched / \(referenceAttachmentCount) references"
    }
}
