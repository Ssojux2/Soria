import AVFoundation
import Foundation

enum LibraryPreviewSeekKind: Equatable {
    case playbackResume
    case waveformTap
    case waveformScrub
    case cuePoint
    case reset
}

struct LibraryPreviewPlaybackState: Equatable {
    let url: URL
    let isPlaying: Bool
    let currentTimeSec: TimeInterval
    let totalDurationSec: TimeInterval
    let isPrepared: Bool
    let isWarm: Bool
}

enum LibraryPreviewPlayerError: LocalizedError, Equatable {
    case unavailable(String)
    case invalidSeek
    case playbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        case .invalidSeek:
            return "Preview unavailable. This track is not ready for waveform seeking yet."
        case .playbackFailed(let message):
            return message
        }
    }
}

@MainActor
protocol LibraryPreviewControlling: AnyObject {
    var onPlaybackStateChange: ((LibraryPreviewPlaybackState) -> Void)? { get set }

    func availabilityMessage(for url: URL?) -> String?
    func prepare(url: URL) async throws
    func play(url: URL, fromTime: TimeInterval) async throws
    func seek(to time: TimeInterval, autoplay: Bool, kind: LibraryPreviewSeekKind) async throws
    func playPrepared(url: URL, fromTime: TimeInterval) throws -> Bool
    func seekPrepared(url: URL, to time: TimeInterval, autoplay: Bool, kind: LibraryPreviewSeekKind) throws -> Bool
    func pause()
    func stop()
    func discardPreparedItem(for url: URL?)
}

@MainActor
protocol LibraryPreviewPlayerBackend: AnyObject {
    var onDurationUpdate: ((TimeInterval) -> Void)? { get set }
    var onTimeUpdate: ((TimeInterval) -> Void)? { get set }
    var onPlaybackEnded: (() -> Void)? { get set }

    func load(url: URL) async throws -> TimeInterval
    func play(from time: TimeInterval) async throws
    func seek(to time: TimeInterval, autoplay: Bool, kind: LibraryPreviewSeekKind) async throws
    func playDirect(from time: TimeInterval) throws -> Bool
    func seekDirect(to time: TimeInterval, autoplay: Bool, kind: LibraryPreviewSeekKind) throws -> Bool
    func pause()
    func stop()
    func discardPreparedItem()
}

extension LibraryPreviewPlayerBackend {
    func playDirect(from time: TimeInterval) throws -> Bool {
        let _ = time
        return false
    }

    func seekDirect(to time: TimeInterval, autoplay: Bool, kind: LibraryPreviewSeekKind) throws -> Bool {
        let _ = time
        let _ = autoplay
        let _ = kind
        return false
    }
}

@MainActor
final class LibraryPreviewPlayer: LibraryPreviewControlling {
    var onPlaybackStateChange: ((LibraryPreviewPlaybackState) -> Void)?

    private let backend: LibraryPreviewPlayerBackend
    private var currentURL: URL?
    private var totalDurationSec: TimeInterval = 0
    private var currentTimeSec: TimeInterval = 0
    private var isPlaying = false
    private var isPrepared = false
    private var isWarm = false
    private var playbackOperationGeneration: UInt64 = 0

    convenience init() {
        self.init(backend: AdaptiveLibraryPreviewBackend())
    }

    init(backend: LibraryPreviewPlayerBackend) {
        self.backend = backend
        backend.onDurationUpdate = { [weak self] duration in
            self?.handleDurationUpdate(duration)
        }
        backend.onTimeUpdate = { [weak self] absoluteTime in
            self?.handleTimeUpdate(absoluteTime)
        }
        backend.onPlaybackEnded = { [weak self] in
            self?.handlePlaybackEnded()
        }
    }

