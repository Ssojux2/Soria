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
    @Published var libraryRoots: [String] = LibraryRootsStore.loadRoots()
    @Published var isAnalyzing = false
    @Published var recommendations: [RecommendationCandidate] = []
    @Published var exportMessage: String = ""
    @Published var weights = RecommendationWeights()
    @Published var constraints = RecommendationConstraints()
    @Published var playlistTracks: [Track] = []
    @Published var playlistTargetCount: Int = 8
    @Published var selectedExportFormat: ExportFormat = .rekordboxXML
    @Published var analysisQueueProgressText: String = ""
    @Published var geminiAPIKey: String = AppSettingsStore.loadGeminiAPIKey()
    @Published var pythonExecutablePath: String = AppSettingsStore.loadPythonExecutablePath()
    @Published var workerScriptPath: String = AppSettingsStore.loadWorkerScriptPath()
    @Published var embeddingProvider: EmbeddingProvider = AppSettingsStore.loadEmbeddingProvider()
    @Published var isEmbeddingProviderLocked: Bool = AppSettingsStore.loadEmbeddingProviderLocked()
    @Published var settingsStatusMessage: String = ""
    @Published var workerHealthSummary: String = ""
    @Published var analysisErrorMessage: String = ""
    @Published var isShowingInitialSetupSheet = false
    @Published var initialSetupLibraryRoot: String = ""
    @Published var initialSetupRekordboxPath: String = ""
    @Published var initialSetupSeratoPath: String = ""
    @Published var initialSetupStatusMessage: String = ""
    @Published var isRunningInitialSetup = false

    private let database: LibraryDatabase
    private let scanner: LibraryScannerService
    private let worker: PythonWorkerClient
    private let recommendationEngine = RecommendationEngine()
    private let exporter = PlaylistExportService()
    private let externalMetadataImporter = ExternalMetadataService()

    init() {
        AppPaths.ensureDirectories()
        do {
            let database = try LibraryDatabase()
            self.database = database
            self.scanner = LibraryScannerService(database: database)
            self.worker = PythonWorkerClient()
        } catch {
            fatalError("Database init failed: \(error)")
        }

        let hasExistingRoots = !libraryRoots.isEmpty
        if hasExistingRoots {
            initialSetupLibraryRoot = libraryRoots[0]
            LibraryRootsStore.markInitialSetupCompleted()
        }

        Task {
            await refreshTracks()
            if !hasExistingRoots, tracks.isEmpty, !LibraryRootsStore.isInitialSetupCompleted() {
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

    func addLibraryRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK {
            addLibraryRoots(panel.urls.map(\.path))
        }
    }

    func removeLibraryRoot(_ path: String) {
        libraryRoots.removeAll(where: { $0 == path })
        LibraryRootsStore.saveRoots(libraryRoots)
    }

    func chooseInitialSetupLibraryRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            initialSetupLibraryRoot = url.path
        }
    }

    func chooseInitialSetupRekordboxFile() {
        if let path = chooseMetadataFile(prompt: "Choose rekordbox XML", allowedTypes: [.xml]) {
            initialSetupRekordboxPath = path
        }
    }

    func chooseInitialSetupSeratoFile() {
        if let path = chooseMetadataFile(prompt: "Choose Serato CSV", allowedTypes: [.commaSeparatedText]) {
            initialSetupSeratoPath = path
        }
    }

    func clearInitialSetupMetadataPath(for source: ExternalDJMetadata.Source) {
        switch source {
        case .rekordbox:
            initialSetupRekordboxPath = ""
        case .serato:
            initialSetupSeratoPath = ""
        }
    }

    func dismissInitialSetup() {
        guard !isRunningInitialSetup else { return }
        initialSetupStatusMessage = ""
        isShowingInitialSetupSheet = false
    }

    func completeInitialSetup() {
        guard !initialSetupLibraryRoot.isEmpty else {
            initialSetupStatusMessage = "Choose a music folder first."
            return
        }

        let selectedRoot = initialSetupLibraryRoot
        let metadataURLs = [initialSetupRekordboxPath, initialSetupSeratoPath]
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }

        addLibraryRoots([selectedRoot])
        selectedSection = .scanJobs
        initialSetupStatusMessage = "Scanning selected music folder..."
        isRunningInitialSetup = true

        Task {
            await scanner.scan(roots: [URL(fileURLWithPath: selectedRoot, isDirectory: true)]) { progress in
                Task { @MainActor [self, progress] in
                    self.scanProgress = progress
                }
            }

            await refreshTracks()

            do {
                let summaries = try await importExternalMetadataFiles(metadataURLs)
                LibraryRootsStore.markInitialSetupCompleted()
                let metadataSummary = summaries.isEmpty ? "" : " " + summaries.map(\.displayText).joined(separator: " ")
                initialSetupStatusMessage = "Initial library setup finished. Indexed \(tracks.count) tracks.\(metadataSummary)"
                isRunningInitialSetup = false
                isShowingInitialSetupSheet = false
                selectedSection = .library
            } catch {
                isRunningInitialSetup = false
                initialSetupStatusMessage = "Setup finished scanning, but metadata import failed: \(error.localizedDescription)"
                AppLogger.shared.error("Initial setup metadata import failed: \(error.localizedDescription)")
            }
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
            try persistAnalysisSettings()
            settingsStatusMessage = "Analysis settings saved."
        } catch {
            settingsStatusMessage = "Failed to save settings: \(error.localizedDescription)"
            AppLogger.shared.error("Settings save failed: \(error.localizedDescription)")
        }
    }

    func validateAnalysisSetup() {
        Task {
            do {
                try persistAnalysisSettings()
                let result = try await worker.healthcheck()
                if let locked = result.embeddingProviderLocked {
                    isEmbeddingProviderLocked = locked
                }
                if
                    let workerProviderRaw = result.embeddingProvider,
                    let workerProvider = EmbeddingProvider(rawValue: workerProviderRaw),
                    isEmbeddingProviderLocked
                {
                    embeddingProvider = workerProvider
                    AppSettingsStore.saveEmbeddingProvider(workerProvider)
                }
                workerHealthSummary =
                    "API key: \(result.apiKeyConfigured ? "configured" : "missing") | " +
                    "librosa: \(result.dependencies.librosa ? "ok" : "missing") | " +
                    "chromadb: \(result.dependencies.chromadb ? "ok" : "missing") | " +
                    "requests: \(result.dependencies.requests ? "ok" : "missing")"
                settingsStatusMessage =
                    "Worker: \(result.pythonExecutable) | Script: \(result.workerScriptPath) | Embedding: \(embeddingProvider.displayName)"
            } catch {
                workerHealthSummary = ""
                settingsStatusMessage = "Validation failed: \(error.localizedDescription)"
                AppLogger.shared.error("Worker validation failed: \(error.localizedDescription)")
            }
        }
    }

    func runScan() {
        let roots = libraryRoots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard !roots.isEmpty else { return }

        Task {
            await scanner.scan(roots: roots) { progress in
                Task { @MainActor [self, progress] in
                    self.scanProgress = progress
                }
            }
            await refreshTracks()
        }
    }

    func analyzeSelectedTrack() {
        guard let track = selectedTrack else { return }
        Task {
            await analyzeTracks([track], mode: .singleSelection)
        }
    }

    func analyzeUnanalyzedTracks(limit: Int = 100) {
        let pending = Array(tracks.filter { $0.analyzedAt == nil }.prefix(limit))
        guard !pending.isEmpty else {
            analysisQueueProgressText = "No unanalyzed tracks."
            return
        }
        Task {
            await analyzeTracks(pending, mode: .batch)
        }
    }

    func generateRecommendations(limit: Int = 20) {
        guard let seed = selectedTrack else { return }
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
                    candidates: tracks,
                    embeddingsByTrackID: embeddingsByTrackID,
                    vectorSimilarityByPath: similarityMap,
                    constraints: constraints,
                    weights: weights,
                    limit: limit,
                    excludeTrackIDs: Set(playlistTracks.map(\.id))
                )
                recommendations = recs
                selectedRecommendationID = recs.first?.id
            } catch {
                AppLogger.shared.error("Recommendation failed: \(error.localizedDescription)")
            }
        }
    }

    func buildPlaylistPath() {
        guard let seed = selectedTrack else { return }
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
                        candidates: tracks,
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
                exportMessage = "Built \(pathTracks.count)-track path from seed: \(seed.title)"
            } catch {
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
        defer { isAnalyzing = false }

        for (index, track) in tracksToAnalyze.enumerated() {
            do {
                let externalMetadata = try database.fetchExternalMetadata(trackID: track.id)
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
                try database.replaceSegments(trackID: track.id, segments: segments, analysisSummary: summary)

                if var updatedTrack = tracks.first(where: { $0.id == track.id }) {
                    if updatedTrack.bpm == nil { updatedTrack.bpm = result.estimatedBPM }
                    if updatedTrack.musicalKey == nil { updatedTrack.musicalKey = result.estimatedKey }
                    updatedTrack.analyzedAt = Date()
                    try database.upsertTrack(updatedTrack)
                }

                if mode == .batch {
                    analysisQueueProgressText = "Analyzed \(index + 1)/\(tracksToAnalyze.count)"
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
        for track in tracks {
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

        let filters = WorkerSimilarityFilters(
            bpmMin: constraints.targetBPMMin,
            bpmMax: constraints.targetBPMMax,
            durationMaxSec: constraints.maxDurationMinutes.map { $0 * 60 },
            musicalKey: constraints.keyStrictness > 0.85 ? seed.musicalKey : nil,
            genre: constraints.genreContinuity > 0.85 ? seed.genre : nil
        )
        let response = try await worker.querySimilarTracks(
            queryEmbedding: seedEmbedding,
            limit: limit,
            excludeTrackPaths: Array(excludedPaths.union([seed.filePath])),
            filters: filters
        )
        return Dictionary(uniqueKeysWithValues: response.results.map { ($0.filePath, $0.vectorSimilarity) })
    }

    private func persistAnalysisSettings() throws {
        AppSettingsStore.savePythonExecutablePath(pythonExecutablePath)
        AppSettingsStore.saveWorkerScriptPath(workerScriptPath)
        if isEmbeddingProviderLocked {
            let lockedProvider = AppSettingsStore.loadEmbeddingProvider()
            embeddingProvider = lockedProvider
            AppSettingsStore.saveEmbeddingProvider(lockedProvider)
        } else {
            AppSettingsStore.lockEmbeddingProviderIfNeeded(embeddingProvider)
            isEmbeddingProviderLocked = AppSettingsStore.loadEmbeddingProviderLocked()
        }
        try AppSettingsStore.saveGeminiAPIKey(geminiAPIKey)
    }

    private func addLibraryRoots(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        libraryRoots = Array(Set(libraryRoots + paths)).sorted()
        LibraryRootsStore.saveRoots(libraryRoots)
        if !libraryRoots.isEmpty {
            LibraryRootsStore.markInitialSetupCompleted()
        }
    }

    private func chooseMetadataFile(prompt: String, allowedTypes: [UTType]) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = allowedTypes
        panel.prompt = "Choose"
        panel.message = prompt
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
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
            if updatedTrack.bpm == nil {
                updatedTrack.bpm = entries.compactMap(\.bpm).first
            }
            if updatedTrack.musicalKey == nil {
                updatedTrack.musicalKey = entries.compactMap(\.musicalKey).first
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
}

private enum AnalysisMode {
    case singleSelection
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
