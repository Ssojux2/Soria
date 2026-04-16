import SwiftUI

struct LibraryView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 10) {
                libraryControlsPanel(maxHeight: controlsPanelHeight(for: proxy.size.height))
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 96,
                        idealHeight: controlsPanelIdealHeight(for: proxy.size.height),
                        maxHeight: controlsPanelHeight(for: proxy.size.height),
                        alignment: .top
                    )

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
        .accessibilityIdentifier("library-view")
    }

    private var libraryTracksTable: some View {
        ZStack {
            Table(viewModel.filteredTracks, selection: viewModel.libraryTableSelection) {
                TableColumn("Title", value: \.title)
                TableColumn("Artist", value: \.artist)
                TableColumn("BPM / Key") { track in
                    Text(bpmKeySummary(for: track))
                        .foregroundStyle(.secondary)
                }
                TableColumn("Status") { track in
                    statusBadge(for: track)
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library-table")
    }

    private func libraryControlsPanel(maxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Filter")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

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
                title: "Advanced Filters",
                initiallyExpanded: false
            )
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            HStack(spacing: 2) {
                AccessibilityMarker(identifier: "library-filter-control", label: "Library Filter Control")
                AccessibilityMarker(identifier: "library-advanced-filters", label: "Library Advanced Filters")
            }
        }
    }

    private func controlsPanelIdealHeight(for availableHeight: CGFloat) -> CGFloat {
        min(max(availableHeight * 0.14, 104), 140)
    }

    private func controlsPanelHeight(for availableHeight: CGFloat) -> CGFloat {
        min(max(availableHeight * 0.18, 124), 168)
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

            if viewModel.scopeFilter(for: target).isEmpty {
                Text("Selections use union matching across Serato crates and rekordbox playlists.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Applied filters stay active until you clear them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var openFiltersButton: some View {
        Button(openFiltersButtonTitle) {
            viewModel.openScopeInspector(for: target)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("scope-filter-open-\(target.rawValue)")
    }

    private var openFiltersButtonTitle: String {
        if viewModel.isScopeInspectorPresented, viewModel.activeScopeInspectorTarget == target {
            return target == .library ? "Hide Filters" : "Hide Scope"
        }

        return viewModel.scopeFilter(for: target).isEmpty ? "Open Filters" : "Edit Filters"
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
