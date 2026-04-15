import AppKit
import Combine
import CryptoKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppViewModel: ObservableObject {
    @Published var selectedSection: SidebarSection = .library
    @Published var tracks: [Track] = []
    @Published var selectedTrackIDs: Set<UUID> = [] {
        didSet {
            Task { await loadSelectedTrackDetails() }
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
    @Published var isAnalyzing = false
    @Published var isSearching = false
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
    @Published var searchResults: [TrackSearchResult] = []
    @Published var searchMode: SearchMode = .text {
        didSet {
            searchResults = []
            searchStatusMessage = ""
        }
    }
    @Published var searchStatusMessage: String = ""
    @Published var exportMessage: String = ""
    @Published var weights = RecommendationWeights()
    @Published var constraints = RecommendationConstraints()
    @Published var playlistTracks: [Track] = []
    @Published var playlistTargetCount: Int = 8
    @Published var selectedExportFormat: ExportFormat = .rekordboxXML
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
            searchResults = []
            recommendationStatusMessage = ""
            searchStatusMessage = ""
            scheduleWorkerHealthRefresh()
        }
    }
    @Published var validationStatus: ValidationStatus
    @Published var settingsStatusMessage: String = ""
    @Published var analysisErrorMessage: String = ""
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
    @Published var isCancellingSearch: Bool = false
    @Published private(set) var workerProfileStatuses: [String: WorkerProfileStatus] = [:]

    private let database: LibraryDatabase
    private let recommendationEngine = RecommendationEngine()
    private let exporter = PlaylistExportService()
    private let externalMetadataImporter = ExternalMetadataService()
    private let externalVisualizationResolver = ExternalVisualizationResolver()
    private var pendingAnalyzeAllTrackIDs: [UUID] = []
    private var analysisTask: Task<Void, Never>?
    private var analysisWatchdogTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var workerHealthTask: Task<Void, Never>?
    private var validationTask: Task<Void, Never>?
    private var readyTrackIDs: Set<UUID> = []
    private var pendingAnalysisTrackIDs: [UUID] = []
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

    init() {
        AppPaths.ensureDirectories()

        let loadedAPIKey = AppSettingsStore.loadGoogleAIAPIKey()
        let loadedPythonPath = AppSettingsStore.loadPythonExecutablePath()
        let loadedWorkerPath = AppSettingsStore.loadWorkerScriptPath()
        let loadedProfile = AppSettingsStore.loadEmbeddingProfile()

        self.googleAIAPIKey = loadedAPIKey
        self.pythonExecutablePath = loadedPythonPath
        self.workerScriptPath = loadedWorkerPath
        self.embeddingProfile = loadedProfile
        self.validationStatus = AppSettingsStore.currentValidationStatus(apiKey: loadedAPIKey, profile: loadedProfile)

        do {
            let database = try LibraryDatabase()
            self.database = database
            self.librarySources = try database.fetchLibrarySources()
        } catch {
            fatalError("Database init failed: \(error)")
        }

        let hasExistingRoots = !libraryRoots.isEmpty
        if hasExistingRoots {
            initialSetupLibraryRoot = libraryRoots[0]
            LibraryRootsStore.markInitialSetupCompleted()
        }

        persistFolderFallbackSource()

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

    var selectedTrackIDsInOrder: [UUID] {
        selectedTracks.map(\.id)
    }

    var selectedTrackID: UUID? {
        selectedTracks.first?.id
    }

    var selectedTracks: [Track] {
        tracks.filter { selectedTrackIDs.contains($0.id) }
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

    var selectedReferenceTracksMissingEmbeddingCount: Int {
        selectedTracks.filter { !readyTrackIDs.contains($0.id) }.count
    }

    var recommendationReferenceSummary: String {
        selectedTracks
            .prefix(3)
            .map { "\($0.title) - \($0.artist)" }
            .joined(separator: ", ")
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
        return detail.isEmpty ? "This embedding profile is currently unavailable." : detail
    }

    func isTrackReadyForActiveProfile(_ track: Track) -> Bool {
        readyTrackIDs.contains(track.id)
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
        if track.analyzedAt != nil {
            return "Needs Embedding"
        }
        return "Needs Analysis"
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
        Task {
            do {
                let summary = try await syncLibrariesInternal()
                libraryStatusMessage = summary ?? "No DJ library sources were synced."
                await refreshTracks()
            } catch {
                libraryStatusMessage = "Library sync failed: \(error.localizedDescription)"
                AppLogger.shared.error("Library sync failed: \(error.localizedDescription)")
            }
        }
    }

    func runFallbackScan() {
        Task {
            let summary = await runFallbackScanInternal()
            if let summary {
                libraryStatusMessage = summary
            }
            await refreshTracks()
        }
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
                searchResults = []
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

    func requestAnalysis() {
        guard isSelectedEmbeddingProfileSupported else {
            analysisErrorMessage = selectedEmbeddingProfileDependencyMessage ?? "The active embedding profile is unavailable."
            return
        }
        guard hasValidatedEmbeddingProfile else {
            analysisErrorMessage = "Validate the active embedding profile before analyzing tracks."
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
                "Analyze or re-embed \(targets.count) indexed tracks with \(embeddingProfile.displayName)? " +
                "Estimated embedding vectors: up to \(targets.count * 4)."
            isShowingAnalyzeAllConfirmation = true
            return
        }

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

    func confirmAnalyzeAllTracks() {
        let targets = tracks.filter { pendingAnalyzeAllTrackIDs.contains($0.id) }
        pendingAnalyzeAllTrackIDs = []
        isShowingAnalyzeAllConfirmation = false
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
        analysisTask?.cancel()
        cancelAnalysisProgressWatchdog()
        isCancellingAnalysis = true
        analysisErrorMessage = "Cancelling analysis..."
        for trackID in pendingAnalysisTrackIDs {
            let currentState = analysisStateByTrackID[trackID]?.state
            if currentState == .queued || currentState == .running {
                updateAnalysisState(trackID: trackID, state: .canceled, message: "Canceled")
            }
        }
        if let activity = analysisActivity {
            var updatedActivity = activity
            updatedActivity.markFinished(state: AnalysisTaskState.canceled, message: "Canceled by user")
            analysisActivity = updatedActivity
            updateAnalysisQueueTextFromActivity()
        }
        analysisTask = nil
    }

    func generateRecommendations(limit: Int? = nil) {
        guard isSelectedEmbeddingProfileSupported else {
            recommendationStatusMessage = selectedEmbeddingProfileDependencyMessage ?? "The active embedding profile is unavailable."
            return
        }
        guard hasValidatedEmbeddingProfile else {
            recommendationStatusMessage = "Validate the active embedding profile first."
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
                    constraints: constraints,
                    weights: weights,
                    limit: effectiveLimit,
                    excludeTrackIDs: Set(playlistTracks.map(\.id)).union(excludedReferenceTrackIDs)
                )
                recommendations = recs
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
            recommendationStatusMessage = selectedEmbeddingProfileDependencyMessage ?? "The active embedding profile is unavailable."
            return
        }
        guard hasValidatedEmbeddingProfile else {
            recommendationStatusMessage = "Validate the active embedding profile first."
            return
        }
        guard let input = resolveRecommendationInput() else {
            recommendationStatusMessage = recommendationInputValidationMessage()
            return
        }

        Task {
            do {
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
                var current = seedContext.seed

                while pathTracks.count < targetCount {
                    let similarityMap = try await workerSimilarityMap(
                        seed: current,
                        embeddingsByTrackID: embeddingsByTrackID,
                        limit: max(15, targetCount * 2),
                        excludedPaths: Set(pathTracks.map(\.filePath))
                    )
                    let next = recommendationEngine.recommendNextTracks(
                        seed: current,
                        candidates: tracks.filter { readyTrackIDs.contains($0.id) },
                        embeddingsByTrackID: embeddingsByTrackID,
                        summariesByTrackID: summariesByTrackID,
                        vectorSimilarityByPath: similarityMap,
                        constraints: constraints,
                        weights: weights,
                        limit: 1,
                        excludeTrackIDs: Set(pathTracks.map(\.id)).union(excludedReferenceTrackIDs)
                    ).first?.track

                    guard let next else { break }
                    pathTracks.append(next)
                    current = next
                }

                playlistTracks = pathTracks
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

        let panel = NSSavePanel()
        panel.title = "Export Playlist"
        panel.nameFieldStringValue = "Soria-Recommendation"
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            let outputDirectory = url.deletingLastPathComponent()
            Task {
                do {
                    let result = try exporter.export(
                        playlistName: url.deletingPathExtension().lastPathComponent,
                        tracks: playlistTracks,
                        format: selectedExportFormat,
                        outputDirectory: outputDirectory
                    )
                    exportMessage = "\(result.message): \(result.outputPaths.joined(separator: ", "))"
                } catch {
                    exportMessage = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func loadExternalMetadata() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.xml, .commaSeparatedText]

        guard panel.runModal() == .OK else { return }

        Task {
            do {
                _ = try await importExternalMetadataFiles(panel.urls)
            } catch {
                AppLogger.shared.error("Metadata import failed: \(error.localizedDescription)")
            }
        }
    }

    func searchTracks(
        queryText: String,
        bpmMin: Double?,
        bpmMax: Double?,
        musicalKey: String,
        genre: String,
        analysisFocus: AnalysisFocus?,
        mixabilityTags: [String],
        maxDurationMinutes: Double?,
        limit: Int = 25
    ) {
        guard hasValidatedEmbeddingProfile else {
            searchStatusMessage = "Validate the active embedding profile first."
            return
        }
        guard isSelectedEmbeddingProfileSupported else {
            searchStatusMessage = selectedEmbeddingProfileDependencyMessage ?? "The active embedding profile is unavailable."
            return
        }

        let filters = WorkerSimilarityFilters(
            bpmMin: bpmMin,
            bpmMax: bpmMax,
            durationMaxSec: maxDurationMinutes.map { $0 * 60 },
            musicalKey: musicalKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : musicalKey,
            genre: genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : genre
        )

        searchTask?.cancel()
        isSearching = true
        searchResults = []
        searchStatusMessage = ""

        searchTask = Task {
            defer {
                isSearching = false
                isCancellingSearch = false
            }

            do {
                if Task.isCancelled {
                    return
                }

                let response: WorkerTrackSearchResponse
                switch searchMode {
                case .text:
                    let trimmedQuery = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedQuery.isEmpty else {
                        searchStatusMessage = "Enter a text query first."
                        return
                    }
                    response = try await worker.searchTracksText(
                        query: trimmedQuery,
                        limit: limit,
                        excludeTrackPaths: [],
                        filters: filters
                    )

                case .referenceTrack:
                    let selectedReferenceTracks = selectedTracks.filter {
                        readyTrackIDs.contains($0.id)
                    }
                    guard !selectedReferenceTracks.isEmpty else {
                        searchStatusMessage = "Select one or more reference tracks."
                        return
                    }
                    guard let referenceData = buildReferenceTrackSearchPayload(from: selectedReferenceTracks) else {
                        searchStatusMessage = "Selected track(s) do not have active embeddings yet."
                        return
                    }

                    response = try await worker.searchTracksReference(
                        track: selectedReferenceTracks[0],
                        segments: referenceData.segments,
                        trackEmbedding: referenceData.trackEmbedding,
                        limit: limit,
                        excludeTrackPaths: Array(referenceData.excludeTrackPaths),
                        filters: filters
                    )
                }

                if Task.isCancelled {
                    return
                }

                let trackIndex = Dictionary(uniqueKeysWithValues: tracks.map { ($0.filePath, $0) })
                let candidateTrackIDs = response.results.compactMap { item in trackIndex[item.filePath]?.id }
                let summariesByTrackID = try loadAnalysisSummaries(trackIDs: candidateTrackIDs)
                searchResults = response.results.compactMap { item in
                    guard let track = trackIndex[item.filePath] else { return nil }
                    let summary = summariesByTrackID[track.id]
                    if let analysisFocus, summary?.analysisFocus != analysisFocus {
                        return nil
                    }
                    if !mixabilityTags.isEmpty {
                        let trackTags = Set(summary?.mixabilityTags ?? [])
                        if !mixabilityTags.allSatisfy(trackTags.contains) {
                            return nil
                        }
                    }
                    return TrackSearchResult(
                        track: track,
                        score: item.fusedScore,
                        trackScore: item.trackScore,
                        introScore: item.introScore,
                        middleScore: item.middleScore,
                        outroScore: item.outroScore,
                        bestMatchedCollection: collectionDisplayName(item.bestMatchedCollection),
                        analysisFocus: summary?.analysisFocus,
                        mixabilityTags: summary?.mixabilityTags ?? [],
                        matchReasons: searchMatchReasons(
                            summary: summary,
                            result: item
                        )
                    )
                }
                searchStatusMessage = searchResults.isEmpty ? "No semantic matches found." : "Found \(searchResults.count) semantic matches."
            } catch {
                if Task.isCancelled {
                    return
                }
                searchStatusMessage = "Search failed: \(error.localizedDescription)"
                AppLogger.shared.error("Search failed: \(error.localizedDescription)")
            }
        }
    }

    func analyzeSelectedTrackForSearch() {
        analysisScope = .selectedTrack
        requestAnalysis()
    }

    func analyzeSelectedTracksForSearch() {
        analyzeSelectedTrackForSearch()
    }

    func analyzeSelectedTracksForRecommendations() {
        analyzeSelectedTrackForSearch()
    }

    func cancelSearch() {
        searchTask?.cancel()
        isCancellingSearch = true
        searchStatusMessage = "Canceling search..."
    }

    func refreshTracks() async {
        do {
            tracks = try database.fetchAllTracks()
            readyTrackIDs = try database.fetchReadyTrackIDs(profileID: embeddingProfile.id)
            let availableIDs = Set(tracks.map(\.id))
            analysisStateByTrackID = analysisStateByTrackID.filter { availableIDs.contains($0.key) }
            if selectedTrackIDs.isEmpty {
                selectedTrackIDs = tracks.first.map { Set([$0.id]) } ?? []
            } else {
                let preservedIDs = selectedTrackIDs.intersection(availableIDs)
                if preservedIDs.isEmpty {
                    selectedTrackIDs = tracks.first.map { Set([$0.id]) } ?? []
                } else {
                    selectedTrackIDs = preservedIDs
                }
            }

            await loadSelectedTrackDetails()
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
        if analysisActivity == nil {
            prepareAnalysisSession(for: tracksToAnalyze)
        }
        isCancellingAnalysis = false
        let batchStartedAt = Date()
        defer {
            isAnalyzing = false
            analysisTask = nil
            pendingAnalysisTrackIDs = []
            cancelAnalysisProgressWatchdog()
            if Task.isCancelled {
                analysisErrorMessage = "Analysis was canceled."
            }
        }

        for (index, track) in tracksToAnalyze.enumerated() {
            let queueIndex = index + 1
            let trackStartedAt = Date()
            if Task.isCancelled {
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
                analysisErrorMessage = decoratedError
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
            }
        } catch {
            AppLogger.shared.error("Track detail load failed: \(error.localizedDescription)")
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
            return "Analyze the selected track(s) for the active embedding profile first, or enter text."
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
        switch input.state.seedSource {
        case .selectedReference:
            guard let seed = input.readyReferenceTracks.first else {
                throw RecommendationResolutionError.missingReferenceTrack
            }
            let similarityMap = try await workerSimilarityMap(
                seed: seed,
                embeddingsByTrackID: embeddingsByTrackID,
                limit: max(limit, 1),
                excludedPaths: excludedPaths
            )
            return RecommendationSeedContext(seed: seed, similarityMap: similarityMap)

        case .semanticMatch:
            let response = try await searchRecommendationMatches(
                input: input,
                limit: max(limit, 1),
                excludedPaths: excludedPaths
            )
            let trackIndex = Dictionary(uniqueKeysWithValues: tracks.map { ($0.filePath, $0) })
            let rankedMatches = response.results.compactMap { item -> (Track, Double)? in
                guard let track = trackIndex[item.filePath], readyTrackIDs.contains(track.id) else {
                    return nil
                }
                guard recommendationEngine.matchesConstraints(
                    track: track,
                    summary: summariesByTrackID[track.id],
                    constraints: constraints
                ) else {
                    return nil
                }
                return (track, item.fusedScore)
            }
            guard let seed = rankedMatches.first?.0 else {
                throw RecommendationResolutionError.noSemanticSeed
            }
            return RecommendationSeedContext(
                seed: seed,
                similarityMap: Dictionary(uniqueKeysWithValues: rankedMatches.map { ($0.0.filePath, $0.1) })
            )
        }
    }

    private func searchRecommendationMatches(
        input: RecommendationResolvedInput,
        limit: Int,
        excludedPaths: Set<String>
    ) async throws -> WorkerTrackSearchResponse {
        let filters = recommendationWorkerFilters()
        let referenceExcludedPaths = input.referencePayload?.excludeTrackPaths ?? []
        let effectiveExcludedPaths = Array(excludedPaths.union(referenceExcludedPaths))

        switch input.state.mode {
        case .text:
            return try await worker.searchTracksText(
                query: input.state.trimmedQueryText,
                limit: limit,
                excludeTrackPaths: effectiveExcludedPaths,
                filters: filters
            )

        case .reference:
            guard
                let referencePayload = input.referencePayload,
                let referenceTrack = input.readyReferenceTracks.first
            else {
                throw RecommendationResolutionError.missingReferencePayload
            }
            return try await worker.searchTracksReference(
                track: referenceTrack,
                segments: referencePayload.segments,
                trackEmbedding: referencePayload.trackEmbedding,
                limit: limit,
                excludeTrackPaths: effectiveExcludedPaths,
                filters: filters
            )

        case .hybrid:
            guard let referencePayload = input.referencePayload else {
                throw RecommendationResolutionError.missingReferencePayload
            }
            return try await worker.searchTracksHybrid(
                query: input.state.trimmedQueryText,
                segments: referencePayload.segments,
                trackEmbedding: referencePayload.trackEmbedding,
                limit: limit,
                excludeTrackPaths: effectiveExcludedPaths,
                filters: filters
            )
        }
    }

    private func recommendationWorkerFilters() -> WorkerSimilarityFilters {
        WorkerSimilarityFilters(
            bpmMin: constraints.targetBPMMin,
            bpmMax: constraints.targetBPMMax,
            durationMaxSec: constraints.maxDurationMinutes.map { $0 * 60 },
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

    private func workerSimilarityMap(
        seed: Track,
        embeddingsByTrackID: [UUID: [Double]],
        limit: Int,
        excludedPaths: Set<String>
    ) async throws -> [String: Double] {
        guard let seedEmbedding = embeddingsByTrackID[seed.id], !seedEmbedding.isEmpty else {
            return [:]
        }

        let seedSegments = try database.fetchSegments(trackID: seed.id).filter { segment in
            guard let vector = segment.vector else { return false }
            return !vector.isEmpty
        }
        let filters = WorkerSimilarityFilters(
            bpmMin: constraints.targetBPMMin,
            bpmMax: constraints.targetBPMMax,
            durationMaxSec: constraints.maxDurationMinutes.map { $0 * 60 },
            musicalKey: constraints.keyStrictness > 0.85 ? seed.musicalKey : nil,
            genre: constraints.genreContinuity > 0.85 ? seed.genre : nil
        )
        let response = try await worker.searchTracksReference(
            track: seed,
            segments: seedSegments,
            trackEmbedding: seedEmbedding,
            limit: limit,
            excludeTrackPaths: Array(excludedPaths.union([seed.filePath])),
            filters: filters
        )
        return Dictionary(uniqueKeysWithValues: response.results.map { ($0.filePath, $0.fusedScore) })
    }

    private func persistAnalysisSettings() throws {
        pythonExecutablePath = AppSettingsStore.savePythonExecutablePath(pythonExecutablePath)
        workerScriptPath = AppSettingsStore.saveWorkerScriptPath(workerScriptPath)
        AppSettingsStore.saveEmbeddingProfile(embeddingProfile)
        try AppSettingsStore.saveGoogleAIAPIKey(googleAIAPIKey)
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
            searchResults = []
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

    private func searchMatchReasons(
        summary: TrackAnalysisSummary?,
        result: WorkerTrackSearchResult
    ) -> [String] {
        var reasons: [String] = [collectionDisplayName(result.bestMatchedCollection)]
        if result.trackScore >= 0.7 {
            reasons.append("Strong full-track match")
        }
        if let summary {
            reasons.append(summary.analysisFocus.displayName)
            reasons.append(contentsOf: summary.mixabilityTags.prefix(2).map {
                $0.replacingOccurrences(of: "_", with: " ").capitalized
            })
        }
        let ordered = NSOrderedSet(array: reasons).array as? [String] ?? reasons
        return Array(ordered.prefix(3))
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

private struct MetadataImportSummary {
    let source: ExternalDJMetadata.Source
    let importedEntries: Int
    let matchedTracks: Int

    var displayText: String {
        let sourceName = source == .rekordbox ? "rekordbox" : "Serato"
        return "\(sourceName): \(matchedTracks) matched / \(importedEntries) imported"
    }
}
