import SwiftUI

struct TrackDetailView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let track = viewModel.selectedTrack {
                Text(track.title)
                    .font(.title2.bold())
                Text(track.artist.isEmpty ? "Unknown artist" : track.artist)
                    .foregroundStyle(.secondary)
                Text(track.filePath)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                GroupBox("Waveform Preview") {
                    VStack(alignment: .leading, spacing: 10) {
                        WaveformPreview(
                            samples: viewModel.selectedTrackAnalysis?.waveformPreview ?? [],
                            segments: viewModel.selectedTrackSegments
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
            } else {
                ContentUnavailableView("Select a track", systemImage: "music.note.list")
            }

            Spacer()
        }
        .padding()
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

    var body: some View {
        GeometryReader { proxy in
            let values = samples.isEmpty ? Array(repeating: 0.15, count: 128) : samples
            let barWidth = max(1.0, proxy.size.width / CGFloat(max(values.count, 1)))
            let totalDuration = max(segments.map(\.endSec).max() ?? 1.0, 1.0)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.08))

                HStack(alignment: .center, spacing: 1) {
                    ForEach(Array(values.enumerated()), id: \.offset) { item in
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(0.7))
                            .frame(width: barWidth, height: max(6, proxy.size.height * item.element))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 6)

                ForEach(segments) { segment in
                    let startRatio = segment.startSec / totalDuration
                    let endRatio = segment.endSec / totalDuration
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(color(for: segment), lineWidth: 2)
                        .background(color(for: segment).opacity(0.12))
                        .frame(width: max(12, proxy.size.width * CGFloat(endRatio - startRatio)))
                        .offset(x: proxy.size.width * CGFloat(startRatio))
                }
            }
        }
    }

    private func color(for segment: TrackSegment) -> Color {
        switch segment.type {
        case .intro: return .cyan
        case .middle: return .orange
        case .outro: return .mint
        }
    }
}
