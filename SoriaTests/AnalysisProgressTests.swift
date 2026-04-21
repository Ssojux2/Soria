import Foundation
import Darwin
import Testing
@testable import Soria

@MainActor
struct AnalysisProgressTests {
    @Test
    func workerStderrRouterSeparatesProgressEventsFromPlainText() {
        let events = TestProgressEventBox()
        let router = WorkerStderrRouter { event in
            events.append(event)
        }

        let payload = """
        \(PythonWorkerClient.workerProgressPrefix){"stage":"extracting_features","message":"Extracting rhythmic and spectral features","fraction":0.3,"trackPath":"/tmp/example.mp3","timestamp":"2026-04-15T06:30:00Z"}
        plain stderr line
        """

        let splitIndex = payload.index(payload.startIndex, offsetBy: 45)
        router.append(Data(payload[..<splitIndex].utf8))
        router.append(Data(payload[splitIndex...].utf8))
        router.finish()

        let capturedEvents = events.events
        #expect(capturedEvents.count == 1)
        #expect(capturedEvents.first?.stage == .extractingFeatures)
        #expect(capturedEvents.first?.message == "Extracting rhythmic and spectral features")
        #expect(capturedEvents.first?.trackPath == "/tmp/example.mp3")
        #expect(router.plainText == "plain stderr line")
    }

    @Test
    func analysisActivityTracksProgressAndCompletion() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var activity = AnalysisActivity.started(
            trackTitle: "Example Track",
            trackPath: "/tmp/example.mp3",
            queueIndex: 2,
            totalCount: 4,
            timeoutSec: 120,
            startedAt: startedAt
        )

        activity.recordProgress(
            WorkerProgressEvent(
                stage: .extractingFeatures,
                message: "Extracting rhythmic and spectral features",
                fraction: 0.30,
                trackPath: "/tmp/example.mp3",
                timestamp: startedAt.addingTimeInterval(3)
            ),
            trackTitle: "Example Track",
            fallbackTrackPath: "/tmp/example.mp3",
            queueIndex: 2,
            totalCount: 4
        )

        #expect(activity.stage == .extractingFeatures)
        #expect(activity.currentMessage == "Extracting rhythmic and spectral features")
        #expect(abs((activity.overallProgress ?? 0) - 0.325) < 0.0001)

        activity.markFinished(
            state: .failed,
            errorMessage: "Worker timed out after 120 seconds.",
            message: "Failed Example Track",
            at: startedAt.addingTimeInterval(120)
        )

