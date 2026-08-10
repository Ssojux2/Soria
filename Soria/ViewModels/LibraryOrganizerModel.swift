import AppKit
import Combine
import Foundation

/// State and actions for the Organizer pane.
///
/// Lives outside `AppViewModel` on purpose: that file is already 7,000 lines and
/// 80-odd published properties, and the abandoned stash added another 420 to it.
/// Everything the organizer needs from the app arrives through `Dependencies`, so
/// `AppViewModel` gains one lazy property and a small factory instead.
///
/// Views observe this object directly. SwiftUI does not forward a nested
/// `ObservableObject`'s changes to a parent, which is exactly why that works
/// without any `objectWillChange` plumbing. Data flows back the other way through
/// `onLibraryChanged`.
@MainActor
final class LibraryOrganizerModel: ObservableObject {
    struct Dependencies {
        var planner: LibraryOrganizationPlanner
        var organizer: LibraryFileOrganizerService
        var labelCache: LabelEmbeddingCache
        var embedTextLabels: @Sendable ([String]) async throws -> [String: [Double]]
        var loadTrackEmbeddings: @Sendable (Set<UUID>) throws -> [UUID: [Double]]
        var visibleTracks: @MainActor () -> [Track]
        var selectedTracks: @MainActor () -> [Track]
        var allTracks: @MainActor () -> [Track]
        var readyTrackIDs: @MainActor () -> Set<UUID>
        var libraryRoots: @MainActor () -> [String]
        var embeddingProfileID: @MainActor () -> String
        var hasDurableWriteAccess: @MainActor ([String]) -> Bool
        var addLibraryRoot: @MainActor (String) -> Void
        var onLibraryChanged: @MainActor () async -> Void
    }

