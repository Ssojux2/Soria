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

                Button("Clear Queue") {
                    viewModel.clearPlaylist()
                }
                .disabled(viewModel.playlistTracks.isEmpty)
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
                    TableColumn("Action") { row in
                        Button("Remove") {
                            viewModel.removeFromPlaylist(row.track.id)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
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
        switch count {
        case 0:
            return "The export queue is currently empty."
        case 1:
            return "1 track is ready for export."
        default:
            return "\(count) tracks are ready for export."
        }
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
}

private struct PlaylistQueueRow: Identifiable {
    let position: Int
    let track: Track

    var id: UUID { track.id }
}