        #expect(activity.finalState == .failed)
        #expect(activity.lastErrorMessage == "Worker timed out after 120 seconds.")
        #expect(activity.displayedEvents.first?.message == "Failed Example Track")
    }

    @Test
    func timedOutWorkerErrorIncludesDetail() {
        let error = WorkerError.timedOut(120, detail: "Last stderr line")
        #expect(error.localizedDescription.contains("120"))
        #expect(error.localizedDescription.contains("Last stderr line"))
    }

    @Test
    func failureSummaryDistinguishesExecutionAndDecodeFailures() {
        let executionSummary = PythonWorkerClient.failureSummary(
            for: "healthcheck",
            error: WorkerError.executionFailed("permission denied")
        )
        let decodeSummary = PythonWorkerClient.failureSummary(
            for: "healthcheck",
            error: WorkerError.decodeFailed("Payload preview: {\"ok\":true}")
        )

        #expect(executionSummary.contains("execution failed"))
        #expect(decodeSummary.contains("decode failed"))
    }

    @Test
    func healthcheckPayloadDecodesRepresentativeJSON() throws {
        let json = """
        {
          "ok": true,
          "apiKeyConfigured": true,
          "pythonExecutable": "/tmp/python",
          "workerScriptPath": "/tmp/main.py",
          "embeddingProfileID": "google/gemini-embedding-2-preview",
          "dependencies": {
            "librosa": true,
            "chromadb": true,
            "requests": true
          },
          "profileStatusByID": {
            "google/gemini-embedding-2-preview": {
              "supported": true,
              "requiresAPIKey": true,
              "dependencyErrors": []
            }
          },
          "vectorIndexState": {
            "trackCount": 3,
            "collectionCounts": {
              "tracks": 3,
              "intro": 3,
              "middle": 3,
              "outro": 3
            },
            "manifestHash": "abc123"
          }
        }
        """

        let decoded = try JSONDecoder().decode(WorkerHealthcheckResponse.self, from: Data(json.utf8))
        #expect(decoded.ok)
        #expect(decoded.embeddingProfileID == "google/gemini-embedding-2-preview")
        #expect(decoded.vectorIndexState?.trackCount == 3)
        #expect(decoded.profileStatusByID["google/gemini-embedding-2-preview"]?.supported == true)
    }

    @Test
    func noProgressWatchdogBuildsSyntheticEventOnceThresholdIsExceeded() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let activity = AnalysisActivity(
            currentTrackTitle: "Example Track",
            currentTrackPath: "/tmp/example.mp3",
            queueIndex: 1,
            totalCount: 1,
            stage: .launching,
            stageFraction: 0.02,
            startedAt: startedAt,
            updatedAt: startedAt,
            recentEvents: [
                AnalysisActivityEvent(
                    stage: .launching,
                    message: "Launching worker",
                    timestamp: startedAt,
                    fraction: 0.02
                )
            ],
            finalState: nil,
            lastErrorMessage: nil,
            timeoutSec: 120
        )

        let event = AppViewModel.makeAnalysisWatchdogEvent(
            activity: activity,
            thresholdSec: 12,
            now: startedAt.addingTimeInterval(13)
        )

        #expect(event?.stage == .launching)
        #expect(event?.message.contains("No new worker progress for 12s") == true)
    }

    @Test
    func noProgressWatchdogSkipsFinishedOrAlreadyAnnotatedActivities() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let finishedActivity = AnalysisActivity(
            currentTrackTitle: "Done Track",
            currentTrackPath: "/tmp/done.mp3",
            queueIndex: 1,
            totalCount: 1,
            stage: .returningResult,
            stageFraction: 0.98,
            startedAt: startedAt,
            updatedAt: startedAt,
            recentEvents: [],
            finalState: .succeeded,
            lastErrorMessage: nil,
            timeoutSec: 120
        )
        let annotatedActivity = AnalysisActivity(
            currentTrackTitle: "Stalled Track",
            currentTrackPath: "/tmp/stalled.mp3",
            queueIndex: 1,
            totalCount: 1,
            stage: .embeddingAudioSegments,
            stageFraction: 0.72,
            startedAt: startedAt,
            updatedAt: startedAt,
            recentEvents: [
                AnalysisActivityEvent(
                    stage: .embeddingAudioSegments,
                    message: "No new worker progress for 12s (last stage: Embedding Audio Segments)",
                    timestamp: startedAt,
                    fraction: 0.72
                )
            ],
            finalState: nil,
            lastErrorMessage: nil,
            timeoutSec: 120
        )

        #expect(
            AppViewModel.makeAnalysisWatchdogEvent(
                activity: finishedActivity,
                thresholdSec: 12,
                now: startedAt.addingTimeInterval(20)
            ) == nil
        )
        #expect(
            AppViewModel.makeAnalysisWatchdogEvent(
                activity: annotatedActivity,
                thresholdSec: 12,
                now: startedAt.addingTimeInterval(20)
            ) == nil
        )
    }

    @Test
    func preparationOverviewPrefersActiveAnalysisOverScanProgress() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let activity = AnalysisActivity.started(
            trackTitle: "Selected Track",
            trackPath: "/tmp/selected.mp3",
            queueIndex: 2,
            totalCount: 4,
            timeoutSec: 120,
            startedAt: startedAt
        )

        let context = PreparationOverviewContext(
            selectionReadiness: SelectionReadiness(
                signature: "sel",
                selectedCount: 1,
                readyCount: 0,
                needsAnalysisCount: 1,
                needsRefreshCount: 0
            ),
            filteredTrackCount: 12,
            filteredNeedsPreparationCount: 6,
            totalTrackCount: 12,
            hasSourceSetupIssue: false,
            hasSyncableSource: true,
            canPrepareSelection: true,
            canPrepareVisible: true,
            preparationBlockedMessage: nil,
            isAnalyzing: true,
            isCancellingAnalysis: false,
            analysisSessionProgress: AnalysisSessionProgress(
                totalCount: 20,
                runningCount: 3,
                queuedCount: 10,
                completedCount: 7,
                failedCount: 0,
                canceledCount: 0,
                overallProgress: 0.43,
                latestTrackTitle: "Selected Track",
                latestMessage: "Extracting rhythmic and spectral features"
            ),
            analysisActivity: activity,
            preparationNotice: nil,
            analysisErrorMessage: "",
            scanProgress: ScanJobProgress(
                scannedFiles: 10,
                totalFiles: 100,
                indexedFiles: 4,
                skippedFiles: 0,
                duplicateFiles: 0,
                isRunning: true,
                currentFile: "example.mp3"
            ),
            syncingSourceNames: ["Serato"],
            libraryStatusMessage: ""
        )

        let overview = AppViewModel.makePreparationOverview(from: context)

        #expect(overview.phase == .analyzing)
        #expect(overview.isCancellable)
        #expect(overview.message.contains("Selected Track"))
        #expect(overview.message.contains("3 running"))
    }

    @Test
    func preparationOverviewMapsSyncingFailureAndCompletedStates() {
        let syncingContext = PreparationOverviewContext(
            selectionReadiness: SelectionReadiness(
                signature: "",
                selectedCount: 0,
                readyCount: 0,
                needsAnalysisCount: 0,
                needsRefreshCount: 0
            ),
            filteredTrackCount: 0,
            filteredNeedsPreparationCount: 0,
            totalTrackCount: 0,
            hasSourceSetupIssue: false,
            hasSyncableSource: true,
            canPrepareSelection: false,
            canPrepareVisible: false,
            preparationBlockedMessage: nil,
            isAnalyzing: false,
            isCancellingAnalysis: false,
            analysisSessionProgress: nil,
            analysisActivity: nil,
            preparationNotice: nil,
            analysisErrorMessage: "",
            scanProgress: ScanJobProgress(
                scannedFiles: 24,
                totalFiles: 120,
                indexedFiles: 12,
                skippedFiles: 0,
                duplicateFiles: 0,
                isRunning: true,
                currentFile: "track.mp3"
            ),
            syncingSourceNames: ["rekordbox"],
            libraryStatusMessage: ""
        )
        let failedContext = PreparationOverviewContext(
            selectionReadiness: SelectionReadiness(
                signature: "sel",
                selectedCount: 1,
                readyCount: 0,
                needsAnalysisCount: 1,
                needsRefreshCount: 0
            ),
            filteredTrackCount: 1,
            filteredNeedsPreparationCount: 1,
            totalTrackCount: 1,
            hasSourceSetupIssue: false,
            hasSyncableSource: true,
            canPrepareSelection: true,
            canPrepareVisible: true,
            preparationBlockedMessage: nil,
            isAnalyzing: false,
            isCancellingAnalysis: false,
            analysisSessionProgress: nil,
            analysisActivity: nil,
            preparationNotice: nil,
            analysisErrorMessage: "Worker command failed.",
            scanProgress: ScanJobProgress(),
            syncingSourceNames: [],
            libraryStatusMessage: ""
        )
        let completedContext = PreparationOverviewContext(
            selectionReadiness: SelectionReadiness(
                signature: "ready",
                selectedCount: 0,
                readyCount: 0,
                needsAnalysisCount: 0,
                needsRefreshCount: 0
            ),
            filteredTrackCount: 8,
            filteredNeedsPreparationCount: 0,
            totalTrackCount: 8,
            hasSourceSetupIssue: false,
            hasSyncableSource: true,
            canPrepareSelection: false,
            canPrepareVisible: false,
            preparationBlockedMessage: nil,
            isAnalyzing: false,
            isCancellingAnalysis: false,
            analysisSessionProgress: nil,
            analysisActivity: nil,
            preparationNotice: nil,
            analysisErrorMessage: "",
            scanProgress: ScanJobProgress(),
            syncingSourceNames: [],
            libraryStatusMessage: ""
        )

        let syncingOverview = AppViewModel.makePreparationOverview(from: syncingContext)
        let failedOverview = AppViewModel.makePreparationOverview(from: failedContext)
        let completedOverview = AppViewModel.makePreparationOverview(from: completedContext)

        #expect(syncingOverview.phase == .syncing)
        #expect(syncingOverview.primaryAction == .syncLibrary)
        #expect(syncingOverview.primaryActionTitleOverride == "Refreshing Library")
        #expect(syncingOverview.isPrimaryActionDisabled)
        #expect(failedOverview.phase == .failed)
        #expect(completedOverview.phase == .completed)
    }

    @Test
    func preparationOverviewTransitionsToAnalyzeActionsAfterSyncCompletes() {
        let context = PreparationOverviewContext(
            selectionReadiness: SelectionReadiness(
                signature: "",
                selectedCount: 0,
                readyCount: 0,
                needsAnalysisCount: 0,
                needsRefreshCount: 0
            ),
            filteredTrackCount: 8,
            filteredNeedsPreparationCount: 3,
            totalTrackCount: 8,
            hasSourceSetupIssue: false,
            hasSyncableSource: true,
            canPrepareSelection: false,
            canPrepareVisible: true,
            preparationBlockedMessage: nil,
            isAnalyzing: false,
            isCancellingAnalysis: false,
            analysisSessionProgress: nil,
            analysisActivity: nil,
            preparationNotice: nil,
            analysisErrorMessage: "",
            scanProgress: ScanJobProgress(
                scannedFiles: 120,
                totalFiles: 120,
                indexedFiles: 75,
                skippedFiles: 5,
                duplicateFiles: 0,
                isRunning: false,
                currentFile: ""
            ),
            syncingSourceNames: [],
            libraryStatusMessage: "Synced 75 canonical tracks."
        )

        let overview = AppViewModel.makePreparationOverview(from: context)

        #expect(overview.phase == .idle)
        #expect(overview.title == "Prepare Visible Tracks")
        #expect(overview.primaryAction == .prepareVisible)
        #expect(overview.primaryActionTitleOverride == nil)
        #expect(overview.isPrimaryActionDisabled == false)
    }

    @Test
    func preparationOverviewKeepsAnalyzeActionVisibleWhenPreparationSetupNeedsAttention() {
        let context = PreparationOverviewContext(
            selectionReadiness: SelectionReadiness(
                signature: "",
                selectedCount: 0,
                readyCount: 0,
                needsAnalysisCount: 0,
                needsRefreshCount: 0
            ),
            filteredTrackCount: 8,
            filteredNeedsPreparationCount: 3,
            totalTrackCount: 8,
            hasSourceSetupIssue: false,
            hasSyncableSource: true,
            canPrepareSelection: false,
            canPrepareVisible: true,
            preparationBlockedMessage: "Enter a Google AI API Key in Settings before preparing tracks.",
            isAnalyzing: false,
            isCancellingAnalysis: false,
            analysisSessionProgress: nil,
            analysisActivity: nil,
            preparationNotice: nil,
            analysisErrorMessage: "",
            scanProgress: ScanJobProgress(
                scannedFiles: 120,
                totalFiles: 120,
                indexedFiles: 75,
                skippedFiles: 5,
                duplicateFiles: 0,
                isRunning: false,
                currentFile: ""
            ),
            syncingSourceNames: [],
            libraryStatusMessage: "Synced 75 canonical tracks."
        )

        let overview = AppViewModel.makePreparationOverview(from: context)

        #expect(overview.phase == .idle)
        #expect(overview.primaryAction == .prepareVisible)
        #expect(overview.isPrimaryActionDisabled == false)
        #expect(overview.secondaryAction == .syncLibrary)
    }

    @Test
    func initialSetupIsShownWhenGoogleAPIKeyPromptIsRequired() {
        #expect(
            AppViewModel.shouldShowInitialSetup(
                hasTracks: true,
                initialSetupCompleted: true,
                hasNativeLibraries: true,
                hasExistingRoots: true,
                requiresGoogleAPIKeyPrompt: true
            )
        )
        #expect(
            AppViewModel.shouldShowInitialSetup(
                hasTracks: true,
                initialSetupCompleted: true,
                hasNativeLibraries: true,
                hasExistingRoots: true,
                requiresGoogleAPIKeyPrompt: false
            ) == false
        )
    }

    @Test
    func friendlyPreparationMessageRemovesDetailedStageContext() {
        let raw = """
        Worker command failed.
        Last stage: Embedding Audio Segments
        Last event: Preparing audio segment payload
        """

        #expect(AppViewModel.friendlyPreparationMessage(from: raw) == "Worker command failed.")
        #expect(
            AppViewModel.friendlyPreparationMessage(
                from: "Worker timed out after 120 seconds.\nLast stage: Returning Result"
            ) == "Preparation is taking longer than expected. Check the logs if this keeps happening."
        )
    }

    @Test
    func canceledPreparationOverviewReturnsToActionableState() {
        let context = PreparationOverviewContext(
            selectionReadiness: SelectionReadiness(
                signature: "sel",
                selectedCount: 1,
                readyCount: 0,
                needsAnalysisCount: 1,
                needsRefreshCount: 0
            ),
            filteredTrackCount: 4,
            filteredNeedsPreparationCount: 2,
            totalTrackCount: 4,
            hasSourceSetupIssue: false,
            hasSyncableSource: true,
            canPrepareSelection: true,
            canPrepareVisible: true,
            preparationBlockedMessage: nil,
            isAnalyzing: false,
            isCancellingAnalysis: false,
            analysisSessionProgress: nil,
            analysisActivity: nil,
            preparationNotice: PreparationNotice(kind: .canceled, message: "Preparation was canceled."),
            analysisErrorMessage: "",
            scanProgress: ScanJobProgress(),
            syncingSourceNames: [],
            libraryStatusMessage: ""
        )

        let overview = AppViewModel.makePreparationOverview(from: context)

        #expect(overview.phase == .idle)
        #expect(overview.primaryAction == .prepareSelection)
        #expect(overview.isCancellable == false)
    }

    @Test
    func finalizeAnalysisSessionClearsCancelingStateAndPublishesNotice() {
        let viewModel = AppViewModel(skipAsyncBootstrap: true)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_100)

        viewModel.isAnalyzing = true
        viewModel.isCancellingAnalysis = true
        viewModel.analysisActivity = AnalysisActivity.started(
            trackTitle: "Pending Track",
            trackPath: "/tmp/pending.mp3",
            queueIndex: 1,
            totalCount: 1,
            timeoutSec: 120,
            startedAt: startedAt
        )

        viewModel.finalizeAnalysisSession(result: .canceled)

        #expect(viewModel.isAnalyzing == false)
        #expect(viewModel.isCancellingAnalysis == false)
        #expect(viewModel.preparationNotice == PreparationNotice(kind: .canceled, message: "Preparation was canceled."))
    }

    @Test
    func analysisConcurrencyProfileUsesBalancedAndOverrideRules() {
        #expect(
            AnalysisConcurrencyProfile.balancedAuto.resolvedMaxConcurrentJobs(
                processorCount: 10,
                backendKind: .googleAI,
                environment: [:]
            ) == 3
        )
        #expect(
            AnalysisConcurrencyProfile.balancedAuto.resolvedMaxConcurrentJobs(
                processorCount: 10,
                backendKind: .clap,
                environment: [:]
            ) == 1
        )
        #expect(
            AnalysisConcurrencyProfile.balancedAuto.resolvedMaxConcurrentJobs(
                processorCount: 10,
                backendKind: .googleAI,
                environment: ["SORIA_ANALYSIS_MAX_CONCURRENCY": "5"]
            ) == 5
        )
    }

    @Test
    func analysisSessionProgressStatusLineShowsParallelSummary() {
        let progress = AnalysisSessionProgress(
            totalCount: 20,
            runningCount: 3,
            queuedCount: 10,
            completedCount: 7,
            failedCount: 0,
            canceledCount: 0,
            overallProgress: 0.45,
            latestTrackTitle: "Track X",
            latestMessage: "Loading audio"
        )

        #expect(progress.finishedCount == 7)
        #expect(progress.statusLine == "3 running • 7/20 finished • latest: Track X")
    }

    @Test
    func syncLibrariesImmediatelyPresentsSyncSheet() {
        let viewModel = AppViewModel(skipAsyncBootstrap: true)
        viewModel.selectedSection = .settings
        viewModel.tracks = [
            {
                var track = Track.empty(
                    path: "/Music/Authority/Local Track.mp3",
                    modifiedTime: Date(),
                    hash: "local-track"
                )
                track.title = "Local Track"
                track.artist = "Soria"
                track.lastSeenInLocalScanAt = Date()
                return track
            }()
        ]
        viewModel.librarySources = [
            LibrarySourceRecord(
                id: UUID(),
                kind: .serato,
                enabled: true,
                resolvedPath: "/UITests/Serato",
                lastSyncAt: nil,
                status: .available,
                lastError: nil
            ),
            LibrarySourceRecord.default(for: .folderFallback)
        ]

        viewModel.syncLibraries()

        #expect(viewModel.selectedSection == .library)
        #expect(viewModel.scanProgress.isRunning == true)
        #expect(viewModel.librarySources.first?.status == .syncing)
        #expect(viewModel.librarySyncPresentationState?.phase == .running)
        #expect(viewModel.librarySyncPresentationState?.title == "Refreshing Vendor Metadata")
        #expect(viewModel.isLibrarySyncSheetPresented == true)
        #expect(viewModel.preparationOverview.primaryAction == .syncLibrary)
        #expect(viewModel.preparationOverview.primaryActionTitleOverride == "Refreshing Library")
        #expect(viewModel.preparationOverview.isPrimaryActionDisabled)
    }

    @Test
    func finishSuccessfulLibrarySyncDismissesSheetAndResetsProgress() {
        let viewModel = AppViewModel(skipAsyncBootstrap: true)
        viewModel.presentLibrarySyncSheet(
            title: "Refreshing Vendor Metadata",
            actionVerb: "Refreshing vendor metadata for",
            sourceNames: ["Serato"]
        )
        viewModel.scanProgress = ScanJobProgress(
            scannedFiles: 12,
            totalFiles: 24,
            indexedFiles: 8,
            skippedFiles: 1,
            duplicateFiles: 0,
            isRunning: true,
            currentFile: "Current Track.mp3"
        )
        viewModel.preparationNotice = PreparationNotice(kind: .failed, message: "Old failure")

        viewModel.finishSuccessfulLibrarySync(summary: "Synced 8 canonical tracks.")

        #expect(viewModel.librarySyncPresentationState == nil)
        #expect(viewModel.scanProgress.isRunning == false)
        #expect(viewModel.scanProgress.currentFile.isEmpty)
        #expect(viewModel.libraryStatusMessage == "Synced 8 canonical tracks.")
        #expect(viewModel.preparationNotice == nil)
    }

    @Test
    func syncLibrariesWithoutEnabledSourcesPublishesFailureNotice() {
        let viewModel = AppViewModel(skipAsyncBootstrap: true)
        viewModel.selectedSection = .settings
        viewModel.tracks = [
            {
                var track = Track.empty(
                    path: "/Music/Authority/Local Track.mp3",
                    modifiedTime: Date(),
                    hash: "local-track"
                )
                track.title = "Local Track"
                track.artist = "Soria"
                track.lastSeenInLocalScanAt = Date()
                return track
            }()
        ]
        viewModel.librarySources = [LibrarySourceRecord.default(for: .folderFallback)]

        viewModel.syncLibraries()

        #expect(viewModel.selectedSection == .library)
        #expect(viewModel.librarySyncPresentationState == nil)
        #expect(viewModel.preparationNotice?.kind == .failed)
        #expect(viewModel.preparationNotice?.message.contains("Enable Serato or rekordbox metadata sources") == true)
    }

    @Test
    func scopeSummaryTracksSelectedFacetCount() {
        var filter = LibraryScopeFilter()
        filter.seratoMembershipPaths = ["Warmup / Deep", "Peak / Tools"]
        filter.rekordboxMembershipPaths = ["Festival / Day 1 / Sunrise"]

        let statistics = ScopedTrackStatistics(
            total: 9,
            ready: 5,
            needsAnalysis: 3,
            needsRefresh: 1,
            seratoCoverage: 6,
            rekordboxCoverage: 4
        )

        #expect(filter.selectedFacetCount == 3)
        #expect(
            AppViewModel.scopeSummary(
                target: .recommendation,
                filter: filter,
                statistics: statistics
            ) == "3 references • 9 tracks in scope"
        )
        #expect(
            AppViewModel.scopeSummary(
                target: .library,
                filter: LibraryScopeFilter(),
                statistics: statistics
            ) == "All scanned local tracks"
        )
    }

    @Test
    func swiftProcessWorkerAnalyzeSmokeTest() throws {
        guard ProcessInfo.processInfo.environment["SORIA_RUN_WORKER_IPC_TESTS"] == "1" else { return }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let pythonURL = root.appendingPathComponent("analysis-worker/.venv/bin/python")
        let workerURL = root.appendingPathComponent("analysis-worker/main.py")
        let apiKey =
            ProcessInfo.processInfo.environment["GOOGLE_AI_API_KEY"]
            ?? ProcessInfo.processInfo.environment["GOOGLE_API_KEY"]
            ?? ProcessInfo.processInfo.environment["GEMINI_API_KEY"]

        guard
            FileManager.default.fileExists(atPath: pythonURL.path),
            FileManager.default.fileExists(atPath: workerURL.path),
            let apiKey,
            !apiKey.isEmpty
        else {
            return
        }

        let tempDirectory = try makeTemporaryDirectory()
        let audioURL = tempDirectory.appendingPathComponent("worker-ipc-smoke.wav")
        try writeTestWAV(to: audioURL)

        let payload: [String: Any] = [
            "command": "analyze",
            "filePath": audioURL.path,
            "trackMetadata": [
                "trackID": UUID().uuidString,
                "title": "Worker IPC Smoke",
                "artist": "Soria Tests",
                "genre": "House",
                "bpm": 122.0,
                "musicalKey": "8A",
                "duration": 1.0,
                "modifiedTime": LibraryDatabase.iso8601.string(from: Date(timeIntervalSince1970: 1_700_000_000)),
                "contentHash": "worker-ipc-smoke",
                "hasSeratoMetadata": false,
                "hasRekordboxMetadata": false,
                "tags": [],
                "rating": NSNull(),
                "playCount": NSNull(),
                "playlistMemberships": [],
                "cueCount": NSNull(),
                "comment": NSNull()
            ],
            "options": [
                "googleAIAPIKey": apiKey,
                "cacheDirectory": tempDirectory.appendingPathComponent("worker-cache", isDirectory: true).path,
                "embeddingProfileID": EmbeddingProfile.googleGeminiEmbedding2Preview.id,
                "embeddingPipelineID": EmbeddingPipeline.audioSegmentsV1.id,
                "analysisFocus": AnalysisFocus.balanced.rawValue
            ]
        ]

        let result = try runWorkerProcess(
            pythonExecutable: pythonURL.path,
            workerScriptPath: workerURL.path,
            payload: payload,
            timeoutSec: 180
        )

        let progressEvents = TestProgressEventBox()
        let router = WorkerStderrRouter { event in
            progressEvents.append(event)
        }
        router.append(result.stderrData)
        router.finish()

        let response = try JSONDecoder().decode(WorkerAnalysisResult.self, from: result.stdoutData)
        #expect(result.terminationStatus == 0)
        #expect(progressEvents.events.isEmpty == false)
        #expect(response.segments.count == 3)
        #expect(response.trackEmbedding?.isEmpty == false)
    }
}

