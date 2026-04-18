import SwiftUI

struct TrackDetailView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        let overview = viewModel.preparationOverview

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(for: overview)

                VStack(alignment: .leading, spacing: 4) {
                    Text(selectionHeadline)
                        .font(.headline)
                    Text(selectionDetail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                progressSection(for: overview)

                if let notice = viewModel.preparationNotice {
                    preparationNoticeBanner(notice)
                }

                if !vendorReferenceSections.isEmpty {
                    vendorReferencesSection
                }

                preparationActionRow(for: overview)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            HStack(spacing: 2) {
                AccessibilityMarker(identifier: "library-preparation-card", label: "Library Preparation")
                if let primaryAction = overview.primaryAction {
                    AccessibilityMarker(
                        identifier: preparationActionIdentifier(for: primaryAction),
                        label: primaryActionTitle(for: overview, action: primaryAction)
                    )
                }
                if let secondaryAction = overview.secondaryAction {
                    AccessibilityMarker(
                        identifier: preparationActionIdentifier(for: secondaryAction),
                        label: viewModel.preparationActionTitle(secondaryAction)
                    )
                }
                if overview.isCancellable {
                    AccessibilityMarker(identifier: "library-cancel-button", label: "Cancel")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library-preparation-card")
    }

    private var selectionHeadline: String {
        switch viewModel.selectedTracks.count {
        case 0:
            return viewModel.filteredTracks.isEmpty ? "No tracks selected" : "\(viewModel.filteredTracks.count) tracks in the current view"
        case 1:
            return viewModel.selectedTrack?.title ?? "1 track selected"
        default:
            return "\(viewModel.selectedTracks.count) tracks selected"
        }
    }

    private var selectionDetail: String {
        switch viewModel.selectedTracks.count {
        case 0:
            return viewModel.filteredTracks.isEmpty
                ? "Scan Music Folders to load tracks, then select one or more tracks to prepare."
                : "Use Cmd or Shift to select multiple tracks for preparation."
        case 1:
            let artist = viewModel.selectedTrack?.artist.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return artist.isEmpty ? viewModel.selectionReadiness.bannerMessage : artist
        default:
            return viewModel.selectedTracks
                .prefix(3)
                .map { track in
                    let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
                    return artist.isEmpty ? track.title : "\(track.title) - \(artist)"
                }
                .joined(separator: ", ")
        }
    }

    private var vendorReferenceSections: [(ExternalDJMetadata.Source, [String])] {
        ExternalDJMetadata.Source.allCases.compactMap { source in
            let references = Array(
                Set(
                    viewModel.selectedTrackExternalMetadata
                        .filter { $0.source == source }
                        .flatMap(\.playlistMemberships)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                )
            )
            .sorted()
            guard !references.isEmpty else { return nil }
            return (source, references)
        }
    }

    @ViewBuilder
    private func header(for overview: PreparationOverviewState) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Library Preparation")
                        .font(.title2.bold())
                    Text(overview.title)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                PreparationPhaseBadge(phase: overview.phase, showSuccess: overview.showSuccess)
            }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Library Preparation")
                        .font(.title2.bold())
                    Text(overview.title)
                        .foregroundStyle(.secondary)
                }

                PreparationPhaseBadge(phase: overview.phase, showSuccess: overview.showSuccess)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func progressSection(for overview: PreparationOverviewState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if overview.phase != .syncing {
                HStack(spacing: 10) {
                    if let progress = overview.progress {
                        ProgressView(value: progress, total: 1)
                            .accessibilityIdentifier("library-preparation-progress")
                    } else if overview.phase == .analyzing {
                        ProgressView()
                            .accessibilityIdentifier("library-preparation-progress")
                    }

                    if let progress = overview.progress {
                        Text("\(Int(progress * 100))%")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text(overview.message)
                .font(.footnote)
                .foregroundStyle(messageColor(for: overview.phase))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var vendorReferencesSection: some View {
        GroupBox("Vendor References") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(vendorReferenceSections, id: \.0) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.0.displayName)
                            .font(.footnote.weight(.semibold))
                        ForEach(section.1, id: \.self) { reference in
                            Text(reference)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("library-vendor-references")
    }

    @ViewBuilder
    private func preparationNoticeBanner(_ notice: PreparationNotice) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: noticeIcon(for: notice.kind))
                .foregroundStyle(noticeForegroundColor(for: notice.kind))

            VStack(alignment: .leading, spacing: 4) {
                Text(noticeTitle(for: notice.kind))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(noticeForegroundColor(for: notice.kind))
                Text(notice.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button {
                viewModel.dismissPreparationNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(noticeForegroundColor(for: notice.kind).opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library-preparation-notice")
    }

    private func messageColor(for phase: PreparationOverviewPhase) -> Color {
        switch phase {
        case .failed:
            return .red
        default:
            return .secondary
        }
    }

    private func preparationActionIdentifier(for action: PreparationOverviewAction) -> String {
        switch action {
        case .prepareSelection:
            return "library-prepare-selection-button"
        case .prepareVisible:
            return "library-prepare-visible-button"
        case .syncLibrary:
            return "library-sync-button"
        }
    }

    private func primaryActionTitle(for overview: PreparationOverviewState, action: PreparationOverviewAction) -> String {
        overview.primaryActionTitleOverride ?? viewModel.preparationActionTitle(action)
    }

    @ViewBuilder
    private func preparationActionRow(for overview: PreparationOverviewState) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                preparationActionButtons(for: overview)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 10) {
                preparationActionButtons(for: overview)
            }
        }
    }

    @ViewBuilder
    private func preparationActionButtons(for overview: PreparationOverviewState) -> some View {
        if let primaryAction = overview.primaryAction {
            Button(primaryActionTitle(for: overview, action: primaryAction)) {
                viewModel.performPreparationAction(primaryAction)
            }
            .buttonStyle(.borderedProminent)
            .disabled(overview.isPrimaryActionDisabled)
            .accessibilityIdentifier(preparationActionIdentifier(for: primaryAction))
        }

        if let secondaryAction = overview.secondaryAction {
            Button(viewModel.preparationActionTitle(secondaryAction)) {
                viewModel.performPreparationAction(secondaryAction)
            }
            .accessibilityIdentifier(preparationActionIdentifier(for: secondaryAction))
        }

        if overview.isCancellable {
            Button(viewModel.isCancellingAnalysis ? "Cancelling..." : "Cancel") {
                viewModel.cancelAnalysis()
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(viewModel.isCancellingAnalysis)
            .accessibilityIdentifier("library-cancel-button")
        }
    }

    private func noticeTitle(for kind: PreparationNoticeKind) -> String {
        switch kind {
        case .canceled:
            return "Preparation Canceled"
        case .failed:
            return "Preparation Needs Attention"
        case .success:
            return "Preparation Complete"
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
}

private struct PreparationPhaseBadge: View {
    let phase: PreparationOverviewPhase
    let showSuccess: Bool

    var body: some View {
        HStack(spacing: 6) {
            if showSuccess {
                Image(systemName: "checkmark.circle.fill")
            }
            Text(phase.badgeTitle)
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(foregroundColor)
        .background(backgroundColor, in: Capsule())
    }

    private var foregroundColor: Color {
        switch phase {
        case .idle:
            return .orange
        case .syncing:
            return .blue
        case .analyzing:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }

    private var backgroundColor: Color {
        foregroundColor.opacity(0.14)
    }
}

struct SelectionReadinessBanner: View {
    let readiness: SelectionReadiness
    let canAnalyzePending: Bool
    let onAnalyzePending: () -> Void
    let onContinueWithReady: () -> Void
    let onReviewSelection: () -> Void

    var body: some View {
        GroupBox(readiness.bannerTitle) {
            VStack(alignment: .leading, spacing: 12) {
                Text(readiness.bannerMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Prepare Missing Tracks") {
                        onAnalyzePending()
                    }
                    .disabled(!canAnalyzePending)

                    if readiness.hasReadyTracks {
                        Button("Continue With Ready Tracks") {
                            onContinueWithReady()
                        }
                    }

                    Button("Review Selection") {
                        onReviewSelection()
                    }

                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
