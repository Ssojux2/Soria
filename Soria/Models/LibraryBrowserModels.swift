import Foundation

/// The crate tree in the left pane of the Library.
///
/// `soria_collections` has carried a `parent_id` hierarchy since the organizer
/// shipped, but nothing in the app ever drew it — the folders Soria built were
/// visible only as a count on the Plan tab. This type turns that table, plus the
/// vendor membership facets and the fixed library scopes, into one navigable
/// list.
///
/// Pure and view-free, in the same shape as `WorkspaceDashboardState.make(from:)`:
/// a plain context in, a rendered tree out, so the counts and the roll-up
/// arithmetic can be tested without a database.

// MARK: - What a node points at

/// The scope a node selects. Everything downstream — the table's filter, the
/// classifier panel's target — keys off this one value.
enum CrateSelection: Equatable, Hashable {
    case allTracks
    /// Recently added and nobody has classified it yet. The pile to work through.
    case inbox
    case needsPreparation
    case collection(UUID)
    case smartCrate(UUID)
    case vendorMembership(source: ExternalDJMetadata.Source, path: String)
    case trash
}

// MARK: - Nodes

struct CrateTreeNode: Identifiable, Equatable {
    let id: String
    let title: String
    let selection: CrateSelection
    /// Indent level. Carried explicitly rather than inferred at render time so a
    /// flattened list and a nested one agree.
    let depth: Int
    let trackCount: Int
    /// Set for smart crates, which the user colours; nil elsewhere.
    let colorLabel: TrackColorLabel?
    let children: [CrateTreeNode]

    var hasChildren: Bool { !children.isEmpty }

    /// This node and every descendant, depth-first — what the view renders when
    /// the node is expanded.
    var flattened: [CrateTreeNode] {
        [self] + children.flatMap(\.flattened)
    }
}

struct CrateTreeSection: Identifiable, Equatable {
    let id: String
    let title: String
    let nodes: [CrateTreeNode]
}

// MARK: - Input

struct CrateTreeContext: Equatable {
    var totalTrackCount: Int = 0
    var inboxTrackCount: Int = 0
    var needsPreparationCount: Int = 0
    var quarantinedTrackCount: Int = 0

    /// Every collection, in any order. The tree is rebuilt from `parentID`.
    var collections: [SoriaCollection] = []
    /// Direct membership per collection — descendants are rolled up here, not by
    /// the caller.
    var trackCountsByCollectionID: [UUID: Int] = [:]

    var smartCrates: [SmartCrateSummary] = []

    var seratoFacets: [MembershipFacet] = []
    var rekordboxFacets: [MembershipFacet] = []

    init() {}
}

/// The little a crate tree needs to know about a smart crate. The rules
/// themselves live in `SmartCrateModels`.
struct SmartCrateSummary: Identifiable, Equatable {
    let id: UUID
    let name: String
    let colorLabel: TrackColorLabel?
    let matchCount: Int
    let sortIndex: Int

    init(id: UUID, name: String, colorLabel: TrackColorLabel? = nil, matchCount: Int = 0, sortIndex: Int = 0) {
        self.id = id
        self.name = name
        self.colorLabel = colorLabel
        self.matchCount = matchCount
        self.sortIndex = sortIndex
    }
}

// MARK: - Building the tree

enum LibraryCrateTree {
    /// Collections that only exist to nest others. They are still shown — the
    /// hierarchy is the point — but they carry no tracks of their own.
    private static let containerKinds: Set<SoriaCollection.Kind> = [.group]

    static func makeSections(from context: CrateTreeContext) -> [CrateTreeSection] {
        var sections: [CrateTreeSection] = [librarySection(context)]

        let folders = collectionNodes(context)
        if !folders.isEmpty {
            sections.append(CrateTreeSection(id: "soria-folders", title: "Soria Folders", nodes: folders))
        }

        let smart = smartCrateNodes(context)
        if !smart.isEmpty {
            sections.append(CrateTreeSection(id: "smart-crates", title: "Smart Crates", nodes: smart))
        }

        let references = referenceNodes(context)
        if !references.isEmpty {
            sections.append(CrateTreeSection(id: "references", title: "References", nodes: references))
        }

        sections.append(
            CrateTreeSection(
                id: "maintenance",
                title: "Maintenance",
                nodes: [
                    CrateTreeNode(
                        id: "trash",
                        title: "Soria Trash",
                        selection: .trash,
                        depth: 0,
                        trackCount: context.quarantinedTrackCount,
                        colorLabel: nil,
                        children: []
                    )
                ]
            )
        )

        return sections
    }

    // MARK: Fixed scopes

    private static func librarySection(_ context: CrateTreeContext) -> CrateTreeSection {
        var nodes: [CrateTreeNode] = [
            CrateTreeNode(
                id: "all-tracks",
                title: "All Tracks",
                selection: .allTracks,
                depth: 0,
                trackCount: context.totalTrackCount,
                colorLabel: nil,
                children: []
            )
        ]

        // Hidden at zero rather than shown empty: an Inbox that always reads 0 is
        // a permanent reminder of nothing.
        if context.inboxTrackCount > 0 {
            nodes.append(
                CrateTreeNode(
                    id: "inbox",
                    title: "Inbox",
                    selection: .inbox,
                    depth: 0,
                    trackCount: context.inboxTrackCount,
                    colorLabel: nil,
                    children: []
                )
            )
        }

        if context.needsPreparationCount > 0 {
            nodes.append(
                CrateTreeNode(
                    id: "needs-prep",
                    title: "Needs Prep",
                    selection: .needsPreparation,
                    depth: 0,
                    trackCount: context.needsPreparationCount,
                    colorLabel: nil,
                    children: []
                )
            )
        }

        return CrateTreeSection(id: "library", title: "Library", nodes: nodes)
    }

