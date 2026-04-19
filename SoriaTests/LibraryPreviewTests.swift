import Foundation
import SwiftUI
import Testing
@testable import Soria

@MainActor
struct LibraryPreviewTests {
    @Test
    func libraryPreviewRequiresExactlyOneSelectedTrack() async {
        let previewPlayer = PreviewPlayerStub()
        let viewModel = AppViewModel(skipAsyncBootstrap: true, libraryPreviewPlayer: previewPlayer)
        let first = makeTrack(title: "First", duration: 240)
        let second = makeTrack(title: "Second", duration: 240)

        viewModel.configureRecommendationSearchStateForTesting(
            tracks: [first, second],
            selectedTrackIDs: [],
            readyTrackIDs: [],
            validationStatus: .validated(Date())
        )
        #expect(viewModel.libraryPreviewState == .hidden)

        viewModel.configureRecommendationSearchStateForTesting(
            tracks: [first, second],
            selectedTrackIDs: [first.id],
            readyTrackIDs: [],
            validationStatus: .validated(Date())
        )
        #expect(await waitUntil { viewModel.libraryPreviewState.isPrepared })
        #expect(viewModel.libraryPreviewState.trackID == first.id)
        #expect(viewModel.libraryPreviewState.isAvailable)
        #expect(viewModel.libraryPreviewState.isPrepared)
        #expect(viewModel.libraryPreviewState.totalDurationSec == 240)
        #expect(viewModel.shouldShowLibraryPreviewStrip)

        viewModel.configureRecommendationSearchStateForTesting(
            tracks: [first, second],
            selectedTrackIDs: [first.id, second.id],
            readyTrackIDs: [],
            validationStatus: .validated(Date())
        )
        #expect(viewModel.libraryPreviewState == .hidden)
    }

    @Test
    func libraryPreviewStopsForSectionChangesSelectionChangesAndSearchFocus() async {
        let previewPlayer = PreviewPlayerStub()
        let viewModel = AppViewModel(skipAsyncBootstrap: true, libraryPreviewPlayer: previewPlayer)
        let first = makeTrack(title: "First", duration: 240)
        let second = makeTrack(title: "Second", duration: 240)

        viewModel.configureRecommendationSearchStateForTesting(
            tracks: [first, second],
            selectedTrackIDs: [first.id],
            readyTrackIDs: [],
            validationStatus: .validated(Date())
        )

        viewModel.toggleLibraryPreview()
        #expect(await waitUntil { viewModel.libraryPreviewState.isPlaying && previewPlayer.totalPlayInvocationCount == 1 })

        viewModel.selectedSection = .mixAssistant
        #expect(!viewModel.libraryPreviewState.isPlaying)
        #expect(previewPlayer.stopCount == 1)

        viewModel.selectedSection = .library
        viewModel.refreshLibraryPreviewAvailability()
        viewModel.toggleLibraryPreview()
        #expect(await waitUntil { viewModel.libraryPreviewState.isPlaying })

        viewModel.libraryTableSelection.wrappedValue = [second.id]
        #expect(
            await waitUntil {
                !viewModel.libraryPreviewState.isPlaying &&
                viewModel.libraryPreviewState.trackID == second.id &&
                previewPlayer.stopCount >= 2
            }
        )

