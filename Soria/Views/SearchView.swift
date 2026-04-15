import SwiftUI

struct SearchView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var queryText: String = ""
    @State private var bpmMinText: String = ""
    @State private var bpmMaxText: String = ""
    @State private var musicalKeyText: String = ""
    @State private var genreText: String = ""
    @State private var maxDurationText: String = ""
    @State private var mixabilityTagsText: String = ""
    @State private var searchAnalysisFocus: AnalysisFocus?

    var body: some View {
        let canSearch = viewModel.searchMode.canSubmit(
            validationStatus: viewModel.validationStatus,
            isBusy: viewModel.isSearching,
            queryText: queryText,
            hasReferenceTrackEmbedding: viewModel.canRunReferenceTrackFeatures
        )

        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    Text("Search")
                        .font(.title2.bold())
                    Spacer(minLength: 12)
                    searchModePicker
                        .frame(width: 260)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Search")
                        .font(.title2.bold())
                    searchModePicker
                        .frame(maxWidth: 320)
                }
            }

            Text("Semantic search uses the active embedding profile. Reference mode searches from selected tracks.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    searchQueryField
                    searchButton(canSearch: canSearch)
                }

                VStack(alignment: .leading, spacing: 12) {
                    searchQueryField
                    HStack {
                        searchButton(canSearch: canSearch)
                        Spacer()
                    }
                }
            }
            .layoutPriority(1)

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
                Picker("Focus", selection: $searchAnalysisFocus) {
                    Text("Any Focus").tag(Optional<AnalysisFocus>.none)
                    ForEach(AnalysisFocus.allCases) { focus in
                        Text(focus.displayName).tag(Optional(focus))
                    }
                }
                .frame(width: 180)
                Spacer()
            }

            HStack {
                TextField("Mixability tags (comma separated)", text: $mixabilityTagsText)
                    .textFieldStyle(.roundedBorder)
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
                TableColumn("Focus") { row in
                    Text(row.analysisFocus?.displayName ?? "-")
                }
                TableColumn("Tags") { row in
                    Text(row.mixabilityTags.prefix(3).joined(separator: ", ").isEmpty ? "-" : row.mixabilityTags.prefix(3).joined(separator: ", "))
                }
                TableColumn("Why") { row in
                    Text(row.matchReasons.joined(separator: " • "))
                        .lineLimit(2)
                }
            }
            .frame(minHeight: 220, maxHeight: .infinity)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("search-info-view")
    }

    private var searchModePicker: some View {
        Picker("Mode", selection: $viewModel.searchMode) {
            ForEach(SearchMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var searchQueryField: some View {
        TextField(viewModel.searchMode.queryPlaceholder, text: $queryText)
            .textFieldStyle(.roundedBorder)
            .disabled(!viewModel.searchMode.isQueryEditable)
    }

    private func searchButton(canSearch: Bool) -> some View {
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
                    analysisFocus: searchAnalysisFocus,
                    mixabilityTags: splitTags(mixabilityTagsText),
                    maxDurationMinutes: Double(maxDurationText)
                )
            }
        }
        .disabled(!canSearch)
    }

    private func splitTags(_ input: String) -> [String] {
        input
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
