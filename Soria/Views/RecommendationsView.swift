import SwiftUI

struct MixAssistantView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var dismissedSelectionSignature: String?
    @State private var similarBPMMinText: String = ""
    @State private var similarBPMMaxText: String = ""
    @State private var similarMusicalKeyText: String = ""
    @State private var similarGenreText: String = ""
    @State private var similarMaxDurationText: String = ""
    @State private var similarMixabilityTagsText: String = ""
    @State private var similarAnalysisFocus: AnalysisFocus?
    @State private var similarResultLimit: Int = 25
    @State private var mixBPMMinText: String = ""
    @State private var mixBPMMaxText: String = ""
    @State private var includeTagsText: String = ""
    @State private var excludeTagsText: String = ""
    @State private var mixMaxDurationText: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        headerTitle
                        Spacer(minLength: 12)
                        modePicker
                            .frame(width: 280)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        headerTitle
                        modePicker
                            .frame(maxWidth: 320)
                    }
                }

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
                    Text("Validate the active analysis setup in Settings before running similarity or mixset actions.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                switch viewModel.mixAssistantMode {
                case .similarTracks:
                    similarTracksPanel
                case .buildMixset:
                    buildMixsetPanel
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            hydrateMixFiltersFromConstraints()
        }
        .onChange(of: viewModel.selectionReadiness.signature) { _, newValue in
            if dismissedSelectionSignature != newValue {
                dismissedSelectionSignature = nil
            }
        }
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

    private var modePicker: some View {
        Picker("Mode", selection: $viewModel.mixAssistantMode) {
            ForEach(MixAssistantMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var similarTracksPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    TextField(
                        "Describe the sound you want, or leave empty to use the selected tracks only",
                        text: $viewModel.mixAssistantSimilarQueryText
                    )
                    .textFieldStyle(.roundedBorder)

                    Stepper("Results \(similarResultLimit)", value: $similarResultLimit, in: 10...100)
                        .frame(width: 180, alignment: .leading)

                    similarTracksButtonRow
                }

                VStack(alignment: .leading, spacing: 10) {
                    TextField(
                        "Describe the sound you want, or leave empty to use the selected tracks only",
                        text: $viewModel.mixAssistantSimilarQueryText
                    )
                    .textFieldStyle(.roundedBorder)

                    HStack {
                        Stepper("Results \(similarResultLimit)", value: $similarResultLimit, in: 10...100)
                            .frame(width: 180, alignment: .leading)
                        Spacer()
                    }

                    similarTracksButtonRow
                }
            }

            LibraryScopeFilterSection(
                viewModel: viewModel,
                target: .search,
                title: "DJ Scope",
                initiallyExpanded: false
            )

            HStack {
                TextField("BPM Min", text: $similarBPMMinText)
                    .frame(width: 80)
                TextField("BPM Max", text: $similarBPMMaxText)
                    .frame(width: 80)
                TextField("Key", text: $similarMusicalKeyText)
                    .frame(width: 80)
                TextField("Genre", text: $similarGenreText)
                    .frame(width: 120)
                TextField("Max Minutes", text: $similarMaxDurationText)
                    .frame(width: 100)
                Picker("Focus", selection: $similarAnalysisFocus) {
                    Text("Any Focus").tag(Optional<AnalysisFocus>.none)
                    ForEach(AnalysisFocus.allCases) { focus in
                        Text(focus.displayName).tag(Optional(focus))
                    }
                }
                .frame(width: 180)
                Spacer()
            }

            HStack {
                TextField("Mixability tags (comma separated)", text: $similarMixabilityTagsText)
                    .textFieldStyle(.roundedBorder)
                Spacer()
            }

            if !viewModel.searchStatusMessage.isEmpty {
                Text(viewModel.searchStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Table(viewModel.searchResults, selection: $viewModel.selectedSearchResultID) {
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
            .frame(minHeight: 240, maxHeight: 360)

            if let selectedSearchResult = viewModel.selectedSearchResult {
                GroupBox("Selected Match Breakdown") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(selectedSearchResult.track.title) - \(selectedSearchResult.track.artist)")
                            .font(.headline)
                        vectorBreakdownSection(
                            breakdown: selectedSearchResult.vectorBreakdown,
                            bestMatch: selectedSearchResult.bestMatchedCollection
                        )
                        if !selectedSearchResult.matchedMemberships.isEmpty {
                            detailLine(
                                "Matched Scope",
                                selectedSearchResult.matchedMemberships.joined(separator: " • ")
                            )
                        }
                        if let focus = selectedSearchResult.analysisFocus {
                            detailLine("Focus", focus.displayName)
                        }
                        if !selectedSearchResult.mixabilityTags.isEmpty {
                            detailLine("Tags", selectedSearchResult.mixabilityTags.joined(separator: ", "))
                        }
                        if !selectedSearchResult.matchReasons.isEmpty {
                            Text(selectedSearchResult.matchReasons.joined(separator: " • "))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if let scoreSessionID = selectedSearchResult.scoreSessionID {
                            Text("Score session \(scoreSessionID.uuidString.prefix(8))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var similarTracksButtonRow: some View {
        HStack(spacing: 8) {
            if shouldShowSimilarScopeAnalyzeCTA {
                Button("Analyze Scope") {
                    viewModel.analyzeScopedTracks(for: .search)
                }
                Text("No ready tracks are available in the current search scope yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Button(viewModel.isSearching ? "Cancel" : "Find Similar Tracks") {
                    if viewModel.isSearching {
                        viewModel.cancelSearch()
                    } else {
                        viewModel.searchSimilarTracks(
                            bpmMin: Double(similarBPMMinText),
                            bpmMax: Double(similarBPMMaxText),
                            musicalKey: similarMusicalKeyText,
                            genre: similarGenreText,
                            analysisFocus: similarAnalysisFocus,
                            mixabilityTags: splitTags(similarMixabilityTagsText),
                            maxDurationMinutes: Double(similarMaxDurationText),
                            limit: similarResultLimit
                        )
                    }
                }
                .disabled(!viewModel.isSearching && !viewModel.canRunSimilarTrackActions)
            }
        }
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
                initiallyExpanded: false
            )

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
                TextField("Min", text: $mixBPMMinText)
                    .frame(width: 60)
                TextField("Max", text: $mixBPMMaxText)
                    .frame(width: 60)
                Picker("Focus", selection: $viewModel.constraints.analysisFocus) {
                    Text("Any Focus").tag(Optional<AnalysisFocus>.none)
                    ForEach(AnalysisFocus.allCases) { focus in
                        Text(focus.displayName).tag(Optional(focus))
                    }
                }
                .frame(width: 170)
                Text("Max Minutes")
                TextField("Minutes", text: $mixMaxDurationText)
                    .frame(width: 70)
                Stepper("Path Length \(viewModel.playlistTargetCount)", value: $viewModel.playlistTargetCount, in: 2...24)
                    .frame(width: 180)
                Button("Apply Filters") {
                    viewModel.constraints.targetBPMMin = Double(mixBPMMinText)
                    viewModel.constraints.targetBPMMax = Double(mixBPMMaxText)
                    viewModel.constraints.maxDurationMinutes = Double(mixMaxDurationText)
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

    private func hydrateMixFiltersFromConstraints() {
        mixBPMMinText = viewModel.constraints.targetBPMMin.map { String(format: "%.1f", $0) } ?? ""
        mixBPMMaxText = viewModel.constraints.targetBPMMax.map { String(format: "%.1f", $0) } ?? ""
        includeTagsText = viewModel.constraints.includeTags.joined(separator: ", ")
        excludeTagsText = viewModel.constraints.excludeTags.joined(separator: ", ")
        mixMaxDurationText = viewModel.constraints.maxDurationMinutes.map { String(format: "%.1f", $0) } ?? ""
    }

    private func splitTags(_ input: String) -> [String] {
        input
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var shouldShowSimilarScopeAnalyzeCTA: Bool {
        let filter = viewModel.scopeFilter(for: .search)
        let statistics = viewModel.scopeStatistics(for: .search)
        return !filter.isEmpty && statistics.ready == 0 && statistics.needsPreparation > 0
    }

    private var shouldShowRecommendationScopeAnalyzeCTA: Bool {
        let filter = viewModel.scopeFilter(for: .recommendation)
        let statistics = viewModel.scopeStatistics(for: .recommendation)
        return !filter.isEmpty && statistics.ready == 0 && statistics.needsPreparation > 0
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
