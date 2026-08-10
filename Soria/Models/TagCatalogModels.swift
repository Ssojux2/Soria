import Foundation

/// The user's own vocabulary for describing tracks — Soria's answer to
/// rekordbox's "My Tag".
///
/// Four categories, no more and no fewer. That is not an arbitrary cap: rekordbox
/// exposes exactly four My Tag categories, so four is what survives an export
/// intact. It also keeps the tagging panel usable — the entire point of a tag
/// grid is that a DJ can hit the right chip without reading, and that stops being
/// true once the categories scroll.
///
/// The count is enforced by the type system rather than by a runtime check:
/// `TagCategorySlot` has four cases and a catalog always carries one category per
/// slot, so there is no code path that can produce a fifth.

// MARK: - Categories

/// The four fixed slots. Named by position rather than by meaning because the
/// user can rename them — a slot called `.vibe` that reads "Mood" on screen would
/// be a lie in every stack trace afterwards.
enum TagCategorySlot: String, CaseIterable, Codable, Identifiable, Sendable {
    case one = "1"
    case two = "2"
    case three = "3"
    case four = "4"

    var id: String { rawValue }

    /// Starting names, chosen to cover how DJs actually sort a set: what it feels
    /// like, where it goes in the night, what is in it, and a free slot.
    var defaultName: String {
        switch self {
        case .one: return "Vibe"
        case .two: return "Situation"
        case .three: return "Element"
        case .four: return "Custom"
        }
    }

    /// Position in the rekordbox My Tag export, 1-based.
    var exportIndex: Int {
        switch self {
        case .one: return 1
        case .two: return 2
        case .three: return 3
        case .four: return 4
        }
    }
}

struct TagCategory: Equatable, Hashable, Codable, Identifiable, Sendable {
    let slot: TagCategorySlot
    var name: String

    var id: TagCategorySlot { slot }

    init(slot: TagCategorySlot, name: String? = nil) {
        self.slot = slot
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.name = trimmed.isEmpty ? slot.defaultName : trimmed
    }
}

// MARK: - Tags

struct Tag: Equatable, Hashable, Codable, Identifiable, Sendable {
    let id: UUID
    let slot: TagCategorySlot
    var name: String
    var sortIndex: Int

    init(id: UUID = UUID(), slot: TagCategorySlot, name: String, sortIndex: Int = 0) {
        self.id = id
        self.slot = slot
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sortIndex = sortIndex
    }

