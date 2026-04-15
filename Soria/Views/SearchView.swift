import SwiftUI

struct SearchView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var queryText: String = ""
    @State private var bpmMinText: String = ""
    @State private var bpmMaxText: String = ""
    @State private var musicalKeyText: String = ""
    @State private var genreText: String = ""
    @State private var maxDurationText: String = ""

    var body: some View {
        let canSearch = viewModel.searchMode.canSubmit(
            validationStatus: viewModel.validationStatus,
            isBusy: viewModel.isSearching,
            queryText: queryText,
            hasReferenceTrackEmbedding: viewModel.canRunReferenceTrackFeatures
        )

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Search")
                    .font(.title2.bold())
                Spacer()
                Picker("Mode", selection: $viewModel.searchMode) {
                    ForEach(SearchMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }

            Text("Semantic search uses the active embedding profile. Reference mode searches from selected tracks.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                TextField(viewModel.searchMode.queryPlaceholder, text: $queryText)
                .textFieldStyle(.roundedBorder)
                .disabled(!viewModel.searchMode.isQueryEditable)

                Button(viewModel.isSearching ? "Cancel" : "Search") {
                    if viewModel.isSearching {
                        viewModel.cancelSearch()
                    } else {
                        viewModel.searchTracks(
                            queryText: queryText,
                            bpmMin: Double(bpmMinText),
                            bpmMax: Double(bpmMaxText),
                            musicalKey: musicalKeyText,
                            genre: genreText,
                            maxDurationMinutes: Double(maxDurationText)
                        )
                    }
                }
                .disabled(!canSearch)
            }

            HStack {
                TextField("BPM Min", text: $bpmMinText)
                    .frame(width: 80)
                TextField("BPM Max", text: $bpmMaxText)
                    .frame(width: 80)
                TextField("Key", text: $musicalKeyText)
                    .frame(width: 80)
                TextField("Genre", text: $genreText)
                    .frame(width: 120)
                TextField("Max Minutes", text: $maxDurationText)
                    .frame(width: 100)
                Spacer()
            }

            if viewModel.searchMode == .referenceTrack {
                if !viewModel.selectedTracks.isEmpty {
                    Text("Reference tracks: \(viewModel.selectedTracks.count)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(
                        viewModel.selectedTracks
                            .prefix(3)
                            .map { "\($0.title) - \($0.artist)" }
                            .joined(separator: ", ")
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    if viewModel.selectedReferenceTracksMissingEmbeddingCount > 0 {
                        HStack {
                            Text("Some selected tracks are not analyzed for this profile yet.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("Analyze Selected Tracks First") {
                                viewModel.analyzeSelectedTracksForSearch()
                            }
                            .disabled(!viewModel.hasValidatedEmbeddingProfile || viewModel.isAnalyzing)
                        }
                    }
                } else {
                    Text("Select one or more library tracks to use reference search.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if !viewModel.searchStatusMessage.isEmpty {
                Text(viewModel.searchStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Table(viewModel.searchResults) {
                TableColumn("Track") { row in
                    VStack(alignment: .leading) {
                        Text(row.track.title)
                        Text(row.track.artist)
                            .foregroundStyle(.secondary)
                    }
                }
                TableColumn("Score") { row in
                    Text(String(format: "%.3f", row.score))
                }
                TableColumn("BPM") { row in
                    Text(row.track.bpm.map { String(format: "%.1f", $0) } ?? "-")
                }
                TableColumn("Key") { row in
                    Text(row.track.musicalKey ?? "-")
                }
                TableColumn("Genre") { row in
                    Text(row.track.genre.isEmpty ? "-" : row.track.genre)
                }
                TableColumn("Best Match") { row in
                    Text(row.bestMatchedCollection)
                }
            }
            .frame(minHeight: 300)

            Spacer()
        }
        .padding()
    }
}
