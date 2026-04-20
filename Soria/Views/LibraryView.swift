import AppKit
import SwiftUI

struct LibraryView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var controlsContentHeight: CGFloat = 0
    @FocusState private var isLibrarySearchFieldFocused: Bool

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
        .onDisappear {
            viewModel.setLibrarySearchFieldFocused(false)
        }
        .onChange(of: isLibrarySearchFieldFocused) { _, isFocused in
            viewModel.setLibrarySearchFieldFocused(isFocused)
        }
    }

    private var libraryTracksTable: some View {
        ZStack {
            Table(
                viewModel.filteredTracks,
                selection: viewModel.libraryTableSelection,
                sortOrder: viewModel.libraryTrackSortOrderBinding
            ) {
                TableColumn("Title", sortUsing: LibraryTrackSortComparator(column: .title)) { track in
                    Text(track.title)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.selectTrackFromLibrary(track.id)
                        }
                        .accessibilityIdentifier("library-visible-track-\(accessibilitySlug(for: track.title))")
                }
                TableColumn("Artist", sortUsing: LibraryTrackSortComparator(column: .artist)) { track in
                    Text(track.artist)
                }
                TableColumn("BPM / Key", sortUsing: LibraryTrackSortComparator(column: .bpm)) { track in
                    Text(bpmKeySummary(for: track))
                        .foregroundStyle(.secondary)
                }
                TableColumn("Status", sortUsing: LibraryTrackSortComparator(column: .status)) { track in
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
                    .focused($isLibrarySearchFieldFocused)
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

                if viewModel.shouldShowLibraryPreviewStrip {
                    libraryPreviewStrip
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .focusable()
        .onKeyPress(.space) {
            guard viewModel.shouldHandleLibraryPreviewSpacebar else {
                return .ignored
            }

            viewModel.toggleLibraryPreview()
            return .handled
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

    private var libraryPreviewStrip: some View {
        LibraryPreviewStripView(
            previewUIState: viewModel.libraryPreviewUIState,
            waveformEnvelope: viewModel.selectedTrackWaveformEnvelope,
            fallbackSamples: viewModel.selectedTrackWaveformPreview,
            cueGroups: TrackCuePresentation.waveformCueGroups(from: viewModel.selectedTrackExternalMetadata),
            onToggle: viewModel.handleLibraryPreviewTogglePress,
            onScrub: { normalizedPosition, phase in
                viewModel.handleLibraryPreviewInteraction(
                    normalizedPosition: normalizedPosition,
                    phase: phase
                )
            },
            onCueSelected: { cueGroup in
                viewModel.seekLibraryPreview(
                    to: cueGroup.startSec,
                    autoplay: true,
                    seekKind: .cuePoint
                )
            }
        )
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

private struct LibraryPreviewStripView: View {
    @ObservedObject var previewUIState: LibraryPreviewUIState
    let waveformEnvelope: TrackWaveformEnvelope?
    let fallbackSamples: [Double]
    let cueGroups: [TrackCuePresentation.WaveformCueGroup]
    let onToggle: () -> Void
    let onScrub: (Double, LibraryPreviewInteractionPhase) -> Void
    let onCueSelected: (TrackCuePresentation.WaveformCueGroup) -> Void

    var body: some View {
        let state = previewUIState.renderedState

        HStack(alignment: .center, spacing: 10) {
            ImmediateActivationButton(
                isEnabled: state.isAvailable,
                accessibilityIdentifier: "library-preview-toggle",
                accessibilityLabel: state.isPlaying ? "Pause Preview" : "Play Preview",
                accessibilityValue: state.isPlaying ? "playing" : "paused",
                action: onToggle
            ) {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(state.isAvailable ? 0.14 : 0.08), in: Circle())
            }

            LibraryPreviewWaveformView(
                waveformEnvelope: waveformEnvelope,
                fallbackSamples: fallbackSamples,
                progress: state.progress,
                currentTimeSec: state.currentTimeSec,
                totalDurationSec: state.totalDurationSec,
                cueGroups: cueGroups,
                onScrub: onScrub,
                onCueSelected: onCueSelected
            )
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .accessibilityIdentifier("library-preview-progress")
            .animation(.linear(duration: 0.1), value: state.progress)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(previewTimeText(for: state.currentTimeSec)) / \(previewTimeText(for: state.totalDurationSec))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("library-preview-time")

                if !state.message.isEmpty {
                    Text(state.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
            .frame(minWidth: 160, alignment: .trailing)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library-preview-strip")
    }

    private func previewTimeText(for seconds: Double) -> String {
        let roundedSeconds = max(Int(seconds.rounded(.down)), 0)
        let minutes = roundedSeconds / 60
        let remainder = roundedSeconds % 60
        return String(format: "%d:%02d", minutes, remainder)
    }
}

enum PreviewPressIntentState: Equatable {
    case idle
    case armed(origin: CGPoint, location: CGPoint)
    case committed(location: CGPoint)
    case dragging(origin: CGPoint, location: CGPoint)
    case canceled
}

enum PreviewPressIntentDecision: Equatable {
    case none
    case commit(CGPoint)
    case beginDrag(CGPoint)
    case drag(CGPoint)
    case end(CGPoint)
    case cancel
}

struct PreviewPressIntentTracker {
    let movementSlop: CGFloat
    private(set) var state: PreviewPressIntentState = .idle

    init(movementSlop: CGFloat = 4) {
        self.movementSlop = movementSlop
    }

    mutating func arm(at point: CGPoint) {
        state = .armed(origin: point, location: point)
    }

    mutating func move(to point: CGPoint, within bounds: CGRect) -> PreviewPressIntentDecision {
        switch state {
        case .armed(let origin, _):
            guard bounds.contains(point) else {
                state = .canceled
                return .cancel
            }
            if movedBeyondSlop(from: origin, to: point) {
                state = .dragging(origin: origin, location: point)
                return .beginDrag(point)
            }
            state = .armed(origin: origin, location: point)
            return .none
        case .dragging(let origin, _):
            state = .dragging(origin: origin, location: point)
            return .drag(point)
        case .idle, .committed, .canceled:
            return .none
        }
    }

    mutating func commitIfPossible(within bounds: CGRect, isWindowActive: Bool) -> PreviewPressIntentDecision {
        let _ = isWindowActive
        guard case .armed(let origin, let location) = state else { return .none }
        guard bounds.contains(location), !movedBeyondSlop(from: origin, to: location) else {
            state = .canceled
            return .cancel
        }
        state = .committed(location: location)
        return .commit(location)
    }

    mutating func end(at point: CGPoint) -> PreviewPressIntentDecision {
        switch state {
        case .armed:
            state = .idle
            return .cancel
        case .committed:
            state = .idle
            return .end(point)
        case .dragging:
            state = .idle
            return .end(point)
        case .idle, .canceled:
            state = .idle
            return .none
        }
    }

    mutating func cancel() {
        state = .canceled
    }

    mutating func reset() {
        state = .idle
    }

    private func movedBeyondSlop(from origin: CGPoint, to point: CGPoint) -> Bool {
        hypot(point.x - origin.x, point.y - origin.y) > movementSlop
    }
}

private func previewInteractionDebugLog(_ message: String) {
#if DEBUG
    AppLogger.shared.info("Library preview input | \(message)")
#endif
}

private func waveformEnvelopeSignature(_ envelope: TrackWaveformEnvelope) -> Int {
    var hasher = Hasher()
    hasher.combine(envelope.durationSec.bitPattern)
    hasher.combine(envelope.binCount)
    hasher.combine(envelope.sourceVersion)
    for value in envelope.upperPeaks {
        hasher.combine(value.bitPattern)
    }
    for value in envelope.lowerPeaks {
        hasher.combine(value.bitPattern)
    }
    return hasher.finalize()
}

private func makeWaveformCGPath(
    envelope: TrackWaveformEnvelope,
    layout: LibraryPreviewWaveformLayout
) -> CGPath {
    let pointCount = min(envelope.upperPeaks.count, envelope.lowerPeaks.count)
    guard pointCount > 1 else { return CGMutablePath() }

    let centerY = layout.contentRect.midY
    let amplitude = layout.contentRect.height * 0.45

    func point(for index: Int, peak: Double) -> CGPoint {
        let normalized = CGFloat(index) / CGFloat(max(pointCount - 1, 1))
        let x = layout.contentRect.minX + (normalized * layout.contentRect.width)
        let y = centerY - CGFloat(peak) * amplitude
        return CGPoint(x: x, y: y)
    }

    let path = CGMutablePath()
    path.move(to: point(for: 0, peak: envelope.upperPeaks[0]))
    for index in 1..<pointCount {
        path.addLine(to: point(for: index, peak: envelope.upperPeaks[index]))
    }
    for index in stride(from: pointCount - 1, through: 0, by: -1) {
        path.addLine(to: point(for: index, peak: envelope.lowerPeaks[index]))
    }
    path.closeSubpath()
    return path
}

struct LibraryPreviewWaveformLayout {
    let totalWidth: CGFloat
    let totalHeight: CGFloat
    let totalDurationSec: Double
    let horizontalInset: CGFloat
    let verticalInset: CGFloat
    let cueTapHeight: CGFloat
    let cueHorizontalPadding: CGFloat
    let pointCueMinimumWidth: CGFloat

    init(
        totalWidth: CGFloat,
        totalHeight: CGFloat,
        totalDurationSec: Double,
        horizontalInset: CGFloat = 0,
        verticalInset: CGFloat = 4,
        cueTapHeight: CGFloat = 18,
        cueHorizontalPadding: CGFloat = 4,
        pointCueMinimumWidth: CGFloat = 16
    ) {
        self.totalWidth = totalWidth
        self.totalHeight = totalHeight
        self.totalDurationSec = totalDurationSec
        self.horizontalInset = horizontalInset
        self.verticalInset = verticalInset
        self.cueTapHeight = cueTapHeight
        self.cueHorizontalPadding = cueHorizontalPadding
        self.pointCueMinimumWidth = pointCueMinimumWidth
    }

    var contentRect: CGRect {
        let usableWidth = max(totalWidth - (horizontalInset * 2), 1)
        let usableHeight = max(totalHeight - (verticalInset * 2), 1)
        return CGRect(x: horizontalInset, y: verticalInset, width: usableWidth, height: usableHeight)
    }

    var interactionRect: CGRect {
        CGRect(x: contentRect.minX, y: 0, width: contentRect.width, height: totalHeight)
    }

    func clampedInteractionX(for x: CGFloat) -> CGFloat {
        min(max(x, interactionRect.minX), interactionRect.maxX)
    }

    func normalizedPosition(for x: CGFloat) -> Double {
        let rect = contentRect
        guard rect.width > 0 else { return 0 }
        let clampedX = min(max(x, rect.minX), rect.maxX)
        return Double((clampedX - rect.minX) / rect.width)
    }

    func xPosition(for timeSec: Double) -> CGFloat {
        guard totalDurationSec > 0 else { return contentRect.minX }
        let normalized = min(max(timeSec / totalDurationSec, 0), 1)
        return contentRect.minX + (contentRect.width * CGFloat(normalized))
    }

    func cueHitRect(for cueGroup: TrackCuePresentation.WaveformCueGroup, cueLineWidth: CGFloat) -> CGRect {
        let tapY = max(contentRect.minY - 1, 0)
        let tapHeight = min(max(cueTapHeight, 12), totalHeight - tapY)

        if cueGroup.isLoop {
            let startX = xPosition(for: cueGroup.startSec)
            let endX = xPosition(for: cueGroup.endSec ?? cueGroup.startSec)
            let minX = max(min(startX, endX) - cueHorizontalPadding, interactionRect.minX)
            let maxX = min(max(startX, endX) + cueHorizontalPadding, interactionRect.maxX)
            return CGRect(x: minX, y: tapY, width: max(maxX - minX, pointCueMinimumWidth), height: tapHeight)
        }

        let centerX = xPosition(for: cueGroup.startSec)
        let hitWidth = max(cueLineWidth + (cueHorizontalPadding * 2), pointCueMinimumWidth)
        let minX = max(centerX - (hitWidth / 2), interactionRect.minX)
        let maxX = min(centerX + (hitWidth / 2), interactionRect.maxX)
        return CGRect(x: minX, y: tapY, width: max(maxX - minX, pointCueMinimumWidth), height: tapHeight)
    }
}

private struct LibraryPreviewWaveformBackgroundView: NSViewRepresentable {
    let envelope: TrackWaveformEnvelope
    let layout: LibraryPreviewWaveformLayout
    let progressWidth: CGFloat

    func makeNSView(context: Context) -> LibraryPreviewWaveformBackgroundNSView {
        LibraryPreviewWaveformBackgroundNSView()
    }

    func updateNSView(_ nsView: LibraryPreviewWaveformBackgroundNSView, context: Context) {
        nsView.update(
            envelope: envelope,
            layout: layout,
            progressWidth: progressWidth
        )
    }
}

private final class LibraryPreviewWaveformBackgroundNSView: NSView {
    private let backgroundLayer = CAGradientLayer()
    private let progressTintLayer = CALayer()
    private let inactiveWaveformLayer = CAShapeLayer()
    private let activeWaveformLayer = CAShapeLayer()
    private let activeWaveformMaskLayer = CALayer()

    private var lastEnvelopeSignature: Int?
    private var lastSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        configureLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        backgroundLayer.frame = bounds
        inactiveWaveformLayer.frame = bounds
        activeWaveformLayer.frame = bounds
    }

    func update(
        envelope: TrackWaveformEnvelope,
        layout: LibraryPreviewWaveformLayout,
        progressWidth: CGFloat
    ) {
        let size = CGSize(width: layout.totalWidth, height: layout.totalHeight)
        let envelopeSignature = waveformEnvelopeSignature(envelope)
        if envelopeSignature != lastEnvelopeSignature || size != lastSize {
            let path = makeWaveformCGPath(envelope: envelope, layout: layout)
            inactiveWaveformLayer.path = path
            activeWaveformLayer.path = path
            lastEnvelopeSignature = envelopeSignature
            lastSize = size
        }

        let contentMinX = layout.contentRect.minX
        progressTintLayer.frame = CGRect(
            x: contentMinX,
            y: 0,
            width: max(progressWidth, 0),
            height: layout.totalHeight
        )
        activeWaveformMaskLayer.frame = CGRect(
            x: 0,
            y: 0,
            width: max(contentMinX + progressWidth, 0),
            height: layout.totalHeight
        )
    }

    private func configureLayers() {
        backgroundLayer.colors = [
            NSColor.secondaryLabelColor.withAlphaComponent(0.16).cgColor,
            NSColor.secondaryLabelColor.withAlphaComponent(0.09).cgColor,
        ]
        backgroundLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
        backgroundLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        layer?.addSublayer(backgroundLayer)

        progressTintLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        layer?.addSublayer(progressTintLayer)

        inactiveWaveformLayer.fillColor = NSColor.secondaryLabelColor.withAlphaComponent(0.24).cgColor
        inactiveWaveformLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(inactiveWaveformLayer)

        activeWaveformMaskLayer.backgroundColor = NSColor.white.cgColor
        activeWaveformLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.92).cgColor
        activeWaveformLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        activeWaveformLayer.mask = activeWaveformMaskLayer
        layer?.addSublayer(activeWaveformLayer)
    }
}

private struct LibraryPreviewWaveformView: View {
    let waveformEnvelope: TrackWaveformEnvelope?
    let fallbackSamples: [Double]
    let progress: Double
    let currentTimeSec: Double
    let totalDurationSec: Double
    let cueGroups: [TrackCuePresentation.WaveformCueGroup]
    let onScrub: (Double, LibraryPreviewInteractionPhase) -> Void
    let onCueSelected: (TrackCuePresentation.WaveformCueGroup) -> Void

    @State private var hoverLocationX: CGFloat?
    @State private var pressLocationX: CGFloat?

    private var resolvedEnvelope: TrackWaveformEnvelope? {
        if let waveformEnvelope, waveformEnvelope.hasRenderableData {
            return waveformEnvelope
        }
        return TrackWaveformEnvelope.fromPreview(
            fallbackSamples,
            durationSec: totalDurationSec,
            sourceVersion: TrackWaveformEnvelope.legacyPreviewSourceVersion
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let height = max(proxy.size.height, 1)
            let layout = LibraryPreviewWaveformLayout(
                totalWidth: width,
                totalHeight: height,
                totalDurationSec: totalDurationSec
            )
            let progressWidth = layout.contentRect.width * CGFloat(min(max(progress, 0), 1))
            let activeLocationX = pressLocationX ?? hoverLocationX
            let cueHitRects = cueExclusionRects(layout: layout)

            ZStack(alignment: .leading) {
                waveformBackground(layout: layout, height: height, progressWidth: progressWidth)
                    .allowsHitTesting(false)

                waveformInteractionLayer(
                    layout: layout,
                    height: height,
                    cueExclusionRects: cueHitRects
                )

                cueOverlay(layout: layout, height: height)
                    .zIndex(2)

                if totalDurationSec > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.95))
                        .frame(width: 2, height: height - 8)
                        .offset(x: max(playheadX(layout: layout) - 1, 0), y: 4)
                        .shadow(color: Color.black.opacity(0.18), radius: 1, x: 0, y: 0)
                        .allowsHitTesting(false)
                }

                if let activeLocationX {
                    Rectangle()
                        .fill(Color.white.opacity(0.45))
                        .frame(width: 1, height: height - 10)
                        .offset(x: max(min(activeLocationX, width) - 0.5, 0), y: 5)
                        .allowsHitTesting(false)
                }

                if let activeLocationX {
                    scrubBadge(
                        layout: layout,
                        locationX: activeLocationX,
                        normalizedPosition: layout.normalizedPosition(for: activeLocationX)
                    )
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 2) {
                    AccessibilityMarker(identifier: "library-preview-waveform-hit-area", label: "Preview Waveform")
                    AccessibilityMarker(
                        identifier: "library-preview-playhead",
                        label: TrackCuePresentation.timeText(for: currentTimeSec)
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func waveformBackground(
        layout: LibraryPreviewWaveformLayout,
        height: CGFloat,
        progressWidth: CGFloat
    ) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(
                LinearGradient(
                    colors: [
                        Color.secondary.opacity(0.16),
                        Color.secondary.opacity(0.09)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

        if let resolvedEnvelope {
            LibraryPreviewWaveformBackgroundView(
                envelope: resolvedEnvelope,
                layout: layout,
                progressWidth: progressWidth
            )
        } else {
            Capsule()
                .fill(Color.secondary.opacity(0.28))
                .frame(height: max(height * 0.18, 4))
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func waveformInteractionLayer(
        layout: LibraryPreviewWaveformLayout,
        height: CGFloat,
        cueExclusionRects: [CGRect]
    ) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.black.opacity(0.001))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                PreviewWaveformInteractionOverlay(
                    interactionRect: layout.interactionRect,
                    cueExclusionRects: cueExclusionRects,
                    onHoverChanged: { locationX in
                        if let locationX {
                            hoverLocationX = layout.clampedInteractionX(for: locationX)
                        } else if pressLocationX == nil {
                            hoverLocationX = nil
                        }
                    },
                    onInteraction: { phase, locationX in
                        let clampedX = layout.clampedInteractionX(for: locationX)
                        switch phase {
                        case .mouseDown:
                            pressLocationX = clampedX
                            hoverLocationX = clampedX
                        case .dragChanged:
                            pressLocationX = clampedX
                            hoverLocationX = clampedX
                        case .mouseUp:
                            pressLocationX = nil
                            hoverLocationX = clampedX
                        }

                        onScrub(
                            layout.normalizedPosition(for: clampedX),
                            phase
                        )
                    }
                )
            }
            .frame(width: layout.totalWidth, height: height)
    }

    @ViewBuilder
    private func cueOverlay(layout: LibraryPreviewWaveformLayout, height: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            ForEach(Array(cueGroups.enumerated()), id: \.offset) { entry in
                let cueGroup = entry.element
                let hitRect = cueHitRect(for: cueGroup, layout: layout)
                if cueGroup.isLoop {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(cueColor(for: cueGroup).opacity(0.24))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(cueColor(for: cueGroup).opacity(0.68), lineWidth: 1)
                        )
                        .frame(
                            width: loopWidth(for: cueGroup, layout: layout),
                            height: max(height - 14, 10)
                        )
                        .offset(x: layout.xPosition(for: cueGroup.startSec), y: 7)
                        .allowsHitTesting(false)

                    cueTapButton(for: cueGroup, index: entry.offset, hitRect: hitRect)
                } else {
                    VStack(spacing: 3) {
                        Capsule()
                            .fill(cueColor(for: cueGroup))
                            .frame(width: 8, height: 8)
                        Rectangle()
                            .fill(cueColor(for: cueGroup).opacity(0.85))
                            .frame(width: cueLineWidth(for: cueGroup), height: max(height - 18, 10))
                    }
                    .frame(width: 12, height: max(height - 10, 10), alignment: .top)
                    .offset(x: layout.xPosition(for: cueGroup.startSec) - 6, y: 5)
                    .allowsHitTesting(false)

                    cueTapButton(for: cueGroup, index: entry.offset, hitRect: hitRect)
                }
            }
        }
    }

    @ViewBuilder
    private func cueTapButton(
        for cueGroup: TrackCuePresentation.WaveformCueGroup,
        index: Int,
        hitRect: CGRect
    ) -> some View {
        Button {
            onCueSelected(cueGroup)
        } label: {
            Color.clear
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: hitRect.width, height: hitRect.height)
        .accessibilityIdentifier("library-preview-cue-\(index)")
        .help(cueGroup.tooltipText)
        .offset(x: hitRect.minX, y: hitRect.minY)
    }

    @ViewBuilder
    private func scrubBadge(
        layout: LibraryPreviewWaveformLayout,
        locationX: CGFloat,
        normalizedPosition: Double
    ) -> some View {
        let xPosition = min(
            max(locationX, layout.contentRect.minX + 26),
            max(layout.contentRect.maxX - 26, layout.contentRect.minX + 26)
        )

        Text(TrackCuePresentation.timeText(for: totalDurationSec * normalizedPosition))
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.72), in: Capsule())
            .foregroundStyle(.white)
            .offset(x: xPosition - 30, y: 4)
    }

    private func playheadX(layout: LibraryPreviewWaveformLayout) -> CGFloat {
        guard totalDurationSec > 0 else { return 0 }
        return layout.xPosition(for: currentTimeSec)
    }

    private func loopWidth(for cueGroup: TrackCuePresentation.WaveformCueGroup, layout: LibraryPreviewWaveformLayout) -> CGFloat {
        guard let endSec = cueGroup.endSec else { return 6 }
        let startX = layout.xPosition(for: cueGroup.startSec)
        let endX = layout.xPosition(for: endSec)
        return max(endX - startX, 6)
    }

    private func cueExclusionRects(layout: LibraryPreviewWaveformLayout) -> [CGRect] {
        cueGroups.map { cueHitRect(for: $0, layout: layout) }
    }

    private func cueHitRect(
        for cueGroup: TrackCuePresentation.WaveformCueGroup,
        layout: LibraryPreviewWaveformLayout
    ) -> CGRect {
        layout.cueHitRect(for: cueGroup, cueLineWidth: cueLineWidth(for: cueGroup))
    }

    private func cueColor(for cueGroup: TrackCuePresentation.WaveformCueGroup) -> Color {
        let sourceSet = Set(cueGroup.sources.map(\.source))

        switch cueGroup.kind {
        case .loop:
            return .green
        case .hotcue:
            if sourceSet.count > 1 { return .orange }
            return sourceSet.contains(.serato) ? .red : .blue
        case .cue, .unknown:
            if sourceSet.count > 1 { return .yellow }
            return sourceSet.contains(.serato) ? .pink : .teal
        }
    }

    private func cueLineWidth(for cueGroup: TrackCuePresentation.WaveformCueGroup) -> CGFloat {
        switch cueGroup.kind {
        case .hotcue:
            return 3
        case .loop:
            return 4
        case .cue, .unknown:
            return 2
        }
    }
}

private struct ImmediateActivationButton<Label: View>: View {
    let isEnabled: Bool
    let accessibilityIdentifier: String
    let accessibilityLabel: String
    let accessibilityValue: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        label()
            .overlay {
                ImmediatePressOverlay(
                    isEnabled: isEnabled,
                    onPress: action
                )
            }
            .opacity(isEnabled ? 1 : 0.72)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(accessibilityIdentifier)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
    }
}

private struct ImmediatePressOverlay: NSViewRepresentable {
    let isEnabled: Bool
    let onPress: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPress: onPress)
    }

    func makeNSView(context: Context) -> ImmediatePressView {
        let view = ImmediatePressView()
        view.isEnabled = isEnabled
        view.coordinator = context.coordinator
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: ImmediatePressView, context: Context) {
        context.coordinator.onPress = onPress
        nsView.isEnabled = isEnabled
    }

    final class Coordinator {
        var onPress: () -> Void

        init(onPress: @escaping () -> Void) {
            self.onPress = onPress
        }
    }
}

private final class ImmediatePressView: NSView {
    var isEnabled = true
    weak var coordinator: ImmediatePressOverlay.Coordinator?

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else {
            previewInteractionDebugLog("toggle mouseDown | ignored outside")
            return
        }
        previewInteractionDebugLog("toggle mouseDown | committed")
        coordinator?.onPress()
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            previewInteractionDebugLog("toggle mouseUp")
        }
    }
}

