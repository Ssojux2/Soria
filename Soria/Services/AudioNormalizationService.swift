import AudioToolbox
import AVFoundation
import Foundation

final class AudioNormalizationService: @unchecked Sendable {
    nonisolated private static let peakTolerance = 1e-4
    nonisolated private static let m4aCorrectionAttempts = 2
    nonisolated private static let bufferFrameCount: AVAudioFrameCount = 65_536

    private let worker: AudioNormalizationWorkering
    private let fileManager: FileManager
    private let trackRefresher: @Sendable (URL) async throws -> Track
    private let trashBackupOperation: @Sendable (FileManager, URL) throws -> URL?

    init(
        worker: AudioNormalizationWorkering = PythonWorkerClient(),
        fileManager: FileManager = .default,
        trackRefresher: @escaping @Sendable (URL) async throws -> Track,
        trashBackupOperation: @escaping @Sendable (FileManager, URL) throws -> URL? = { fileManager, backupURL in
            var trashedURL: NSURL?
            try fileManager.trashItem(at: backupURL, resultingItemURL: &trashedURL)
            return trashedURL as URL?
        }
    ) {
        self.worker = worker
        self.fileManager = fileManager
        self.trackRefresher = trackRefresher
        self.trashBackupOperation = trashBackupOperation
    }

    func inspectTrack(_ track: Track) async -> TrackNormalizationInspection {
        do {
            return try await inspectTrackThrowing(track)
        } catch {
            return .failed(for: track, message: error.localizedDescription)
        }
    }

    func inspectTracks(_ tracks: [Track], maxConcurrent: Int = 2) async -> [UUID: TrackNormalizationInspection] {
        guard !tracks.isEmpty else { return [:] }

        let limit = max(1, maxConcurrent)
        var iterator = tracks.makeIterator()

        return await withTaskGroup(of: (UUID, TrackNormalizationInspection).self) { group in
            for _ in 0..<min(limit, tracks.count) {
                guard let track = iterator.next() else { break }
                group.addTask { [self] in
                    (track.id, await inspectTrack(track))
                }
            }

            var output: [UUID: TrackNormalizationInspection] = [:]
            while let (trackID, inspection) = await group.next() {
                output[trackID] = inspection
                if let nextTrack = iterator.next() {
                    group.addTask { [self] in
                        (nextTrack.id, await inspectTrack(nextTrack))
                    }
                }
            }

            return output
        }
    }

