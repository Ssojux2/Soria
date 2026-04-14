import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppViewModel: ObservableObject {
    @Published var selectedSection: SidebarSection = .library
    @Published var tracks: [Track] = []
    @Published var selectedTrackID: UUID? {
        didSet {
            Task { await loadSelectedTrackDetails() }
        }
    }
    @Published var selectedTrackSegments: [TrackSegment] = []
    @Published var selectedTrackAnalysis: TrackAnalysisSummary?
    @Published var selectedTrackExternalMetadata: [ExternalDJMetadata] = []
    @Published var selectedRecommendationID: UUID?
    @Published var scanProgress = ScanJobProgress()
    @Published var libraryRoots: [String] = LibraryRootsStore.loadRoots().map(TrackPathNormalizer.normalizedAbsolutePath)
    @Published var librarySources: [LibrarySourceRecord] = []
    @Published var isAnalyzing = false
    @Published var isSearching = false
    @Published var recommendations: [RecommendationCandidate] = []
    @Published var recommendationStatusMessage: String = ""
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

    private let database: LibraryDatabase
    private let scanner: LibraryScannerService
    private let worker: PythonWorkerClient
    private let recommendationEngine = RecommendationEngine()
    private let exporter = PlaylistExportService()
    private let externalMetadataImporter = ExternalMetadataService()
    private let librarySyncService: DJLibrarySyncService
    private var pendingAnalyzeAllTrackIDs: [UUID] = []

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
            self.scanner = LibraryScannerService(database: database)
            self.worker = PythonWorkerClient()
            self.librarySyncService = DJLibrarySyncService(database: database)
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
            if shouldShowInitialSetup(hasExistingRoots: hasExistingRoots) {
                isShowingInitialSetupSheet = true
            }
        }
    }

    var selectedTrack: Track? {
        guard let selectedTrackID else { return nil }
        return tracks.first(where: { $0.id == selectedTrackID })
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
        tracks.filter { $0.hasCurrentEmbedding(profileID: embeddingProfile.id) }.count
    }

    var staleEmbeddingTrackCount: Int {
        tracks.filter { $0.analyzedAt != nil && !$0.hasCurrentEmbedding(profileID: embeddingProfile.id) }.count
    }

    var canRunReferenceTrackFeatures: Bool {
        guard let selectedTrack else { return false }
        return hasValidatedEmbeddingProfile && selectedTrack.hasCurrentEmbedding(profileID: embeddingProfile.id)
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
        selectedSection = .scanJobs
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
        } catch {
            settingsStatusMessage = "Failed to save settings: \(error.localizedDescription)"
            AppLogger.shared.error("Settings save failed: \(error.localizedDescription)")
        }
    }

    func validateEmbeddingProfile() {
        guard !embeddingProfile.requiresAPIKey || !googleAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            validationStatus = .failed("Enter a Google AI API Key first.")
            settingsStatusMessage = "Enter a Google AI API Key before validating."
            return
        }

        do {
            try persistAnalysisSettings()
        } catch {
            validationStatus = .failed(error.localizedDescription)
            settingsStatusMessage = "Failed to save settings before validation: \(error.localizedDescription)"
            return
        }

        validationStatus = .validating
        settingsStatusMessage = "Validating \(embeddingProfile.displayName)..."

        Task {
            do {
                let response = try await worker.validateEmbeddingProfile()
                let validatedAt = Date()
                AppSettingsStore.markValidationSuccess(
                    apiKey: googleAIAPIKey,
                    profile: embeddingProfile,
                    date: validatedAt
                )
                validationStatus = .validated(validatedAt)
                settingsStatusMessage = "Validated \(response.modelName)."
            } catch {
                validationStatus = .failed(error.localizedDescription)
                settingsStatusMessage = "Validation failed: \(error.localizedDescription)"
                AppLogger.shared.error("Embedding validation failed: \(error.localizedDescription)")
            }
        }
    }

    func runScan() {
        runFallbackScan()
    }

    func requestAnalysis() {
        guard hasValidatedEmbeddingProfile else {
            analysisErrorMessage = "Validate the active embedding profile before analyzing tracks."
            return
        }

        let targets = analysisScope.resolveTracks(
            from: tracks,
            selectedTrackID: selectedTrackID,
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

        Task {
            await analyzeTracks(targets, mode: .batch)
        }
    }

    func confirmAnalyzeAllTracks() {
        let targets = tracks.filter { pendingAnalyzeAllTrackIDs.contains($0.id) }
        pendingAnalyzeAllTrackIDs = []
        isShowingAnalyzeAllConfirmation = false
        Task {
            await analyzeTracks(targets, mode: .batch)
        }
    }

    func cancelAnalyzeAllTracks() {
        pendingAnalyzeAllTrackIDs = []
        isShowingAnalyzeAllConfirmation = false
    }

    func generateRecommendations(limit: Int = 20) {
        guard hasValidatedEmbeddingProfile else {
            recommendationStatusMessage = "Validate the active embedding profile first."
            return
        }
        guard let seed = selectedTrack else {
            recommendationStatusMessage = "Select a track first."
            return
        }
        guard seed.hasCurrentEmbedding(profileID: embeddingProfile.id) else {
            recommendationStatusMessage = "Analyze the selected track for the active embedding profile first."
            return
        }

        Task {
            do {
                let embeddingsByTrackID = try loadTrackEmbeddings()
                let similarityMap = try await workerSimilarityMap(
                    seed: seed,
                    embeddingsByTrackID: embeddingsByTrackID,
                    limit: limit,
                    excludedPaths: Set(playlistTracks.map(\.filePath))
                )
                let recs = recommendationEngine.recommendNextTracks(
                    seed: seed,
                    candidates: tracks.filter { $0.hasCurrentEmbedding(profileID: embeddingProfile.id) },
                    embeddingsByTrackID: embeddingsByTrackID,
                    vectorSimilarityByPath: similarityMap,
                    constraints: constraints,
                    weights: weights,
                    limit: limit,
                    excludeTrackIDs: Set(playlistTracks.map(\.id))
                )
                recommendations = recs
                selectedRecommendationID = recs.first?.id
                recommendationStatusMessage = recs.isEmpty ? "No recommendations found." : "Generated \(recs.count) matches."
            } catch {
                recommendationStatusMessage = "Recommendation failed: \(error.localizedDescription)"
                AppLogger.shared.error("Recommendation failed: \(error.localizedDescription)")
            }
        }
    }

    func buildPlaylistPath() {
        guard hasValidatedEmbeddingProfile else {
            recommendationStatusMessage = "Validate the active embedding profile first."
            return
        }
        guard let seed = selectedTrack else {
            recommendationStatusMessage = "Select a track first."
            return
        }
        guard seed.hasCurrentEmbedding(profileID: embeddingProfile.id) else {
            recommendationStatusMessage = "Analyze the selected track for the active embedding profile first."
            return
        }

        Task {
            do {
                let embeddingsByTrackID = try loadTrackEmbeddings()
                var pathTracks: [Track] = [seed]
                var current = seed
                let targetCount = max(2, playlistTargetCount)

                while pathTracks.count < targetCount {
                    let similarityMap = try await workerSimilarityMap(
                        seed: current,
                        embeddingsByTrackID: embeddingsByTrackID,
                        limit: max(15, targetCount * 2),
                        excludedPaths: Set(pathTracks.map(\.filePath))
                    )
                    let next = recommendationEngine.recommendNextTracks(
                        seed: current,
                        candidates: tracks.filter { $0.hasCurrentEmbedding(profileID: embeddingProfile.id) },
                        embeddingsByTrackID: embeddingsByTrackID,
                        vectorSimilarityByPath: similarityMap,
                        constraints: constraints,
                        weights: weights,
                        limit: 1,
                        excludeTrackIDs: Set(pathTracks.map(\.id))
                    ).first?.track

                    guard let next else { break }
                    pathTracks.append(next)
                    current = next
                }

                playlistTracks = pathTracks
                recommendationStatusMessage = "Built \(pathTracks.count)-track path from seed: \(seed.title)"
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
        maxDurationMinutes: Double?,
        limit: Int = 25
    ) {
        guard hasValidatedEmbeddingProfile else {
            searchStatusMessage = "Validate the active embedding profile first."
            return
        }

        let filters = WorkerSimilarityFilters(
            bpmMin: bpmMin,
            bpmMax: bpmMax,
            durationMaxSec: maxDurationMinutes.map { $0 * 60 },
            musicalKey: musicalKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : musicalKey,
            genre: genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : genre
        )

        isSearching = true
        searchResults = []
        searchStatusMessage = ""

        Task {
            defer { isSearching = false }

            do {
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
                    guard let selectedTrack else {
                        searchStatusMessage = "Select a library track first."
                        return
                    }
                    guard selectedTrack.hasCurrentEmbedding(profileID: embeddingProfile.id) else {
                        searchStatusMessage = "Analyze the selected track for the active embedding profile first."
                        return
                    }
                    let segments = try database.fetchSegments(trackID: selectedTrack.id)
                    guard let trackEmbedding = try database.fetchTrackEmbedding(trackID: selectedTrack.id), !trackEmbedding.isEmpty else {
                        searchStatusMessage = "The selected track does not have an active embedding yet."
                        return
                    }
                    response = try await worker.searchTracksReference(
                        track: selectedTrack,
                        segments: segments,
                        trackEmbedding: trackEmbedding,
                        limit: limit,
                        excludeTrackPaths: [selectedTrack.filePath],
                        filters: filters
                    )
                }

                let trackIndex = Dictionary(uniqueKeysWithValues: tracks.map { ($0.filePath, $0) })
                searchResults = response.results.compactMap { item in
                    guard let track = trackIndex[item.filePath] else { return nil }
                    return TrackSearchResult(
                        track: track,
                        score: item.fusedScore,
                        trackScore: item.trackScore,
                        introScore: item.introScore,
                        middleScore: item.middleScore,
                        outroScore: item.outroScore,
                        bestMatchedCollection: collectionDisplayName(item.bestMatchedCollection)
                    )
                }
                searchStatusMessage = searchResults.isEmpty ? "No semantic matches found." : "Found \(searchResults.count) semantic matches."
            } catch {
                searchStatusMessage = "Search failed: \(error.localizedDescription)"
                AppLogger.shared.error("Search failed: \(error.localizedDescription)")
            }
        }
    }

    func analyzeSelectedTrackForSearch() {
        analysisScope = .selectedTrack
        requestAnalysis()
    }

    func refreshTracks() async {
        do {
            tracks = try database.fetchAllTracks()
            if selectedTrackID == nil {
                selectedTrackID = tracks.first?.id
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
        analysisQueueProgressText = ""
        defer { isAnalyzing = false }

        for (index, track) in tracksToAnalyze.enumerated() {
            do {
                let externalMetadata = try database.fetchExternalMetadata(trackID: track.id)
                let existingSegments = try database.fetchSegments(trackID: track.id)
                let existingSummary = try database.fetchAnalysisSummary(trackID: track.id)
                let canReembed = track.analyzedAt != nil
                    && !track.hasCurrentEmbedding(profileID: embeddingProfile.id)
                    && !existingSegments.isEmpty
                    && existingSummary != nil

                if canReembed {
                    let result = try await worker.embedDescriptors(
                        track: track,
                        segments: existingSegments,
                        externalMetadata: externalMetadata
                    )
                    guard let refreshedSegments = mergedReembeddedSegments(
                        trackID: track.id,
                        existingSegments: existingSegments,
                        workerSegments: result.segments
                    ) else {
                        throw WorkerError.executionFailed("Stored descriptor segments no longer match the re-embedded payload.")
                    }

                    try database.replaceTrackEmbeddings(
                        trackID: track.id,
                        segments: refreshedSegments,
                        trackEmbedding: result.trackEmbedding,
                        embeddingProfileID: result.embeddingProfileID
                    )

                    if var updatedTrack = tracks.first(where: { $0.id == track.id }) {
                        updatedTrack.embeddingProfileID = result.embeddingProfileID
                        updatedTrack.embeddingUpdatedAt = Date()
                        try database.upsertTrack(updatedTrack)
                    }
                } else {
                    let result = try await worker.analyze(
                        filePath: track.filePath,
                        track: track,
                        externalMetadata: externalMetadata
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

                    let summary = TrackAnalysisSummary(
                        trackID: track.id,
                        segments: segments,
                        trackEmbedding: result.trackEmbedding,
                        estimatedBPM: result.estimatedBPM,
                        estimatedKey: result.estimatedKey,
                        brightness: result.brightness,
                        onsetDensity: result.onsetDensity,
                        rhythmicDensity: result.rhythmicDensity,
                        lowMidHighBalance: result.lowMidHighBalance,
                        waveformPreview: result.waveformPreview
                    )
                    try database.replaceSegments(
                        trackID: track.id,
                        segments: segments,
                        analysisSummary: summary,
                        embeddingProfileID: result.embeddingProfileID
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
                        updatedTrack.embeddingProfileID = result.embeddingProfileID
                        updatedTrack.embeddingUpdatedAt = Date()
                        try database.upsertTrack(updatedTrack)
                    }
                }

                if mode == .batch {
                    analysisQueueProgressText = "Processed \(index + 1) / \(tracksToAnalyze.count)"
                }
            } catch {
                analysisErrorMessage = error.localizedDescription
                AppLogger.shared.error("Analyze failed for \(track.filePath): \(error.localizedDescription)")
            }
        }

        await refreshTracks()
    }

    private func loadSelectedTrackDetails() async {
        guard let track = selectedTrack else {
            selectedTrackSegments = []
            selectedTrackAnalysis = nil
            selectedTrackExternalMetadata = []
            return
        }

        do {
            selectedTrackSegments = try database.fetchSegments(trackID: track.id)
            selectedTrackAnalysis = try database.fetchAnalysisSummary(trackID: track.id)
            selectedTrackExternalMetadata = try database.fetchExternalMetadata(trackID: track.id)
        } catch {
            AppLogger.shared.error("Track detail load failed: \(error.localizedDescription)")
        }
    }

    private func loadTrackEmbeddings() throws -> [UUID: [Double]] {
        var output: [UUID: [Double]] = [:]
        for track in tracks where track.hasCurrentEmbedding(profileID: embeddingProfile.id) {
            if let embedding = try database.fetchTrackEmbedding(trackID: track.id), !embedding.isEmpty {
                output[track.id] = embedding
            }
        }
        return output
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

        let seedSegments = try database.fetchSegments(trackID: seed.id)
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
        AppSettingsStore.savePythonExecutablePath(pythonExecutablePath)
        AppSettingsStore.saveWorkerScriptPath(workerScriptPath)
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

private struct MetadataImportSummary {
    let source: ExternalDJMetadata.Source
    let importedEntries: Int
    let matchedTracks: Int

    var displayText: String {
        let sourceName = source == .rekordbox ? "rekordbox" : "Serato"
        return "\(sourceName): \(matchedTracks) matched / \(importedEntries) imported"
    }
}
