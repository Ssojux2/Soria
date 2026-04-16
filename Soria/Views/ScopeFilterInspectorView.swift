import SwiftUI

struct ScopeFilterInspectorView: View {
    @ObservedObject var viewModel: AppViewModel
    let target: ScopeFilterTarget

    @State private var seratoSearchText: String = ""
    @State private var rekordboxSearchText: String = ""
    @State private var isSeratoExpanded = false
    @State private var isRekordboxExpanded = false

    private let collapsedFacetLimit = 8

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection

                    ScopeStatisticsStrip(
                        statistics: viewModel.scopeStatistics(for: target),
                        coverageText: coverageText
                    )

                    Text("Selections use union matching across Serato crates and rekordbox playlists.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    facetSection(
                        title: "Serato Crates",
                        source: .serato,
                        searchText: $seratoSearchText
                    )

                    facetSection(
                        title: "rekordbox Playlists",
                        source: .rekordbox,
                        searchText: $rekordboxSearchText
                    )
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Divider()

            actionRow
                .padding()
                .background(.regularMaterial)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("scope-filter-inspector-\(target.rawValue)")
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(headerTitle)
                .font(.title3.bold())

            Text(viewModel.scopeSummary(for: target))
                .font(.footnote)
                .foregroundStyle(.secondary)

            if activeChipLabels.isEmpty {
                Text("No scope filters are active yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                chipWrap(activeChipLabels)
            }
        }
    }

    private var headerTitle: String {
        switch target {
        case .library:
            return "Advanced Filters"
        case .search:
            return "Search DJ Scope"
        case .recommendation:
            return "Mix Assistant DJ Scope"
        }
    }

    private var coverageText: String {
        let statistics = viewModel.scopeStatistics(for: target)
        return "Serato \(statistics.seratoCoverage) • rekordbox \(statistics.rekordboxCoverage)"
    }

    private var activeChipLabels: [String] {
        viewModel.selectedScopeChipLabels(for: target)
    }

    @ViewBuilder
    private func facetSection(
        title: String,
        source: ExternalDJMetadata.Source,
        searchText: Binding<String>
    ) -> some View {
        let allFacets = viewModel.membershipFacets(for: source)
        let query = searchText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredFacets = facets(allFacets, matching: query)
        let isExpanded = isFacetSectionExpanded(for: source)
        let visibleFacets = visibleFacets(filteredFacets, for: source, query: query)

        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if allFacets.count >= 15 {
                    TextField(searchFieldPlaceholder(for: source), text: searchText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("scope-filter-search-\(source.rawValue)")
                }

                if visibleFacets.isEmpty {
                    Text(emptyStateMessage(for: source, query: query))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(visibleFacets) { facet in
                            facetToggle(facet, source: source)
                        }
                    }
                }

                if query.isEmpty, filteredFacets.count > collapsedFacetLimit {
                    Button(isExpanded ? "Show Less" : "Show All \(filteredFacets.count)") {
                        toggleFacetExpansion(for: source)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .accessibilityIdentifier("scope-filter-show-all-\(source.rawValue)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text("\(filteredFacets.count)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func facetToggle(_ facet: MembershipFacet, source: ExternalDJMetadata.Source) -> some View {
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
        .accessibilityIdentifier(facetAccessibilityIdentifier(for: facet, source: source))
    }

    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                actionButtons
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                actionButtons
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button(target == .library ? "Clear Filters" : "Clear Scope") {
            viewModel.clearScope(for: target)
        }
        .disabled(viewModel.scopeFilter(for: target).isEmpty)

        if target != .library {
            Button("Use Library Filter") {
                viewModel.copyLibraryScope(to: target)
            }
        }

        Button("Close") {
            viewModel.closeScopeInspector()
        }
    }

    private func facets(_ facets: [MembershipFacet], matching query: String) -> [MembershipFacet] {
        guard !query.isEmpty else { return facets }
        return facets.filter { facet in
            facet.displayName.localizedCaseInsensitiveContains(query)
                || facet.membershipPath.localizedCaseInsensitiveContains(query)
                || (facet.parentPath?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func visibleFacets(
        _ facets: [MembershipFacet],
        for source: ExternalDJMetadata.Source,
        query: String
    ) -> [MembershipFacet] {
        if query.isEmpty, !isFacetSectionExpanded(for: source) {
            return Array(facets.prefix(collapsedFacetLimit))
        }
        return facets
    }

    private func toggleFacetExpansion(for source: ExternalDJMetadata.Source) {
        switch source {
        case .serato:
            isSeratoExpanded.toggle()
        case .rekordbox:
            isRekordboxExpanded.toggle()
        }
    }

    private func isFacetSectionExpanded(for source: ExternalDJMetadata.Source) -> Bool {
        switch source {
        case .serato:
            return isSeratoExpanded
        case .rekordbox:
            return isRekordboxExpanded
        }
    }

    private func searchFieldPlaceholder(for source: ExternalDJMetadata.Source) -> String {
        switch source {
        case .serato:
            return "Search Serato crates"
        case .rekordbox:
            return "Search rekordbox playlists"
        }
    }

    private func emptyStateMessage(for source: ExternalDJMetadata.Source, query: String) -> String {
        if !query.isEmpty {
            return "No filters matched \"\(query)\"."
        }

        switch source {
        case .serato:
            return "No Serato crates are synced yet."
        case .rekordbox:
            return "No rekordbox playlists are synced yet. Try Sync Libraries, or import a Rekordbox XML file to attach playlists to indexed tracks."
        }
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

    private func facetAccessibilityIdentifier(
        for facet: MembershipFacet,
        source: ExternalDJMetadata.Source
    ) -> String {
        "scope-filter-facet-\(source.rawValue)-\(sanitizedAccessibilityToken(facet.membershipPath))"
    }

    private func sanitizedAccessibilityToken(_ rawValue: String) -> String {
        let lowered = rawValue.lowercased()
        let collapsed = lowered.replacingOccurrences(
            of: "[^a-z0-9]+",
            with: "-",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