    func normalizeQueuedTracks(
        _ tracks: [Track],
        preparedInspections: [UUID: TrackNormalizationInspection] = [:],
        maxConcurrent: Int = 2,
        onTrackStateChange: (@Sendable (Track, TrackNormalizationState) async -> Void)? = nil
    ) async -> AudioNormalizationQueueResult {
        guard !tracks.isEmpty else {
            return AudioNormalizationQueueResult(
                updatedTracksByID: [:],
                inspectionsByTrackID: [:],
                warnings: [],
                normalizedCount: 0,
                skippedLowPriorityCount: 0
            )
        }

        let limit = max(1, maxConcurrent)
        var updatedTracksByID: [UUID: Track] = [:]
        var inspectionsByTrackID: [UUID: TrackNormalizationInspection] = Dictionary(uniqueKeysWithValues: tracks.compactMap { track in
            guard let inspection = preparedInspections[track.id], inspection.matches(track) else { return nil }
            return (track.id, inspection)
        })
        var warnings: [String] = []

        let tracksToInspect = tracks.filter { inspectionsByTrackID[$0.id] == nil }
        if !tracksToInspect.isEmpty {
            let inspected = await inspectTracks(tracksToInspect, maxConcurrent: limit)
            for track in tracksToInspect {
                if let inspection = inspected[track.id] {
                    inspectionsByTrackID[track.id] = inspection
                }
            }
        }

        let skippedLowPriorityCount = tracks.reduce(into: 0) { partialResult, track in
            if inspectionsByTrackID[track.id]?.needTier == .low {
                partialResult += 1
            }
        }

        let tracksToNormalize = tracks.filter { track in
            inspectionsByTrackID[track.id]?.shouldNormalizeInQueue == true
        }
        let trackIDsToNormalize = Set(tracksToNormalize.map { $0.id })

        for track in tracks where !trackIDsToNormalize.contains(track.id) {
            if let onTrackStateChange, let inspection = inspectionsByTrackID[track.id] {
                await onTrackStateChange(track, inspection.state)
            }
        }

        var iterator = tracksToNormalize.makeIterator()
        var mutationResults: [UUID: Result<NormalizedTrackMutationResult, Error>] = [:]

        await withTaskGroup(of: (UUID, Result<NormalizedTrackMutationResult, Error>).self) { group in
            func launch(_ track: Track) async {
                if let onTrackStateChange {
                    await onTrackStateChange(track, .normalizing)
                }
                group.addTask { [self] in
                    do {
                        return (track.id, .success(try await normalizeTrackMutation(track)))
                    } catch {
                        return (track.id, .failure(error))
                    }
                }
            }

            var launchedCount = 0
            while launchedCount < min(limit, tracksToNormalize.count), let track = iterator.next() {
                await launch(track)
                launchedCount += 1
            }

            while let (trackID, result) = await group.next() {
                mutationResults[trackID] = result
                if let nextTrack = iterator.next() {
                    await launch(nextTrack)
                }
            }
        }

        for track in tracksToNormalize {
            switch mutationResults[track.id] {
            case let .success(mutationResult):
                warnings.append(contentsOf: mutationResult.warnings)
                if mutationResult.didReplaceOriginal {
                    do {
                        let updatedTrack = try await trackRefresher(mutationResult.originalURL)
                        let refreshedInspection = await inspectTrack(updatedTrack)
                        updatedTracksByID[track.id] = updatedTrack
                        inspectionsByTrackID[track.id] = refreshedInspection
                        if let onTrackStateChange {
                            await onTrackStateChange(track, refreshedInspection.state)
                        }
                    } catch {
                        let failedInspection = TrackNormalizationInspection.failed(for: track, message: error.localizedDescription)
                        inspectionsByTrackID[track.id] = failedInspection
                        warnings.append("Normalization failed for \(track.fileName): \(error.localizedDescription)")
                        if let onTrackStateChange {
                            await onTrackStateChange(track, .failed)
                        }
                    }
                } else {
                    inspectionsByTrackID[track.id] = mutationResult.inspection
                    if let onTrackStateChange {
                        await onTrackStateChange(track, mutationResult.inspection.state)
                    }
                }
            case let .failure(error):
                let failedInspection = TrackNormalizationInspection.failed(for: track, message: error.localizedDescription)
                inspectionsByTrackID[track.id] = failedInspection
                warnings.append("Normalization failed for \(track.fileName): \(error.localizedDescription)")
                if let onTrackStateChange {
                    await onTrackStateChange(track, .failed)
                }
            case .none:
                if let onTrackStateChange, let inspection = inspectionsByTrackID[track.id] {
                    await onTrackStateChange(track, inspection.state)
                }
            }
        }

        return AudioNormalizationQueueResult(
            updatedTracksByID: updatedTracksByID,
            inspectionsByTrackID: inspectionsByTrackID,
            warnings: warnings,
            normalizedCount: updatedTracksByID.count,
            skippedLowPriorityCount: skippedLowPriorityCount
        )
    }

