import SwiftUI

struct LibraryView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Library Setup") { viewModel.openInitialSetup() }
                Button("Sync Libraries") { viewModel.syncLibraries() }
                Button("Rescan Fallback Folder") { viewModel.runFallbackScan() }
                Button("Choose Fallback Folder") { viewModel.addLibraryRoot() }
                Spacer()
                Text("Sources: \(activeSourceCount)")
                    .foregroundStyle(.secondary)
                Text("Selected: \(viewModel.selectedTracks.count)")
                    .foregroundStyle(.secondary)
                Text("Showing: \(viewModel.filteredTracks.count) / \(viewModel.tracks.count)")
                    .foregroundStyle(.secondary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    Picker("Filter", selection: $viewModel.libraryTrackFilter) {
                        ForEach(LibraryTrackFilter.allCases) { filter in
                            Text("\(filter.displayName) (\(viewModel.libraryTrackCount(for: filter)))")
                                .tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)

                    Spacer(minLength: 12)

                    Text(viewModel.selectionReadiness.referenceSummaryText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Picker("Filter", selection: $viewModel.libraryTrackFilter) {
                        ForEach(LibraryTrackFilter.allCases) { filter in
                            Text(filter.displayName).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(viewModel.selectionReadiness.referenceSummaryText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            ScopeStatisticsStrip(
                statistics: viewModel.scopeStatistics(for: .library),
                coverageText: viewModel.libraryScopeSourceCoverageText
            )

            LibraryScopeFilterSection(
                viewModel: viewModel,
                target: .library,
                title: "DJ Scope",
                initiallyExpanded: true
            )

            if viewModel.selectionReadiness.hasSelection {
                GroupBox(viewModel.selectionReadiness.selectedCount > 1 ? "Selection Actions" : "Track Actions") {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            Button(viewModel.selectionReadiness.selectedCount > 1 ? "Analyze Selection" : "Analyze Track") {
                                viewModel.analyzeSelectedTracksFromLibrary()
                            }
                            .disabled(!viewModel.canRunAnalysis)

                            Button(viewModel.selectionReadiness.selectedCount > 1 ? "Find Shared Vibe" : "Find Similar Tracks") {
                                viewModel.openMixAssistant(mode: .similarTracks)
                            }

                            Button(viewModel.selectionReadiness.selectedCount > 1 ? "Start Mixset From Selection" : "Start Mixset From This Track") {
                                viewModel.openMixAssistant(mode: .buildMixset)
                            }

                            Spacer()
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Button(viewModel.selectionReadiness.selectedCount > 1 ? "Analyze Selection" : "Analyze Track") {
                                viewModel.analyzeSelectedTracksFromLibrary()
                            }
                            .disabled(!viewModel.canRunAnalysis)

                            Button(viewModel.selectionReadiness.selectedCount > 1 ? "Find Shared Vibe" : "Find Similar Tracks") {
                                viewModel.openMixAssistant(mode: .similarTracks)
                            }

                            Button(viewModel.selectionReadiness.selectedCount > 1 ? "Start Mixset From Selection" : "Start Mixset From This Track") {
                                viewModel.openMixAssistant(mode: .buildMixset)
                            }
                        }
                    }
                }
            }

            if !viewModel.libraryStatusMessage.isEmpty {
                Text(viewModel.libraryStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text("Tip: Cmd/Shift to select multiple tracks.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if viewModel.scanProgress.isRunning {
                GroupBox("Library Activity") {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(
                            value: Double(viewModel.scanProgress.scannedFiles),
                            total: Double(max(viewModel.scanProgress.totalFiles, 1))
                        )

                        Text("Scanned \(viewModel.scanProgress.scannedFiles) / \(viewModel.scanProgress.totalFiles)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if !viewModel.scanProgress.currentFile.isEmpty {
                            Text(viewModel.scanProgress.currentFile)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Table(viewModel.filteredTracks, selection: $viewModel.selectedTrackIDs) {
                TableColumn("Title", value: \.title)
                TableColumn("Artist", value: \.artist)
                TableColumn("BPM") { track in
                    Text(track.bpm.map { String(format: "%.1f", $0) } ?? "-")
                }
                TableColumn("Key") { track in
                    Text(track.musicalKey ?? "-")
                }
                TableColumn("Duration") { track in
                    Text(formatDuration(track.duration))
                }
                TableColumn("Genre", value: \.genre)
                TableColumn("Status") { track in
                    statusBadge(for: track)
                }
                TableColumn("BPM Source") { track in
                    Text(track.bpmSource?.displayName ?? "-")
                }
                TableColumn("Serato") { track in
                    Image(systemName: track.hasSeratoMetadata ? "checkmark.circle.fill" : "circle")
                }
                TableColumn("rekordbox") { track in
                    Image(systemName: track.hasRekordboxMetadata ? "checkmark.circle.fill" : "circle")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("library-view")
    }

    private var activeSourceCount: Int {
        viewModel.librarySources.filter { $0.enabled && $0.resolvedPath != nil }.count
    }

    private func formatDuration(_ sec: Double) -> String {
        let t = Int(sec)
        return String(format: "%d:%02d", t / 60, t % 60)
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
    private let initiallyExpanded: Bool
    @State private var isExpanded: Bool

    init(
        viewModel: AppViewModel,
        target: ScopeFilterTarget,
        title: String,
        initiallyExpanded: Bool = false
    ) {
        self.viewModel = viewModel
        self.target = target
        self.title = title
        self.initiallyExpanded = initiallyExpanded
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    actionRow

                    ScopeStatisticsStrip(
                        statistics: viewModel.scopeStatistics(for: target),
                        coverageText: coverageText
                    )

                    Text("Selections use union matching across Serato crates and rekordbox playlists.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            facetColumn(
                                title: "Serato Crates",
                                facets: viewModel.membershipFacets(for: .serato),
                                source: .serato
                            )
                            facetColumn(
                                title: "rekordbox Playlists",
                                facets: viewModel.membershipFacets(for: .rekordbox),
                                source: .rekordbox
                            )
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            facetColumn(
                                title: "Serato Crates",
                                facets: viewModel.membershipFacets(for: .serato),
                                source: .serato
                            )
                            facetColumn(
                                title: "rekordbox Playlists",
                                facets: viewModel.membershipFacets(for: .rekordbox),
                                source: .rekordbox
                            )
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack {
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Text(summaryText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statistics: ScopedTrackStatistics {
        viewModel.scopeStatistics(for: target)
    }

    private var coverageText: String {
        "Serato \(statistics.seratoCoverage) • rekordbox \(statistics.rekordboxCoverage)"
    }

    private var summaryText: String {
        if viewModel.scopeFilter(for: target).isEmpty {
            return "All library files"
        }
        return "\(statistics.total) tracks in scope"
    }

    @ViewBuilder
    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                if target == .library {
                    Button("Select Visible") { viewModel.selectVisibleTracks() }
                        .disabled(viewModel.filteredTracks.isEmpty)

                    Button("Analyze Visible Unprepared") {
                        viewModel.analyzeVisibleUnpreparedTracks()
                    }
                    .disabled(viewModel.filteredTracks.allSatisfy { viewModel.trackWorkflowStatus(for: $0) == .ready })
                } else {
                    Button("Use Library Filter") {
                        viewModel.copyLibraryScope(to: target)
                    }

                    if statistics.needsPreparation > 0 {
                        Button("Analyze Scope") {
                            viewModel.analyzeScopedTracks(for: target)
                        }
                    }
                }

                Button("Clear Scope") {
                    viewModel.clearScope(for: target)
                }
                .disabled(viewModel.scopeFilter(for: target).isEmpty)

                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                if target == .library {
                    Button("Select Visible") { viewModel.selectVisibleTracks() }
                        .disabled(viewModel.filteredTracks.isEmpty)

                    Button("Analyze Visible Unprepared") {
                        viewModel.analyzeVisibleUnpreparedTracks()
                    }
                    .disabled(viewModel.filteredTracks.allSatisfy { viewModel.trackWorkflowStatus(for: $0) == .ready })
                } else {
                    Button("Use Library Filter") {
                        viewModel.copyLibraryScope(to: target)
                    }

                    if statistics.needsPreparation > 0 {
                        Button("Analyze Scope") {
                            viewModel.analyzeScopedTracks(for: target)
                        }
                    }
                }

                Button("Clear Scope") {
                    viewModel.clearScope(for: target)
                }
                .disabled(viewModel.scopeFilter(for: target).isEmpty)
            }
        }
    }

    private func facetColumn(
        title: String,
        facets: [MembershipFacet],
        source: ExternalDJMetadata.Source
    ) -> some View {
        GroupBox(title) {
            if facets.isEmpty {
                Text("No \(source.displayName) memberships are synced yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(facets) { facet in
                            Toggle(
                                isOn: Binding(
                                    get: {
                                        viewModel.isMembershipSelected(
                                            facet.membershipPath,
                                            source: source,
                                            target: target
                                        )
                                    },
                                    set: { isSelected in
                                        viewModel.setMembershipSelection(
                                            isSelected,
                                            membershipPath: facet.membershipPath,
                                            source: source,
                                            target: target
                                        )
                                    }
                                )
                            ) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(facet.displayName)
                                        Spacer(minLength: 8)
                                        Text("\(facet.trackCount)")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    if let parentPath = facet.parentPath, !parentPath.isEmpty {
                                        Text(parentPath)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(.leading, CGFloat(facet.depth) * 12)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 220)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
