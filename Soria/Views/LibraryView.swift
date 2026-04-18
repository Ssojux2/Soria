import SwiftUI

struct LibraryView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var controlsContentHeight: CGFloat = 0

    private let controlsPanelMinHeight: CGFloat = 248
    private let controlsPanelMaxHeightCap: CGFloat = 460

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 12) {
                libraryControlsPanel(availableHeight: proxy.size.height)

                libraryTracksTable
                    .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            AccessibilityMarker(identifier: "library-view", label: "Library View")
        }
        .overlay(alignment: .bottomLeading) {
            librarySearchAccessibilitySummary
        }
    }

    private var libraryTracksTable: some View {
        ZStack {
            Table(viewModel.filteredTracks, selection: viewModel.libraryTableSelection) {
                TableColumn("Title") { track in
                    Text(track.title)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.selectTrackFromLibrary(track.id)
                        }
                        .accessibilityIdentifier("library-visible-track-\(accessibilitySlug(for: track.title))")
                }
                TableColumn("Artist") { track in
                    Text(track.artist)
                }
                TableColumn("BPM / Key") { track in
                    Text(bpmKeySummary(for: track))
                        .foregroundStyle(.secondary)
                }
                TableColumn("Status") { track in
                    statusBadge(for: track)
                }
            }

            if viewModel.filteredTracks.isEmpty {
                if !viewModel.trimmedLibrarySearchText.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No tracks matched \"\(viewModel.trimmedLibrarySearchText)\"")
                            .font(.headline)
                            .accessibilityIdentifier(
                                "library-search-empty-message-\(accessibilitySlug(for: viewModel.trimmedLibrarySearchText))"
                            )
                        Text("Try a different title or artist search.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("library-search-empty-state")
                } else if viewModel.tracks.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "music.note.list")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No tracks are loaded yet.")
                            .font(.headline)
                        Text("Start with Library Setup or scan your Music Folders to populate the library.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("library-empty-state")
                }
            }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 2) {
                AccessibilityMarker(identifier: "library-table", label: "Library Table")
                AccessibilityMarker(identifier: "library-column-title", label: "Title Column")
                AccessibilityMarker(identifier: "library-column-artist", label: "Artist Column")
                AccessibilityMarker(identifier: "library-column-bpm-key", label: "BPM and Key Column")
                AccessibilityMarker(identifier: "library-column-status", label: "Status Column")
            }
        }
    }

    private var librarySearchAccessibilitySummary: some View {
        VStack(spacing: 0) {
            AccessibilityMarker(
                identifier: "library-visible-track-count",
                label: "\(viewModel.filteredTracks.count)"
            )

            AccessibilityMarker(
                identifier: "library-visible-track-titles",
                label: viewModel.filteredTracks.map(\.title).joined(separator: "|")
            )

            if !viewModel.trimmedLibrarySearchText.isEmpty {
                AccessibilityMarker(
                    identifier: "library-search-query",
                    label: viewModel.trimmedLibrarySearchText
                )
            }
        }
        .frame(width: 1, height: 1, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func libraryControlsPanel(availableHeight: CGFloat) -> some View {
        let maxHeight = controlsPanelMaxHeight(for: availableHeight)
        let measuredHeight = max(controlsContentHeight, controlsPanelMinHeight)
        let resolvedHeight = min(measuredHeight, maxHeight)
        let showsScrollIndicators = measuredHeight > maxHeight + 1

        return ScrollView(.vertical, showsIndicators: showsScrollIndicators) {
            libraryControlsContent
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background {
                    GeometryReader { contentProxy in
                        Color.clear.preference(
                            key: LibraryControlPanelHeightPreferenceKey.self,
                            value: contentProxy.size.height
                        )
                    }
                }
        }
        .scrollDisabled(!showsScrollIndicators)
        .onPreferenceChange(LibraryControlPanelHeightPreferenceKey.self) { newHeight in
            guard abs(newHeight - controlsContentHeight) > 0.5 else { return }
            controlsContentHeight = newHeight
        }
        .frame(
            maxWidth: .infinity,
            minHeight: resolvedHeight,
            idealHeight: resolvedHeight,
            maxHeight: resolvedHeight,
            alignment: .topLeading
        )
    }

    private var libraryControlsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            libraryActionBar

            if viewModel.shouldShowLibrarySetupPrompt {
                librarySetupPrompt
            }

            if viewModel.shouldShowLibraryAnalysisProgress {
                libraryAnalysisProgressCard
            } else {
                libraryFeedbackBanner
            }

            Text("Search")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search title or artist", text: $viewModel.librarySearchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Library Search")
                    .accessibilityIdentifier("library-search-field")

                if !viewModel.librarySearchText.isEmpty {
                    Button {
                        viewModel.librarySearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }

            Picker("Filter", selection: $viewModel.libraryTrackFilter) {
                ForEach(LibraryTrackFilter.allCases) { filter in
                    Text("\(filter.displayName) (\(viewModel.libraryTrackCount(for: filter)))")
                        .tag(filter)
                }
            }
            .pickerStyle(.segmented)

            LibraryScopeFilterSection(
                viewModel: viewModel,
                target: .library,
                title: "Vendor References",
                initiallyExpanded: false
            )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            HStack(spacing: 2) {
                AccessibilityMarker(identifier: "library-filter-control", label: "Library Filter Control")
                AccessibilityMarker(identifier: "library-advanced-filters", label: "Library Vendor References")
            }
        }
    }

    private func controlsPanelMaxHeight(for availableHeight: CGFloat) -> CGFloat {
        min(max(availableHeight * 0.5, 280), controlsPanelMaxHeightCap)
    }

    private var libraryActionBar: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        librarySelectionSummary
                        Spacer(minLength: 12)
                        libraryActionButtons
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        librarySelectionSummary
                        libraryActionButtons
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("library-action-bar")
    }

    private var librarySelectionSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Current Selection")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(librarySelectionHeadline)
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("library-selection-headline")

            Text(viewModel.librarySelectionStatusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("library-selection-summary")
        }
    }

    private var libraryActionButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                analyzeSelectionButton
                recommendationSearchButton
            }

            VStack(alignment: .leading, spacing: 8) {
                analyzeSelectionButton
                recommendationSearchButton
            }
        }
    }

    private var analyzeSelectionButton: some View {
        Button("Analyze Selection") {
            viewModel.analyzePendingSelection()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!viewModel.canAnalyzeSelectionFromLibrary)
        .accessibilityIdentifier("library-analyze-selection-button")
    }

    private var recommendationSearchButton: some View {
        Button("Recommendation Search") {
            viewModel.openRecommendationSearchFromLibrary()
        }
        .buttonStyle(.bordered)
        .disabled(!viewModel.canOpenRecommendationSearchFromLibrary)
        .accessibilityIdentifier("library-recommendation-search-button")
    }

    private var librarySetupPrompt: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(viewModel.librarySetupPromptTitle)
                    .font(.headline)

                Text(viewModel.librarySetupPromptMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(viewModel.librarySetupPromptActionTitle) {
                    viewModel.handleLibrarySetupPromptAction()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("library-setup-button")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("library-setup-card")
    }

    private var libraryAnalysisProgressCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        analysisProgressSummary
                        Spacer(minLength: 12)
                        cancelAnalysisButton
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        analysisProgressSummary
                        cancelAnalysisButton
                    }
                }

                if let progress = viewModel.analysisSessionProgress?.overallProgress {
                    HStack(spacing: 10) {
                        ProgressView(value: progress, total: 1)
                            .accessibilityIdentifier("library-inline-analysis-progress")

                        Text("\(Int(progress * 100))%")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView()
                        .accessibilityIdentifier("library-inline-analysis-progress")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("library-inline-analysis-card")
    }

    @ViewBuilder
    private var libraryFeedbackBanner: some View {
        if let notice = viewModel.preparationNotice {
            libraryNoticeBanner(
                title: noticeTitle(for: notice.kind),
                message: notice.message,
                kind: notice.kind,
                showsDismissButton: true
            )
        } else if let errorMessage = viewModel.friendlyPreparationError {
            libraryNoticeBanner(
                title: "Analysis Needs Attention",
                message: errorMessage,
                kind: .failed,
                showsDismissButton: false
            )
        }
    }

    private var analysisProgressSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(viewModel.isCancellingAnalysis ? "Stopping Analysis" : "Analyzing Selection")
                .font(.headline)

            Text(libraryAnalysisStatusLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let latestMessage = libraryAnalysisLatestMessage, latestMessage != libraryAnalysisStatusLine {
                Text(latestMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var cancelAnalysisButton: some View {
        Button(viewModel.isCancellingAnalysis ? "Cancelling..." : "Cancel") {
            viewModel.cancelAnalysis()
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .disabled(viewModel.isCancellingAnalysis)
        .accessibilityIdentifier("library-cancel-button")
    }

    private func libraryNoticeBanner(
        title: String,
        message: String,
        kind: PreparationNoticeKind,
        showsDismissButton: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: noticeIcon(for: kind))
                .foregroundStyle(noticeForegroundColor(for: kind))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(noticeForegroundColor(for: kind))

                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if showsDismissButton {
                Button {
                    viewModel.dismissPreparationNotice()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(noticeForegroundColor(for: kind).opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library-preparation-notice")
    }

    private var librarySelectionHeadline: String {
        switch viewModel.selectionReadiness.selectedCount {
        case 0:
            return "No tracks selected"
        case 1:
            return "1 track selected"
        default:
            return "\(viewModel.selectionReadiness.selectedCount) tracks selected"
        }
    }

    private var libraryAnalysisStatusLine: String {
        let candidates = [
            viewModel.analysisSessionProgress?.statusLine,
            viewModel.analysisQueueProgressText,
            viewModel.analysisActivity?.currentTrackTitle
        ]

        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return "Preparing tracks for the active analysis setup."
    }

    private var libraryAnalysisLatestMessage: String? {
        let candidates = [
            viewModel.analysisSessionProgress?.latestMessage,
            viewModel.analysisActivity?.currentMessage
        ]

        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return nil
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

    @ViewBuilder
    private func statusBadge(for track: Track) -> some View {
        let transient = viewModel.analysisStatusIsTransient(for: track)
        let label = viewModel.analysisStatusText(for: track)
        let workflowStatus = viewModel.trackWorkflowStatus(for: track)
        let foreground: Color = transient ? .blue : foregroundColor(for: workflowStatus)
        let background: Color = transient ? .blue.opacity(0.14) : foreground.opacity(0.14)

        Text(label)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .lineLimit(1)
    }

    private func foregroundColor(for status: TrackWorkflowStatus) -> Color {
        switch status {
        case .ready:
            return .green
        case .needsAnalysis:
            return .orange
        case .needsRefresh:
            return .yellow
        }
    }

    private func noticeTitle(for kind: PreparationNoticeKind) -> String {
        switch kind {
        case .canceled:
            return "Analysis Canceled"
        case .failed:
            return "Analysis Needs Attention"
        case .success:
            return "Analysis Complete"
        }
    }

    private func noticeIcon(for kind: PreparationNoticeKind) -> String {
        switch kind {
        case .canceled:
            return "slash.circle"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .success:
            return "checkmark.circle.fill"
        }
    }

    private func noticeForegroundColor(for kind: PreparationNoticeKind) -> Color {
        switch kind {
        case .canceled:
            return .orange
        case .failed:
            return .red
        case .success:
            return .green
        }
    }

    private func accessibilitySlug(for text: String) -> String {
        let segments = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return segments.isEmpty ? "empty" : segments.joined(separator: "-")
    }
}

struct LibraryScopeFilterSection: View {
    @ObservedObject var viewModel: AppViewModel
    let target: ScopeFilterTarget
    let title: String
    private let accessibilityIdentifier: String?

    init(
        viewModel: AppViewModel,
        target: ScopeFilterTarget,
        title: String,
        initiallyExpanded: Bool = false,
        accessibilityIdentifier: String? = nil
    ) {
        self.viewModel = viewModel
        self.target = target
        self.title = title
        self.accessibilityIdentifier = accessibilityIdentifier
        _ = initiallyExpanded
    }

    var body: some View {
        let group = GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        summaryCopy
                        Spacer(minLength: 12)
                        openFiltersButton
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        summaryCopy
                        openFiltersButton
                    }
                }

                if !activeChipLabels.isEmpty {
                    chipWrap(activeChipLabels)
                }

                ScopeStatisticsStrip(
                    statistics: viewModel.scopeStatistics(for: target),
                    coverageText: coverageText
                )
            }
        }

        if let accessibilityIdentifier {
            group.accessibilityIdentifier(accessibilityIdentifier)
        } else {
            group
        }
    }

    private var summaryCopy: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(viewModel.scopeSummary(for: target))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.scopeFilter(for: target).isEmpty {
                Text("Optional reference filters from Serato crates and rekordbox playlists.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Reference filters stay active until you clear them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var openFiltersButton: some View {
        Button(openFiltersButtonTitle) {
            viewModel.openScopeInspector(for: target)
        }
        .buttonStyle(.bordered)
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityIdentifier("scope-filter-open-\(target.rawValue)")
    }

    private var openFiltersButtonTitle: String {
        if viewModel.isScopeInspectorPresented, viewModel.activeScopeInspectorTarget == target {
            return target == .library ? "Hide References" : "Hide References"
        }

        return viewModel.scopeFilter(for: target).isEmpty ? "Open References" : "Edit References"
    }

    private var activeChipLabels: [String] {
        let allLabels = viewModel.selectedScopeChipLabels(for: target)
        let preview = Array(allLabels.prefix(6))
        let remainingCount = allLabels.count - preview.count
        guard remainingCount > 0 else { return preview }
        return preview + ["+\(remainingCount) more"]
    }

    private var coverageText: String {
        let statistics = viewModel.scopeStatistics(for: target)
        return "Serato \(statistics.seratoCoverage) • rekordbox \(statistics.rekordboxCoverage)"
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
}

private struct LibraryControlPanelHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ScopeStatisticsStrip: View {
    let statistics: ScopedTrackStatistics
    let coverageText: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                statPill(label: "In Scope", value: "\(statistics.total)")
                statPill(label: "Ready", value: "\(statistics.ready)")
                statPill(label: "Needs Prep", value: "\(statistics.needsPreparation)")
                statPill(label: "Coverage", value: coverageText)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                statPill(label: "In Scope", value: "\(statistics.total)")
                statPill(label: "Ready", value: "\(statistics.ready)")
                statPill(label: "Needs Prep", value: "\(statistics.needsPreparation)")
                statPill(label: "Coverage", value: coverageText)
            }
        }
    }

    private func statPill(label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.semibold)
        }
        .font(.footnote)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}
