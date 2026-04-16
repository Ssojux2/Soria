import SwiftUI

struct MixAssistantView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var dismissedSelectionSignature: String?
    @State private var includeTagsText: String = ""
    @State private var excludeTagsText: String = ""
    @State private var isAdvancedScoreExpanded = true

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerTitle

                    Text(viewModel.mixAssistantMode.helperText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    GroupBox("Current Library Selection") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(viewModel.mixAssistantReferenceLabel)
                                .font(.headline)

                            Text(viewModel.selectionReadiness.referenceSummaryText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            if viewModel.mixAssistantSelectionChips.isEmpty {
                                Text("Select one or more tracks in the library to use them as the current reference.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                chipWrap(viewModel.mixAssistantSelectionChips)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if shouldShowSelectionReadinessBanner {
                        SelectionReadinessBanner(
                            readiness: viewModel.selectionReadiness,
                            canAnalyzePending: viewModel.canAnalyzePendingSelection,
                            onAnalyzePending: {
                                dismissedSelectionSignature = nil
                                viewModel.analyzePendingSelection()
                            },
                            onContinueWithReady: {
                                dismissedSelectionSignature = viewModel.selectionReadiness.signature
                            },
                            onReviewSelection: {
                                dismissedSelectionSignature = nil
                                viewModel.reviewSelectedTracks()
                            }
                        )
                    }

                    if let dependencyMessage = viewModel.selectedEmbeddingProfileDependencyMessage {
                        Text(dependencyMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if !viewModel.hasValidatedEmbeddingProfile {
                        Text("Validate the active analysis setup in Settings before running mixset actions.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    buildMixsetPanel
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            hydrateTagEditorsFromConstraints()
        }
        .onChange(of: viewModel.selectionReadiness.signature) { _, newValue in
            if dismissedSelectionSignature != newValue {
                dismissedSelectionSignature = nil
            }
        }
        .onChange(of: viewModel.constraints.includeTags) { _, newValue in
            let joined = newValue.joined(separator: ", ")
            if includeTagsText != joined {
                includeTagsText = joined
            }
        }
        .onChange(of: viewModel.constraints.excludeTags) { _, newValue in
            let joined = newValue.joined(separator: ", ")
            if excludeTagsText != joined {
                excludeTagsText = joined
            }
        }
        .overlay(alignment: .topLeading) {
            AccessibilityMarker(identifier: "mix-assistant-info-view", label: "Mix Assistant Info")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mix-assistant-info-view")
    }

    private var shouldShowSelectionReadinessBanner: Bool {
        viewModel.selectionReadiness.hasPendingTracks
            && dismissedSelectionSignature != viewModel.selectionReadiness.signature
    }

    private var headerTitle: some View {
        Text("Mix Assistant")
            .font(.title2.bold())
    }

    private var buildMixsetPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    recommendationQueryField
                    resultLimitStepper
                    recommendationActions
                }

                VStack(alignment: .leading, spacing: 12) {
                    recommendationQueryField
                    resultLimitStepper
                    recommendationActions
                }
            }

            LibraryScopeFilterSection(
                viewModel: viewModel,
                target: .recommendation,
                title: "DJ Scope",
                initiallyExpanded: false,
                accessibilityIdentifier: "recommendation-dj-scope-summary"
            )

            advancedScoreControls

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
                    let preview = row.mixabilityTags.prefix(3).joined(separator: ", ")
                    Text(preview.isEmpty ? "-" : preview)
                }
            }
            .frame(minHeight: 220, idealHeight: 260, maxHeight: 320)
            .accessibilityIdentifier("recommendations-results-table")

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
                        Divider()
                        vectorBreakdownSection(
                            breakdown: selectedRecommendation.vectorBreakdown,
                            bestMatch: collectionDisplayName(selectedRecommendation.vectorBreakdown.bestMatchedCollection)
                        )
                        if !selectedRecommendation.matchedMemberships.isEmpty {
                            detailLine(
                                "Matched Scope",
                                selectedRecommendation.matchedMemberships.joined(separator: " • ")
                            )
                        }
                        if !selectedRecommendation.mixabilityTags.isEmpty {
                            detailLine("Tags", selectedRecommendation.mixabilityTags.joined(separator: ", "))
                        }
                        if !selectedRecommendation.matchReasons.isEmpty {
                            Text(selectedRecommendation.matchReasons.joined(separator: " • "))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if let scoreSessionID = selectedRecommendation.scoreSessionID {
                            Text("Score session \(scoreSessionID.uuidString.prefix(8))")
                                .font(.caption)
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
            .frame(minHeight: 140, idealHeight: 160, maxHeight: 220)
            .accessibilityIdentifier("recommendations-playlist-list")
        }
    }

    private var recommendationActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                if shouldShowRecommendationScopeAnalyzeCTA {
                    Button("Analyze Scope") { viewModel.analyzeScopedTracks(for: .recommendation) }
                    Text("No ready tracks are available in the current mix scope yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Generate") { viewModel.generateRecommendations() }
                        .disabled(!viewModel.canRunRecommendationActions)
                    Button("Build Playlist Path") { viewModel.buildPlaylistPath() }
                        .disabled(!viewModel.canRunRecommendationActions)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                if shouldShowRecommendationScopeAnalyzeCTA {
                    Button("Analyze Scope") { viewModel.analyzeScopedTracks(for: .recommendation) }
                    Text("No ready tracks are available in the current mix scope yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Generate") { viewModel.generateRecommendations() }
                        .disabled(!viewModel.canRunRecommendationActions)
                    Button("Build Playlist Path") { viewModel.buildPlaylistPath() }
                        .disabled(!viewModel.canRunRecommendationActions)
                }
            }
        }
    }

    private var recommendationQueryField: some View {
        TextField("Describe the mix vibe or transition you want", text: $viewModel.recommendationQueryText)
            .textFieldStyle(.roundedBorder)
    }

    private var resultLimitStepper: some View {
        Stepper(
            "Results \(viewModel.recommendationResultLimit)",
            value: $viewModel.recommendationResultLimit,
            in: RecommendationInputState.minimumResultLimit...RecommendationInputState.maximumResultLimit
        )
        .frame(width: 180, alignment: .leading)
    }

    private var advancedScoreControls: some View {
        GroupBox {
            DisclosureGroup("Advanced Score Controls", isExpanded: $isAdvancedScoreExpanded) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Final and embedding weights are normalized automatically when scoring.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Final Score Weights")
                            .font(.headline)
                        NumericSliderField(
                            title: "Embedding",
                            value: $viewModel.weights.embed,
                            range: 0...1,
                            accessibilityIdentifier: "score-weight-embedding"
                        )
                        NumericSliderField(title: "BPM", value: $viewModel.weights.bpm, range: 0...1)
                        NumericSliderField(title: "Key", value: $viewModel.weights.key, range: 0...1)
                        NumericSliderField(title: "Energy", value: $viewModel.weights.energy, range: 0...1)
                        NumericSliderField(title: "Transition", value: $viewModel.weights.introOutro, range: 0...1)
                        NumericSliderField(title: "External", value: $viewModel.weights.external, range: 0...1)
                        runtimeWeightSummary(
                            title: "Normalized Final",
                            values: [
                                ("Embed", viewModel.normalizedRecommendationWeights.embed),
                                ("BPM", viewModel.normalizedRecommendationWeights.bpm),
                                ("Key", viewModel.normalizedRecommendationWeights.key),
                                ("Energy", viewModel.normalizedRecommendationWeights.energy),
                                ("Transition", viewModel.normalizedRecommendationWeights.introOutro),
                                ("External", viewModel.normalizedRecommendationWeights.external)
                            ]
                        )
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Embedding Mix Weights")
                            .font(.headline)
                        NumericSliderField(title: "Track", value: $viewModel.vectorWeights.track, range: 0...1)
                        NumericSliderField(title: "Intro", value: $viewModel.vectorWeights.intro, range: 0...1)
                        NumericSliderField(title: "Middle", value: $viewModel.vectorWeights.middle, range: 0...1)
                        NumericSliderField(title: "Outro", value: $viewModel.vectorWeights.outro, range: 0...1)
                        runtimeWeightSummary(
                            title: "Normalized Embedding",
                            values: [
                                ("Track", viewModel.normalizedMixsetVectorWeights.track),
                                ("Intro", viewModel.normalizedMixsetVectorWeights.intro),
                                ("Middle", viewModel.normalizedMixsetVectorWeights.middle),
                                ("Outro", viewModel.normalizedMixsetVectorWeights.outro)
                            ]
                        )
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Mix Constraints")
                            .font(.headline)
                        OptionalNumericSliderField(
                            title: "BPM Min",
                            value: $viewModel.constraints.targetBPMMin,
                            range: 60...180,
                            defaultValue: viewModel.selectedTracks.first?.bpm ?? 118,
                            step: 0.5
                        )
                        OptionalNumericSliderField(
                            title: "BPM Max",
                            value: $viewModel.constraints.targetBPMMax,
                            range: 60...180,
                            defaultValue: viewModel.selectedTracks.first?.bpm ?? 128,
                            step: 0.5
                        )
                        OptionalNumericSliderField(
                            title: "Max Minutes",
                            value: $viewModel.constraints.maxDurationMinutes,
                            range: 1...20,
                            defaultValue: 8,
                            step: 0.25
                        )
                        NumericSliderField(title: "Key Strictness", value: $viewModel.constraints.keyStrictness, range: 0...1)
                        NumericSliderField(title: "Genre Continuity", value: $viewModel.constraints.genreContinuity, range: 0...1)
                        NumericSliderField(
                            title: "External Priority",
                            value: $viewModel.constraints.externalMetadataPriority,
                            range: 0...1
                        )
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Focus", selection: $viewModel.constraints.analysisFocus) {
                            Text("Any Focus").tag(Optional<AnalysisFocus>.none)
                            ForEach(AnalysisFocus.allCases) { focus in
                                Text(focus.displayName).tag(Optional(focus))
                            }
                        }
                        .frame(width: 220)

                        TextField("Include tags or text", text: $includeTagsText)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: includeTagsText) { _, newValue in
                                viewModel.constraints.includeTags = splitTags(newValue)
                            }

                        TextField("Exclude tags or text", text: $excludeTagsText)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: excludeTagsText) { _, newValue in
                                viewModel.constraints.excludeTags = splitTags(newValue)
                            }
                    }

                    HStack {
                        Button("Reset to Defaults") {
                            viewModel.resetMixsetScoringControls()
                            hydrateTagEditorsFromConstraints()
                        }
                        Spacer()
                    }
                }
                .padding(.top, 12)
            }
        }
        .accessibilityIdentifier("advanced-score-controls")
    }

    @ViewBuilder
    private func chipWrap(_ chips: [String]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(chips, id: \.self) { chip in
                    chipView(chip)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(chips, id: \.self) { chip in
                    chipView(chip)
                }
            }
        }
    }

    private func chipView(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    private func hydrateTagEditorsFromConstraints() {
        includeTagsText = viewModel.constraints.includeTags.joined(separator: ", ")
        excludeTagsText = viewModel.constraints.excludeTags.joined(separator: ", ")
    }

    private func splitTags(_ input: String) -> [String] {
        input
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var shouldShowRecommendationScopeAnalyzeCTA: Bool {
        let filter = viewModel.scopeFilter(for: .recommendation)
        let statistics = viewModel.scopeStatistics(for: .recommendation)
        return !filter.isEmpty && statistics.ready == 0 && statistics.needsPreparation > 0
    }

    private func runtimeWeightSummary(title: String, values: [(String, Double)]) -> some View {
        let summary = values
            .map { "\($0.0) \(String(format: "%.2f", $0.1))" }
            .joined(separator: " • ")

        return Text("\(title): \(summary)")
            .font(.caption)
            .foregroundStyle(.secondary)
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

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.footnote)
    }

    private func vectorBreakdownSection(
        breakdown: VectorScoreBreakdown,
        bestMatch: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            breakdownRow("Fused", breakdown.fusedScore)
            breakdownRow("Track", breakdown.trackScore)
            breakdownRow("Intro", breakdown.introScore)
            breakdownRow("Middle", breakdown.middleScore)
            breakdownRow("Outro", breakdown.outroScore)
            detailLine("Best Match", bestMatch)
        }
    }

    private func collectionDisplayName(_ collection: String) -> String {
        switch collection {
        case "tracks":
            return "Track"
        case "intro":
            return "Intro"
        case "middle":
            return "Middle"
        case "outro":
            return "Outro"
        default:
            return collection.capitalized
        }
    }
}