        viewModel.toggleLibraryPreview()
        #expect(viewModel.libraryPreviewState.isPlaying)
        viewModel.setLibrarySearchFieldFocused(true)
        #expect(!viewModel.libraryPreviewState.isPlaying)
        #expect(previewPlayer.stopCount >= 3)
    }

    @Test
    func libraryPreviewPrefersCueThenIntroThenZeroAcrossFullTrack() {
        let previewPlayer = PreviewPlayerStub()
        let viewModel = AppViewModel(skipAsyncBootstrap: true, libraryPreviewPlayer: previewPlayer)
        let track = makeTrack(title: "Preview Track", duration: 35)

        viewModel.configureRecommendationSearchStateForTesting(
            tracks: [track],
            selectedTrackIDs: [track.id],
            readyTrackIDs: [],
            validationStatus: .validated(Date())
        )

        viewModel.selectedTrackAnalysis = TrackAnalysisSummary(
            trackID: track.id,
            segments: [],
            trackEmbedding: nil,
            estimatedBPM: nil,
            estimatedKey: nil,
            brightness: 0,
            onsetDensity: 0,
            rhythmicDensity: 0,
            lowMidHighBalance: [0.2, 0.3, 0.5],
            waveformPreview: [],
            introLengthSec: 12
        )
        viewModel.selectedTrackExternalMetadata = [
            ExternalDJMetadata(
                id: UUID(),
                trackPath: track.filePath,
                source: .rekordbox,
                bpm: nil,
                musicalKey: nil,
                rating: nil,
                color: nil,
                tags: [],
                playCount: nil,
                lastPlayed: nil,
                playlistMemberships: [],
                cueCount: 1,
                cuePoints: [
                    ExternalDJCuePoint(
                        kind: .hotcue,
                        name: "A",
                        index: 1,
                        startSec: 28,
                        endSec: nil,
                        color: nil,
                        source: nil
                    )
                ],
                comment: nil,
                vendorTrackID: nil,
                analysisState: nil,
                analysisCachePath: nil,
                syncVersion: nil
            )
        ]
        viewModel.refreshLibraryPreviewAvailability()

        #expect(viewModel.libraryPreviewState.defaultStartSec == 28)
        #expect(viewModel.libraryPreviewState.totalDurationSec == 35)

        viewModel.selectedTrackExternalMetadata = []
        viewModel.refreshLibraryPreviewAvailability()
        #expect(viewModel.libraryPreviewState.defaultStartSec == 12)

        let noIntroTrack = makeTrack(title: "No Intro", duration: 20)
        viewModel.configureRecommendationSearchStateForTesting(
            tracks: [noIntroTrack],
            selectedTrackIDs: [noIntroTrack.id],
            readyTrackIDs: [],
            validationStatus: .validated(Date())
        )
        viewModel.selectedTrackAnalysis = TrackAnalysisSummary(
            trackID: noIntroTrack.id,
            segments: [],
            trackEmbedding: nil,
            estimatedBPM: nil,
            estimatedKey: nil,
            brightness: 0,
            onsetDensity: 0,
            rhythmicDensity: 0,
            lowMidHighBalance: [0.2, 0.3, 0.5],
            waveformPreview: [],
            introLengthSec: 7
        )
        viewModel.refreshLibraryPreviewAvailability()
        #expect(viewModel.libraryPreviewState.defaultStartSec == 0)
        #expect(viewModel.libraryPreviewState.totalDurationSec == 20)
    }

    @Test
    func libraryPreviewSeekUsesNormalizedPositionAndAutoplays() async {
        let previewPlayer = PreviewPlayerStub()
        let viewModel = AppViewModel(skipAsyncBootstrap: true, libraryPreviewPlayer: previewPlayer)
        let track = makeTrack(title: "Seek Track", duration: 240)

        viewModel.configureRecommendationSearchStateForTesting(
            tracks: [track],
            selectedTrackIDs: [track.id],
            readyTrackIDs: [],
            validationStatus: .validated(Date())
        )

        viewModel.seekLibraryPreview(normalizedPosition: 0.5, autoplay: true)

        #expect(await waitUntil { previewPlayer.totalSeekInvocationCount == 1 })
        #expect(previewPlayer.lastObservedSeekRequest?.time == 120)
        #expect(previewPlayer.lastObservedSeekRequest?.autoplay == true)
        #expect(previewPlayer.lastObservedSeekRequest?.kind == .waveformScrub)
        #expect(viewModel.libraryPreviewState.currentTimeSec == 120)
        #expect(viewModel.libraryPreviewState.isPlaying)
        #expect(viewModel.libraryPreviewState.progress == 0.5)
    }

    @Test
    func libraryPreviewUsesPreciseCueSeekKind() async {
        let previewPlayer = PreviewPlayerStub()
        let viewModel = AppViewModel(skipAsyncBootstrap: true, libraryPreviewPlayer: previewPlayer)
        let track = makeTrack(title: "Cue Track", duration: 240)

        viewModel.configureRecommendationSearchStateForTesting(
            tracks: [track],
            selectedTrackIDs: [track.id],
            readyTrackIDs: [],
            validationStatus: .validated(Date())
        )

        viewModel.seekLibraryPreview(to: 24, autoplay: true, seekKind: .cuePoint)

        #expect(await waitUntil { previewPlayer.lastObservedSeekRequest?.kind == .cuePoint })
        #expect(previewPlayer.lastObservedSeekRequest?.kind == .cuePoint)
        #expect(viewModel.libraryPreviewState.currentTimeSec == 24)
    }

    @Test
    func libraryPreviewRapidWaveformClicksKeepLatestPosition() async {
        let previewPlayer = PreviewPlayerStub()
        let viewModel = AppViewModel(skipAsyncBootstrap: true, libraryPreviewPlayer: previewPlayer)
        let track = makeTrack(title: "Rapid Seek Track", duration: 240)

        viewModel.configureRecommendationSearchStateForTesting(
            tracks: [track],
            selectedTrackIDs: [track.id],
            readyTrackIDs: [],
            validationStatus: .validated(Date())
        )

        viewModel.seekLibraryPreview(normalizedPosition: 0.2, autoplay: true)
        viewModel.seekLibraryPreview(normalizedPosition: 0.75, autoplay: true)

        #expect(await waitUntil { previewPlayer.totalSeekInvocationCount == 1 })
        #expect(previewPlayer.totalSeekInvocationCount == 1)
        #expect(previewPlayer.lastObservedSeekRequest?.time == 180)
        #expect(previewPlayer.lastObservedSeekRequest?.kind == .waveformScrub)
        #expect(viewModel.libraryPreviewState.currentTimeSec == 180)
        #expect(viewModel.libraryPreviewState.progress == 0.75)
        #expect(viewModel.libraryPreviewState.isPlaying)
    }

    @Test
    func libraryPreviewWaveformMouseDownSeeksImmediatelyAndMouseUpAddsNoExtraSeek() async {
        let previewPlayer = PreviewPlayerStub()
        let viewModel = AppViewModel(skipAsyncBootstrap: true, libraryPreviewPlayer: previewPlayer)
        let track = makeTrack(title: "Immediate Input Track", duration: 240)

        viewModel.configureRecommendationSearchStateForTesting(
            tracks: [track],
            selectedTrackIDs: [track.id],
            readyTrackIDs: [],
            validationStatus: .validated(Date())
        )

        viewModel.handleLibraryPreviewInteraction(normalizedPosition: 0.5, phase: .mouseDown)
        #expect(await waitUntil { previewPlayer.totalSeekInvocationCount == 1 })
        #expect(previewPlayer.lastObservedSeekRequest?.time == 120)
        #expect(viewModel.libraryPreviewState.currentTimeSec == 120)

        viewModel.handleLibraryPreviewInteraction(normalizedPosition: 0.5, phase: .mouseUp)
        #expect(previewPlayer.totalSeekInvocationCount == 1)
    }

    @Test
    func libraryPreviewWarmPreparedSeekUsesDirectFastPath() async {
        let previewPlayer = PreviewPlayerStub()
        let viewModel = AppViewModel(skipAsyncBootstrap: true, libraryPreviewPlayer: previewPlayer)
        let track = makeTrack(title: "Warm Direct Track", duration: 240)

        viewModel.configureRecommendationSearchStateForTesting(
            tracks: [track],
            selectedTrackIDs: [track.id],
            readyTrackIDs: [],
            validationStatus: .validated(Date())
        )

        #expect(await waitUntil { viewModel.libraryPreviewState.isWarm })

        viewModel.seekLibraryPreview(to: 96, autoplay: true, seekKind: .waveformScrub)

        #expect(await waitUntil { previewPlayer.directSeekRequests.count == 1 })
        #expect(previewPlayer.directSeekRequests.count == 1)
        #expect(previewPlayer.seekRequests.isEmpty)
        #expect(previewPlayer.directSeekRequests.last?.time == 96)
        #expect(viewModel.libraryPreviewState.currentTimeSec == 96)
    }

    @Test
    func previewPressIntentTrackerCommitsOnlyInsideActiveWindow() {
        var tracker = PreviewPressIntentTracker()
        let bounds = CGRect(x: 0, y: 0, width: 120, height: 40)
        let point = CGPoint(x: 20, y: 20)

        tracker.arm(at: point)
        #expect(tracker.commitIfPossible(within: bounds, isWindowActive: true) == .commit(point))

        tracker.arm(at: point)
        #expect(tracker.commitIfPossible(within: bounds, isWindowActive: false) == .cancel)
    }

    @Test
    func previewPressIntentTrackerTurnsLargeMovementIntoDrag() {
        var tracker = PreviewPressIntentTracker()
        let bounds = CGRect(x: 0, y: 0, width: 240, height: 52)

        tracker.arm(at: CGPoint(x: 20, y: 20))
        #expect(
            tracker.move(to: CGPoint(x: 26, y: 20), within: bounds) == .beginDrag(CGPoint(x: 26, y: 20))
        )
        #expect(tracker.commitIfPossible(within: bounds, isWindowActive: true) == .none)
    }

    @Test
    func libraryPreviewWaveformDragCoalescesToLatestSeek() async {
        let previewPlayer = PreviewPlayerStub()
        let viewModel = AppViewModel(
            skipAsyncBootstrap: true,
            libraryPreviewPlayer: previewPlayer,
            libraryPreviewInteractiveSeekDispatchIntervalSec: 0.05
        )
        let track = makeTrack(title: "Drag Track", duration: 240)

        viewModel.configureRecommendationSearchStateForTesting(
            tracks: [track],
            selectedTrackIDs: [track.id],
            readyTrackIDs: [],
            validationStatus: .validated(Date())
        )

        viewModel.handleLibraryPreviewInteraction(normalizedPosition: 0.2, phase: .mouseDown)
        viewModel.handleLibraryPreviewInteraction(normalizedPosition: 0.24, phase: .dragChanged)
        viewModel.handleLibraryPreviewInteraction(normalizedPosition: 0.75, phase: .dragChanged)
        viewModel.handleLibraryPreviewInteraction(normalizedPosition: 0.75, phase: .mouseUp)

        #expect(await waitUntil { previewPlayer.totalSeekInvocationCount == 1 })
        #expect(previewPlayer.totalSeekInvocationCount == 1)
        #expect(previewPlayer.lastObservedSeekRequest?.time == 180)
        #expect(viewModel.libraryPreviewState.currentTimeSec == 180)
    }

    @Test
    func waveformCueGroupsMergeSourcesWithinFiftyMilliseconds() {
        let metadata = [
            ExternalDJMetadata(
                id: UUID(),
                trackPath: "/music/track.wav",
                source: .serato,
                bpm: nil,
                musicalKey: nil,
                rating: nil,
                color: nil,
                tags: [],
                playCount: nil,
                lastPlayed: nil,
                playlistMemberships: [],
                cueCount: 1,
                cuePoints: [
                    ExternalDJCuePoint(
                        kind: .hotcue,
                        name: "Drop",
                        index: 1,
                        startSec: 32.000,
                        endSec: nil,
                        color: "#FF5500",
                        source: "serato:markers2"
                    )
                ],
                comment: nil,
                vendorTrackID: nil,
                analysisState: nil,
                analysisCachePath: nil,
                syncVersion: nil
            ),
            ExternalDJMetadata(
                id: UUID(),
                trackPath: "/music/track.wav",
                source: .rekordbox,
                bpm: nil,
                musicalKey: nil,
                rating: nil,
                color: nil,
                tags: [],
                playCount: nil,
                lastPlayed: nil,
                playlistMemberships: [],
                cueCount: 2,
                cuePoints: [
                    ExternalDJCuePoint(
                        kind: .hotcue,
                        name: "Drop",
                        index: 1,
                        startSec: 32.035,
                        endSec: nil,
                        color: "#2563EB",
                        source: "rekordbox:anlz"
                    ),
                    ExternalDJCuePoint(
                        kind: .loop,
                        name: "Loop",
                        index: 2,
                        startSec: 64,
                        endSec: 72,
                        color: "#10B981",
                        source: "rekordbox:anlz_ext"
                    )
                ],
                comment: nil,
                vendorTrackID: nil,
                analysisState: nil,
                analysisCachePath: nil,
                syncVersion: nil
            )
        ]

        let groups = TrackCuePresentation.waveformCueGroups(from: metadata)

        #expect(groups.count == 2)
        #expect(groups[0].sources.count == 2)
        #expect(groups[0].tooltipText.contains("Serato Hot Cue"))
        #expect(groups[0].tooltipText.contains("rekordbox Hot Cue"))
        #expect(groups[1].isLoop)
        #expect(groups[1].endSec == 72)
    }

    @Test
    func libraryPreviewPlayerPreparesSeeksAndEndsAtTrackDuration() async throws {
        let backend = PreviewBackendStub(durationSec: 180)
        let player = LibraryPreviewPlayer(backend: backend)
        let url = try makeTempAudioFile()
        var states: [LibraryPreviewPlaybackState] = []
        player.onPlaybackStateChange = { states.append($0) }

        try await player.prepare(url: url)
        #expect(backend.loadedURLs == [url.standardizedFileURL])
        #expect(states.last?.isPrepared == true)
        #expect(states.last?.isWarm == true)
        #expect(states.last?.totalDurationSec == 180)

        try await player.play(url: url, fromTime: 12)
        #expect(backend.playTimes == [12])
        #expect(states.last?.isPlaying == true)
        #expect(states.last?.currentTimeSec == 12)

        try await player.seek(to: 42, autoplay: false, kind: .waveformScrub)
        #expect(backend.seekRequests.last?.time == 42)
        #expect(backend.seekRequests.last?.autoplay == false)
        #expect(backend.seekRequests.last?.kind == .waveformScrub)
        #expect(states.last?.isPlaying == false)
        #expect(states.last?.currentTimeSec == 42)

        backend.emitTime(50)
        #expect(states.last?.currentTimeSec == 50)

        backend.emitEnded()
        #expect(states.last?.isPlaying == false)
        #expect(states.last?.currentTimeSec == 180)
    }

    @Test
    func libraryPreviewPlayerAvoidsReloadingPreparedTrackAndMapsMissingFiles() async throws {
        let backend = PreviewBackendStub(durationSec: 120)
        let player = LibraryPreviewPlayer(backend: backend)
        let url = try makeTempAudioFile()

        try await player.prepare(url: url)
        try await player.play(url: url, fromTime: 4)
        try await player.play(url: url, fromTime: 4)
        #expect(backend.loadedURLs.count == 1)
        #expect(backend.playTimes.count == 2)

        do {
            try await player.play(
                url: URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).wav"),
                fromTime: 0
            )
            Issue.record("Expected preview play to fail for a missing file.")
        } catch let error as LibraryPreviewPlayerError {
            #expect(error.errorDescription == "Preview unavailable. The audio file could not be found.")
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }
    }

    @Test
    func libraryPreviewPlayerPauseDoesNotReloadPreparedTrack() async throws {
        let backend = PreviewBackendStub(durationSec: 120)
        let player = LibraryPreviewPlayer(backend: backend)
        let url = try makeTempAudioFile()

        try await player.play(url: url, fromTime: 4)
        player.pause()
        try await player.play(url: url, fromTime: 4)

        #expect(backend.loadedURLs.count == 1)
        #expect(backend.pauseCount == 1)
        #expect(backend.playTimes.count == 2)
    }

    @Test
    func libraryPreviewPlayerAppliesLateDurationUpdate() async throws {
        let backend = PreviewBackendStub(durationSec: 0)
        let player = LibraryPreviewPlayer(backend: backend)
        let url = try makeTempAudioFile()
        var states: [LibraryPreviewPlaybackState] = []
        player.onPlaybackStateChange = { states.append($0) }

        try await player.prepare(url: url)
        #expect(states.last?.totalDurationSec == 0)

        backend.emitDuration(180)
        #expect(states.last?.totalDurationSec == 180)
    }

    @Test
    func libraryPreviewPlayerWarmStopAvoidsReloadUntilExplicitDiscard() async throws {
        let backend = PreviewBackendStub(durationSec: 120)
        let player = LibraryPreviewPlayer(backend: backend)
        let url = try makeTempAudioFile()
        var states: [LibraryPreviewPlaybackState] = []
        player.onPlaybackStateChange = { states.append($0) }

        try await player.prepare(url: url)
        try await player.play(url: url, fromTime: 16)
        player.stop()

        #expect(backend.loadedURLs.count == 1)
        #expect(backend.stopCount == 1)
        #expect(states.last?.currentTimeSec == 0)
        #expect(states.last?.isPrepared == true)
        #expect(states.last?.isWarm == true)

        try await player.play(url: url, fromTime: 0)
        #expect(backend.loadedURLs.count == 1)
        #expect(backend.playTimes.count == 2)

        player.discardPreparedItem(for: url)
        #expect(backend.discardCount == 1)
        #expect(states.last?.isPrepared == false)
        #expect(states.last?.isWarm == false)

        try await player.play(url: url, fromTime: 0)
        #expect(backend.loadedURLs.count == 2)
    }

    @Test
    func adaptivePreviewBackendUsesAudioEngineWhenAvailable() async throws {
        let audioEngineBackend = PreviewBackendStub(durationSec: 111)
        let avPlayerBackend = PreviewBackendStub(durationSec: 222)
        let backend = AdaptiveLibraryPreviewBackend(
            environment: ["SORIA_LIBRARY_PREVIEW_BACKEND": "auto"],
            audioEngineBackend: audioEngineBackend,
            avPlayerBackend: avPlayerBackend
        )
        let url = try makeTempAudioFile()

        let duration = try await backend.load(url: url)

        #expect(duration == 111)
        #expect(audioEngineBackend.loadedURLs == [url.standardizedFileURL])
        #expect(avPlayerBackend.loadedURLs.isEmpty)
    }

    @Test
    func adaptivePreviewBackendFallsBackToAVPlayerWhenAudioEngineLoadFails() async throws {
        let audioEngineBackend = ThrowingPreviewBackendStub()
        let avPlayerBackend = PreviewBackendStub(durationSec: 222)
        let backend = AdaptiveLibraryPreviewBackend(
            environment: ["SORIA_LIBRARY_PREVIEW_BACKEND": "auto"],
            audioEngineBackend: audioEngineBackend,
            avPlayerBackend: avPlayerBackend
        )
        let url = try makeTempAudioFile()

        let duration = try await backend.load(url: url)

        #expect(duration == 222)
        #expect(audioEngineBackend.loadAttempts == [url.standardizedFileURL])
        #expect(avPlayerBackend.loadedURLs == [url.standardizedFileURL])
    }

    @Test
    func libraryPreviewRunsOnlyLatestPendingActionAfterDelayedPrepare() async {
        let previewPlayer = PreviewPlayerStub()
        previewPlayer.prepareDelayNanoseconds = 80_000_000
        let viewModel = AppViewModel(skipAsyncBootstrap: true, libraryPreviewPlayer: previewPlayer)
        let track = makeTrack(title: "Delayed Prepare Track", duration: 240)

        viewModel.configureRecommendationSearchStateForTesting(
            tracks: [track],
            selectedTrackIDs: [track.id],
            readyTrackIDs: [],
            validationStatus: .validated(Date())
        )

        viewModel.seekLibraryPreview(normalizedPosition: 0.2, autoplay: true)
        viewModel.seekLibraryPreview(normalizedPosition: 0.75, autoplay: true)

        #expect(await waitUntil { previewPlayer.totalSeekInvocationCount == 1 })
        #expect(previewPlayer.lastObservedSeekRequest?.time == 180)
        #expect(viewModel.libraryPreviewState.currentTimeSec == 180)
    }

    @Test
    func libraryPreviewRefreshAvoidsDuplicateWarmPrepareAndSeek() async {
        let previewPlayer = PreviewPlayerStub()
        let viewModel = AppViewModel(skipAsyncBootstrap: true, libraryPreviewPlayer: previewPlayer)
        let track = makeTrack(title: "Warm Track", duration: 240)

        viewModel.configureRecommendationSearchStateForTesting(
            tracks: [track],
            selectedTrackIDs: [track.id],
            readyTrackIDs: [],
            validationStatus: .validated(Date())
        )
        #expect(await waitUntil { previewPlayer.prepareRequests.count == 1 })
        let initialPrepareCount = previewPlayer.prepareRequests.count

        viewModel.seekLibraryPreview(normalizedPosition: 0.25, autoplay: false)
        #expect(await waitUntil { previewPlayer.totalSeekInvocationCount == 1 })

        viewModel.selectedTrackExternalMetadata = []
        viewModel.refreshLibraryPreviewAvailability()
        viewModel.refreshLibraryPreviewAvailability()

        #expect(previewPlayer.prepareRequests.count == initialPrepareCount)
        #expect(previewPlayer.totalSeekInvocationCount == 1)
    }

    @Test
    func libraryPreviewReleasesWarmItemAfterGraceWindow() async {
        let previewPlayer = PreviewPlayerStub()
        let viewModel = AppViewModel(
            skipAsyncBootstrap: true,
            libraryPreviewPlayer: previewPlayer,
            libraryPreviewWarmReleaseDelaySec: 0
        )
        let track = makeTrack(title: "Grace Track", duration: 240)

        viewModel.configureRecommendationSearchStateForTesting(
            tracks: [track],
            selectedTrackIDs: [track.id],
            readyTrackIDs: [],
            validationStatus: .validated(Date())
        )
        #expect(await waitUntil { viewModel.libraryPreviewState.isWarm })

        viewModel.setLibrarySearchFieldFocused(true)
        #expect(await waitUntil {
            previewPlayer.stopCount == 1 &&
                previewPlayer.discardCount == 1 &&
                viewModel.libraryPreviewState.isWarm == false
        })
    }

    @Test
    func libraryPreviewKeepsWarmItemWhenSameTrackReturnsBeforeGraceWindow() async {
        let previewPlayer = PreviewPlayerStub()
        let viewModel = AppViewModel(
            skipAsyncBootstrap: true,
            libraryPreviewPlayer: previewPlayer,
            libraryPreviewWarmReleaseDelaySec: 0.05
        )
        let track = makeTrack(title: "Warm Return Track", duration: 240)

        viewModel.configureRecommendationSearchStateForTesting(
            tracks: [track],
            selectedTrackIDs: [track.id],
            readyTrackIDs: [],
            validationStatus: .validated(Date())
        )
        #expect(await waitUntil { viewModel.libraryPreviewState.isWarm })

        viewModel.setLibrarySearchFieldFocused(true)
        viewModel.setLibrarySearchFieldFocused(false)
        viewModel.refreshLibraryPreviewAvailability()
        #expect(viewModel.libraryPreviewState.isWarm == true)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(previewPlayer.stopCount == 1)
        #expect(previewPlayer.discardCount == 0)
        #expect(viewModel.libraryPreviewState.isWarm == true)
    }

    @Test
    func libraryPreviewStopResetsUIAndImmediateSeekCanRestartWarmPreview() async {
        let previewPlayer = PreviewPlayerStub()
        let viewModel = AppViewModel(skipAsyncBootstrap: true, libraryPreviewPlayer: previewPlayer)
        let track = makeTrack(title: "Stop Resume Track", duration: 240)

        viewModel.configureRecommendationSearchStateForTesting(
            tracks: [track],
            selectedTrackIDs: [track.id],
            readyTrackIDs: [],
            validationStatus: .validated(Date())
        )

        viewModel.toggleLibraryPreview()
        #expect(await waitUntil { viewModel.libraryPreviewState.isPlaying })

        viewModel.stopLibraryPreview()
        #expect(previewPlayer.stopCount == 1)
        #expect(viewModel.libraryPreviewState.currentTimeSec == 0)
        #expect(viewModel.libraryPreviewState.progress == 0)
        #expect(!viewModel.libraryPreviewState.isPlaying)

        viewModel.seekLibraryPreview(to: 96, autoplay: true)
        #expect(await waitUntil { previewPlayer.lastObservedSeekRequest?.time == 96 })
        #expect(previewPlayer.lastObservedSeekRequest?.time == 96)
        #expect(viewModel.libraryPreviewState.currentTimeSec == 96)
        #expect(viewModel.libraryPreviewState.isPlaying)
    }

    private func makeTrack(
        id: UUID = UUID(),
        title: String,
        duration: TimeInterval
    ) -> Track {
        Track(
            id: id,
            filePath: "/tmp/\(id.uuidString).wav",
            fileName: "\(id.uuidString).wav",
            title: title,
            artist: "Fixture Artist",
            album: "Fixture Album",
            genre: "House",
            duration: duration,
            sampleRate: 44_100,
            bpm: 124,
            musicalKey: "8A",
            modifiedTime: Date(timeIntervalSince1970: 1_700_000_000),
            contentHash: id.uuidString,
            analyzedAt: nil,
            embeddingProfileID: nil,
            embeddingUpdatedAt: nil,
            hasSeratoMetadata: false,
            hasRekordboxMetadata: false,
            bpmSource: nil,
            keySource: nil
        )
    }

    private func makeTempAudioFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-preview-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data("RIFFTEST".utf8).write(to: url)
        return url
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        step: TimeInterval = 0.01,
        condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
        }
        return condition()
    }
}