    func availabilityMessage(for url: URL?) -> String? {
        guard let url else {
            return "Preview unavailable. Select a local audio file."
        }

        let standardizedURL = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardizedURL.path) else {
            return "Preview unavailable. The audio file could not be found."
        }
        guard FileManager.default.isReadableFile(atPath: standardizedURL.path) else {
            return "Preview unavailable. The audio file is not readable."
        }
        return nil
    }

    func prepare(url: URL) async throws {
        let standardizedURL = url.standardizedFileURL
        if let message = availabilityMessage(for: standardizedURL) {
            throw LibraryPreviewPlayerError.unavailable(message)
        }

        if currentURL != standardizedURL || !isWarm {
            let duration = try await backend.load(url: standardizedURL)
            currentURL = standardizedURL
            totalDurationSec = duration.isFinite ? max(duration, 0) : 0
            currentTimeSec = 0
            isPrepared = true
            isPlaying = false
            isWarm = true
        } else {
            isPrepared = true
            isWarm = true
        }

        emitStateIfPossible()
    }

    func play(url: URL, fromTime: TimeInterval) async throws {
        let generation = beginPlaybackOperation()
        try await prepare(url: url)
        guard isCurrentPlaybackOperation(generation) else { return }
        let targetTime = clampedTime(for: fromTime)

        do {
            try await backend.play(from: targetTime)
        } catch let error as LibraryPreviewPlayerError {
            throw error
        } catch {
            throw LibraryPreviewPlayerError.playbackFailed(
                "Preview unavailable. \(error.localizedDescription)"
            )
        }
        guard isCurrentPlaybackOperation(generation) else { return }

        currentTimeSec = targetTime
        isPlaying = true
        isPrepared = true
        isWarm = true
        emitStateIfPossible()
    }

    func seek(to time: TimeInterval, autoplay: Bool, kind: LibraryPreviewSeekKind) async throws {
        let generation = beginPlaybackOperation()
        guard isWarm, currentURL != nil else {
            throw LibraryPreviewPlayerError.invalidSeek
        }

        let targetTime = clampedTime(for: time)
        do {
            try await backend.seek(to: targetTime, autoplay: autoplay, kind: kind)
        } catch let error as LibraryPreviewPlayerError {
            throw error
        } catch {
            throw LibraryPreviewPlayerError.playbackFailed(
                "Preview unavailable. \(error.localizedDescription)"
            )
        }
        guard isCurrentPlaybackOperation(generation) else { return }

        currentTimeSec = targetTime
        isPlaying = autoplay
        isPrepared = true
        isWarm = true
        emitStateIfPossible()
    }

    func playPrepared(url: URL, fromTime: TimeInterval) throws -> Bool {
        _ = beginPlaybackOperation()
        let standardizedURL = url.standardizedFileURL
        guard currentURL == standardizedURL, isWarm else { return false }

        let targetTime = clampedTime(for: fromTime)
        do {
            guard try backend.playDirect(from: targetTime) else { return false }
        } catch let error as LibraryPreviewPlayerError {
            throw error
        } catch {
            throw LibraryPreviewPlayerError.playbackFailed(
                "Preview unavailable. \(error.localizedDescription)"
            )
        }

        currentTimeSec = targetTime
        isPlaying = true
        isPrepared = true
        isWarm = true
        debugLog("direct play | time=\(String(format: "%.3f", targetTime))")
        emitStateIfPossible()
        return true
    }

    func seekPrepared(url: URL, to time: TimeInterval, autoplay: Bool, kind: LibraryPreviewSeekKind) throws -> Bool {
        _ = beginPlaybackOperation()
        let standardizedURL = url.standardizedFileURL
        guard currentURL == standardizedURL, isWarm else { return false }

        let targetTime = clampedTime(for: time)
        do {
            guard try backend.seekDirect(to: targetTime, autoplay: autoplay, kind: kind) else { return false }
        } catch let error as LibraryPreviewPlayerError {
            throw error
        } catch {
            throw LibraryPreviewPlayerError.playbackFailed(
                "Preview unavailable. \(error.localizedDescription)"
            )
        }

        currentTimeSec = targetTime
        isPlaying = autoplay
        isPrepared = true
        isWarm = true
        debugLog(
            "direct seek | time=\(String(format: "%.3f", targetTime)) | autoplay=\(autoplay) | kind=\(kind.debugName)"
        )
        emitStateIfPossible()
        return true
    }

    func pause() {
        invalidatePlaybackOperations()
        isPlaying = false
        guard isWarm else { return }
        backend.pause()
        emitStateIfPossible()
    }

    func stop() {
        invalidatePlaybackOperations()
        guard currentURL != nil || isWarm || isPrepared else {
            isPlaying = false
            currentTimeSec = 0
            totalDurationSec = 0
            isPrepared = false
            isWarm = false
            return
        }
        isPlaying = false
        backend.stop()
        currentTimeSec = 0
        isPrepared = currentURL != nil
        isWarm = currentURL != nil
        emitStateIfPossible()
    }

    func discardPreparedItem(for url: URL?) {
        guard let currentURL else { return }
        if let url, currentURL != url.standardizedFileURL {
            return
        }

        let previousURL = currentURL
        invalidatePlaybackOperations()
        isPlaying = false
        backend.discardPreparedItem()
        currentTimeSec = 0
        totalDurationSec = 0
        isPrepared = false
        isWarm = false
        self.currentURL = nil

        onPlaybackStateChange?(
            LibraryPreviewPlaybackState(
                url: previousURL,
                isPlaying: false,
                currentTimeSec: 0,
                totalDurationSec: 0,
                isPrepared: false,
                isWarm: false
            )
        )
    }

    private func handleTimeUpdate(_ absoluteTime: TimeInterval) {
        guard isWarm else { return }
        currentTimeSec = clampedTime(for: absoluteTime)
        emitStateIfPossible()
    }

    private func handleDurationUpdate(_ duration: TimeInterval) {
        guard currentURL != nil else { return }
        let resolvedDuration = duration.isFinite ? max(duration, 0) : 0
        guard resolvedDuration > 0 else { return }
        totalDurationSec = resolvedDuration
        currentTimeSec = clampedTime(for: currentTimeSec)
        emitStateIfPossible()
    }

    private func handlePlaybackEnded() {
        guard isWarm else { return }
        isPlaying = false
        currentTimeSec = totalDurationSec
        emitStateIfPossible()
    }

    private func clampedTime(for time: TimeInterval) -> TimeInterval {
        let sanitized = max(0, time.isFinite ? time : 0)
        guard totalDurationSec.isFinite, totalDurationSec > 0 else { return sanitized }
        return min(sanitized, totalDurationSec)
    }

    private func emitStateIfPossible() {
        guard let currentURL else { return }
        onPlaybackStateChange?(
            LibraryPreviewPlaybackState(
                url: currentURL,
                isPlaying: isPlaying,
                currentTimeSec: currentTimeSec,
                totalDurationSec: totalDurationSec,
                isPrepared: isPrepared,
                isWarm: isWarm
            )
        )
    }

    private func debugLog(_ message: String) {
#if DEBUG
        AppLogger.shared.info("Library preview player | \(message)")
#endif
    }

    private func beginPlaybackOperation() -> UInt64 {
        playbackOperationGeneration &+= 1
        return playbackOperationGeneration
    }

    private func invalidatePlaybackOperations() {
        playbackOperationGeneration &+= 1
    }

    private func isCurrentPlaybackOperation(_ generation: UInt64) -> Bool {
        generation == playbackOperationGeneration
    }
}

