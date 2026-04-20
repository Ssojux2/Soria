import SwiftUI

struct ExportPlaylistQueueView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Playlist Queue")
                        .font(.title3.bold())
                    Text(queueSummaryText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Button(viewModel.normalizePlaylistQueueButtonTitle) {
                    viewModel.normalizePlaylistQueue()
                }
                .disabled(!viewModel.canNormalizePlaylistQueue)

                Button("Clear Queue") {
                    viewModel.clearPlaylist()
                }
                .disabled(!viewModel.canClearPlaylistQueue)
            }

            if let progress = viewModel.playlistQueueNormalizationProgress {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(progress.titleText)
                            .font(.footnote.weight(.semibold))
                        Spacer(minLength: 8)
                        if let fractionCompleted = progress.fractionCompleted {
                            Text("\(progress.completedSuggestedTrackCount)/\(progress.totalSuggestedTrackCount)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("\(Int((fractionCompleted * 100).rounded())) percent complete")
                        } else {
                            Text("Preparing...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let fractionCompleted = progress.fractionCompleted {
                        ProgressView(value: fractionCompleted, total: 1)
                    } else {
                        ProgressView()
                    }

                    Text(progress.detailText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if queueRows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No tracks queued for export")
                        .font(.headline)
                    Text("Build a playlist path or add tracks from Mix Assistant, then export them here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("exports-playlist-queue-empty-state")
            } else {
                Table(queueRows) {
                    TableColumn("#") { row in
                        Text("\(row.position)")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    TableColumn("Title") { row in
                        Text(row.track.title)
                    }
                    TableColumn("Artist") { row in
                        Text(row.track.artist)
                    }
                    TableColumn("BPM / Key") { row in
                        Text(bpmKeySummary(for: row.track))
                            .foregroundStyle(.secondary)
                    }
                    TableColumn("Normalization") { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(viewModel.playlistNormalizationStatusText(for: row.track))
                                .foregroundStyle(normalizationColor(for: row.track))
                            if let detail = viewModel.playlistNormalizationDetailText(for: row.track) {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    TableColumn("Action") { row in
                        Button("Remove") {
                            viewModel.removeFromPlaylist(row.track.id)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .disabled(viewModel.isNormalizingPlaylistQueue)
                    }
                }
                .accessibilityIdentifier("exports-playlist-queue-table")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            AccessibilityMarker(identifier: "exports-playlist-queue-view", label: "Exports Playlist Queue")
        }
    }

    private var queueRows: [PlaylistQueueRow] {
        viewModel.playlistTracks.enumerated().map { index, track in
            PlaylistQueueRow(position: index + 1, track: track)
        }
    }

    private var queueSummaryText: String {
        let count = viewModel.playlistTracks.count
        let baseText: String
        switch count {
        case 0:
            baseText = "The export queue is currently empty."
        case 1:
            baseText = "1 track is ready for export."
        default:
            baseText = "\(count) tracks are ready for export."
        }

        let suggestedCount = viewModel.playlistSuggestedNormalizationTrackCount
        switch suggestedCount {
        case 1:
            return "\(baseText) 1 suggested track can be normalized in the queue."
        case let count where count > 1:
            return "\(baseText) \(count) suggested tracks can be normalized in the queue."
        default:
            break
        }

        if viewModel.isInspectingPlaylistNormalization {
            return "\(baseText) Checking suggested normalization targets."
        }
        return baseText
    }

    private func bpmKeySummary(for track: Track) -> String {
        let bpm = track.bpm.map { String(format: "%.1f BPM", $0) }
        let musicalKey = track.musicalKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        var values: [String] = []
        if let bpm, !bpm.isEmpty {
            values.append(bpm)
        }
        if let musicalKey, !musicalKey.isEmpty {
            values.append(musicalKey)
        }
        return values.isEmpty ? "-" : values.joined(separator: " • ")
    }

    private func normalizationColor(for track: Track) -> Color {
        if let inspection = viewModel.playlistNormalizationInspection(for: track),
           inspection.effectiveQueueState == .needsNormalize {
            switch inspection.needTier {
            case .low:
                return .secondary
            case .medium, .high:
                return .orange
            case nil:
                break
            }
        }

        switch viewModel.playlistNormalizationState(for: track) {
        case .ready, .silent:
            return .secondary
        case .needsNormalize, .unsupported:
            return .orange
        case .failed:
            return .red
        case .normalizing:
            return .primary
        case nil:
            return .secondary
        }
    }
}

private struct PlaylistQueueRow: Identifiable {
    let position: Int
    let track: Track

    var id: UUID { track.id }
}