@MainActor
private final class PreviewPlayerStub: LibraryPreviewControlling {
    var onPlaybackStateChange: ((LibraryPreviewPlaybackState) -> Void)?
    var availabilityMessageResult: String?
    var prepareRequests: [URL] = []
    var playRequests: [(url: URL, fromTime: TimeInterval)] = []
    var seekRequests: [(time: TimeInterval, autoplay: Bool, kind: LibraryPreviewSeekKind)] = []
    var directPlayRequests: [(url: URL, fromTime: TimeInterval)] = []
    var directSeekRequests: [(url: URL, time: TimeInterval, autoplay: Bool, kind: LibraryPreviewSeekKind)] = []
    var pauseCount = 0
    var stopCount = 0
    var discardCount = 0
    var preparedURL: URL?
    var preparedDurationSec: TimeInterval = 240
    var currentTimeSec: TimeInterval = 0
    var isWarm = false
    var prepareDelayNanoseconds: UInt64 = 0

    var totalPlayInvocationCount: Int {
        playRequests.count + directPlayRequests.count
    }

    var totalSeekInvocationCount: Int {
        seekRequests.count + directSeekRequests.count
    }

    var lastObservedPlayTime: TimeInterval? {
        if let last = directPlayRequests.last {
            return last.fromTime
        }
        return playRequests.last?.fromTime
    }