private struct NumericSliderField: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    var accessibilityIdentifier: String?

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 140, alignment: .leading)
            Slider(value: $value, in: range, step: step)
            TextField(
                title,
                value: $value,
                format: FloatingPointFormatStyle<Double>.number.precision(.fractionLength(2))
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
            .font(.system(.body, design: .monospaced))
        }
        .accessibilityIdentifier(accessibilityIdentifier ?? "numeric-slider-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }
}

private struct OptionalNumericSliderField: View {
    let title: String
    @Binding var value: Double?
    let range: ClosedRange<Double>
    let defaultValue: Double
    var step: Double = 0.01

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { value != nil },
            set: { enabled in
                value = enabled ? (value ?? defaultValue) : nil
            }
        )
    }

    private var resolvedValue: Binding<Double> {
        Binding(
            get: { value ?? defaultValue },
            set: { value = $0 }
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: isEnabled) {
                Text(title)
                    .frame(width: 140, alignment: .leading)
            }
            .toggleStyle(.checkbox)
            Slider(value: resolvedValue, in: range, step: step)
                .disabled(value == nil)
            TextField(
                title,
                value: resolvedValue,
                format: FloatingPointFormatStyle<Double>.number.precision(.fractionLength(2))
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 80)
            .font(.system(.body, design: .monospaced))
            .disabled(value == nil)
            Button("Clear") {
                value = nil
            }
            .disabled(value == nil)
        }
    }
}