private struct PreviewWaveformInteractionOverlay: NSViewRepresentable {
    let interactionRect: CGRect
    let cueExclusionRects: [CGRect]
    let onHoverChanged: (CGFloat?) -> Void
    let onInteraction: (LibraryPreviewInteractionPhase, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            interactionRect: interactionRect,
            cueExclusionRects: cueExclusionRects,
            onHoverChanged: onHoverChanged,
            onInteraction: onInteraction
        )
    }

    func makeNSView(context: Context) -> PreviewWaveformInteractionView {
        let view = PreviewWaveformInteractionView()
        view.coordinator = context.coordinator
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: PreviewWaveformInteractionView, context: Context) {
        context.coordinator.interactionRect = interactionRect
        context.coordinator.cueExclusionRects = cueExclusionRects
        context.coordinator.onHoverChanged = onHoverChanged
        context.coordinator.onInteraction = onInteraction
    }

    final class Coordinator {
        var interactionRect: CGRect
        var cueExclusionRects: [CGRect]
        var onHoverChanged: (CGFloat?) -> Void
        var onInteraction: (LibraryPreviewInteractionPhase, CGFloat) -> Void

        init(
            interactionRect: CGRect,
            cueExclusionRects: [CGRect],
            onHoverChanged: @escaping (CGFloat?) -> Void,
            onInteraction: @escaping (LibraryPreviewInteractionPhase, CGFloat) -> Void
        ) {
            self.interactionRect = interactionRect
            self.cueExclusionRects = cueExclusionRects
            self.onHoverChanged = onHoverChanged
            self.onInteraction = onInteraction
        }
    }
}

