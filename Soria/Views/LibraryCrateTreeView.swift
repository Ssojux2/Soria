import SwiftUI

/// The left pane of the Library: everything you can scope the table to.
///
/// `soria_collections` has carried a `parent_id` hierarchy since the organizer
/// shipped and nothing ever drew it — the folders Soria built for you were
/// visible only as a count on the Plan tab. This is where they finally appear,
/// alongside the fixed scopes and the Serato/rekordbox crates that used to hide
/// in the scope inspector.
struct LibraryCrateTreeView: View {
    @ObservedObject var model: LibraryBrowserModel

    // `sheet(item:)` needs an Identifiable, and UUID is not one.
    @State private var editingCrate: EditingSmartCrate?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(model.treeSections) { section in
                    Section {
                        ForEach(visibleNodes(in: section), id: \.id) { node in
                            CrateNodeRow(
                                node: node,
                                isSelected: model.crateSelection == node.selection,
                                isExpanded: model.isExpanded(node.id),
                                onSelect: { model.selectCrate(node.selection) },
                                onToggleExpansion: { model.toggleExpansion(node.id) }
                            )
                            .contextMenu {
                                if case let .smartCrate(crateID) = node.selection {
                                    Button("Edit Rules…") { editingCrate = EditingSmartCrate(id: crateID) }
                                    Button("Delete Crate", role: .destructive) {
                                        model.deleteSmartCrate(crateID)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text(section.title)
                            .font(.caption2.weight(.semibold))
                            .textCase(.uppercase)
                            .kerning(0.6)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                            .padding(.bottom, 3)
                            .background(.bar)
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .frame(minWidth: 168, idealWidth: 208, maxWidth: 320)
        .overlay(alignment: .bottomLeading) {
            AccessibilityMarker(
                identifier: "crate-tree-node-count",
                label: "\(model.treeSections.reduce(0) { $0 + $1.nodes.count })"
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library-crate-tree")
        .sheet(item: $editingCrate) { editing in
            SmartCrateRuleBuilderView(
                crateName: model.smartCrateName(for: editing.id) ?? "Smart Crate",
                ruleSet: model.ruleSet(for: editing.id) ?? SmartCrateRuleSet(),
                tagCatalog: model.tagCatalog,
                matchCount: { model.matchCount(for: $0) },
                onSave: { ruleSet in
                    model.updateSmartCrate(editing.id, ruleSet: ruleSet)
                    editingCrate = nil
                },
                onCancel: { editingCrate = nil }
            )
        }
    }

    /// Depth-first, but stopping at any node the user has collapsed. Building the
    /// list here rather than nesting `ForEach` keeps the whole tree inside one
    /// `LazyVStack`, which matters on a library with hundreds of clusters.
    private func visibleNodes(in section: CrateTreeSection) -> [CrateTreeNode] {
        var result: [CrateTreeNode] = []

        func walk(_ nodes: [CrateTreeNode]) {
            for node in nodes {
                result.append(node)
                if node.hasChildren, model.isExpanded(node.id) {
                    walk(node.children)
                }
            }
        }

        walk(section.nodes)
        return result
    }
}

private struct CrateNodeRow: View {
    let node: CrateTreeNode
    let isSelected: Bool
    let isExpanded: Bool
    let onSelect: () -> Void
    let onToggleExpansion: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            disclosure

            if let color = node.colorLabel {
                ColorLabelDot(color: color)
            }

            Text(node.title)
                .font(.callout)
                .fontWeight(isSelected ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 6)

            Text(WorkspaceDashboardState.formatted(node.trackCount))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, CGFloat(node.depth) * 12 + 10)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("crate-node-\(accessibilitySlug(for: node.title))")
    }

    @ViewBuilder
    private var disclosure: some View {
        if node.hasChildren {
            Button(action: onToggleExpansion) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
        } else {
            Color.clear.frame(width: 10, height: 1)
        }
    }
}


private struct EditingSmartCrate: Identifiable {
    let id: UUID
}
