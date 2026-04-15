import SwiftUI

struct TrackDetailView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !viewModel.selectedTracks.isEmpty {
                    selectionHeader

                    GroupBox("Analysis Controls") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Analysis Scope", selection: $viewModel.analysisScope) {
                                ForEach(AnalysisScope.allCases) { scope in
                                    Text(scope.displayName).tag(scope)
                                }
                            }
                            .pickerStyle(.segmented)

                            Text(viewModel.analysisScope.helperText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            Text(analysisSelectionMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            HStack {
                                Button(viewModel.isAnalyzing ? "Processing..." : "Analyze") {
                                    viewModel.requestAnalysis()
                                }
                                .disabled(!viewModel.canRunAnalysis)

                                Button("Cancel") {
                                    viewModel.cancelAnalysis()
                                }
                                .disabled(!viewModel.isAnalyzing)
                                .tint(.red)
                            }

                            if !viewModel.analysisQueueProgressText.isEmpty {
                                Text(viewModel.analysisQueueProgressText)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            if !viewModel.analysisErrorMessage.isEmpty {
                                Text(viewModel.analysisErrorMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if viewModel.selectedTracks.count > 1 {
                        multiSelectionDetails
                    } else if let track = viewModel.selectedTrack {
                        singleTrackDetails(for: track)
                    }
                } else {
                    ContentUnavailableView("Select one or more tracks", systemImage: "music.note.list")
                }

                Spacer(minLength: 0)
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("track-detail-info-view")
    }

    @ViewBuilder
    private var selectionHeader: some View {
        if let track = viewModel.selectedTrack, viewModel.selectedTracks.count == 1 {
            Text(track.title)
                .font(.title2.bold())
            Text(track.artist.isEmpty ? "Unknown artist" : track.artist)
                .foregroundStyle(.secondary)
            Text(track.filePath)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        } else {
            Text("\(viewModel.selectedTracks.count) Tracks Selected")
                .font(.title2.bold())
            Text(viewModel.selectedTracks.prefix(6).map { "\($0.title) - \($0.artist)" }.joined(separator: ", "))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }

    private func singleTrackDetails(for track: Track) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Waveform Preview") {
                VStack(alignment: .leading, spacing: 10) {
                        let cuePoints = viewModel.selectedTrackExternalMetadata.flatMap(\.cuePoints)
                        WaveformPreview(
                            samples: viewModel.selectedTrackWaveformPreview,
                            segments: viewModel.selectedTrackSegments,
                            cuePoints: cuePoints,
                            trackDuration: track.duration
                        )
                    .frame(height: 96)

                    if viewModel.selectedTrackSegments.isEmpty {
                        Text("No segment data yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.selectedTrackSegments) { segment in
                            HStack {
                                Text(segment.type.rawValue.capitalized)
                                    .frame(width: 64, alignment: .leading)
                                Text("\(String(format: "%.1f", segment.startSec))s - \(String(format: "%.1f", segment.endSec))s")
                                    .font(.system(.body, design: .monospaced))
                                Spacer()
                                Text("Energy \(String(format: "%.2f", segment.energyScore))")
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Analysis Summary") {
                if let analysis = viewModel.selectedTrackAnalysis {
                    VStack(alignment: .leading, spacing: 6) {
                        analysisRow("Estimated BPM", analysis.estimatedBPM.map { String(format: "%.1f", $0) } ?? "-")
                        analysisRow("Estimated Key", analysis.estimatedKey ?? "-")
                        analysisRow("Brightness", String(format: "%.3f", analysis.brightness))
                        analysisRow("Onset Density", String(format: "%.3f", analysis.onsetDensity))
                        analysisRow("Rhythmic Density", String(format: "%.3f", analysis.rhythmicDensity))
                        analysisRow(
                            "Band Balance",
                            analysis.lowMidHighBalance.map { String(format: "%.2f", $0) }.joined(separator: " / ")
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Analyze this track to populate waveform and feature summary.")
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("Library Metadata") {
                VStack(alignment: .leading, spacing: 6) {
                    analysisRow("BPM", track.bpm.map { String(format: "%.1f", $0) } ?? "-")
                    analysisRow("BPM Source", track.bpmSource?.displayName ?? "-")
                    analysisRow("Key", track.musicalKey ?? "-")
                    analysisRow("Key Source", track.keySource?.displayName ?? "-")
                    analysisRow("Genre", track.genre.isEmpty ? "-" : track.genre)
                    analysisRow("Duration", formatDuration(track.duration))
                    analysisRow("Serato", track.hasSeratoMetadata ? "Detected" : "None")
                    analysisRow("rekordbox", track.hasRekordboxMetadata ? "Detected" : "None")
                    analysisRow("Source Provenance", provenanceText(for: track))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("External DJ Metadata") {
                if viewModel.selectedTrackExternalMetadata.isEmpty {
                    Text("No imported Serato / rekordbox metadata for this track yet.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.selectedTrackExternalMetadata) { metadata in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(metadata.source.displayName)
                                    .font(.headline)
                                analysisRow("BPM", metadata.bpm.map { String(format: "%.1f", $0) } ?? "-")
                                analysisRow("Key", metadata.musicalKey ?? "-")
                                analysisRow("Rating", metadata.rating.map(String.init) ?? "-")
                                analysisRow("Play Count", metadata.playCount.map(String.init) ?? "-")
                                analysisRow("Cue Count", metadata.cueCount.map(String.init) ?? "-")
                                analysisRow("Cue Points", "\(metadata.cuePoints.count)")
                                analysisRow(
                                    "Tags",
                                    metadata.tags.isEmpty ? "-" : metadata.tags.joined(separator: ", ")
                                )
                                analysisRow(
                                    "Playlists",
                                    metadata.playlistMemberships.isEmpty ? "-" : metadata.playlistMemberships.joined(separator: ", ")
                                )
                                analysisRow("Vendor Track ID", metadata.vendorTrackID ?? "-")
                                analysisRow("Analysis State", metadata.analysisState ?? "-")
                                analysisRow("Analysis Cache", metadata.analysisCachePath ?? "-")
                                analysisRow("Sync Version", metadata.syncVersion ?? "-")
                                if let comment = metadata.comment, !comment.isEmpty {
                                    Text(comment)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }

    private var multiSelectionDetails: some View {
        GroupBox("Selected Tracks") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(viewModel.selectedTracks.prefix(12)), id: \.id) { track in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                            Text(track.artist.isEmpty ? "Unknown artist" : track.artist)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(track.hasCurrentEmbedding(profileID: viewModel.embeddingProfile.id) ? "Ready" : "Needs Analysis")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if viewModel.selectedTracks.count > 12 {
                    Text("+ \(viewModel.selectedTracks.count - 12) more tracks selected")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text("Waveform and per-track metadata are shown when a single track is selected.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var analysisSelectionMessage: String {
        switch viewModel.analysisScope {
        case .selectedTrack:
            let count = viewModel.selectedTracks.count
            return count <= 1
                ? "Analysis will run for the selected track."
                : "Analysis will run for all \(count) selected tracks from the library."
        case .unanalyzedTracks:
            return "Analysis will run for every track that is missing analysis or needs fresh embeddings."
        case .allIndexedTracks:
            return "Analysis will rebuild embeddings for the entire indexed library."
        }
    }

    private func analysisRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
        }
    }

    private func formatDuration(_ sec: Double) -> String {
        let total = Int(sec)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func provenanceText(for track: Track) -> String {
        var sources: [String] = []
        if track.hasSeratoMetadata {
            sources.append("Serato")
        }
        if track.hasRekordboxMetadata {
            sources.append("rekordbox")
        }
        if track.bpmSource == .audioTags || track.keySource == .audioTags {
            sources.append("Audio Tags")
        }
        if track.analyzedAt != nil {
            sources.append("Soria Analysis")
        }
        return Array(Set(sources)).sorted().joined(separator: ", ").isEmpty
            ? "Manual Fallback"
            : Array(Set(sources)).sorted().joined(separator: ", ")
    }
}

private struct WaveformPreview: View {
    let samples: [Double]
    let segments: [TrackSegment]
    let cuePoints: [ExternalDJCuePoint]
    let trackDuration: Double

    private let barCount = 128
    private let sidePadding: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let values = normalizedWaveformSamples(from: samples)
            let trackLength = resolvedTrackDuration
            let barWidth = max(1.0, (proxy.size.width - (sidePadding * 2.0)) / CGFloat(max(values.count, 1)))
            let segmentBars = segmentOverlays()
            let cueOverlays = cuePointOverlays()
            let hasWaveformData = !values.isEmpty

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.08))

                if hasWaveformData {
                    HStack(alignment: .center, spacing: 1) {
                        ForEach(Array(values.enumerated()), id: \.offset) { item in
                            Capsule(style: .continuous)
                                .fill(Color.accentColor.opacity(0.7))
                                .frame(
                                    width: barWidth,
                                    height: max(6, proxy.size.height * item.element)
                                )
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                    .padding(.horizontal, sidePadding)
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(height: 1)
                        .padding(.horizontal, sidePadding)
                        .frame(maxHeight: .infinity, alignment: .center)

                    Text(cueOverlays.isEmpty ? "No waveform preview available" : "Cue points loaded without waveform preview")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }

                ForEach(segmentBars) { segment in
                    let startRatio = CGFloat(segment.startSec / trackLength)
                    let endRatio = CGFloat(segment.endSec / trackLength)
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(color(for: segment), lineWidth: 2)
                        .background(color(for: segment).opacity(0.12))
                        .frame(width: max(12, max(0, min(1, endRatio - startRatio)) * (proxy.size.width - (sidePadding * 2))))
                        .offset(x: sidePadding + (proxy.size.width - (sidePadding * 2)) * min(1, max(0, startRatio)))
                }

                ForEach(Array(cueOverlays.enumerated()), id: \.offset) { item in
                    let ratio = CGFloat(item.element.startSec / trackLength)
                    let x = sidePadding + (proxy.size.width - (sidePadding * 2)) * min(1, max(0, ratio))
                    Capsule(style: .continuous)
                        .fill(color(for: item.element))
                        .frame(width: 2, height: proxy.size.height + 6)
                        .offset(x: x)
                        .opacity(0.85)
                }
            }
        }
    }

    private var resolvedTrackDuration: Double {
        if trackDuration.isFinite && trackDuration > 0 {
            return trackDuration
        }

        let segmentEnd = segments
            .map(\.endSec)
            .filter { $0.isFinite }
            .max()

        if let segmentEnd, segmentEnd > 0 {
            return segmentEnd
        }

        return 1.0
    }

    private func segmentOverlays() -> [TrackSegment] {
        segments.compactMap { segment in
            let start = segment.startSec
            let end = segment.endSec
            guard start.isFinite && end.isFinite else { return nil }

            let clampedStart = min(max(0, start), resolvedTrackDuration)
            let clampedEnd = min(max(0, end), resolvedTrackDuration)
            guard clampedEnd >= clampedStart else { return nil }

            return TrackSegment(
                id: segment.id,
                trackID: segment.trackID,
                type: segment.type,
                startSec: clampedStart,
                endSec: clampedEnd,
                energyScore: segment.energyScore,
                descriptorText: segment.descriptorText,
                vector: segment.vector
            )
        }.sorted { $0.startSec < $1.startSec }
    }

    private func cuePointOverlays() -> [ExternalDJCuePoint] {
        let normalized = cuePoints
            .filter { $0.startSec.isFinite }
            .compactMap { point -> ExternalDJCuePoint? in
                guard point.startSec >= 0 else { return nil }
                return ExternalDJCuePoint(
                    kind: point.kind,
                    name: point.name,
                    index: point.index,
                    startSec: min(point.startSec, resolvedTrackDuration),
                    endSec: point.endSec,
                    color: point.color,
                    source: point.source
                )
            }
            .sorted { lhs, rhs in
                if lhs.startSec == rhs.startSec {
                    return (lhs.index ?? Int.max) < (rhs.index ?? Int.max)
                }
                return lhs.startSec < rhs.startSec
            }

        return normalized.enumerated().reduce(into: [ExternalDJCuePoint]()) { result, item in
            let point = item.element
            guard let previous = result.last else {
                result.append(point)
                return
            }

            let isDuplicate = abs(previous.startSec - point.startSec) < 0.001 &&
                previous.kind == point.kind &&
                (previous.color ?? "") == (point.color ?? "")

            if !isDuplicate {
                result.append(point)
            }
        }
    }

    private func normalizedWaveformSamples(from values: [Double]) -> [Double] {
        let source = values
            .filter(\.isFinite)
            .map { max(0.0, min(1.0, $0)) }
        guard !source.isEmpty else { return [] }

        if source.count == barCount {
            return source
        }

        if source.count > barCount {
            let span = Double(source.count) / Double(barCount)
            return (0..<barCount).compactMap { index in
                let start = Int(Double(index) * span)
                let end = Int(Double(index + 1) * span)
                guard end > start else { return source[min(start, source.count - 1)] }
                let values = source[start..<min(end, source.count)]
                return values.reduce(0.0, +) / Double(values.count)
            }
        }

        return (0..<barCount).map { index in
            if source.count == 1 {
                return source[0]
            }
            let raw = Double(index) * Double(source.count - 1) / Double(barCount - 1)
            let lower = Int(floor(raw))
            let upper = min(source.count - 1, lower + 1)
            let fraction = raw - Double(lower)
            return (1.0 - fraction) * source[lower] + fraction * source[upper]
        }
    }

    private func color(for segment: TrackSegment) -> Color {
        switch segment.type {
        case .intro: return .cyan
        case .middle: return .orange
        case .outro: return .mint
        }
    }

    private func color(for cuePoint: ExternalDJCuePoint) -> Color {
        switch cuePoint.kind {
        case .cue: return .blue
        case .hotcue: return .orange
        case .loop: return .purple
        case .unknown: return .secondary
        }
    }
}