private final class PreviewWaveformInteractionView: NSView {
    weak var coordinator: PreviewWaveformInteractionOverlay.Coordinator?
    private var trackingAreaToken: NSTrackingArea?
    private var pressTracker = PreviewPressIntentTracker()
    private var isSuppressingScrubForCue = false

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaToken {
            removeTrackingArea(trackingAreaToken)
        }

        let options: NSTrackingArea.Options = [
            .activeAlways,
            .inVisibleRect,
            .mouseEnteredAndExited,
            .mouseMoved,
            .enabledDuringMouseDrag
        ]
        let trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
        trackingAreaToken = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(for: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(for: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        coordinator?.onHoverChanged(nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHover(for: point)
        guard shouldHandleWaveformPress(at: point) else {
            isSuppressingScrubForCue = true
            previewInteractionDebugLog("waveform mouseDown | suppressed for cue")
            return
        }

        isSuppressingScrubForCue = false
        pressTracker.arm(at: point)
        previewInteractionDebugLog("waveform mouseDown | committed")
        coordinator?.onInteraction(.mouseDown, clampedX(for: point))
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHover(for: point)
        guard !isSuppressingScrubForCue else { return }

        switch pressTracker.move(to: point, within: bounds) {
        case .beginDrag(let dragPoint):
            previewInteractionDebugLog("waveform drag began")
            coordinator?.onInteraction(.dragChanged, clampedX(for: dragPoint))
        case .drag(let dragPoint):
            coordinator?.onInteraction(.dragChanged, clampedX(for: dragPoint))
        case .cancel:
            previewInteractionDebugLog("waveform drag canceled outside")
        case .none, .commit, .end:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !isSuppressingScrubForCue {
            previewInteractionDebugLog("waveform mouseUp")
            coordinator?.onInteraction(.mouseUp, clampedX(for: point))
            pressTracker.reset()
        }
        isSuppressingScrubForCue = false
    }

    private func clampedX(for point: CGPoint) -> CGFloat {
        guard let coordinator else {
            return max(min(point.x, bounds.width), 0)
        }
        return min(max(point.x, coordinator.interactionRect.minX), coordinator.interactionRect.maxX)
    }

    private func shouldHandleWaveformPress(at point: CGPoint) -> Bool {
        guard let coordinator else { return false }
        guard coordinator.interactionRect.contains(point) else { return false }
        return !coordinator.cueExclusionRects.contains { $0.contains(point) }
    }

    private func updateHover(for point: CGPoint) {
        guard let coordinator else { return }
        guard coordinator.interactionRect.contains(point) else {
            coordinator.onHoverChanged(nil)
            return
        }
        coordinator.onHoverChanged(clampedX(for: point))
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
