import SwiftUI

struct LibraryView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Add Folder") { viewModel.addLibraryRoot() }
                Button("Scan") { viewModel.runScan() }
                Button("Import DJ Metadata") { viewModel.loadExternalMetadata() }
                Spacer()
                Text("Tracks: \(viewModel.tracks.count)")
                    .foregroundStyle(.secondary)
            }

            Table(viewModel.tracks, selection: $viewModel.selectedTrackID) {
                TableColumn("Title", value: \.title)
                TableColumn("Artist", value: \.artist)
                TableColumn("BPM") { track in
                    Text(track.bpm.map { String(format: "%.1f", $0) } ?? "-")
                }
                TableColumn("Key") { track in
                    Text(track.musicalKey ?? "-")
                }
                TableColumn("Duration") { track in
                    Text(formatDuration(track.duration))
                }
                TableColumn("Genre", value: \.genre)
                TableColumn("Analyzed") { track in
                    Text(track.analyzedAt == nil ? "No" : "Yes")
                }
                TableColumn("Serato") { track in
                    Image(systemName: track.hasSeratoMetadata ? "checkmark.circle.fill" : "circle")
                }
                TableColumn("rekordbox") { track in
                    Image(systemName: track.hasRekordboxMetadata ? "checkmark.circle.fill" : "circle")
                }
            }
        }
        .padding()
    }

    private func formatDuration(_ sec: Double) -> String {
        let t = Int(sec)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