    /// The form two tag names are compared by. Case- and whitespace-insensitive,
    /// because "Peak Time", "peak time", and "peak  time" are one tag as far as
    /// the person typing them is concerned.
    var normalizedName: String {
        name.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// MARK: - Errors

enum TagCatalogError: Error, Equatable {
    case emptyName
    case duplicateName(slot: TagCategorySlot, name: String)
    case categoryFull(slot: TagCategorySlot, limit: Int)
    case unknownTag(id: UUID)
}

// MARK: - Catalog

/// The whole vocabulary: four named categories and the tags inside them.
///
/// Every mutation returns a new catalog rather than editing in place, so a failed
/// edit cannot leave a half-applied vocabulary behind and the view model can
/// diff old against new.
struct TagCatalog: Equatable, Codable, Sendable {
    /// rekordbox's own ceiling. Matching it means an export never has to silently
    /// drop the 51st tag.
    static let maximumTagsPerCategory = 50

    private(set) var categories: [TagCategory]
    private(set) var tags: [Tag]

    /// A fresh vocabulary: four default-named categories, no tags. The user
    /// invents their own tags — shipping a starter set would bias how they
    /// classify before they have listened to anything.
    static var empty: TagCatalog {
        TagCatalog(
            categories: TagCategorySlot.allCases.map { TagCategory(slot: $0) },
            tags: []
        )
    }

    /// Rebuilds from persisted rows, filling in any slot the database is missing.
    /// A partial read yields a usable catalog rather than a crash, which matters
    /// because the tag tables arrive by migration on an existing library.
    init(categories: [TagCategory], tags: [Tag]) {
        self.categories = TagCategorySlot.allCases.map { slot in
            categories.first { $0.slot == slot } ?? TagCategory(slot: slot)
        }

        let knownSlots = Set(TagCategorySlot.allCases)
        self.tags = tags
            .filter { knownSlots.contains($0.slot) && !$0.name.isEmpty }
            .sorted { lhs, rhs in
                if lhs.slot != rhs.slot { return lhs.slot.exportIndex < rhs.slot.exportIndex }
                if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
                return lhs.normalizedName < rhs.normalizedName
            }
    }

    func category(_ slot: TagCategorySlot) -> TagCategory {
        // Safe by construction: `init` guarantees one entry per slot.
        categories.first { $0.slot == slot } ?? TagCategory(slot: slot)
    }

    func tags(in slot: TagCategorySlot) -> [Tag] {
        tags.filter { $0.slot == slot }
    }

    func tag(id: UUID) -> Tag? {
        tags.first { $0.id == id }
    }

    var isEmpty: Bool { tags.isEmpty }

    // MARK: Mutations

    func renamingCategory(_ slot: TagCategorySlot, to newName: String) throws -> TagCatalog {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TagCatalogError.emptyName }

        var updated = self
        updated.categories = categories.map { category in
            category.slot == slot ? TagCategory(slot: slot, name: trimmed) : category
        }
        return updated
    }

    func addingTag(named name: String, to slot: TagCategorySlot) throws -> (catalog: TagCatalog, tag: Tag) {
        let candidate = Tag(slot: slot, name: name, sortIndex: nextSortIndex(in: slot))
        guard !candidate.name.isEmpty else { throw TagCatalogError.emptyName }

        let existing = tags(in: slot)
        if existing.contains(where: { $0.normalizedName == candidate.normalizedName }) {
            throw TagCatalogError.duplicateName(slot: slot, name: candidate.name)
        }
        guard existing.count < Self.maximumTagsPerCategory else {
            throw TagCatalogError.categoryFull(slot: slot, limit: Self.maximumTagsPerCategory)
        }

        return (TagCatalog(categories: categories, tags: tags + [candidate]), candidate)
    }

    func renamingTag(id: UUID, to newName: String) throws -> TagCatalog {
        guard let current = tag(id: id) else { throw TagCatalogError.unknownTag(id: id) }

        let candidate = Tag(id: id, slot: current.slot, name: newName, sortIndex: current.sortIndex)
        guard !candidate.name.isEmpty else { throw TagCatalogError.emptyName }

        let collides = tags(in: current.slot).contains {
            $0.id != id && $0.normalizedName == candidate.normalizedName
        }
        if collides {
            throw TagCatalogError.duplicateName(slot: current.slot, name: candidate.name)
        }

        return TagCatalog(
            categories: categories,
            tags: tags.map { $0.id == id ? candidate : $0 }
        )
    }

    /// Removing a tag from the vocabulary. Callers are responsible for dropping
    /// the corresponding `track_tags` rows — this type deliberately knows nothing
    /// about which tracks carry the tag, so that deleting from the catalog and
    /// un-tagging tracks stay one explicit decision rather than a hidden cascade.
    func removingTag(id: UUID) throws -> TagCatalog {
        guard tag(id: id) != nil else { throw TagCatalogError.unknownTag(id: id) }
        return TagCatalog(categories: categories, tags: tags.filter { $0.id != id })
    }

    private func nextSortIndex(in slot: TagCategorySlot) -> Int {
        (tags(in: slot).map(\.sortIndex).max() ?? -1) + 1
    }
}

// MARK: - Track assignments

/// Which tracks carry which tags, held in memory.
///
/// The Library re-filters on every keystroke over a five-thousand-track list, so
/// tag membership has to be an O(1) set lookup. The database stays the source of
/// truth and this is rebuilt from it; hitting SQLite per row per keystroke is the
/// thing this type exists to prevent.
struct TrackTagIndex: Equatable {
    private(set) var tagIDsByTrack: [UUID: Set<UUID>]

    init(tagIDsByTrack: [UUID: Set<UUID>] = [:]) {
        self.tagIDsByTrack = tagIDsByTrack.filter { !$0.value.isEmpty }
    }

    func tagIDs(for trackID: UUID) -> Set<UUID> {
        tagIDsByTrack[trackID] ?? []
    }

    func hasTag(_ tagID: UUID, on trackID: UUID) -> Bool {
        tagIDsByTrack[trackID]?.contains(tagID) ?? false
    }

    func isUntagged(_ trackID: UUID) -> Bool {
        tagIDs(for: trackID).isEmpty
    }

    func trackIDs(carrying tagID: UUID) -> Set<UUID> {
        Set(tagIDsByTrack.filter { $0.value.contains(tagID) }.keys)
    }

    /// How a multi-track selection renders in the tag grid: every track has it,
    /// some do, or none do. The middle case is why this is not a `Bool` — a
    /// checkbox that reads "off" for a selection where half the tracks carry the
    /// tag would erase those tags the moment the user clicked it.
    enum SelectionState: Equatable {
        case none
        case partial
        case all
    }

    func selectionState(for tagID: UUID, across trackIDs: [UUID]) -> SelectionState {
        guard !trackIDs.isEmpty else { return .none }

        var carrying = 0
        for trackID in trackIDs where hasTag(tagID, on: trackID) {
            carrying += 1
        }

        if carrying == 0 { return .none }
        return carrying == trackIDs.count ? .all : .partial
    }

    func applying(tagID: UUID, to trackIDs: [UUID]) -> TrackTagIndex {
        var updated = tagIDsByTrack
        for trackID in trackIDs {
            updated[trackID, default: []].insert(tagID)
        }
        return TrackTagIndex(tagIDsByTrack: updated)
    }

    func removing(tagID: UUID, from trackIDs: [UUID]) -> TrackTagIndex {
        var updated = tagIDsByTrack
        for trackID in trackIDs {
            updated[trackID]?.remove(tagID)
        }
        return TrackTagIndex(tagIDsByTrack: updated)
    }

    /// Drops a tag everywhere, for when it leaves the catalog.
    func removingTagEverywhere(_ tagID: UUID) -> TrackTagIndex {
        TrackTagIndex(tagIDsByTrack: tagIDsByTrack.mapValues { $0.subtracting([tagID]) })
    }
}