private final class TestProgressEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [WorkerProgressEvent] = []

    var events: [WorkerProgressEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ event: WorkerProgressEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeTestWAV(to url: URL) throws {
    let sampleRate = 22_050
    let durationSec = 1.0
    let sampleCount = Int(Double(sampleRate) * durationSec)
    var pcmData = Data(capacity: sampleCount * MemoryLayout<Int16>.size)

    for index in 0..<sampleCount {
        let sample = sin(2 * Double.pi * 440 * Double(index) / Double(sampleRate))
        let scaled = Int16(max(min(sample * Double(Int16.max) * 0.3, Double(Int16.max)), Double(Int16.min)))
        var littleEndian = scaled.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            pcmData.append(contentsOf: bytes)
        }
    }

    let byteRate = sampleRate * 2
    let blockAlign: UInt16 = 2
    let bitsPerSample: UInt16 = 16
    let chunkSize = 36 + pcmData.count

    var wav = Data()
    wav.append(Data("RIFF".utf8))
    wav.append(littleEndian32(chunkSize))
    wav.append(Data("WAVE".utf8))
    wav.append(Data("fmt ".utf8))
    wav.append(littleEndian32(16))
    wav.append(littleEndian16(1))
    wav.append(littleEndian16(1))
    wav.append(littleEndian32(sampleRate))
    wav.append(littleEndian32(byteRate))
    wav.append(littleEndian16(Int(blockAlign)))
    wav.append(littleEndian16(Int(bitsPerSample)))
    wav.append(Data("data".utf8))
    wav.append(littleEndian32(pcmData.count))
    wav.append(pcmData)

    try wav.write(to: url)
}