    @Published var scope: LibraryOrganizationScope = .visibleReadyTracks {
        didSet {
            guard scope != oldValue else { return }
            clearPlan(message: "Scope changed. Build a new organization preview.")
        }
    }
    @Published var destinationRoot: String = ""
    @Published private(set) var plan: LibraryOrganizationPlan?
    @Published private(set) var excludedMoveIDs: Set<UUID> = []
    @Published private(set) var progress = LibraryOrganizationProgress()
    @Published private(set) var isPlanning = false
    @Published private(set) var isApplying = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var warnings: [String] = []

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        destinationRoot = Self.defaultDestinationRoot(libraryRoots: dependencies.libraryRoots())
    }

    // MARK: - Derived state

    var availableScopes: [LibraryOrganizationScope] { LibraryOrganizationScope.allCases }

    var scopedTracks: [Track] {
        switch scope {
        case .visibleReadyTracks: return dependencies.visibleTracks()
        case .selectedReadyTracks: return dependencies.selectedTracks()
        case .allReadyTracks: return dependencies.allTracks()
        }
    }

    var readyCandidateCount: Int {
        let ready = dependencies.readyTrackIDs()
        return scopedTracks.count { ready.contains($0.id) }
    }

    var summaryText: String {
        let total = scopedTracks.count
        let ready = readyCandidateCount
        if total == 0 {
            return "No tracks in scope. Widen the scope or scan a Music Folder first."
        }
        if ready == 0 {
            return "\(total) tracks in scope, none prepared yet. Analyze them before organizing."
        }
        return "\(ready) of \(total) tracks in scope are prepared and can be organized."
    }

    var includedMoveCount: Int {
        plan?.includedMoves(excluding: excludedMoveIDs).count ?? 0
    }

    var canBuildPlan: Bool {
        !isPlanning && !isApplying && !destinationRoot.isEmpty && readyCandidateCount > 0
    }

    var canApplyPlan: Bool {
        guard !isPlanning, !isApplying, let plan, !plan.moves.isEmpty else { return false }
        return includedMoveCount > 0
    }

    // MARK: - Planning

    func buildPlan() {
        guard canBuildPlan else { return }

        let tracks = scopedTracks
        let readyIDs = dependencies.readyTrackIDs()
        let roots = dependencies.libraryRoots()
        let profileID = dependencies.embeddingProfileID()
        let destination = destinationRoot

        isPlanning = true
        progress = LibraryOrganizationProgress(
            stage: .planning,
            message: "Reading track embeddings..."
        )
        statusMessage = "Building preview..."

        Task {
            defer { isPlanning = false }

            do {
                let candidateIDs = Set(tracks.map(\.id)).intersection(readyIDs)
                let embeddings = try dependencies.loadTrackEmbeddings(candidateIDs)

                progress = LibraryOrganizationProgress(
                    stage: .planning,
                    message: "Embedding genre labels..."
                )
                let labelEmbeddings = try await genreLabelEmbeddings(profileID: profileID)

                let builtPlan = dependencies.planner.makePlan(
                    tracks: tracks,
                    readyTrackIDs: readyIDs,
                    embeddingsByTrackID: embeddings,
                    labelEmbeddingsByFamilyID: labelEmbeddings,
                    destinationRootPath: destination,
                    libraryRoots: roots
                )

                plan = builtPlan
                excludedMoveIDs = []
                warnings = builtPlan.warnings
                progress = LibraryOrganizationProgress(
                    stage: .completed,
                    completedCount: builtPlan.moveCount,
                    totalCount: builtPlan.moveCount,
                    message: "Preview ready."
                )
                statusMessage = builtPlan.moves.isEmpty
                    ? "Nothing to move. \(builtPlan.skippedTracks.count) tracks were skipped."
                    : "\(builtPlan.moveCount) moves proposed across \(builtPlan.groups.count) folders."
            } catch {
                plan = nil
                warnings = []
                progress = LibraryOrganizationProgress(stage: .failed, message: "Preview failed.")
                statusMessage = "Could not build the preview: \(error.localizedDescription)"
                AppLogger.shared.error("organizer_plan_failed error=\(error.localizedDescription)")
            }
        }
    }

    /// Genre label vectors, served from the per-profile disk cache and topped up
    /// with a single worker call for whatever is missing.
    private func genreLabelEmbeddings(profileID: String) async throws -> [String: [Double]] {
        let promptsByFamilyID = GenreTaxonomy.promptsByFamilyID
        let prompts = promptsByFamilyID.values.sorted()

        let (cached, missing) = dependencies.labelCache.load(labels: prompts, profileID: profileID)
        var vectorsByPrompt = cached

        if !missing.isEmpty {
            let fetched = try await dependencies.embedTextLabels(missing)
            dependencies.labelCache.store(fetched, profileID: profileID)
            vectorsByPrompt.merge(fetched) { _, new in new }
        }

        var byFamilyID: [String: [Double]] = [:]
        for (familyID, prompt) in promptsByFamilyID {
            guard let vector = vectorsByPrompt[prompt], !vector.isEmpty else { continue }
            byFamilyID[familyID] = vector
        }

        guard !byFamilyID.isEmpty else {
            throw NSError(
                domain: "LibraryOrganizerModel",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No genre labels could be embedded with the current profile."]
            )
        }
        return byFamilyID
    }

    // MARK: - Applying

    func applyPlan() {
        guard canApplyPlan, let plan else { return }

        let movePaths = plan.includedMoves(excluding: excludedMoveIDs).map(\.sourcePath)
        guard dependencies.hasDurableWriteAccess(movePaths + [plan.destinationRootPath]) else {
            statusMessage = "Soria needs permission to move these files. Re-select the Music Folder first."
            return
        }

        let excluded = excludedMoveIDs
        let profileID = dependencies.embeddingProfileID()

        isApplying = true
        statusMessage = "Moving files..."

        Task {
            defer { isApplying = false }

            let result = await dependencies.organizer.apply(
                plan: plan,
                excludedMoveIDs: excluded,
                kind: .genreClusters,
                embeddingProfileID: profileID
            ) { [weak self] update in
                await MainActor.run { self?.progress = update }
            }

            if plan.shouldAddDestinationRootToLibrary, result.movedCount > 0 {
                dependencies.addLibraryRoot(plan.destinationRootPath)
            }

            warnings = result.warnings
            statusMessage = result.failedCount == 0
                ? "Organized \(result.movedCount) tracks."
                : "Organized \(result.movedCount) tracks, \(result.failedCount) failed."

            // The plan's source paths are stale now that files moved.
            self.plan = nil
            excludedMoveIDs = []

            await dependencies.onLibraryChanged()
        }
    }

    // MARK: - Plan editing

    func toggleMoveIncluded(_ moveID: UUID) {
        if excludedMoveIDs.contains(moveID) {
            excludedMoveIDs.remove(moveID)
        } else {
            excludedMoveIDs.insert(moveID)
        }
    }

    func setAllMovesIncluded(_ included: Bool) {
        guard let plan else { return }
        excludedMoveIDs = included ? [] : Set(plan.moves.map(\.id))
    }

    func clearPlan(message: String = "") {
        guard !isApplying else { return }
        plan = nil
        excludedMoveIDs = []
        warnings = []
        progress = LibraryOrganizationProgress()
        statusMessage = message
    }

    func chooseDestinationRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose where Soria should create the organized folders."
        if !destinationRoot.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: destinationRoot, isDirectory: true)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        LibraryRootsStore.rememberAccess(to: url)
        destinationRoot = TrackPathNormalizer.normalizedAbsolutePath(url)
        clearPlan(message: "Destination changed. Build a new organization preview.")
    }

    /// Defaults to a "Soria Organized" folder inside the first library root, which
    /// keeps the move on the same volume and inside already-granted access.
    static func defaultDestinationRoot(libraryRoots: [String]) -> String {
        guard let first = libraryRoots.first(where: { !$0.isEmpty }) else { return "" }
        return TrackPathNormalizer.normalizedAbsolutePath(
            URL(fileURLWithPath: first, isDirectory: true)
                .appendingPathComponent("Soria Organized", isDirectory: true)
        )
    }
}