@MainActor
final class UITestLibraryPreviewPlayer: LibraryPreviewControlling {
    var onPlaybackStateChange: ((LibraryPreviewPlaybackState) -> Void)?

    private var currentURL: URL?
    private var isPlaying = false
    private var isPrepared = false
    private var isWarm = false
    private var currentTimeSec: TimeInterval = 0
    private var totalDurationSec: TimeInterval = 0

    func availabilityMessage(for url: URL?) -> String? {
        guard url != nil else {
            return "Preview unavailable. Select a local audio file."
        }
        return nil
    }

    func prepare(url: URL) async throws {
        currentURL = url.standardizedFileURL
        isPrepared = true
        isWarm = true
        isPlaying = false
        currentTimeSec = 0
        emitState()
    }

    func play(url: URL, fromTime: TimeInterval) async throws {
        try await prepare(url: url)
        currentTimeSec = max(fromTime, 0)
        isPlaying = true
        isPrepared = true
        isWarm = true
        emitState()
    }

    func seek(to time: TimeInterval, autoplay: Bool, kind _: LibraryPreviewSeekKind) async throws {
        guard isWarm else {
            throw LibraryPreviewPlayerError.invalidSeek
        }
        currentTimeSec = max(time, 0)
        isPlaying = autoplay
        isPrepared = true
        emitState()
    }

    func playPrepared(url: URL, fromTime: TimeInterval) throws -> Bool {
        let standardizedURL = url.standardizedFileURL
        guard currentURL == standardizedURL, isWarm else { return false }
        currentTimeSec = max(fromTime, 0)
        isPlaying = true
        emitState()
        return true
    }

    func seekPrepared(url: URL, to time: TimeInterval, autoplay: Bool, kind _: LibraryPreviewSeekKind) throws -> Bool {
        let standardizedURL = url.standardizedFileURL
        guard currentURL == standardizedURL, isWarm else { return false }
        currentTimeSec = max(time, 0)
        isPlaying = autoplay
        emitState()
        return true
    }

    func pause() {
        isPlaying = false
        emitState()
    }

    func stop() {
        isPlaying = false
        currentTimeSec = 0
        isPrepared = currentURL != nil
        isWarm = currentURL != nil
        emitState()
    }

    func discardPreparedItem(for url: URL?) {
        guard let currentURL else { return }
        if let url, currentURL != url.standardizedFileURL {
            return
        }
        isPlaying = false
        isPrepared = false
        isWarm = false
        currentTimeSec = 0
        totalDurationSec = 0
        emitState()
        self.currentURL = nil
    }

    private func emitState() {
        guard let currentURL else { return }
        onPlaybackStateChange?(
            LibraryPreviewPlaybackState(
                url: currentURL,
                isPlaying: isPlaying,
                currentTimeSec: currentTimeSec,
                totalDurationSec: totalDurationSec,
                isPrepared: isPrepared,
                isWarm: isWarm
            )
        )
    }
}

enum LibraryPreviewBackendKind: String, Equatable {
    case audioEngine = "audio_engine"
    case avPlayer = "avplayer"
}

@MainActor
final class AdaptiveLibraryPreviewBackend: LibraryPreviewPlayerBackend {
    var onDurationUpdate: ((TimeInterval) -> Void)?
    var onTimeUpdate: ((TimeInterval) -> Void)?
    var onPlaybackEnded: (() -> Void)?