    var lastObservedSeekRequest: (time: TimeInterval, autoplay: Bool, kind: LibraryPreviewSeekKind)? {
        if let last = directSeekRequests.last {
            return (last.time, last.autoplay, last.kind)
        }
        return seekRequests.last
    }

    func availabilityMessage(for url: URL?) -> String? {
        availabilityMessageResult
    }

    func prepare(url: URL) async throws {
        if prepareDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: prepareDelayNanoseconds)
        }
        let standardizedURL = url.standardizedFileURL
        guard preparedURL != standardizedURL || !isWarm else {
            onPlaybackStateChange?(
                LibraryPreviewPlaybackState(
                    url: standardizedURL,
                    isPlaying: false,
                    currentTimeSec: currentTimeSec,
                    totalDurationSec: preparedDurationSec,
                    isPrepared: true,
                    isWarm: true
                )
            )
            return
        }
        preparedURL = standardizedURL
        prepareRequests.append(standardizedURL)
        isWarm = true
        onPlaybackStateChange?(
            LibraryPreviewPlaybackState(
                url: standardizedURL,
                isPlaying: false,
                currentTimeSec: currentTimeSec,
                totalDurationSec: preparedDurationSec,
                isPrepared: true,
                isWarm: true
            )
        )
    }

    func play(url: URL, fromTime: TimeInterval) async throws {
        try await prepare(url: url)
        let standardizedURL = url.standardizedFileURL
        currentTimeSec = fromTime
        playRequests.append((standardizedURL, fromTime))
        onPlaybackStateChange?(
            LibraryPreviewPlaybackState(
                url: standardizedURL,
                isPlaying: true,
                currentTimeSec: fromTime,
                totalDurationSec: preparedDurationSec,
                isPrepared: true,
                isWarm: true
            )
        )
    }

    func seek(to time: TimeInterval, autoplay: Bool, kind: LibraryPreviewSeekKind) async throws {
        seekRequests.append((time, autoplay, kind))
        currentTimeSec = time
        guard let preparedURL else { return }
        onPlaybackStateChange?(
            LibraryPreviewPlaybackState(
                url: preparedURL,
                isPlaying: autoplay,
                currentTimeSec: time,
                totalDurationSec: preparedDurationSec,
                isPrepared: true,
                isWarm: true
            )
        )
    }

    func playPrepared(url: URL, fromTime: TimeInterval) throws -> Bool {
        let standardizedURL = url.standardizedFileURL
        guard preparedURL == standardizedURL, isWarm else { return false }
        currentTimeSec = fromTime
        directPlayRequests.append((standardizedURL, fromTime))
        onPlaybackStateChange?(
            LibraryPreviewPlaybackState(
                url: standardizedURL,
                isPlaying: true,
                currentTimeSec: fromTime,
                totalDurationSec: preparedDurationSec,
                isPrepared: true,
                isWarm: true
            )
        )
        return true
    }

    func seekPrepared(url: URL, to time: TimeInterval, autoplay: Bool, kind: LibraryPreviewSeekKind) throws -> Bool {
        let standardizedURL = url.standardizedFileURL
        guard preparedURL == standardizedURL, isWarm else { return false }
        currentTimeSec = time
        directSeekRequests.append((standardizedURL, time, autoplay, kind))
        onPlaybackStateChange?(
            LibraryPreviewPlaybackState(
                url: standardizedURL,
                isPlaying: autoplay,
                currentTimeSec: time,
                totalDurationSec: preparedDurationSec,
                isPrepared: true,
                isWarm: true
            )
        )
        return true
    }

    func pause() {
        pauseCount += 1
        guard let preparedURL else { return }
        onPlaybackStateChange?(
            LibraryPreviewPlaybackState(
                url: preparedURL,
                isPlaying: false,
                currentTimeSec: currentTimeSec,
                totalDurationSec: preparedDurationSec,
                isPrepared: true,
                isWarm: true
            )
        )
    }

    func stop() {
        stopCount += 1
        guard let preparedURL = self.preparedURL else { return }
        currentTimeSec = 0
        isWarm = true
        onPlaybackStateChange?(
            LibraryPreviewPlaybackState(
                url: preparedURL,
                isPlaying: false,
                currentTimeSec: 0,
                totalDurationSec: preparedDurationSec,
                isPrepared: true,
                isWarm: true
            )
        )
    }

    func discardPreparedItem(for url: URL?) {
        guard let preparedURL = self.preparedURL else { return }
        if let url, preparedURL != url.standardizedFileURL {
            return
        }
        discardCount += 1
        currentTimeSec = 0
        isWarm = false
        onPlaybackStateChange?(
            LibraryPreviewPlaybackState(
                url: preparedURL,
                isPlaying: false,
                currentTimeSec: 0,
                totalDurationSec: 0,
                isPrepared: false,
                isWarm: false
            )
        )
        self.preparedURL = nil
    }
}

