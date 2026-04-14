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

            Text("Semantic search uses the active embedding profile. Reference mode searches from the currently selected analyzed track.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                TextField(viewModel.searchMode.queryPlaceholder, text: $queryText)
                .textFieldStyle(.roundedBorder)
                .disabled(!viewModel.searchMode.isQueryEditable)

                Button(viewModel.isSearching ? "Searching..." : "Search") {
                    viewModel.searchTracks(
                        queryText: queryText,
                        bpmMin: Double(bpmMinText),
                        bpmMax: Double(bpmMaxText),
                        musicalKey: musicalKeyText,
                        genre: genreText,
                        maxDurationMinutes: Double(maxDurationText)
                    )
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
                if let selectedTrack = viewModel.selectedTrack {
                    HStack {
                        Text("Reference: \(selectedTrack.title) - \(selectedTrack.artist)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if !selectedTrack.hasCurrentEmbedding(profileID: viewModel.embeddingProfile.id) {
                            Button("Analyze Selected Track First") {
                                viewModel.analyzeSelectedTrackForSearch()
                            }
                            .disabled(!viewModel.hasValidatedEmbeddingProfile || viewModel.isAnalyzing)
                        }
                    }
                } else {
                    Text("Select a library track to use Reference Track search.")
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
                TableColumn("Track") { row in
                    Text(String(format: "%.3f", row.trackScore))
                }
                TableColumn("Intro") { row in
                    Text(String(format: "%.3f", row.introScore))
                }
                TableColumn("Middle") { row in
                    Text(String(format: "%.3f", row.middleScore))
                }
                TableColumn("Outro") { row in
                    Text(String(format: "%.3f", row.outroScore))
                }
                TableColumn("Best Match") { row in
                    Text(row.bestMatchedCollection)
                }
                TableColumn("Queue") { row in
                    Button("+") {
                        viewModel.appendToPlaylist(row.track)
                    }
                }
            }
            .frame(minHeight: 300)

            Spacer()
        }
        .padding()
    }
}