    // MARK: Soria folders

    private static func collectionNodes(_ context: CrateTreeContext) -> [CrateTreeNode] {
        let byID = Dictionary(uniqueKeysWithValues: context.collections.map { ($0.id, $0) })

        var childrenByParent: [UUID?: [SoriaCollection]] = [:]
        for collection in context.collections {
            // A collection whose parent was deleted would otherwise vanish from
            // the tree entirely. Re-root it instead — an orphan the user can see
            // and move is better than one they cannot find.
            let parent = collection.parentID.flatMap { byID[$0] == nil ? nil : $0 }
            childrenByParent[parent, default: []].append(collection)
        }

        let roots = sorted(childrenByParent[nil] ?? [])
        return roots.map { node(for: $0, depth: 0, childrenByParent: childrenByParent, context: context, visited: []) }
    }

    private static func node(
        for collection: SoriaCollection,
        depth: Int,
        childrenByParent: [UUID?: [SoriaCollection]],
        context: CrateTreeContext,
        visited: Set<UUID>
    ) -> CrateTreeNode {
        // The schema permits a cycle even though the app never writes one; without
        // this guard a hand-edited database would hang the render loop.
        var seen = visited
        let isCycle = !seen.insert(collection.id).inserted

        let children = isCycle
            ? []
            : sorted(childrenByParent[collection.id] ?? []).map {
                node(for: $0, depth: depth + 1, childrenByParent: childrenByParent, context: context, visited: seen)
            }

        let own = containerKinds.contains(collection.kind)
            ? 0
            : (context.trackCountsByCollectionID[collection.id] ?? 0)

        return CrateTreeNode(
            id: collection.id.uuidString,
            title: collection.name,
            selection: .collection(collection.id),
            depth: depth,
            // Rolled up, so a collapsed genre folder still reports what is under it.
            trackCount: own + children.reduce(0) { $0 + $1.trackCount },
            colorLabel: nil,
            children: children
        )
    }

    private static func sorted(_ collections: [SoriaCollection]) -> [SoriaCollection] {
        collections.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: Smart crates

    private static func smartCrateNodes(_ context: CrateTreeContext) -> [CrateTreeNode] {
        context.smartCrates
            .sorted { lhs, rhs in
                if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .map {
                CrateTreeNode(
                    id: $0.id.uuidString,
                    title: $0.name,
                    selection: .smartCrate($0.id),
                    depth: 0,
                    trackCount: $0.matchCount,
                    colorLabel: $0.colorLabel,
                    children: []
                )
            }
    }

    // MARK: Vendor references

    /// Serato crates and rekordbox playlists, nested by their own path depth.
    ///
    /// These used to live in the scope inspector, where they read as a filter.
    /// They are navigation — "show me what is in this crate" — so they belong in
    /// the tree next to everything else that answers that question.
    private static func referenceNodes(_ context: CrateTreeContext) -> [CrateTreeNode] {
        var nodes: [CrateTreeNode] = []

        if !context.seratoFacets.isEmpty {
            nodes.append(vendorRoot(source: .serato, title: "Serato", facets: context.seratoFacets))
        }
        if !context.rekordboxFacets.isEmpty {
            nodes.append(vendorRoot(source: .rekordbox, title: "rekordbox", facets: context.rekordboxFacets))
        }

        return nodes
    }

    private static func vendorRoot(
        source: ExternalDJMetadata.Source,
        title: String,
        facets: [MembershipFacet]
    ) -> CrateTreeNode {
        var childrenByParent: [String?: [MembershipFacet]] = [:]
        let knownPaths = Set(facets.map(\.membershipPath))
        for facet in facets {
            let parent = facet.parentPath.flatMap { knownPaths.contains($0) ? $0 : nil }
            childrenByParent[parent, default: []].append(facet)
        }

        let roots = (childrenByParent[nil] ?? []).sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        let children = roots.map {
            facetNode(for: $0, source: source, depth: 1, childrenByParent: childrenByParent)
        }

        return CrateTreeNode(
            id: "vendor-\(source.rawValue)",
            title: title,
            selection: .vendorMembership(source: source, path: ""),
            depth: 0,
            trackCount: facets.filter { $0.parentPath == nil }.reduce(0) { $0 + $1.trackCount },
            colorLabel: nil,
            children: children
        )
    }

    private static func facetNode(
        for facet: MembershipFacet,
        source: ExternalDJMetadata.Source,
        depth: Int,
        childrenByParent: [String?: [MembershipFacet]]
    ) -> CrateTreeNode {
        let children = (childrenByParent[facet.membershipPath] ?? [])
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map { facetNode(for: $0, source: source, depth: depth + 1, childrenByParent: childrenByParent) }

        return CrateTreeNode(
            id: facet.id,
            title: facet.displayName,
            // The vendor's own count already covers nested crates, so this is not
            // rolled up the way Soria collections are.
            selection: .vendorMembership(source: source, path: facet.membershipPath),
            depth: depth,
            trackCount: facet.trackCount,
            colorLabel: nil,
            children: children
        )
    }
}