    private let audioEngineBackend: LibraryPreviewPlayerBackend
    private let avPlayerBackend: LibraryPreviewPlayerBackend
    private let backendOverride: BackendOverride
    private var activeBackendKind: LibraryPreviewBackendKind?
    private var activeURL: URL?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        audioEngineBackend: LibraryPreviewPlayerBackend? = nil,
        avPlayerBackend: LibraryPreviewPlayerBackend? = nil
    ) {
        self.audioEngineBackend = audioEngineBackend ?? AudioEngineLibraryPreviewBackend()
        self.avPlayerBackend = avPlayerBackend ?? AVFoundationLibraryPreviewBackend()
        backendOverride = BackendOverride(environmentValue: environment["SORIA_LIBRARY_PREVIEW_BACKEND"])
        bindCallbacks(for: self.audioEngineBackend, kind: .audioEngine)
        bindCallbacks(for: self.avPlayerBackend, kind: .avPlayer)
    }

    func load(url: URL) async throws -> TimeInterval {
        let standardizedURL = url.standardizedFileURL
        if activeURL != standardizedURL {
            discardPreparedItem()
        }

        if let activeBackend = activeBackend {
            activeURL = standardizedURL
            return try await activeBackend.load(url: standardizedURL)
        }

        switch backendOverride {
        case .audioEngine:
            let duration = try await audioEngineBackend.load(url: standardizedURL)
            activeBackendKind = .audioEngine
            activeURL = standardizedURL
            return duration
        case .avPlayer:
            let duration = try await avPlayerBackend.load(url: standardizedURL)
            activeBackendKind = .avPlayer
            activeURL = standardizedURL
            return duration
        case .auto:
            do {
                let duration = try await audioEngineBackend.load(url: standardizedURL)
                activeBackendKind = .audioEngine
                activeURL = standardizedURL
                debugLog("selected backend=audio_engine | url=\(standardizedURL.lastPathComponent)")
                return duration
            } catch {
                audioEngineBackend.discardPreparedItem()
                debugLog(
                    "audio_engine fallback | url=\(standardizedURL.lastPathComponent) | reason=\(error.localizedDescription)"
                )
                let duration = try await avPlayerBackend.load(url: standardizedURL)
                activeBackendKind = .avPlayer
                activeURL = standardizedURL
                return duration
            }
        }
    }

    func play(from time: TimeInterval) async throws {
        guard let activeBackend else {
            throw LibraryPreviewPlayerError.invalidSeek
        }
        try await activeBackend.play(from: time)
    }

    func seek(to time: TimeInterval, autoplay: Bool, kind: LibraryPreviewSeekKind) async throws {
        guard let activeBackend else {
            throw LibraryPreviewPlayerError.invalidSeek
        }
        try await activeBackend.seek(to: time, autoplay: autoplay, kind: kind)
    }

    func playDirect(from time: TimeInterval) throws -> Bool {
        guard let activeBackend else { return false }
        return try activeBackend.playDirect(from: time)
    }

    func seekDirect(to time: TimeInterval, autoplay: Bool, kind: LibraryPreviewSeekKind) throws -> Bool {
        guard let activeBackend else { return false }
        return try activeBackend.seekDirect(to: time, autoplay: autoplay, kind: kind)
    }

    func pause() {
        activeBackend?.pause()
    }

    func stop() {
        activeBackend?.stop()
    }

    func discardPreparedItem() {
        audioEngineBackend.discardPreparedItem()
        avPlayerBackend.discardPreparedItem()
        activeBackendKind = nil
        activeURL = nil
    }

    private var activeBackend: LibraryPreviewPlayerBackend? {
        switch activeBackendKind {
        case .audioEngine:
            return audioEngineBackend
        case .avPlayer:
            return avPlayerBackend
        case .none:
            return nil
        }
    }

    private func bindCallbacks(for backend: LibraryPreviewPlayerBackend, kind: LibraryPreviewBackendKind) {
        backend.onDurationUpdate = { [weak self] duration in
            guard self?.activeBackendKind == kind else { return }
            self?.onDurationUpdate?(duration)
        }
        backend.onTimeUpdate = { [weak self] time in
            guard self?.activeBackendKind == kind else { return }
            self?.onTimeUpdate?(time)
        }
        backend.onPlaybackEnded = { [weak self] in
            guard self?.activeBackendKind == kind else { return }
            self?.onPlaybackEnded?()
        }
    }

    private func debugLog(_ message: String) {
#if DEBUG
        AppLogger.shared.info("Library preview backend | \(message)")
#endif
    }

    private enum BackendOverride {
        case auto
        case audioEngine
        case avPlayer

        init(environmentValue: String?) {
            switch environmentValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case LibraryPreviewBackendKind.audioEngine.rawValue:
                self = .audioEngine
            case LibraryPreviewBackendKind.avPlayer.rawValue:
                self = .avPlayer
            default:
                self = .auto
            }
        }
    }
}

private struct OpenedAudioFile: @unchecked Sendable {
    let audioFile: AVAudioFile
    let durationSec: TimeInterval
    let totalFrames: AVAudioFramePosition
    let sampleRate: Double
    let format: AVAudioFormat
}

private struct AudioEngineFormatDescriptor: Equatable {
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
    let commonFormatRawValue: UInt
    let isInterleaved: Bool

    init(format: AVAudioFormat) {
        sampleRate = format.sampleRate
        channelCount = format.channelCount
        commonFormatRawValue = format.commonFormat.rawValue
        isInterleaved = format.isInterleaved
    }
}

private struct AudioEnginePreviewState {
    var fileURL: URL
    var audioFile: AVAudioFile
    var sampleRate: Double
    var totalFrames: AVAudioFramePosition
    var durationSec: TimeInterval
    var scheduledStartFrame: AVAudioFramePosition
    var pausedAbsoluteFrame: AVAudioFramePosition
    var isPrepared: Bool
    var isPlaying: Bool
    var isPrimed: Bool
}

@MainActor
final class AudioEngineLibraryPreviewBackend: LibraryPreviewPlayerBackend {
    var onDurationUpdate: ((TimeInterval) -> Void)?
    var onTimeUpdate: ((TimeInterval) -> Void)?
    var onPlaybackEnded: (() -> Void)?

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var state: AudioEnginePreviewState?
    private var connectedFormatDescriptor: AudioEngineFormatDescriptor?
    private var timeUpdateTimer: Timer?
    private var pendingPrimeTask: Task<Void, Never>?
    private var playbackGeneration: UInt64 = 0

    private let timeUpdateIntervalSec: TimeInterval = 1.0 / 30.0
    private let primeWindowSec: TimeInterval = 0.25
    private let resumeFrameTolerance: AVAudioFramePosition = 8

    init() {
        engine.attach(playerNode)
    }

    deinit {
        timeUpdateTimer?.invalidate()
        pendingPrimeTask?.cancel()
    }

    func load(url: URL) async throws -> TimeInterval {
        let standardizedURL = url.standardizedFileURL
        if let state, state.fileURL == standardizedURL {
            onDurationUpdate?(state.durationSec)
            return state.durationSec
        }

        cancelPendingPrime()
        stopTimeUpdates()
        playerNode.stop()

        let openedAudioFile = try await Self.openAudioFile(at: standardizedURL)
        try configureEngineIfNeeded(for: openedAudioFile.format)
        try startEngineIfNeeded()

        state = AudioEnginePreviewState(
            fileURL: standardizedURL,
            audioFile: openedAudioFile.audioFile,
            sampleRate: openedAudioFile.sampleRate,
            totalFrames: openedAudioFile.totalFrames,
            durationSec: openedAudioFile.durationSec,
            scheduledStartFrame: 0,
            pausedAbsoluteFrame: 0,
            isPrepared: false,
            isPlaying: false,
            isPrimed: false
        )

        onDurationUpdate?(openedAudioFile.durationSec)
        try scheduleSegment(startingAt: 0, autoplay: false, reason: "load")
        return openedAudioFile.durationSec
    }