@MainActor
private final class PreviewBackendStub: LibraryPreviewPlayerBackend {
    var onDurationUpdate: ((TimeInterval) -> Void)?
    var onTimeUpdate: ((TimeInterval) -> Void)?
    var onPlaybackEnded: (() -> Void)?
    var loadedURLs: [URL] = []
    var playTimes: [TimeInterval] = []
    var seekRequests: [(time: TimeInterval, autoplay: Bool, kind: LibraryPreviewSeekKind)] = []
    var pauseCount = 0
    var stopCount = 0
    var discardCount = 0

    private let durationSec: TimeInterval

    init(durationSec: TimeInterval) {
        self.durationSec = durationSec
    }

    func load(url: URL) async throws -> TimeInterval {
        loadedURLs.append(url.standardizedFileURL)
        return durationSec
    }

    func play(from time: TimeInterval) async throws {
        playTimes.append(time)
    }

    func seek(to time: TimeInterval, autoplay: Bool, kind: LibraryPreviewSeekKind) async throws {
        seekRequests.append((time, autoplay, kind))
    }

    func pause() {
        pauseCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func discardPreparedItem() {
        discardCount += 1
    }

    func emitDuration(_ durationSec: TimeInterval) {
        onDurationUpdate?(durationSec)
    }

    func emitTime(_ time: TimeInterval) {
        onTimeUpdate?(time)
    }

    func emitEnded() {
        onPlaybackEnded?()
    }
}

@MainActor
private final class ThrowingPreviewBackendStub: LibraryPreviewPlayerBackend {
    var onDurationUpdate: ((TimeInterval) -> Void)?
    var onTimeUpdate: ((TimeInterval) -> Void)?
    var onPlaybackEnded: (() -> Void)?
    var loadAttempts: [URL] = []

    func load(url: URL) async throws -> TimeInterval {
        loadAttempts.append(url.standardizedFileURL)
        throw LibraryPreviewPlayerError.playbackFailed("boom")
    }

    func play(from time: TimeInterval) async throws {
        Issue.record("Unexpected play call: \(time)")
    }

    func seek(to time: TimeInterval, autoplay: Bool, kind: LibraryPreviewSeekKind) async throws {
        Issue.record("Unexpected seek call: \(time), autoplay=\(autoplay), kind=\(kind)")
    }

    func pause() {}
    func stop() {}
    func discardPreparedItem() {}
}
