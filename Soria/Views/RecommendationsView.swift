import SwiftUI

struct RecommendationsView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var bpmMinText: String = ""
    @State private var bpmMaxText: String = ""
    @State private var includeTagsText: String = ""
    @State private var excludeTagsText: String = ""
    @State private var maxDurationText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recommendations")
                    .font(.title2.bold())
                Spacer()
                Button("Generate") { viewModel.generateRecommendations() }
                    .disabled(!viewModel.canRunReferenceTrackFeatures)
                Button("Build Playlist Path") { viewModel.buildPlaylistPath() }
                    .disabled(!viewModel.canRunReferenceTrackFeatures)
            }

            HStack {
                Text("Key Strictness")
                Slider(value: $viewModel.constraints.keyStrictness, in: 0...1)
                    .frame(width: 140)
                Text(String(format: "%.2f", viewModel.constraints.keyStrictness))
                    .font(.system(.body, design: .monospaced))
                Text("Genre Continuity")
                Slider(value: $viewModel.constraints.genreContinuity, in: 0...1)
                    .frame(width: 140)
                Text(String(format: "%.2f", viewModel.constraints.genreContinuity))
                    .font(.system(.body, design: .monospaced))
                Toggle("Prioritize External Metadata", isOn: $viewModel.constraints.prioritizeExternalMetadata)
                    .toggleStyle(.checkbox)
                Spacer()
            }

            HStack {
                Text("BPM Range")
                TextField("Min", text: $bpmMinText)
                    .frame(width: 60)
                TextField("Max", text: $bpmMaxText)
                    .frame(width: 60)
                Picker("Focus", selection: $viewModel.constraints.analysisFocus) {
                    Text("Any Focus").tag(Optional<AnalysisFocus>.none)
                    ForEach(AnalysisFocus.allCases) { focus in
                        Text(focus.displayName).tag(Optional(focus))
                    }
                }
                .frame(width: 170)
                Text("Max Minutes")
                TextField("Minutes", text: $maxDurationText)
                    .frame(width: 70)
                Stepper("Path Length \(viewModel.playlistTargetCount)", value: $viewModel.playlistTargetCount, in: 2...24)
                    .frame(width: 180)
                Button("Apply Filters") {
                    viewModel.constraints.targetBPMMin = Double(bpmMinText)
                    viewModel.constraints.targetBPMMax = Double(bpmMaxText)
                    viewModel.constraints.maxDurationMinutes = Double(maxDurationText)
                }
                Spacer()
            }

            HStack {
                TextField("Include tags or text", text: $includeTagsText)
                    .textFieldStyle(.roundedBorder)
                TextField("Exclude tags or text", text: $excludeTagsText)
                    .textFieldStyle(.roundedBorder)
                Button("Apply Tags") {
                    viewModel.constraints.includeTags = splitTags(includeTagsText)
                    viewModel.constraints.excludeTags = splitTags(excludeTagsText)
                }
            }

            if !viewModel.recommendationStatusMessage.isEmpty {
                Text(viewModel.recommendationStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Table(viewModel.recommendations, selection: $viewModel.selectedRecommendationID) {
                TableColumn("Track") { row in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading) {
                            Text(row.track.title)
                            Text(row.track.artist)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("+") { viewModel.appendToPlaylist(row.track) }
                    }
                }
                TableColumn("Score") { row in
                    Text(String(format: "%.3f", row.score))
                }
                TableColumn("Embed") { row in Text(String(format: "%.2f", row.breakdown.embeddingSimilarity)) }
                TableColumn("BPM") { row in Text(String(format: "%.2f", row.breakdown.bpmCompatibility)) }
                TableColumn("Key") { row in Text(String(format: "%.2f", row.breakdown.harmonicCompatibility)) }
                TableColumn("Energy") { row in Text(String(format: "%.2f", row.breakdown.energyFlow)) }
                TableColumn("Transition") { row in Text(String(format: "%.2f", row.breakdown.transitionRegionMatch)) }
                TableColumn("External") { row in Text(String(format: "%.2f", row.breakdown.externalMetadataScore)) }
                TableColumn("Focus") { row in Text(row.analysisFocus?.displayName ?? "-") }
                TableColumn("Tags") { row in
                    Text(row.mixabilityTags.prefix(3).joined(separator: ", ").isEmpty ? "-" : row.mixabilityTags.prefix(3).joined(separator: ", "))
                }
            }
            .frame(minHeight: 260)

            if let selectedRecommendation = viewModel.selectedRecommendation {
                GroupBox("Selected Recommendation Breakdown") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(selectedRecommendation.track.title) - \(selectedRecommendation.track.artist)")
                            .font(.headline)
                        breakdownRow("Embedding", selectedRecommendation.breakdown.embeddingSimilarity)
                        breakdownRow("BPM", selectedRecommendation.breakdown.bpmCompatibility)
                        breakdownRow("Key", selectedRecommendation.breakdown.harmonicCompatibility)
                        breakdownRow("Energy Flow", selectedRecommendation.breakdown.energyFlow)
                        breakdownRow("Transition", selectedRecommendation.breakdown.transitionRegionMatch)
                        breakdownRow("External", selectedRecommendation.breakdown.externalMetadataScore)
                        if !selectedRecommendation.matchReasons.isEmpty {
                            Text(selectedRecommendation.matchReasons.joined(separator: " • "))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()

            HStack {
                Text("Playlist Queue (\(viewModel.playlistTracks.count))")
                    .font(.headline)
                Spacer()
                Button("Clear") { viewModel.clearPlaylist() }
                    .disabled(viewModel.playlistTracks.isEmpty)
            }

            List(viewModel.playlistTracks) { track in
                HStack {
                    VStack(alignment: .leading) {
                        Text(track.title)
                        Text(track.artist)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove") { viewModel.removeFromPlaylist(track.id) }
                }
            }
        }
        .padding()
        .onAppear {
            bpmMinText = viewModel.constraints.targetBPMMin.map { String(format: "%.1f", $0) } ?? ""
            bpmMaxText = viewModel.constraints.targetBPMMax.map { String(format: "%.1f", $0) } ?? ""
            includeTagsText = viewModel.constraints.includeTags.joined(separator: ", ")
            excludeTagsText = viewModel.constraints.excludeTags.joined(separator: ", ")
            maxDurationText = viewModel.constraints.maxDurationMinutes.map { String(format: "%.1f", $0) } ?? ""
        }
        .accessibilityIdentifier("recommendations-info-view")
    }

    private func splitTags(_ input: String) -> [String] {
        input
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func breakdownRow(_ label: String, _ value: Double) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%.3f", value))
                .font(.system(.body, design: .monospaced))
        }
    }
}