    func play(from time: TimeInterval) async throws {
        try playDirectImpl(from: time, reason: "play")
    }

    func seek(to time: TimeInterval, autoplay: Bool, kind: LibraryPreviewSeekKind) async throws {
        guard let state else {
            throw LibraryPreviewPlayerError.invalidSeek
        }

        let targetFrame = frame(for: time, sampleRate: state.sampleRate, totalFrames: state.totalFrames)
        try scheduleSegment(
            startingAt: targetFrame,
            autoplay: autoplay,
            reason: "seek:\(kind.debugName)"
        )
    }

    func playDirect(from time: TimeInterval) throws -> Bool {
        guard state != nil else { return false }
        try playDirectImpl(from: time, reason: "play_direct")
        return true
    }

    func seekDirect(to time: TimeInterval, autoplay: Bool, kind: LibraryPreviewSeekKind) throws -> Bool {
        guard let state else { return false }
        let targetFrame = frame(for: time, sampleRate: state.sampleRate, totalFrames: state.totalFrames)
        try scheduleSegment(
            startingAt: targetFrame,
            autoplay: autoplay,
            reason: "seek_direct:\(kind.debugName)"
        )
        return true
    }

    func pause() {
        cancelPendingPrime()
        guard var state else { return }

        let absoluteFrame = currentAbsoluteFrame(fallback: state.pausedAbsoluteFrame)
        if playerNode.isPlaying {
            playerNode.pause()
        }
        stopTimeUpdates()

        state.pausedAbsoluteFrame = absoluteFrame
        state.isPlaying = false
        self.state = state
        onTimeUpdate?(time(for: absoluteFrame, sampleRate: state.sampleRate))
        debugLog(
            "pause applied | frame=\(absoluteFrame) | latency=\(formattedLatency())"
        )
    }

