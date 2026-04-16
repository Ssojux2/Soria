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

    private enum UITestLibraryState: String {
        case empty
        case prepared
        case analyzing
    }

    enum AnalysisSessionResult: Equatable {
        case succeeded
        case canceled
        case failed(String?)
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
    @Published var recommendationScopeFilter = LibraryScopeFilter()
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
    @Published var recommendationStatusMessage: String = ""
    @Published var recommendationQueryText: String = ""
    @Published var recommendationResultLimit: Int = 20 {
        didSet {
            let clamped = RecommendationInputState.clampedResultLimit(recommendationResultLimit)
            if recommendationResultLimit != clamped {
                recommendationResultLimit = clamped
            }
        }
    }
    @Published var libraryStatusMessage: String = ""
    @Published var exportMessage: String = ""
    @Published var exportWarnings: [String] = []
    @Published var exportDestinationDescription: String = ""
    @Published var weights = RecommendationWeights() {
        didSet { persistRecommendationScoringSettings() }
    }
    @Published var vectorWeights = MixsetVectorWeights() {
        didSet { persistRecommendationScoringSettings() }
    }
    @Published var constraints = RecommendationConstraints() {
        didSet { persistRecommendationScoringSettings() }
    }
    @Published var playlistTracks: [Track] = []
    @Published var playlistTargetCount: Int = 8
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
    @Published var embeddingProfile: EmbeddingProfile {
        didSet {
            refreshValidationStatus()
            recommendations = []
            recommendationStatusMessage = ""
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

    private let database: LibraryDatabase
    private let recommendationEngine = RecommendationEngine()
    private let exporter = PlaylistExportService()
    private let externalMetadataImporter = ExternalMetadataService()
    private let externalVisualizationResolver = ExternalVisualizationResolver()
    private var pendingAnalyzeAllTrackIDs: [UUID] = []
    private var analysisTask: Task<Void, Never>?
    private var analysisWatchdogTask: Task<Void, Never>?
    private var workerHealthTask: Task<Void, Never>?
    private var validationTask: Task<Void, Never>?
    private var readyTrackIDs: Set<UUID> = []
    private var pendingAnalysisTrackIDs: [UUID] = []
    private var membershipSnapshotsByTrackID: [UUID: TrackMembershipSnapshot] = [:]
    private var scopeTrackCache: [LibraryScopeFilter: Set<UUID>] = [:]
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

        if processArguments.contains(Self.uiTestMixAssistantArgument) {
            selectedSection = .mixAssistant
        }

        let loadedAPIKey = AppSettingsStore.loadGoogleAIAPIKey(
            arguments: processArguments,
            environment: processEnvironment
        )
        let loadedPythonPath = AppSettingsStore.loadPythonExecutablePath()
        let loadedWorkerPath = AppSettingsStore.loadWorkerScriptPath()
        let loadedProfile = AppSettingsStore.loadEmbeddingProfile()
        let loadedWeights = AppSettingsStore.loadRecommendationWeights()
        let loadedVectorWeights = AppSettingsStore.loadMixsetVectorWeights()
        let loadedConstraints = AppSettingsStore.loadRecommendationConstraints()

        self.googleAIAPIKey = loadedAPIKey
        self.pythonExecutablePath = loadedPythonPath
        self.workerScriptPath = loadedWorkerPath
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
        let scopedIDs = scopedTrackIDs(for: libraryScopeFilter)
        return tracks.filter { track in
            (libraryScopeFilter.isEmpty || scopedIDs.contains(track.id))
                && libraryTrackFilter.matches(trackWorkflowStatus(for: track))
        }
    }

    var selectedTrackSummaryLabel: String {
        selectedTracks.map { "\($0.title) - \($0.artist)" }.joined(separator: ", ")
    }

    var selectedRecommendation: RecommendationCandidate? {
        guard let selectedRecommendationID else { return nil }
        return recommendations.first(where: { $0.id == selectedRecommendationID })
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
        librarySources.contains { $0.enabled && $0.resolvedPath != nil }
    }

    var hasSourceSetupIssue: Bool {
        tracks.isEmpty && !hasSyncableLibrarySource
    }

    var preparationBlockedMessage: String? {
        if let dependencyMessage = selectedEmbeddingProfileDependencyMessage {
            return dependencyMessage
        }
        if !hasValidatedEmbeddingProfile {
            return "Validate the active analysis setup in Settings before preparing tracks."
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

    var canRunRecommendationActions: Bool {
        guard hasValidatedEmbeddingProfile, isSelectedEmbeddingProfileSupported else { return false }
        return recommendationInputState != nil
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

    var canAnalyzePendingSelection: Bool {
        guard hasValidatedEmbeddingProfile, isSelectedEmbeddingProfileSupported else { return false }
        return selectionReadiness.pendingCount > 0 && !isAnalyzing && !isCancellingAnalysis
    }

    var canAnalyzeVisibleTracks: Bool {
        guard hasValidatedEmbeddingProfile, isSelectedEmbeddingProfileSupported else { return false }
        return filteredTracks.contains { trackWorkflowStatus(for: $0) != .ready } && !isAnalyzing && !isCancellingAnalysis
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
        tracks.filter { filter.matches(trackWorkflowStatus(for: $0)) }.count
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
        analysisActivity = activity
        isAnalysisActivityPanelExpanded = true
        updateAnalysisQueueTextFromActivity()
    }

    private func recordAnalysisProgress(
        _ event: WorkerProgressEvent,
        trackID: UUID,
        trackTitle: String,
        trackPath: String,
        queueIndex: Int,
        totalCount: Int
    ) {
        if analysisActivity?.currentTrackPath != trackPath || analysisActivity?.queueIndex != queueIndex {
            analysisActivity = AnalysisActivity.started(
                trackTitle: trackTitle,
                trackPath: trackPath,
                queueIndex: queueIndex,
                totalCount: totalCount,
                timeoutSec: workerTimeoutSec
            )
            isAnalysisActivityPanelExpanded = true
        }

        analysisActivity?.recordProgress(
            event,
            trackTitle: trackTitle,
            fallbackTrackPath: trackPath,
            queueIndex: queueIndex,
            totalCount: totalCount
        )
        AppLogger.shared.info(
            "Analysis progress | stage=\(event.stage.rawValue) | queue=\(queueIndex)/\(totalCount) | trackPath=\(trackPath) | message=\(event.message)"
        )
        updateAnalysisState(trackID: trackID, state: .running, message: event.stage.displayName, updatedAt: event.timestamp)
        updateAnalysisQueueTextFromActivity()
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
        if analysisActivity?.currentTrackPath != track.filePath || analysisActivity?.queueIndex != queueIndex {
            startAnalysisActivity(for: track, queueIndex: queueIndex, totalCount: totalCount, stage: .queued)
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
        analysisActivity?.markFinished(
            state: state,
            errorMessage: errorMessage,
            message: message
        )
        updateAnalysisQueueTextFromActivity()
    }

    private func updateAnalysisQueueTextFromActivity() {
        guard let activity = analysisActivity else { return }
        let queueText = "\(activity.queueIndex) / \(activity.totalCount)"
        if activity.isFinished {
            analysisQueueProgressText = "\(activity.headlineText) • \(activity.currentTrackTitle) (\(queueText))"
        } else {
            analysisQueueProgressText = "\(activity.currentMessage) • \(activity.currentTrackTitle) (\(queueText))"
        }
    }

    private func prepareAnalysisSession(for tracks: [Track]) {
        guard let firstTrack = tracks.first else {
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
        isAnalysisActivityPanelExpanded = true
        updateAnalysisQueueTextFromActivity()
    }

    private func scheduleAnalysisProgressWatchdog(
        trackID: UUID,
        trackTitle: String,
        trackPath: String,
        queueIndex: Int,
        totalCount: Int
    ) {
        analysisWatchdogTask?.cancel()
        let thresholdSec = analysisWatchdogDelaySec
        analysisWatchdogTask = Task { [weak self] in
            let delayNs = UInt64(max(thresholdSec, 1) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                guard
                    self.isAnalyzing,
                    !self.isCancellingAnalysis,
                    let activity = self.analysisActivity,
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

    private func cancelAnalysisProgressWatchdog() {
        analysisWatchdogTask?.cancel()
        analysisWatchdogTask = nil
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
        recommendations = []
        recommendationStatusMessage = ""
        recommendationQueryText = ""
        recommendationResultLimit = 20
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
        analysisActivity = fixture.analysisActivity
        scanProgress = ScanJobProgress()
        librarySources = fixture.librarySources
        libraryStatusMessage = fixture.libraryStatusMessage
        seratoMembershipFacets = fixture.seratoMembershipFacets
        rekordboxMembershipFacets = fixture.rekordboxMembershipFacets
        readyTrackIDs = fixture.readyTrackIDs
        membershipSnapshotsByTrackID = [:]
        scopeTrackCache.removeAll()
        pendingAnalyzeAllTrackIDs = []
        pendingAnalysisTrackIDs = fixture.pendingAnalysisTrackIDs
        isAnalyzing = fixture.isAnalyzing
        isCancellingAnalysis = false
        analysisErrorMessage = ""
        preparationNotice = nil
        isScopeInspectorPresented = false
        activeScopeInspectorTarget = nil
        validationStatus = fixture.validationStatus
        workerProfileStatuses = [:]
        settingsStatusMessage = ""
        libraryRoots = []
        isShowingInitialSetupSheet = false
        isRunningInitialSetup = false
        initialSetupStatusMessage = ""
        if analysisActivity != nil {
            updateAnalysisQueueTextFromActivity()
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
        analysisActivity: AnalysisActivity?,
        pendingAnalysisTrackIDs: [UUID],
        isAnalyzing: Bool,
        validationStatus: ValidationStatus,
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
                analysisActivity: nil,
                pendingAnalysisTrackIDs: [],
                isAnalyzing: false,
                validationStatus: .unvalidated,
                seratoMembershipFacets: facets.serato,
                rekordboxMembershipFacets: facets.rekordbox
            )
        case .prepared, .analyzing:
            let readyTrackID = UUID()
            let pendingTrackID = UUID()

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
                embeddingProfileID: EmbeddingProfile.googleGeminiEmbedding001.id,
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
                analyzedAt: nil,
                embeddingProfileID: nil,
                embeddingUpdatedAt: nil,
                hasSeratoMetadata: true,
                hasRekordboxMetadata: false,
                bpmSource: .audioTags,
                keySource: .audioTags
            )

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

            return (
                tracks: [readyTrack, pendingTrack],
                readyTrackIDs: Set([readyTrackID]),
                librarySources: [seratoSource, rekordboxSource, fallbackSource],
                libraryStatusMessage: "",
                selectedTrackIDs: state == .analyzing ? Set([pendingTrackID]) : [],
                analysisStateByTrackID: state == .analyzing
                    ? [
                        pendingTrackID: TrackAnalysisState(
                            state: .running,
                            message: AnalysisStage.launching.displayName,
                            updatedAt: now
                        )
                    ]
                    : [:],
                analysisActivity: analysisActivity,
                pendingAnalysisTrackIDs: state == .analyzing ? [pendingTrackID] : [],
                isAnalyzing: state == .analyzing,
                validationStatus: state == .analyzing ? .validated(now) : .unvalidated,
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

        if context.isAnalyzing || context.isCancellingAnalysis {
            let progress = context.analysisActivity?.overallProgress
            let trackSummary: String
            if let activity = context.analysisActivity {
                trackSummary = activity.totalCount > 1
                    ? "\(activity.queueIndex) of \(activity.totalCount) • \(activity.currentTrackTitle)"
                    : activity.currentTrackTitle
            } else {
                trackSummary = "Preparing tracks for the active analysis setup."
            }
            return PreparationOverviewState(
                phase: .analyzing,
                title: context.isCancellingAnalysis ? "Stopping Preparation" : "Preparing Tracks",
                message: trackSummary,
                progress: progress,
                primaryAction: nil,
                secondaryAction: nil,
                isCancellable: true,
                showSuccess: false
            )
        }

        if context.scanProgress.isRunning || !context.syncingSourceNames.isEmpty {
            let sourceSummary = context.syncingSourceNames.isEmpty
                ? "Updating indexed library files."
                : "Updating \(context.syncingSourceNames.joined(separator: ", "))."
            let progress = context.scanProgress.totalFiles > 0
                ? Double(context.scanProgress.scannedFiles) / Double(max(context.scanProgress.totalFiles, 1))
                : nil
            let detail = context.scanProgress.currentFile.isEmpty
                ? sourceSummary
                : "\(sourceSummary) Current: \(context.scanProgress.currentFile)"
            return PreparationOverviewState(
                phase: .syncing,
                title: "Syncing Library",
                message: detail,
                progress: progress,
                primaryAction: nil,
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
                primaryAction: context.canPrepareSelection ? .prepareSelection : (context.canPrepareVisible ? .prepareVisible : syncAction),
                secondaryAction: context.canPrepareSelection || context.canPrepareVisible ? syncAction : nil,
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
                primaryAction: context.canPrepareSelection ? .prepareSelection : (context.canPrepareVisible ? .prepareVisible : syncAction),
                secondaryAction: context.canPrepareSelection || context.canPrepareVisible ? syncAction : nil,
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
                primaryAction: context.canPrepareSelection ? .prepareSelection : syncAction,
                secondaryAction: context.canPrepareSelection ? syncAction : nil,
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
                primaryAction: context.canPrepareVisible ? .prepareVisible : syncAction,
                secondaryAction: context.canPrepareVisible ? syncAction : nil,
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

    private func decoratedAnalysisError(_ error: Error) -> String {
        var segments: [String] = []
        let baseMessage = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !baseMessage.isEmpty {
            segments.append(baseMessage)
        }
        if let activity = analysisActivity {
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
        let hasNativeSelection = librarySources.contains {
            $0.kind != .folderFallback && $0.enabled && $0.resolvedPath != nil
        }
        let hasFallbackFolder = !initialSetupLibraryRoot.isEmpty

        guard hasNativeSelection || hasFallbackFolder else {
            initialSetupStatusMessage = "Enable Serato or rekordbox, or choose a fallback folder first."
            return
        }

        if hasFallbackFolder {
            addLibraryRoots([initialSetupLibraryRoot])
        }
        selectedSection = .library
        initialSetupStatusMessage = "Detecting DJ libraries..."
        isRunningInitialSetup = true

        Task {
            await detectLibrarySources()

            do {
                let nativeSummary = try await syncLibrariesInternal()
                let fallbackSummary = await runFallbackScanInternal()
                await refreshTracks()
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
        preparationNotice = nil
        Task {
            let sourceNames = librarySources
                .filter { $0.kind != .folderFallback && $0.enabled && $0.resolvedPath != nil }
                .map(\.kind.displayName)
                .joined(separator: ",")
            AppLogger.shared.info("Library sync started | sources=\(sourceNames)")
            do {
                let summary = try await syncLibrariesInternal()
                libraryStatusMessage = summary ?? "No DJ library sources were synced."
                AppLogger.shared.info("Library sync completed | summary=\(libraryStatusMessage)")
                await refreshTracks()
            } catch {
                libraryStatusMessage = "Library sync failed: \(error.localizedDescription)"
                AppLogger.shared.error("Library sync failed: \(error.localizedDescription)")
            }
        }
    }

    func runFallbackScan() {
        preparationNotice = nil
        Task {
            AppLogger.shared.info(
                "Fallback scan started | rootCount=\(libraryRoots.count) | roots=\(libraryRoots.joined(separator: ","))"
            )
            let summary = await runFallbackScanInternal()
            if let summary {
                libraryStatusMessage = summary
                AppLogger.shared.info(
                    "Fallback scan completed | summary=\(summary) | scanned=\(scanProgress.scannedFiles) | indexed=\(scanProgress.indexedFiles) | skipped=\(scanProgress.skippedFiles) | duplicates=\(scanProgress.duplicateFiles)"
                )
            }
            await refreshTracks()
        }
    }

    func preparationActionTitle(_ action: PreparationOverviewAction) -> String {
        switch action {
        case .prepareSelection:
            return selectionReadiness.selectedCount == 1 ? "Prepare Track" : "Prepare Selection"
        case .prepareVisible:
            return "Prepare Visible"
        case .syncLibrary:
            return "Sync Libraries"
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
        let hasEnabledNativeSource = librarySources.contains {
            $0.kind != .folderFallback && $0.enabled && $0.resolvedPath != nil
        }

        if hasEnabledNativeSource {
            syncLibraries()
            return
        }

        let hasEnabledFallbackSource = librarySources.contains {
            $0.kind == .folderFallback && $0.enabled && $0.resolvedPath != nil
        }
        if hasEnabledFallbackSource {
            runFallbackScan()
            return
        }

        AppLogger.shared.info("Library sync skipped | reason=no_enabled_sources")
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
                recommendations = []
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

    func dismissPreparationNotice() {
        preparationNotice = nil
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
                return "All library files"
            case .search, .recommendation:
                return "All ready tracks from synced DJ libraries"
            }
        }

        let filterLabel = filter.selectedFacetCount == 1 ? "filter" : "filters"
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
        let targets = filteredTracks.filter { trackWorkflowStatus(for: $0) != .ready }
        guard !targets.isEmpty else {
            analysisQueueProgressText = "Everything visible in the current library scope is already ready."
            return
        }
        analysisScope = .selectedTrack
        startAnalysis(for: targets)
    }

    func analyzeScopedTracks(for target: ScopeFilterTarget) {
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

    func requestAnalysis() {
        preparationNotice = nil
        guard isSelectedEmbeddingProfileSupported else {
            analysisErrorMessage = selectedEmbeddingProfileDependencyMessage ?? "The current analysis setup is unavailable."
            return
        }
        guard hasValidatedEmbeddingProfile else {
            analysisErrorMessage = "Validate the current analysis setup in Settings before analyzing tracks."
            return
        }
        if isAnalyzing {
            analysisErrorMessage = "Analysis is running. Cancel it first."
            return
        }

        let targets = analysisScope.resolveTracks(
            from: tracks,
            selectedTrackIDs: selectedTrackIDs,
            readyTrackIDs: readyTrackIDs,
            activeProfileID: embeddingProfile.id
        )
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
        prepareAnalysisSession(for: targets)
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
        cancelAnalysisProgressWatchdog()

        if analysisTask == nil {
            finalizeAnalysisSession(result: .canceled)
        }
    }

    func finalizeAnalysisSession(result: AnalysisSessionResult) {
        let pendingTrackIDs = pendingAnalysisTrackIDs

        cancelAnalysisProgressWatchdog()
        isAnalyzing = false
        isCancellingAnalysis = false
        analysisTask = nil
        pendingAnalysisTrackIDs = []

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
                }
            }
            if let activity = analysisActivity, !activity.isFinished {
                var updatedActivity = activity
                updatedActivity.markFinished(state: AnalysisTaskState.canceled, message: "Canceled by user")
                analysisActivity = updatedActivity
                updateAnalysisQueueTextFromActivity()
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
                updateAnalysisQueueTextFromActivity()
            }
        }
    }

    func generateRecommendations(limit: Int? = nil) {
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

        Task {
            do {
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
                recommendations = recs.map { candidate in
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
                selectedRecommendationID = recs.first?.id
                if recs.isEmpty {
                    recommendationStatusMessage = "No recommendations found for the current inputs."
                } else if input.state.requiresSemanticSeed {
                    recommendationStatusMessage = "Generated \(recs.count) matches from semantic seed: \(seedContext.seed.title)."
                } else {
                    recommendationStatusMessage = "Generated \(recs.count) matches."
                }
            } catch {
                recommendationStatusMessage = "Recommendation failed: \(error.localizedDescription)"
                AppLogger.shared.error("Recommendation failed: \(error.localizedDescription)")
            }
        }
    }

    func buildPlaylistPath() {
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

        Task {
            do {
                let effectiveConstraints = effectiveRecommendationConstraints
                let embeddingsByTrackID = try loadTrackEmbeddings()
                let summariesByTrackID = try loadAnalysisSummaries(trackIDs: Array(readyTrackIDs))
                let excludedReferenceTrackIDs = Set(input.readyReferenceTracks.map(\.id))
                let targetCount = max(2, playlistTargetCount)
                let seedContext = try await resolveRecommendationSeedContext(
                    input: input,
                    embeddingsByTrackID: embeddingsByTrackID,
                    summariesByTrackID: summariesByTrackID,
                    limit: max(targetCount * 2, 25),
                    excludedPaths: []
                )
                var pathTracks: [Track] = [seedContext.seed]
                var pathCandidates: [RecommendationCandidate] = [
                    RecommendationCandidate(
                        id: seedContext.seed.id,
                        track: seedContext.seed,
                        score: 1.0,
                        breakdown: ScoreBreakdown(
                            embeddingSimilarity: 1,
                            bpmCompatibility: 1,
                            harmonicCompatibility: 1,
                            energyFlow: 1,
                            transitionRegionMatch: 1,
                            externalMetadataScore: 1
                        ),
                        vectorBreakdown: VectorScoreBreakdown(
                            fusedScore: 1,
                            trackScore: 1,
                            introScore: 1,
                            middleScore: 1,
                            outroScore: 1,
                            bestMatchedCollection: "tracks"
                        ),
                        analysisFocus: summariesByTrackID[seedContext.seed.id]?.analysisFocus,
                        mixabilityTags: summariesByTrackID[seedContext.seed.id]?.mixabilityTags ?? [],
                        matchReasons: ["Seed track"],
                        matchedMemberships: membershipSnapshotsByTrackID[seedContext.seed.id]?
                            .matchedPaths(scopeFilter: recommendationScopeFilter) ?? [],
                        scoreSessionID: nil
                    )
                ]
                var current = seedContext.seed

                while pathTracks.count < targetCount {
                    let similarityState = try await similarityState(
                        seed: current,
                        filters: WorkerSimilarityFilters(
                            bpmMin: effectiveConstraints.targetBPMMin,
                            bpmMax: effectiveConstraints.targetBPMMax,
                            durationMaxSec: effectiveConstraints.maxDurationMinutes.map { $0 * 60 },
                            musicalKey: effectiveConstraints.keyStrictness > 0.85 ? current.musicalKey : nil,
                            genre: effectiveConstraints.genreContinuity > 0.85 ? current.genre : nil
                        ),
                        limit: max(15, targetCount * 2),
                        excludedPaths: Set(pathTracks.map(\.filePath)),
                        scopeFilter: recommendationScopeFilter
                    )
                    let nextCandidate = recommendationEngine.recommendNextTracks(
                        seed: current,
                        candidates: tracks.filter { readyTrackIDs.contains($0.id) },
                        embeddingsByTrackID: embeddingsByTrackID,
                        summariesByTrackID: summariesByTrackID,
                        vectorSimilarityByPath: similarityState.similarityMap,
                        vectorBreakdownByPath: similarityState.vectorBreakdownByPath,
                        constraints: constraints,
                        weights: weights,
                        vectorWeights: vectorWeights,
                        limit: 1,
                        excludeTrackIDs: Set(pathTracks.map(\.id)).union(excludedReferenceTrackIDs)
                    ).first

                    guard let nextCandidate else { break }
                    pathTracks.append(nextCandidate.track)
                    pathCandidates.append(nextCandidate)
                    current = nextCandidate.track
                }

                playlistTracks = pathTracks
                _ = try persistRecommendationSession(
                    kind: .playlistPath,
                    queryText: input.state.trimmedQueryText,
                    seedTrackID: seedContext.seed.id,
                    referenceTrackIDs: input.readyReferenceTracks.map(\.id),
                    candidates: pathCandidates,
                    candidateCountBeforeScope: seedContext.candidateCountBeforeScope,
                    candidateCountAfterScope: seedContext.candidateCountAfterScope,
                    resultLimit: targetCount
                )
                recommendationStatusMessage = "Built \(pathTracks.count)-track path from seed: \(seedContext.seed.title)"
            } catch {
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
            tracks = try database.fetchAllTracks()
            readyTrackIDs = try database.fetchReadyTrackIDs(profileID: embeddingProfile.id)
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
        if analysisActivity == nil {
            prepareAnalysisSession(for: tracksToAnalyze)
        }
        isCancellingAnalysis = false
        let batchStartedAt = Date()
        var sessionResult: AnalysisSessionResult = .succeeded
        defer {
            finalizeAnalysisSession(result: sessionResult)
        }

        for (index, track) in tracksToAnalyze.enumerated() {
            let queueIndex = index + 1
            let trackStartedAt = Date()
            if Task.isCancelled {
                sessionResult = .canceled
                analysisQueueProgressText = "Canceled: \(index) / \(tracksToAnalyze.count)"
                for pendingTrack in tracksToAnalyze[index...] {
                    updateAnalysisState(trackID: pendingTrack.id, state: .canceled, message: "Canceled")
                }
                break
            }

            do {
                startAnalysisActivity(for: track, queueIndex: queueIndex, totalCount: tracksToAnalyze.count, stage: .launching)
                updateAnalysisState(trackID: track.id, state: .running, message: AnalysisStage.launching.displayName)
                scheduleAnalysisProgressWatchdog(
                    trackID: track.id,
                    trackTitle: track.title,
                    trackPath: track.filePath,
                    queueIndex: queueIndex,
                    totalCount: tracksToAnalyze.count
                )
                logAnalysisEvent(
                    "track_started",
                    track: track,
                    queueIndex: queueIndex,
                    totalCount: tracksToAnalyze.count,
                    extra: ["mode": "\(mode)"]
                )
                let externalMetadata = try database.fetchExternalMetadata(trackID: track.id)
                let existingSegments = try database.fetchSegments(trackID: track.id)
                let existingSummary = try database.fetchAnalysisSummary(trackID: track.id)
                let canReembed = track.analyzedAt != nil
                    && !readyTrackIDs.contains(track.id)
                    && !existingSegments.isEmpty
                    && existingSummary != nil
                    && existingSummary?.analysisFocus == analysisFocus
                let trackID = track.id
                let trackTitle = track.title
                let trackPath = track.filePath
                let progressHandler: PythonWorkerClient.WorkerProgressHandler = { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.recordAnalysisProgress(
                            event,
                            trackID: trackID,
                            trackTitle: trackTitle,
                            trackPath: trackPath,
                            queueIndex: queueIndex,
                            totalCount: tracksToAnalyze.count
                        )
                    }
                }

                if canReembed {
                    let workerStartedAt = Date()
                    let result = try await worker.embedDescriptors(
                        track: track,
                        segments: existingSegments,
                        externalMetadata: externalMetadata,
                        progress: progressHandler
                    )
                    logAnalysisEvent(
                        "worker_embed_descriptors_completed",
                        track: track,
                        queueIndex: queueIndex,
                        totalCount: tracksToAnalyze.count,
                        elapsedMs: max(Int(Date().timeIntervalSince(workerStartedAt) * 1000), 0),
                        extra: [
                            "embeddingProfileID": result.embeddingProfileID,
                            "segmentCount": "\(result.segments.count)"
                        ]
                    )
                    guard let refreshedSegments = mergedReembeddedSegments(
                        trackID: track.id,
                        existingSegments: existingSegments,
                        workerSegments: result.segments
                    ) else {
                        throw WorkerError.executionFailed("Stored descriptor segments no longer match the re-embedded payload.")
                    }
                    guard let trackEmbedding = result.trackEmbedding, !trackEmbedding.isEmpty else {
                        throw WorkerError.executionFailed("Worker returned an empty track embedding for re-embedding.")
                    }

                    let replaceStartedAt = Date()
                    try database.replaceTrackEmbeddings(
                        trackID: track.id,
                        segments: refreshedSegments,
                        trackEmbedding: trackEmbedding
                    )
                    logAnalysisEvent(
                        "database_replace_track_embeddings_completed",
                        track: track,
                        queueIndex: queueIndex,
                        totalCount: tracksToAnalyze.count,
                        elapsedMs: max(Int(Date().timeIntervalSince(replaceStartedAt) * 1000), 0),
                        extra: ["segmentCount": "\(refreshedSegments.count)"]
                    )
                    let vectorUpsertStartedAt = Date()
                    try await worker.upsertTrackVectors(track: track, segments: refreshedSegments, trackEmbedding: trackEmbedding)
                    logAnalysisEvent(
                        "worker_upsert_track_vectors_completed",
                        track: track,
                        queueIndex: queueIndex,
                        totalCount: tracksToAnalyze.count,
                        elapsedMs: max(Int(Date().timeIntervalSince(vectorUpsertStartedAt) * 1000), 0)
                    )
                    let markIndexedStartedAt = Date()
                    try database.markTrackEmbeddingIndexed(trackID: track.id, embeddingProfileID: result.embeddingProfileID)
                    logAnalysisEvent(
                        "database_mark_track_embedding_indexed_completed",
                        track: track,
                        queueIndex: queueIndex,
                        totalCount: tracksToAnalyze.count,
                        elapsedMs: max(Int(Date().timeIntervalSince(markIndexedStartedAt) * 1000), 0),
                        extra: ["embeddingProfileID": result.embeddingProfileID]
                    )
                    updateAnalysisState(trackID: track.id, state: .succeeded, message: "Done")
                    cancelAnalysisProgressWatchdog()
                    finishAnalysisActivity(
                        state: .succeeded,
                        for: track,
                        queueIndex: queueIndex,
                        totalCount: tracksToAnalyze.count
                    )
                } else {
                    let workerStartedAt = Date()
                    let result = try await worker.analyze(
                        filePath: track.filePath,
                        track: track,
                        analysisFocus: analysisFocus,
                        externalMetadata: externalMetadata,
                        progress: progressHandler
                    )
                    logAnalysisEvent(
                        "worker_analyze_completed",
                        track: track,
                        queueIndex: queueIndex,
                        totalCount: tracksToAnalyze.count,
                        elapsedMs: max(Int(Date().timeIntervalSince(workerStartedAt) * 1000), 0),
                        extra: [
                            "embeddingProfileID": result.embeddingProfileID,
                            "segmentCount": "\(result.segments.count)"
                        ]
                    )
                    let segments = result.segments.compactMap { item -> TrackSegment? in
                        guard let type = TrackSegment.SegmentType(rawValue: item.segmentType) else { return nil }
                        return TrackSegment(
                            id: UUID(),
                            trackID: track.id,
                            type: type,
                            startSec: item.startSec,
                            endSec: item.endSec,
                            energyScore: item.energyScore,
                            descriptorText: item.descriptorText,
                            vector: item.embedding
                        )
                    }
                    guard let trackEmbedding = result.trackEmbedding, !trackEmbedding.isEmpty else {
                        throw WorkerError.executionFailed("Worker returned an empty track embedding during analysis.")
                    }

                    let summary = TrackAnalysisSummary(
                        trackID: track.id,
                        segments: segments,
                        trackEmbedding: trackEmbedding,
                        estimatedBPM: result.estimatedBPM,
                        estimatedKey: result.estimatedKey,
                        brightness: result.brightness,
                        onsetDensity: result.onsetDensity,
                        rhythmicDensity: result.rhythmicDensity,
                        lowMidHighBalance: result.lowMidHighBalance,
                        waveformPreview: result.waveformPreview,
                        analysisFocus: result.analysisFocus,
                        introLengthSec: result.introLengthSec,
                        outroLengthSec: result.outroLengthSec,
                        energyArc: result.energyArc,
                        mixabilityTags: result.mixabilityTags,
                        confidence: result.confidence
                    )
                    let replaceStartedAt = Date()
                    try database.replaceSegments(
                        trackID: track.id,
                        segments: segments,
                        analysisSummary: summary
                    )
                    logAnalysisEvent(
                        "database_replace_segments_completed",
                        track: track,
                        queueIndex: queueIndex,
                        totalCount: tracksToAnalyze.count,
                        elapsedMs: max(Int(Date().timeIntervalSince(replaceStartedAt) * 1000), 0),
                        extra: ["segmentCount": "\(segments.count)"]
                    )

                    if var updatedTrack = tracks.first(where: { $0.id == track.id }) {
                        if shouldAdoptMetadataValue(
                            result.estimatedBPM,
                            from: .soriaAnalysis,
                            over: updatedTrack.bpm,
                            currentSource: updatedTrack.bpmSource
                        ) {
                            updatedTrack.bpm = result.estimatedBPM
                            updatedTrack.bpmSource = .soriaAnalysis
                        }
                        if shouldAdoptMetadataValue(
                            result.estimatedKey,
                            from: .soriaAnalysis,
                            over: updatedTrack.musicalKey,
                            currentSource: updatedTrack.keySource
                        ) {
                            updatedTrack.musicalKey = result.estimatedKey
                            updatedTrack.keySource = .soriaAnalysis
                        }
                        updatedTrack.analyzedAt = Date()
                        updatedTrack.embeddingProfileID = nil
                        updatedTrack.embeddingUpdatedAt = nil
                        let upsertTrackStartedAt = Date()
                        try database.upsertTrack(updatedTrack)
                        logAnalysisEvent(
                            "database_upsert_track_completed",
                            track: track,
                            queueIndex: queueIndex,
                            totalCount: tracksToAnalyze.count,
                            elapsedMs: max(Int(Date().timeIntervalSince(upsertTrackStartedAt) * 1000), 0)
                        )
                        let vectorUpsertStartedAt = Date()
                        try await worker.upsertTrackVectors(track: updatedTrack, segments: segments, trackEmbedding: trackEmbedding)
                        logAnalysisEvent(
                            "worker_upsert_track_vectors_completed",
                            track: track,
                            queueIndex: queueIndex,
                            totalCount: tracksToAnalyze.count,
                            elapsedMs: max(Int(Date().timeIntervalSince(vectorUpsertStartedAt) * 1000), 0)
                        )
                        let markIndexedStartedAt = Date()
                        try database.markTrackEmbeddingIndexed(trackID: track.id, embeddingProfileID: result.embeddingProfileID)
                        logAnalysisEvent(
                            "database_mark_track_embedding_indexed_completed",
                            track: track,
                            queueIndex: queueIndex,
                            totalCount: tracksToAnalyze.count,
                            elapsedMs: max(Int(Date().timeIntervalSince(markIndexedStartedAt) * 1000), 0),
                            extra: ["embeddingProfileID": result.embeddingProfileID]
                        )
                    }
                    updateAnalysisState(trackID: track.id, state: .succeeded, message: "Done")
                    cancelAnalysisProgressWatchdog()
                    finishAnalysisActivity(
                        state: .succeeded,
                        for: track,
                        queueIndex: queueIndex,
                        totalCount: tracksToAnalyze.count
                    )
                }
            } catch {
                if Task.isCancelled || (error as? WorkerError).map({ if case .cancelled = $0 { return true } else { return false } }) == true {
                    sessionResult = .canceled
                    updateAnalysisState(trackID: track.id, state: .canceled, message: "Canceled")
                    cancelAnalysisProgressWatchdog()
                    finishAnalysisActivity(
                        state: .canceled,
                        for: track,
                        queueIndex: queueIndex,
                        totalCount: tracksToAnalyze.count
                    )
                    logAnalysisEvent(
                        "track_finished",
                        track: track,
                        queueIndex: queueIndex,
                        totalCount: tracksToAnalyze.count,
                        elapsedMs: max(Int(Date().timeIntervalSince(trackStartedAt) * 1000), 0),
                        extra: ["result": "canceled"]
                    )
                    continue
                }
                let decoratedError = decoratedAnalysisError(error)
                if sessionResult != .canceled {
                    sessionResult = .failed(decoratedError)
                }
                updateAnalysisState(
                    trackID: track.id,
                    state: .failed,
                    message: analysisActivity?.stage.displayName ?? "Failed"
                )
                finishAnalysisActivity(
                    state: .failed,
                    for: track,
                    queueIndex: queueIndex,
                    totalCount: tracksToAnalyze.count,
                    errorMessage: decoratedError
                )
                cancelAnalysisProgressWatchdog()
                AppLogger.shared.error("Analyze failed for \(track.filePath): \(decoratedError)")
            }

            logAnalysisEvent(
                "track_finished",
                track: track,
                queueIndex: queueIndex,
                totalCount: tracksToAnalyze.count,
                elapsedMs: max(Int(Date().timeIntervalSince(trackStartedAt) * 1000), 0)
            )
        }

        let refreshStartedAt = Date()
        await refreshTracks()
        AppLogger.shared.info(
            "Analysis refresh_tracks_completed | trackCount=\(tracksToAnalyze.count) | elapsedMs=\(max(Int(Date().timeIntervalSince(refreshStartedAt) * 1000), 0)) | batchElapsedMs=\(max(Int(Date().timeIntervalSince(batchStartedAt) * 1000), 0))"
        )
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
        recommendations = []
        recommendationStatusMessage = ""
        selectedRecommendationID = nil
        Task { await loadSelectedTrackDetails() }
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

    private func loadTrackEmbeddings() throws -> [UUID: [Double]] {
        var output: [UUID: [Double]] = [:]
        for track in tracks where readyTrackIDs.contains(track.id) {
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
                    genre: effectiveConstraints.genreContinuity > 0.85 ? seed.genre : nil
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

        var entriesByPath = Dictionary(grouping: imported, by: \.trackPath)
        var updatedTracks = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        var matchedTracks = 0

        for track in tracks {
            guard let entries = entriesByPath.removeValue(forKey: track.filePath), !entries.isEmpty else { continue }
            matchedTracks += 1

            var updatedTrack = track
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
            try database.replaceExternalMetadata(trackID: track.id, source: source, entries: entries)
            updatedTracks[track.id] = updatedTrack
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
            matchedTracks: matchedTracks
        )
    }

    private func refreshValidationStatus() {
        validationStatus = AppSettingsStore.currentValidationStatus(apiKey: googleAIAPIKey, profile: embeddingProfile)
        if !validationStatus.isValidated {
            recommendations = []
        }
    }

    private func startRuntimeValidation(userInitiated: Bool) {
        guard isSelectedEmbeddingProfileSupported else {
            let message = selectedEmbeddingProfileDependencyMessage ?? "The selected embedding profile is unavailable."
            validationStatus = .failed(message)
            settingsStatusMessage = message
            return
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
            return
        }

        do {
            try persistAnalysisSettings()
        } catch {
            validationStatus = .failed(error.localizedDescription)
            settingsStatusMessage = "Failed to save settings before validation: \(error.localizedDescription)"
            return
        }

        validationTask?.cancel()
        let validatingProfile = embeddingProfile
        validationStatus = .validating
        settingsStatusMessage = userInitiated
            ? "Validating \(validatingProfile.displayName)..."
            : "Checking \(validatingProfile.displayName)..."

        validationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await worker.validateEmbeddingProfile()
                guard !Task.isCancelled, validatingProfile.id == self.embeddingProfile.id else { return }
                let validatedAt = Date()
                AppSettingsStore.markValidationSuccess(
                    apiKey: self.googleAIAPIKey,
                    profile: validatingProfile,
                    date: validatedAt
                )
                self.validationStatus = .validated(validatedAt)
                self.settingsStatusMessage = "Validated \(response.modelName)."
            } catch {
                guard !Task.isCancelled, validatingProfile.id == self.embeddingProfile.id else { return }
                let failureSummary = PythonWorkerClient.failureSummary(
                    for: "validate_embedding_profile",
                    error: error
                )
                self.validationStatus = .failed(failureSummary)
                self.settingsStatusMessage = userInitiated
                    ? "Validation failed: \(failureSummary)"
                    : "Runtime validation failed: \(failureSummary)"
                AppLogger.shared.error("Embedding validation failed: \(failureSummary)")
            }
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
            readyTrackIDs = try database.fetchReadyTrackIDs(profileID: embeddingProfile.id)

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

        let repairSignature = vectorRepairSignature(profileID: embeddingProfile.id, manifestHash: readyManifestHash)
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

    private func vectorRepairSignature(profileID: String, manifestHash: String) -> String {
        let joined = [profileID, manifestHash].joined(separator: "\n")
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

    private func syncLibrariesInternal() async throws -> String? {
        let enabledNativeSources = librarySources.filter {
            $0.kind != .folderFallback && $0.enabled && $0.resolvedPath != nil
        }
        guard !enabledNativeSources.isEmpty else { return nil }

        for source in enabledNativeSources {
            var syncingSource = source
            syncingSource.status = .syncing
            syncingSource.lastError = nil
            persistLibrarySource(syncingSource)
        }

        do {
            let summary = try await librarySyncService.syncEnabledSources(librarySources) { progress in
                Task { @MainActor [weak self, progress] in
                    self?.scanProgress = progress
                }
            }

            let now = Date()
            for source in enabledNativeSources {
                var updatedSource = source
                updatedSource.lastSyncAt = now
                updatedSource.status = .available
                updatedSource.lastError = nil
                persistLibrarySource(updatedSource)
            }
            return summary.displayText
        } catch {
            for source in enabledNativeSources {
                var failedSource = source
                failedSource.status = .error
                failedSource.lastError = error.localizedDescription
                persistLibrarySource(failedSource)
            }
            throw error
        }
    }

    private func runFallbackScanInternal() async -> String? {
        let roots = libraryRoots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard !roots.isEmpty else { return nil }

        var folderFallbackSource = librarySources.first(where: { $0.kind == .folderFallback }) ?? .default(for: .folderFallback)
        folderFallbackSource.enabled = true
        folderFallbackSource.status = .syncing
        folderFallbackSource.resolvedPath = libraryRoots.first
        folderFallbackSource.lastError = nil
        persistLibrarySource(folderFallbackSource)

        await scanner.scan(roots: roots) { progress in
            Task { @MainActor [weak self, progress] in
                self?.scanProgress = progress
            }
        }

        folderFallbackSource.lastSyncAt = Date()
        folderFallbackSource.status = .available
        persistLibrarySource(folderFallbackSource)
        return "Rescanned manual fallback folder."
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
        let anyMatched = summaries.contains { $0.matchedTracks > 0 }
        let anyUnmatched = summaries.contains { $0.matchedTracks == 0 }

        if !anyMatched {
            return "\(summaryText). No indexed tracks matched the imported metadata yet. Sync libraries or scan a fallback folder first."
        }

        if anyUnmatched {
            return "\(summaryText). Some imported metadata did not match indexed tracks yet. Sync libraries or scan a fallback folder first."
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

    private func shouldShowInitialSetup(hasExistingRoots: Bool) -> Bool {
        guard tracks.isEmpty, !LibraryRootsStore.isInitialSetupCompleted() else { return false }
        let hasNativeLibraries = librarySources.contains { $0.kind != .folderFallback && $0.resolvedPath != nil }
        return hasNativeLibraries || !hasExistingRoots
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
    let matchedTracks: Int

    nonisolated var displayText: String {
        let sourceName = source == .rekordbox ? "rekordbox" : "Serato"
        return "\(sourceName): \(matchedTracks) matched / \(importedEntries) imported"
    }
}