    private func inspectTrackThrowing(_ track: Track) async throws -> TrackNormalizationInspection {
        let inputURL = URL(fileURLWithPath: track.filePath).standardizedFileURL
        guard fileManager.fileExists(atPath: inputURL.path) else {
            throw NSError(
                domain: "AudioNormalizationService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "File not found at \(inputURL.path)."]
            )
        }

        switch inputURL.pathExtension.lowercased() {
        case "m4a":
            let trackID = track.id
            let signature = TrackNormalizationSignature.make(for: track)
            return try await Task.detached(priority: .utility) {
                try await Self.inspectM4AFile(at: inputURL, trackID: trackID, signature: signature)
            }.value

        case "aac":
            return TrackNormalizationInspection(
                trackID: track.id,
                signature: TrackNormalizationSignature.make(for: track),
                state: .unsupported,
                peakAmplitude: nil,
                formatName: "AAC",
                subtype: nil,
                endian: nil,
                sampleRate: nil,
                channelCount: nil,
                frameCount: nil,
                hasMetadata: false,
                isLossy: true,
                detailMessage: "Raw .aac files are not safely writable in v1."
            )

        default:
            let response = try await worker.inspectAudioNormalization(filePath: inputURL.path)
            return response.inspection(for: track)
        }
    }

    private func normalizeTrackMutation(_ track: Track) async throws -> NormalizedTrackMutationResult {
        let originalURL = URL(fileURLWithPath: track.filePath).standardizedFileURL
        let replacementDirectory = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: originalURL,
            create: true
        )
        let normalizedOutputURL = replacementDirectory.appendingPathComponent(originalURL.lastPathComponent)

        defer {
            try? fileManager.removeItem(at: replacementDirectory)
        }

        let normalizationResponse: WorkerNormalizationResultResponse
        switch originalURL.pathExtension.lowercased() {
        case "m4a":
            normalizationResponse = try await Task.detached(priority: .utility) {
                try await Self.normalizeM4AFile(at: originalURL, to: normalizedOutputURL)
            }.value
        default:
            normalizationResponse = try await worker.normalizeAudioFile(
                filePath: originalURL.path,
                outputPath: normalizedOutputURL.path
            )
        }

        let responseInspection = normalizationResponse.inspection(for: track)
        guard normalizationResponse.didNormalize else {
            return NormalizedTrackMutationResult(
                originalURL: originalURL,
                didReplaceOriginal: false,
                inspection: responseInspection,
                warnings: []
            )
        }