    func stop() {
        cancelPendingPrime()
        guard var state else { return }

        playerNode.stop()
        stopTimeUpdates()
        state.pausedAbsoluteFrame = 0
        state.scheduledStartFrame = 0
        state.isPlaying = false
        state.isPrepared = true
        state.isPrimed = false
        self.state = state
        onTimeUpdate?(0)
        debugLog("stop applied | latency=\(formattedLatency())")

        pendingPrimeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try self.scheduleSegment(startingAt: 0, autoplay: false, reason: "stop_reprime")
            } catch {
                self.debugLog("stop reprime failed | \(error.localizedDescription)")
            }
        }
    }

    func discardPreparedItem() {
        cancelPendingPrime()
        stopTimeUpdates()
        playerNode.stop()
        engine.pause()
        state = nil
    }

    private func scheduleSegment(
        startingAt startFrame: AVAudioFramePosition,
        autoplay: Bool,
        reason: String
    ) throws {
        guard var state else {
            throw LibraryPreviewPlayerError.invalidSeek
        }

        cancelPendingPrime()
        try startEngineIfNeeded()

        let clampedStartFrame = min(max(startFrame, 0), state.totalFrames)
        let remainingFrames = max(state.totalFrames - clampedStartFrame, 0)

        playerNode.stop()

        guard remainingFrames > 0 else {
            stopTimeUpdates()
            state.scheduledStartFrame = state.totalFrames
            state.pausedAbsoluteFrame = state.totalFrames
            state.isPrepared = true
            state.isPlaying = false
            state.isPrimed = false
            self.state = state
            onTimeUpdate?(state.durationSec)
            if autoplay {
                onPlaybackEnded?()
            }
            return
        }

        playbackGeneration &+= 1
        let generation = playbackGeneration
        let frameCount = scheduledFrameCount(for: remainingFrames)

        playerNode.scheduleSegment(
            state.audioFile,
            startingFrame: clampedStartFrame,
            frameCount: frameCount,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePlaybackCompletion(
                    generation: generation,
                    endingFrame: state.totalFrames
                )
            }
        }

        let primeFrameCount = primingFrameCount(
            sampleRate: state.sampleRate,
            remainingFrames: remainingFrames
        )
        if primeFrameCount > 0 {
            playerNode.prepare(withFrameCount: primeFrameCount)
        }

        state.scheduledStartFrame = clampedStartFrame
        state.pausedAbsoluteFrame = clampedStartFrame
        state.isPrepared = true
        state.isPlaying = autoplay
        state.isPrimed = true
        self.state = state

        onTimeUpdate?(time(for: clampedStartFrame, sampleRate: state.sampleRate))
        if autoplay {
            playerNode.play()
            startTimeUpdates()
        } else {
            stopTimeUpdates()
        }

        debugLog(
            "command applied | reason=\(reason) | frame=\(clampedStartFrame) | latency=\(formattedLatency())"
        )
    }

    private func playDirectImpl(from time: TimeInterval, reason: String) throws {
        guard var state else {
            throw LibraryPreviewPlayerError.invalidSeek
        }

        let targetFrame = frame(for: time, sampleRate: state.sampleRate, totalFrames: state.totalFrames)
        try startEngineIfNeeded()

        if state.isPrepared,
           state.isPrimed,
           !state.isPlaying,
           abs(targetFrame - state.pausedAbsoluteFrame) <= resumeFrameTolerance {
            playerNode.play()
            state.isPlaying = true
            self.state = state
            startTimeUpdates()
            debugLog(
                "\(reason) resume | frame=\(targetFrame) | latency=\(formattedLatency())"
            )
            return
        }

        try scheduleSegment(startingAt: targetFrame, autoplay: true, reason: reason)
    }

    private func handlePlaybackCompletion(generation: UInt64, endingFrame: AVAudioFramePosition) {
        guard generation == playbackGeneration, var state else { return }
        stopTimeUpdates()
        state.pausedAbsoluteFrame = endingFrame
        state.scheduledStartFrame = endingFrame
        state.isPlaying = false
        state.isPrimed = false
        self.state = state
        onTimeUpdate?(state.durationSec)
        onPlaybackEnded?()
        debugLog("playback ended | frame=\(endingFrame)")
    }

    private func emitCurrentTimeUpdate() {
        guard let state else { return }
        let absoluteFrame = currentAbsoluteFrame(fallback: state.pausedAbsoluteFrame)
        onTimeUpdate?(time(for: absoluteFrame, sampleRate: state.sampleRate))
    }

    private func startTimeUpdates() {
        stopTimeUpdates()
        let timer = Timer(
            timeInterval: timeUpdateIntervalSec,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.emitCurrentTimeUpdate()
            }
        }
        timeUpdateTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTimeUpdates() {
        timeUpdateTimer?.invalidate()
        timeUpdateTimer = nil
    }

    private func cancelPendingPrime() {
        pendingPrimeTask?.cancel()
        pendingPrimeTask = nil
    }

    private func currentAbsoluteFrame(fallback: AVAudioFramePosition) -> AVAudioFramePosition {
        guard
            let state,
            let nodeTime = playerNode.lastRenderTime,
            let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else {
            return min(max(fallback, 0), state?.totalFrames ?? max(fallback, 0))
        }

        let offset = max(AVAudioFramePosition(playerTime.sampleTime), 0)
        return min(state.scheduledStartFrame + offset, state.totalFrames)
    }

    private func configureEngineIfNeeded(for format: AVAudioFormat) throws {
        let descriptor = AudioEngineFormatDescriptor(format: format)
        guard connectedFormatDescriptor != descriptor else { return }

        playerNode.stop()
        engine.pause()
        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        connectedFormatDescriptor = descriptor
    }

    private func startEngineIfNeeded() throws {
        engine.prepare()
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            throw LibraryPreviewPlayerError.playbackFailed(
                "Preview unavailable. \(error.localizedDescription)"
            )
        }
    }

    private func scheduledFrameCount(for remainingFrames: AVAudioFramePosition) -> AVAudioFrameCount {
        let clampedFrames = min(max(remainingFrames, 1), AVAudioFramePosition(UInt32.max))
        return AVAudioFrameCount(clampedFrames)
    }

    private func primingFrameCount(
        sampleRate: Double,
        remainingFrames: AVAudioFramePosition
    ) -> AVAudioFrameCount {
        let requestedFrames = AVAudioFramePosition(max(sampleRate * primeWindowSec, 1))
        let clampedFrames = min(max(remainingFrames, 1), max(requestedFrames, 1))
        return AVAudioFrameCount(min(clampedFrames, AVAudioFramePosition(UInt32.max)))
    }

    private func frame(
        for time: TimeInterval,
        sampleRate: Double,
        totalFrames: AVAudioFramePosition
    ) -> AVAudioFramePosition {
        let clampedTime = max(time, 0)
        let frame = AVAudioFramePosition((clampedTime * sampleRate).rounded(.towardZero))
        return min(max(frame, 0), totalFrames)
    }

    private func time(for frame: AVAudioFramePosition, sampleRate: Double) -> TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return min(max(TimeInterval(frame) / sampleRate, 0), state?.durationSec ?? .greatestFiniteMagnitude)
    }

    private func formattedLatency() -> String {
        String(format: "%.4f", engine.outputNode.outputPresentationLatency)
    }

    private func debugLog(_ message: String) {
#if DEBUG
        AppLogger.shared.info("Library preview audio_engine | \(message)")
#endif
    }

    private static func openAudioFile(at url: URL) async throws -> OpenedAudioFile {
        try await Task.detached(priority: .userInitiated) {
            let audioFile = try AVAudioFile(forReading: url)
            let sampleRate = audioFile.processingFormat.sampleRate
            let totalFrames = max(audioFile.length, 0)
            let durationSec: TimeInterval
            if sampleRate > 0 {
                durationSec = TimeInterval(totalFrames) / sampleRate
            } else {
                durationSec = 0
            }
            return OpenedAudioFile(
                audioFile: audioFile,
                durationSec: durationSec,
                totalFrames: totalFrames,
                sampleRate: sampleRate,
                format: audioFile.processingFormat
            )
        }.value
    }
}

@MainActor
final class AVFoundationLibraryPreviewBackend: LibraryPreviewPlayerBackend {
    var onDurationUpdate: ((TimeInterval) -> Void)?
    var onTimeUpdate: ((TimeInterval) -> Void)?
    var onPlaybackEnded: (() -> Void)?

    private let player = AVPlayer()
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlStatusObservation: NSKeyValueObservation?
    private var currentURL: URL?
    private var currentDurationSec: TimeInterval = 0
    private var isPrerollPrimed = false
    private var transportGeneration: UInt64 = 0
    private var pendingResetWorkItem: DispatchWorkItem?
    private var lastTransportRequestTimestamp: TimeInterval?

