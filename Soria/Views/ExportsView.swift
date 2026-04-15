import SwiftUI

struct ExportsView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exports").font(.title2.bold())
            Text("Playlist items ready: \(viewModel.playlistTracks.count)")
                .foregroundStyle(.secondary)

            Picker("Format", selection: $viewModel.selectedExportFormat) {
                ForEach(ExportFormat.allCases) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            .pickerStyle(.segmented)

            if viewModel.selectedExportFormat == .seratoSafePackage {
                Text("Non-destructive export: M3U + CSV + import guide. Direct Serato crate writes remain disabled on purpose.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Rekordbox XML playlist export with local file paths and playlist grouping.")
                    .foregroundStyle(.secondary)
            }

            Button("Export Playlist") {
                viewModel.exportPlaylist()
            }
            .disabled(viewModel.playlistTracks.isEmpty)

            Text(viewModel.exportMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
        .accessibilityIdentifier("exports-info-view")
    }
}