private func littleEndian16(_ value: Int) -> Data {
    var value = UInt16(value).littleEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}

private func littleEndian32(_ value: Int) -> Data {
    var value = UInt32(value).littleEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}

private func runWorkerProcess(
    pythonExecutable: String,
    workerScriptPath: String,
    payload: [String: Any],
    timeoutSec: TimeInterval
) throws -> (terminationStatus: Int32, stdoutData: Data, stderrData: Data) {
    let payloadData = try JSONSerialization.data(withJSONObject: payload)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: pythonExecutable)
    process.arguments = [workerScriptPath]

    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    let readGroup = DispatchGroup()
    let stdoutBox = TestDataBox()
    let stderrBox = TestDataBox()

    readGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        stdoutBox.set(outputPipe.fileHandleForReading.readDataToEndOfFile())
        readGroup.leave()
    }

    readGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        stderrBox.set(errorPipe.fileHandleForReading.readDataToEndOfFile())
        readGroup.leave()
    }

    try inputPipe.fileHandleForWriting.write(contentsOf: payloadData)
    try inputPipe.fileHandleForWriting.close()

    let deadline = Date().addingTimeInterval(timeoutSec)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
    }
    if process.isRunning {
        process.terminate()
        kill(process.processIdentifier, SIGKILL)
    }
    _ = readGroup.wait(timeout: .now() + 5)
    return (process.terminationStatus, stdoutBox.data, stderrBox.data)
}

private final class TestDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }
}