    private let playbackResumeSeekTolerance = CMTime(seconds: 0.04, preferredTimescale: 600)
    private let waveformTapSeekTolerance = CMTime(seconds: 0.08, preferredTimescale: 600)
    private let waveformScrubSeekTolerance = CMTime(seconds: 0.32, preferredTimescale: 600)
    private let cueSeekTolerance = CMTime(seconds: 0.01, preferredTimescale: 600)
    private let resetSeekTolerance = CMTime(seconds: 0.08, preferredTimescale: 600)
    private let immediatePlayThresholdSec: TimeInterval = 0.05
    private let deferredResetDelaySec: TimeInterval = 0.12

    init() {
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] currentTime in
            Task { @MainActor [weak self] in
                self?.onTimeUpdate?(currentTime.seconds)
            }
        }
        timeControlStatusObservation = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self] observedPlayer, _ in
            Task { @MainActor [weak self] in
                self?.handleTimeControlStatusChange(observedPlayer)
            }
        }
    }

    deinit {
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    func load(url: URL) async throws -> TimeInterval {
        let standardizedURL = url.standardizedFileURL
        if currentURL != standardizedURL {
            let asset = AVURLAsset(url: standardizedURL)
            let item = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: ["duration", "playable"])
            item.preferredForwardBufferDuration = 0
            currentDurationSec = 0
            cancelPendingReset()
            player.currentItem?.cancelPendingSeeks()
            player.cancelPendingPrerolls()
            player.replaceCurrentItem(with: item)
            currentURL = standardizedURL
            isPrerollPrimed = false
            observePlaybackEnd(for: item)
            observeItemStatus(for: item)
        } else {
            beginPrerollIfPossible(for: player.currentItem)
        }
        return currentDurationSec
    }

    func play(from time: TimeInterval) async throws {
        let generation = beginTransportRequest(
            kind: .playbackResume,
            targetTime: time,
            cancelsPendingSeeks: true,
            invalidatesPreroll: false
        )
        let currentAbsoluteTime = player.currentTime().seconds
        if currentAbsoluteTime.isFinite, abs(currentAbsoluteTime - time) <= immediatePlayThresholdSec {
            debugLog(
                "play immediate | generation=\(generation) | target=\(formattedTime(time))"
            )
            player.playImmediately(atRate: 1.0)
            return
        }

        try performSeek(
            to: time,
            autoplay: true,
            kind: .playbackResume,
            generation: generation
        )
    }

    func seek(to time: TimeInterval, autoplay: Bool, kind: LibraryPreviewSeekKind) async throws {
        let generation = beginTransportRequest(
            kind: kind,
            targetTime: time,
            cancelsPendingSeeks: true,
            invalidatesPreroll: false
        )
        try performSeek(
            to: time,
            autoplay: autoplay,
            kind: kind,
            generation: generation
        )
    }

    private func performSeek(
        to time: TimeInterval,
        autoplay: Bool,
        kind: LibraryPreviewSeekKind,
        generation: UInt64
    ) throws {
        let targetTime = CMTime(seconds: max(0, time), preferredTimescale: 600)
        let tolerance = seekTolerance(for: kind)
        isPrerollPrimed = false
        if autoplay && kind != .playbackResume {
            player.pause()
            debugLog(
                "seek pause applied | generation=\(generation) | kind=\(kind.debugName)"
            )
        }
        player.seek(
            to: targetTime,
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleSeekCompletion(
                    finished: finished,
                    autoplay: autoplay,
                    kind: kind,
                    generation: generation
                )
            }
        }
    }

    func pause() {
        cancelPendingReset()
        player.pause()
        debugLog("pause applied | current=\(formattedTime(player.currentTime().seconds))")
    }

    func stop() {
        let generation = beginTransportRequest(
            kind: .reset,
            targetTime: 0,
            cancelsPendingSeeks: true,
            invalidatesPreroll: false
        )
        player.pause()
        debugLog("stop requested | generation=\(generation) | pause applied")
        scheduleDeferredReset(for: generation)
    }

    func discardPreparedItem() {
        cancelPendingReset()
        player.currentItem?.cancelPendingSeeks()
        player.pause()
        player.cancelPendingPrerolls()
        player.replaceCurrentItem(with: nil)
        currentURL = nil
        currentDurationSec = 0
        isPrerollPrimed = false
        observePlaybackEnd(for: nil)
        itemStatusObservation = nil
    }

    private func observePlaybackEnd(for item: AVPlayerItem?) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }

        guard let item else { return }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onPlaybackEnded?()
            }
        }
    }

    private func observeItemStatus(for item: AVPlayerItem?) {
        itemStatusObservation = nil

        guard let item else { return }
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            Task { @MainActor [weak self] in
                self?.handleObservedItemStatusChange(observedItem)
            }
        }
    }

    private func handleObservedItemStatusChange(_ item: AVPlayerItem) {
        guard item == player.currentItem else { return }
        if item.status == .readyToPlay {
            let resolvedDurationSec = item.duration.seconds
            if resolvedDurationSec.isFinite, resolvedDurationSec > 0 {
                currentDurationSec = resolvedDurationSec
                onDurationUpdate?(resolvedDurationSec)
            }
        }
        beginPrerollIfPossible(for: item)
    }

    private func beginPrerollIfPossible(for item: AVPlayerItem?) {
        guard
            let item,
            item == player.currentItem,
            item.status == .readyToPlay,
            !isPrerollPrimed
        else {
            return
        }

        player.cancelPendingPrerolls()
        player.preroll(atRate: 1.0) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, finished, item == self.player.currentItem else { return }
                self.isPrerollPrimed = true
                self.debugLog(
                    "preroll primed | current=\(self.formattedTime(self.player.currentTime().seconds))"
                )
            }
        }
    }

    private func beginTransportRequest(
        kind: LibraryPreviewSeekKind,
        targetTime: TimeInterval,
        cancelsPendingSeeks: Bool = true,
        invalidatesPreroll: Bool
    ) -> UInt64 {
        transportGeneration &+= 1
        lastTransportRequestTimestamp = ProcessInfo.processInfo.systemUptime
        cancelPendingReset()
        if cancelsPendingSeeks {
            player.currentItem?.cancelPendingSeeks()
        }
        player.cancelPendingPrerolls()
        if invalidatesPreroll {
            isPrerollPrimed = false
        }
        debugLog(
            "transport issued | generation=\(transportGeneration) | kind=\(kind.debugName) | target=\(formattedTime(targetTime))"
        )
        return transportGeneration
    }

    private func handleSeekCompletion(
        finished: Bool,
        autoplay: Bool,
        kind: LibraryPreviewSeekKind,
        generation: UInt64
    ) {
        let elapsedMs = elapsedMillisecondsSinceLastTransportRequest()
        debugLog(
            "seek completed | generation=\(generation) | kind=\(kind.debugName) | finished=\(finished) | elapsed_ms=\(elapsedMs)"
        )
        guard generation == transportGeneration else {
            debugLog(
                "seek completion ignored | generation=\(generation) | active_generation=\(transportGeneration)"
            )
            return
        }
        guard finished else { return }

        if autoplay {
            player.playImmediately(atRate: 1.0)
            debugLog(
                "playImmediately applied | generation=\(generation) | kind=\(kind.debugName) | elapsed_ms=\(elapsedMs)"
            )
        } else {
            player.pause()
            beginPrerollIfPossible(for: player.currentItem)
        }
    }

    private func scheduleDeferredReset(for generation: UInt64) {
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.performDeferredReset(for: generation)
            }
        }
        pendingResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + deferredResetDelaySec,
            execute: workItem
        )
        debugLog(
            "reset scheduled | generation=\(generation) | delay_ms=\(Int((deferredResetDelaySec * 1000).rounded()))"
        )
    }

    private func performDeferredReset(for generation: UInt64) {
        guard generation == transportGeneration else { return }
        pendingResetWorkItem = nil
        player.currentItem?.cancelPendingSeeks()
        player.cancelPendingPrerolls()
        isPrerollPrimed = false
        let targetTime = CMTime.zero
        let tolerance = seekTolerance(for: .reset)
        debugLog("reset seek issued | generation=\(generation)")
        player.seek(
            to: targetTime,
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let elapsedMs = self.elapsedMillisecondsSinceLastTransportRequest()
                self.debugLog(
                    "reset seek completed | generation=\(generation) | finished=\(finished) | elapsed_ms=\(elapsedMs)"
                )
                guard generation == self.transportGeneration, finished else { return }
                self.player.pause()
                self.beginPrerollIfPossible(for: self.player.currentItem)
            }
        }
    }

    private func cancelPendingReset() {
        pendingResetWorkItem?.cancel()
        pendingResetWorkItem = nil
    }

    private func handleTimeControlStatusChange(_ observedPlayer: AVPlayer) {
        debugLog(
            "timeControlStatus=\(observedPlayer.timeControlStatus.debugName) | reason=\(observedPlayer.reasonForWaitingToPlay?.debugName ?? "none")"
        )
    }

    private func elapsedMillisecondsSinceLastTransportRequest() -> Int {
        guard let lastTransportRequestTimestamp else { return 0 }
        return max(
            Int(((ProcessInfo.processInfo.systemUptime - lastTransportRequestTimestamp) * 1000).rounded()),
            0
        )
    }

    private func formattedTime(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "nan" }
        return String(format: "%.3f", time)
    }

    private func debugLog(_ message: String) {
#if DEBUG
        AppLogger.shared.info("Library preview avplayer | \(message)")
#endif
    }

    private func seekTolerance(for kind: LibraryPreviewSeekKind) -> CMTime {
        switch kind {
        case .playbackResume:
            return playbackResumeSeekTolerance
        case .waveformTap:
            return waveformTapSeekTolerance
        case .waveformScrub:
            return waveformScrubSeekTolerance
        case .cuePoint:
            return cueSeekTolerance
        case .reset:
            return resetSeekTolerance
        }
    }
}

private extension LibraryPreviewSeekKind {
    var debugName: String {
        switch self {
        case .playbackResume:
            return "playbackResume"
        case .waveformTap:
            return "waveformTap"
        case .waveformScrub:
            return "waveformScrub"
        case .cuePoint:
            return "cuePoint"
        case .reset:
            return "reset"
        }
    }
}

private extension AVPlayer.TimeControlStatus {
    var debugName: String {
        switch self {
        case .paused:
            return "paused"
        case .playing:
            return "playing"
        case .waitingToPlayAtSpecifiedRate:
            return "waitingToPlayAtSpecifiedRate"
        @unknown default:
            return "unknown"
        }
    }
}

private extension AVPlayer.WaitingReason {
    var debugName: String {
        switch self {
        case .evaluatingBufferingRate:
            return "evaluatingBufferingRate"
        case .toMinimizeStalls:
            return "toMinimizeStalls"
        case .noItemToPlay:
            return "noItemToPlay"
        default:
            return "unknown"
        }
    }
}
