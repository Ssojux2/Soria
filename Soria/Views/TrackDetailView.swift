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

                            Picker("Analysis Focus", selection: $viewModel.analysisFocus) {
                                ForEach(AnalysisFocus.allCases) { focus in
                                    Text(focus.displayName).tag(focus)
                                }
                            }
                            .pickerStyle(.menu)

                            Text(viewModel.analysisScope.helperText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            Text(viewModel.analysisFocus.helperText)
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
            Text(viewModel.analysisStatusText(for: track))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(viewModel.analysisStatusIsTransient(for: track) ? .blue : .secondary)
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
        let cueGroups = TrackCuePresentation.groups(from: viewModel.selectedTrackExternalMetadata)
        let cuePoints = viewModel.selectedTrackExternalMetadata.flatMap(\.cuePoints)
        let hasWaveformPreview = viewModel.selectedTrackWaveformPreview.contains { $0.isFinite }
        let cueCount = cueGroups.reduce(into: 0) { $0 += $1.items.count }

        return VStack(alignment: .leading, spacing: 14) {
            GroupBox("Waveform Preview") {
                VStack(alignment: .leading, spacing: 10) {
                    WaveformPreview(
                        samples: viewModel.selectedTrackWaveformPreview,
                        segments: viewModel.selectedTrackSegments,
                        cuePoints: cuePoints,
                        trackDuration: track.duration
                    )
                    .frame(height: 96)

                    Text(
                        TrackCuePresentation.waveformSummaryText(
                            hasWaveformPreview: hasWaveformPreview,
                            cueCount: cueCount
                        )
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    if !cueGroups.isEmpty {
                        cueGroupList(cueGroups)
                    }

                    Divider()

                    Text("Analysis Segments")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if viewModel.selectedTrackSegments.isEmpty {
                        Text("No analysis segments yet.")
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
                        analysisRow("Analysis Focus", analysis.analysisFocus.displayName)
                        analysisRow("Confidence", String(format: "%.2f", analysis.confidence))
                        analysisRow("Intro Length", String(format: "%.1fs", analysis.introLengthSec))
                        analysisRow("Outro Length", String(format: "%.1fs", analysis.outroLengthSec))
                        analysisRow("Brightness", String(format: "%.3f", analysis.brightness))
                        analysisRow("Onset Density", String(format: "%.3f", analysis.onsetDensity))
                        analysisRow("Rhythmic Density", String(format: "%.3f", analysis.rhythmicDensity))
                        analysisRow(
                            "Band Balance",
                            analysis.lowMidHighBalance.map { String(format: "%.2f", $0) }.joined(separator: " / ")
                        )
                        analysisRow(
                            "Energy Arc",
                            analysis.energyArc.map { String(format: "%.2f", $0) }.joined(separator: " / ")
                        )
                        analysisRow(
                            "Mixability Tags",
                            analysis.mixabilityTags.isEmpty ? "-" : analysis.mixabilityTags.joined(separator: ", ")
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

    @ViewBuilder
    private func cueGroupList(_ groups: [TrackCuePresentation.CueGroup]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Imported Cue Points")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(group.source.displayName)
                            .font(.headline)
                        Spacer()
                        Text("\(group.items.count) cues")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(group.items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                cueKindSwatch(for: item.kind)

                                Text(item.kindLabel)
                                    .fontWeight(.medium)

                                if let indexLabel = item.indexLabel {
                                    Text(indexLabel)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color.secondary.opacity(0.12), in: Capsule())
                                }

                                Spacer()

                                Text(item.timeText)
                                    .font(.system(.body, design: .monospaced))
                            }

                            if let noteText = item.noteText {
                                Text(noteText)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            if let sourceTag = item.sourceTag {
                                Text(sourceTag)
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
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
                        Text(viewModel.analysisStatusText(for: track))
                            .font(.footnote)
                            .foregroundStyle(viewModel.analysisStatusIsTransient(for: track) ? .blue : .secondary)
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

    private func cueKindSwatch(for kind: ExternalDJCuePoint.Kind) -> some View {
        Capsule(style: .continuous)
            .fill(color(for: kind))
            .frame(width: 8, height: 18)
            .opacity(kind == .loop ? 0.5 : 0.9)
    }

    private func color(for kind: ExternalDJCuePoint.Kind) -> Color {
        switch kind {
        case .cue:
            return .blue
        case .hotcue:
            return .orange
        case .loop:
            return .purple
        case .unknown:
            return .secondary
        }
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
            let loopOverlays = cueOverlays.filter { cuePoint in
                cuePoint.kind == .loop &&
                    (cuePoint.endSec ?? cuePoint.startSec) > cuePoint.startSec
            }
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

                ForEach(Array(loopOverlays.enumerated()), id: \.offset) { item in
                    let startRatio = CGFloat(item.element.startSec / trackLength)
                    let endRatio = CGFloat((item.element.endSec ?? item.element.startSec) / trackLength)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color(for: item.element).opacity(0.12))
                        .frame(
                            width: max(
                                6,
                                max(0, min(1, endRatio - startRatio)) * (proxy.size.width - (sidePadding * 2))
                            ),
                            height: proxy.size.height * 0.58
                        )
                        .offset(
                            x: sidePadding + (proxy.size.width - (sidePadding * 2)) * min(1, max(0, startRatio)),
                            y: proxy.size.height * 0.21
                        )
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
                        .frame(
                            width: item.element.kind == .loop ? 1 : 2,
                            height: item.element.kind == .loop ? proxy.size.height : proxy.size.height + 6
                        )
                        .offset(x: x)
                        .opacity(item.element.kind == .loop ? 0.55 : 0.85)
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

enum TrackCuePresentation {
    struct CueGroup: Identifiable, Equatable {
        let source: ExternalDJMetadata.Source
        let items: [CueItem]

        var id: String { source.rawValue }
    }

    struct CueItem: Identifiable, Equatable {
        let source: ExternalDJMetadata.Source
        let kind: ExternalDJCuePoint.Kind
        let kindLabel: String
        let indexLabel: String?
        let startSec: Double
        let timeText: String
        let noteText: String?
        let sourceTag: String?

        var id: String {
            [
                source.rawValue,
                kind.rawValue,
                String(format: "%.3f", startSec),
                indexLabel ?? "",
                noteText ?? "",
                sourceTag ?? ""
            ].joined(separator: "|")
        }
    }

    nonisolated static func groups(from metadata: [ExternalDJMetadata]) -> [CueGroup] {
        let entriesBySource = Dictionary(grouping: metadata, by: \.source)

        return ExternalDJMetadata.Source.allCases.compactMap { source in
            guard let entries = entriesBySource[source] else { return nil }

            var seen: Set<String> = []
            let items = entries
                .flatMap(\.cuePoints)
                .filter { cuePoint in
                    seen.insert(cueKey(for: cuePoint)).inserted
                }
                .sorted(by: cueSort)
                .map { cuePoint in
                    CueItem(
                        source: source,
                        kind: cuePoint.kind,
                        kindLabel: typeLabel(for: cuePoint.kind),
                        indexLabel: indexLabel(for: cuePoint),
                        startSec: cuePoint.startSec,
                        timeText: timeText(for: cuePoint.startSec),
                        noteText: normalizedText(cuePoint.name),
                        sourceTag: normalizedText(cuePoint.source)
                    )
                }

            return items.isEmpty ? nil : CueGroup(source: source, items: items)
        }
    }

    nonisolated static func waveformSummaryText(hasWaveformPreview: Bool, cueCount: Int) -> String {
        switch (hasWaveformPreview, cueCount > 0) {
        case (true, true):
            return "\(cueCount) cue marker\(cueCount == 1 ? "" : "s") loaded on the waveform."
        case (true, false):
            return "Waveform preview loaded. No imported cue points yet."
        case (false, true):
            return "Cue points are available, but no waveform preview was found."
        case (false, false):
            return "No waveform preview or cue points are available yet."
        }
    }

    nonisolated static func typeLabel(for kind: ExternalDJCuePoint.Kind) -> String {
        switch kind {
        case .cue:
            return "Memory Cue"
        case .hotcue:
            return "Hot Cue"
        case .loop:
            return "Loop"
        case .unknown:
            return "Cue Marker"
        }
    }

    nonisolated static func timeText(for seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }

        let totalMilliseconds = Int((seconds * 1000.0).rounded())
        let totalSeconds = totalMilliseconds / 1000
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        let milliseconds = totalMilliseconds % 1000
        return String(format: "%d:%02d.%03d", minutes, secs, milliseconds)
    }

    nonisolated private static func cueSort(lhs: ExternalDJCuePoint, rhs: ExternalDJCuePoint) -> Bool {
        if lhs.startSec == rhs.startSec {
            return (lhs.index ?? Int.max) < (rhs.index ?? Int.max)
        }
        return lhs.startSec < rhs.startSec
    }

    nonisolated private static func indexLabel(for cuePoint: ExternalDJCuePoint) -> String? {
        guard let index = cuePoint.index else { return nil }

        switch cuePoint.kind {
        case .hotcue:
            return "Slot \(index)"
        case .loop:
            return "Loop \(index)"
        case .cue, .unknown:
            return nil
        }
    }

    nonisolated private static func normalizedText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    nonisolated private static func cueKey(for cuePoint: ExternalDJCuePoint) -> String {
        [
            cuePoint.kind.rawValue,
            String(Int((cuePoint.startSec * 1000.0).rounded())),
            cuePoint.endSec.map { String(Int(($0 * 1000.0).rounded())) } ?? "",
            cuePoint.index.map(String.init) ?? "",
            normalizedText(cuePoint.name) ?? "",
            normalizedText(cuePoint.color) ?? "",
            normalizedText(cuePoint.source) ?? ""
        ].joined(separator: "|")
    }
}