        guard fileManager.fileExists(atPath: normalizedOutputURL.path) else {
            throw NSError(
                domain: "AudioNormalizationService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Normalization output was not created."]
            )
        }

        let replacementWarnings = try safelyReplaceOriginal(
            at: originalURL,
            withNormalizedCopyAt: normalizedOutputURL
        )

        return NormalizedTrackMutationResult(
            originalURL: originalURL,
            didReplaceOriginal: true,
            inspection: responseInspection,
            warnings: replacementWarnings
        )
    }

    private func safelyReplaceOriginal(
        at originalURL: URL,
        withNormalizedCopyAt normalizedOutputURL: URL
    ) throws -> [String] {
        let trashedOriginalURL: URL?
        do {
            trashedOriginalURL = try trashBackupOperation(fileManager, originalURL)
        } catch {
            return try replaceOriginalKeepingTimestampedBackup(
                at: originalURL,
                withNormalizedCopyAt: normalizedOutputURL,
                trashError: error
            )
        }

        do {
            try fileManager.moveItem(at: normalizedOutputURL, to: originalURL)
        } catch {
            try? restoreOriginalFromTrashIfPossible(trashedOriginalURL, to: originalURL)
            throw error
        }

        return []
    }

    private func replaceOriginalKeepingTimestampedBackup(
        at originalURL: URL,
        withNormalizedCopyAt normalizedOutputURL: URL,
        trashError: Error
    ) throws -> [String] {
        let extensionSuffix = originalURL.pathExtension.isEmpty ? "" : ".\(originalURL.pathExtension)"
        let backupName = "\(originalURL.deletingPathExtension().lastPathComponent)-soria-backup-\(Self.backupTimestamp())\(extensionSuffix)"
        let backupURL = originalURL.deletingLastPathComponent().appendingPathComponent(backupName)

        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }

        let resultingURL = try fileManager.replaceItemAt(
            originalURL,
            withItemAt: normalizedOutputURL,
            backupItemName: backupName,
            options: [.withoutDeletingBackupItem]
        )

        let activeURL = resultingURL?.standardizedFileURL ?? originalURL
        var warnings: [String] = []

        if fileManager.fileExists(atPath: backupURL.path) {
            warnings.append(
                "Original file for \(activeURL.lastPathComponent) could not be moved to Trash with its original name (\(trashError.localizedDescription)). Backup kept at \(backupURL.path)."
            )
        }

        return warnings
    }

    private func restoreOriginalFromTrashIfPossible(_ trashedOriginalURL: URL?, to originalURL: URL) throws {
        guard !fileManager.fileExists(atPath: originalURL.path),
              let trashedOriginalURL,
              fileManager.fileExists(atPath: trashedOriginalURL.path) else {
            return
        }
        try fileManager.moveItem(at: trashedOriginalURL, to: originalURL)
    }

    nonisolated private static func inspectM4AFile(
        at url: URL,
        trackID: UUID,
        signature: String
    ) async throws -> TrackNormalizationInspection {
        let nativeInspection = try await inspectNativeAACM4A(at: url)
        return TrackNormalizationInspection(
            trackID: trackID,
            signature: signature,
            state: nativeInspection.state,
            peakAmplitude: nativeInspection.peakAmplitude,
            formatName: nativeInspection.formatName,
            subtype: nativeInspection.subtype,
            endian: nil,
            sampleRate: nativeInspection.sampleRate,
            channelCount: nativeInspection.channelCount,
            frameCount: nativeInspection.frameCount,
            hasMetadata: nativeInspection.hasMetadata,
            isLossy: nativeInspection.isLossy,
            detailMessage: nativeInspection.detailMessage
        )
    }

    nonisolated private static func normalizeM4AFile(
        at inputURL: URL,
        to outputURL: URL
    ) async throws -> WorkerNormalizationResultResponse {
        let initialInspection = try await inspectNativeAACM4A(at: inputURL)
        guard initialInspection.state == .needsNormalize else {
            return WorkerNormalizationResultResponse(
                state: initialInspection.state,
                originalPeakAmplitude: initialInspection.peakAmplitude,
                normalizedPeakAmplitude: initialInspection.peakAmplitude,
                appliedGain: initialInspection.state == .ready ? 1.0 : nil,
                didNormalize: false,
                outputPath: nil,
                formatName: initialInspection.formatName,
                subtype: initialInspection.subtype,
                endian: nil,
                sampleRate: initialInspection.sampleRate,
                channelCount: initialInspection.channelCount,
                frameCount: initialInspection.frameCount,
                hasMetadata: initialInspection.hasMetadata,
                isLossy: initialInspection.isLossy,
                detailMessage: initialInspection.detailMessage
            )
        }

        let metadataAsset = AVURLAsset(url: inputURL)
        let metadata = try await metadataAsset.load(.commonMetadata)
        let intermediatePCMURL = outputURL.deletingPathExtension().appendingPathExtension("wav")
        var bestPeak = initialInspection.peakAmplitude
        var bestGain = 1.0 / max(initialInspection.peakAmplitude ?? 0, Self.peakTolerance)

        for _ in 0..<Self.m4aCorrectionAttempts {
            try? FileManager.default.removeItem(at: intermediatePCMURL)
            try? FileManager.default.removeItem(at: outputURL)

            try writeNormalizedPCM(
                from: inputURL,
                to: intermediatePCMURL,
                gain: bestGain
            )
            try await transcodePCMToM4A(
                pcmURL: intermediatePCMURL,
                outputURL: outputURL,
                metadata: metadata
            )

            let normalizedInspection = try await inspectNativeAACM4A(at: outputURL)
            bestPeak = normalizedInspection.peakAmplitude

            if normalizedInspection.state == .ready {
                return WorkerNormalizationResultResponse(
                    state: .ready,
                    originalPeakAmplitude: initialInspection.peakAmplitude,
                    normalizedPeakAmplitude: normalizedInspection.peakAmplitude,
                    appliedGain: bestGain,
                    didNormalize: true,
                    outputPath: outputURL.path,
                    formatName: normalizedInspection.formatName,
                    subtype: normalizedInspection.subtype,
                    endian: nil,
                    sampleRate: normalizedInspection.sampleRate,
                    channelCount: normalizedInspection.channelCount,
                    frameCount: normalizedInspection.frameCount,
                    hasMetadata: normalizedInspection.hasMetadata,
                    isLossy: normalizedInspection.isLossy,
                    detailMessage: nil
                )
            }

            if let peak = normalizedInspection.peakAmplitude, peak > 0 {
                bestGain *= 1.0 / peak
            } else {
                break
            }
        }

        return WorkerNormalizationResultResponse(
            state: .failed,
            originalPeakAmplitude: initialInspection.peakAmplitude,
            normalizedPeakAmplitude: bestPeak,
            appliedGain: bestGain,
            didNormalize: false,
            outputPath: nil,
            formatName: initialInspection.formatName,
            subtype: initialInspection.subtype,
            endian: nil,
            sampleRate: initialInspection.sampleRate,
            channelCount: initialInspection.channelCount,
            frameCount: initialInspection.frameCount,
            hasMetadata: initialInspection.hasMetadata,
            isLossy: initialInspection.isLossy,
            detailMessage: "Normalized .m4a output failed peak validation."
        )
    }

    nonisolated private static func inspectNativeAACM4A(at url: URL) async throws -> NativeM4AInspection {
        let asset = AVURLAsset(url: url)
        let file = try AVAudioFile(forReading: url)
        let formatID = audioFormatID(from: file.fileFormat.settings)
        let subtype = audioFormatDescription(for: formatID)
        let hasMetadata = !(try await asset.load(.commonMetadata)).isEmpty
        let peak = try peakAmplitude(for: file)

        guard formatID == kAudioFormatMPEG4AAC else {
            return NativeM4AInspection(
                state: .unsupported,
                peakAmplitude: peak,
                formatName: "M4A",
                subtype: subtype,
                sampleRate: file.fileFormat.sampleRate,
                channelCount: Int(file.fileFormat.channelCount),
                frameCount: Int(file.length),
                hasMetadata: hasMetadata,
                isLossy: formatID != kAudioFormatAppleLossless,
                detailMessage: "Only AAC-based .m4a files are safely supported in v1."
            )
        }

        let state: TrackNormalizationState
        if peak == 0 {
            state = .silent
        } else if TrackNormalizationQueuePolicy.meetsOrExceedsTargetPeak(peak) {
            state = .ready
        } else {
            state = .needsNormalize
        }

        return NativeM4AInspection(
            state: state,
            peakAmplitude: peak,
            formatName: "M4A",
            subtype: subtype,
            sampleRate: file.fileFormat.sampleRate,
            channelCount: Int(file.fileFormat.channelCount),
            frameCount: Int(file.length),
            hasMetadata: hasMetadata,
            isLossy: true,
            detailMessage: nil
        )
    }

    nonisolated private static func writeNormalizedPCM(
        from sourceURL: URL,
        to destinationURL: URL,
        gain: Double
    ) throws {
        let sourceFile = try AVAudioFile(forReading: sourceURL)
        let processingFormat = sourceFile.processingFormat
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: processingFormat.sampleRate,
            AVNumberOfChannelsKey: Int(processingFormat.channelCount),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false
        ]
        let destinationFile = try AVAudioFile(
            forWriting: destinationURL,
            settings: outputSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: Self.bufferFrameCount
        ) else {
            throw NSError(
                domain: "AudioNormalizationService",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Could not allocate a PCM buffer for .m4a normalization."]
            )
        }

        while true {
            try sourceFile.read(into: buffer, frameCount: Self.bufferFrameCount)
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { break }
            guard let channelData = buffer.floatChannelData else {
                throw NSError(
                    domain: "AudioNormalizationService",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Could not access float channel data for .m4a normalization."]
                )
            }

            for channelIndex in 0..<Int(buffer.format.channelCount) {
                let samples = channelData[channelIndex]
                for frameIndex in 0..<frameLength {
                    let scaled = Double(samples[frameIndex]) * gain
                    samples[frameIndex] = Float(min(max(scaled, -1.0), 1.0))
                }
            }

            try destinationFile.write(from: buffer)
        }
    }

    nonisolated private static func transcodePCMToM4A(
        pcmURL: URL,
        outputURL: URL,
        metadata: [AVMetadataItem]
    ) async throws {
        let asset = AVURLAsset(url: pcmURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(
                domain: "AudioNormalizationService",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Could not create .m4a export session."]
            )
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        exportSession.metadata = metadata
        exportSession.shouldOptimizeForNetworkUse = false
        try await exportSession.export(to: outputURL, as: .m4a)
    }

    nonisolated private static func peakAmplitude(for file: AVAudioFile) throws -> Double {
        file.framePosition = 0
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: Self.bufferFrameCount
        ) else {
            throw NSError(
                domain: "AudioNormalizationService",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Could not allocate a PCM buffer while scanning peak amplitude."]
            )
        }
        var peak = 0.0

        while true {
            try file.read(into: buffer, frameCount: Self.bufferFrameCount)
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { break }
            guard let channelData = buffer.floatChannelData else {
                throw NSError(
                    domain: "AudioNormalizationService",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "Could not access float channel data while scanning peak amplitude."]
                )
            }

            for channelIndex in 0..<Int(buffer.format.channelCount) {
                let samples = channelData[channelIndex]
                for frameIndex in 0..<frameLength {
                    let magnitude = abs(Double(samples[frameIndex]))
                    if magnitude > peak {
                        peak = magnitude
                    }
                }
            }
        }

        file.framePosition = 0
        return peak
    }

    nonisolated private static func audioFormatID(from settings: [String: Any]) -> AudioFormatID? {
        if let number = settings[AVFormatIDKey] as? NSNumber {
            return AudioFormatID(number.uint32Value)
        }
        if let value = settings[AVFormatIDKey] as? AudioFormatID {
            return value
        }
        return nil
    }

    nonisolated private static func audioFormatDescription(for formatID: AudioFormatID?) -> String {
        guard let formatID else { return "Unknown" }
        switch formatID {
        case kAudioFormatMPEG4AAC:
            return "AAC"
        case kAudioFormatAppleLossless:
            return "ALAC"
        default:
            return fourCharacterCode(formatID)
        }
    }

    nonisolated private static func fourCharacterCode(_ value: AudioFormatID) -> String {
        let scalar0 = UnicodeScalar((value >> 24) & 0xFF)
        let scalar1 = UnicodeScalar((value >> 16) & 0xFF)
        let scalar2 = UnicodeScalar((value >> 8) & 0xFF)
        let scalar3 = UnicodeScalar(value & 0xFF)
        let scalars = [scalar0, scalar1, scalar2, scalar3].compactMap { $0 }
        return String(String.UnicodeScalarView(scalars))
    }

    nonisolated private static func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

private struct NormalizedTrackMutationResult {
    let originalURL: URL
    let didReplaceOriginal: Bool
    let inspection: TrackNormalizationInspection
    let warnings: [String]
}

private struct NativeM4AInspection {
    let state: TrackNormalizationState
    let peakAmplitude: Double?
    let formatName: String
    let subtype: String
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int
    let hasMetadata: Bool
    let isLossy: Bool
    let detailMessage: String?
}
