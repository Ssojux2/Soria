import Foundation
import Testing

@testable import Soria

/// The Home dashboard's display logic.
///
/// `WorkspaceDashboardState.make(from:)` is pure, so these run without a database,
/// a worker, or a window — the same arrangement as the `preparationOverview` tests
/// in `AnalysisProgressTests`.
///
/// The point worth guarding: this type decides *what to show*, never *what can
/// run*. Every `can…` flag must pass straight through from the context, because
/// the moment Home computes its own answer it starts disagreeing with the pane
/// that owns the action.
struct WorkspaceDashboardTests {
    private func healthyContext() -> WorkspaceDashboardContext {
        WorkspaceDashboardContext(
            totalTrackCount: 5_004,
            readyTrackCount: 1_780,
            needsPreparationCount: 3_224,
            libraryRootCount: 2,
            isValidated: true,
            validationSummary: "Validated 2026-08-10T00:00:00Z",
            embeddingProfileName: "Google AI gemini-embedding-2-preview",
            hasResolvedWorkerPaths: true,
            enabledVendorSourceNames: ["Serato"],
            soriaFolderCount: 12,
            quarantinedTrackCount: 8,
            latestOrganizationDate: Date(timeIntervalSince1970: 1_700_000_000),
            canExportFolders: true,
            readyReferenceCount: 4,
            generatedRecommendationCount: 30,
            canGenerateRecommendations: true,
            playlistQueueCount: 23,
            exportTargetName: "Serato Crate",
            canExportQueue: true
        )
    }

    // MARK: - Header

    @Test
    func headlineCountsTracksWithThousandsSeparators() {
        let state = WorkspaceDashboardState.make(from: healthyContext())

        #expect(state.headline == "5,004 tracks indexed")
        #expect(state.readinessSummary == "1,780 ready · 3,224 need prep · 8 in Soria Trash")
    }

    @Test
    func headlineGuidesTheUserWhenNothingIsIndexedYet() {
        let state = WorkspaceDashboardState.make(from: WorkspaceDashboardContext())

        #expect(state.headline == "No tracks indexed yet")
        // A bare "0 ready" tells a first-run user nothing about what to do next.
        #expect(state.readinessSummary == "Add a music folder and scan it to build the library.")
    }

    @Test
    func readinessSummaryDropsSectionsThatWouldReadAsZero() {
        var context = healthyContext()
        context.needsPreparationCount = 0
        context.quarantinedTrackCount = 0

        let state = WorkspaceDashboardState.make(from: context)

        #expect(state.readinessSummary == "1,780 ready")
    }

    @Test
    func profileSummaryReportsValidationAndEnabledVendorSources() {
        let validated = WorkspaceDashboardState.make(from: healthyContext())
        #expect(validated.profileSummary == "Google AI gemini-embedding-2-preview · Validated · Serato")

        var unvalidated = healthyContext()
        unvalidated.isValidated = false
        unvalidated.enabledVendorSourceNames = []
        #expect(
            WorkspaceDashboardState.make(from: unvalidated).profileSummary
                == "Google AI gemini-embedding-2-preview · Not validated"
        )
    }

    @Test
    func singularNounsAreNotPluralized() {
        var context = WorkspaceDashboardContext()
        context.totalTrackCount = 1
        context.soriaFolderCount = 1
        context.quarantinedTrackCount = 1
        context.readyReferenceCount = 1
        context.playlistQueueCount = 1
        context.generatedRecommendationCount = 1

        let state = WorkspaceDashboardState.make(from: context)

        #expect(state.headline == "1 track indexed")
        #expect(state.organize.summary == "1 Soria folder")
        #expect(state.organize.trashSummary == "1 track in Soria Trash")
        #expect(state.mix.summary == "1 ready reference")
        #expect(state.mix.generatedSummary == "1 candidate generated")
        #expect(state.export.summary == "1 track queued")
    }

    // MARK: - Setup card gating

    @Test
    func aHealthySetupProducesNoSetupCard() {
        let state = WorkspaceDashboardState.make(from: healthyContext())

        #expect(state.setupIssues.isEmpty)
        #expect(state.isSetupHealthy)
    }

    @Test
    func setupIssuesAreOrderedByHowEarlyTheyBlockThePipeline() {
        var context = healthyContext()
        context.libraryRootCount = 0
        context.isValidated = false
        context.hasResolvedWorkerPaths = false

        let state = WorkspaceDashboardState.make(from: context)

        #expect(state.setupIssues.map(\.kind) == [.musicFolders, .validation, .workerPaths])
        #expect(!state.isSetupHealthy)
    }

    @Test
    func theValidationIssueSurfacesTheRealFailureReason() throws {
        var context = healthyContext()
        context.isValidated = false
        context.validationSummary = "API key rejected by Google AI."

        let state = WorkspaceDashboardState.make(from: context)
        let issue = try #require(state.setupIssues.first { $0.kind == .validation })

        // Showing the generic hint here would hide the actual error from the user.
        #expect(issue.detail == "API key rejected by Google AI.")
    }

    @Test
    func anEmptyLibraryIsOnlyReportedOnceFoldersExist() {
        var withoutFolders = healthyContext()
        withoutFolders.libraryRootCount = 0
        withoutFolders.totalTrackCount = 0
        // Saying "library is empty" next to "no folder connected" is noise; the
        // folder issue already explains it.
        #expect(!WorkspaceDashboardState.make(from: withoutFolders).setupIssues.contains { $0.kind == .emptyLibrary })

        var withFolders = healthyContext()
        withFolders.totalTrackCount = 0
        #expect(WorkspaceDashboardState.make(from: withFolders).setupIssues.contains { $0.kind == .emptyLibrary })
    }

    // MARK: - Cards pass enablement through untouched

    @Test
    func cardsNeverOverrideTheEnablementFlagsTheyAreGiven() {
        var context = healthyContext()
        context.canExportFolders = false
        context.canGenerateRecommendations = false
        context.canExportQueue = false

        let blocked = WorkspaceDashboardState.make(from: context)

        // Counts are healthy but the owning panes said no, so Home must say no too.
        #expect(!blocked.organize.canExportFolders)
        #expect(!blocked.mix.canGenerate)
        #expect(!blocked.export.canExport)
        #expect(blocked.organize.summary == "12 Soria folders")
        #expect(blocked.export.summary == "23 tracks queued")

        let allowed = WorkspaceDashboardState.make(from: healthyContext())
        #expect(allowed.organize.canExportFolders)
        #expect(allowed.mix.canGenerate)
        #expect(allowed.export.canExport)
    }

    @Test
    func anEmptyTrashHidesItsRowAndItsRestoreAction() {
        var context = healthyContext()
        context.quarantinedTrackCount = 0

        let state = WorkspaceDashboardState.make(from: context)

        #expect(state.organize.trashSummary == nil)
        #expect(!state.organize.canRestoreTrash)
    }

    @Test
    func organizeDetailPointsAtWhateverIsMissing() {
        var noFolders = healthyContext()
        noFolders.soriaFolderCount = 0
        #expect(WorkspaceDashboardState.make(from: noFolders).organize.summary == "No Soria folders yet")
        #expect(WorkspaceDashboardState.make(from: noFolders).organize.detail.contains("Build a folder plan"))

        var nothingPrepared = noFolders
        nothingPrepared.readyTrackCount = 0
        // Organizing runs off analysis results, so preparing comes first.
        #expect(WorkspaceDashboardState.make(from: nothingPrepared).organize.detail.contains("Prepare some tracks first"))
    }

    @Test
    func anEmptyExportQueueExplainsHowToFillIt() {
        var context = healthyContext()
        context.playlistQueueCount = 0
        context.canExportQueue = false

        let state = WorkspaceDashboardState.make(from: context)

        #expect(state.export.summary == "Queue is empty")
        #expect(state.export.detail.contains("Mix Assistant"))
        #expect(!state.export.canExport)
    }

    @Test
    func theExportCardNamesTheSelectedTarget() {
        let state = WorkspaceDashboardState.make(from: healthyContext())

        #expect(state.export.detail == "Exports to Serato Crate.")
    }

    @Test
    func mixCardDistinguishesHavingReferencesFromHavingNone() {
        let withReferences = WorkspaceDashboardState.make(from: healthyContext())
        #expect(withReferences.mix.summary == "4 ready references")
        #expect(withReferences.mix.generatedSummary == "30 candidates generated")

        var withoutReferences = healthyContext()
        withoutReferences.readyReferenceCount = 0
        withoutReferences.generatedRecommendationCount = 0
        let bare = WorkspaceDashboardState.make(from: withoutReferences)
        #expect(bare.mix.summary == "No reference tracks selected")
        // Text-only mixing is supported, so the empty state must not read as a block.
        #expect(bare.mix.detail.contains("describe what you want"))
        #expect(bare.mix.generatedSummary == nil)
    }

    // MARK: - Determinism

    @Test
    func identicalContextsProduceIdenticalState() {
        let first = WorkspaceDashboardState.make(from: healthyContext())
        let second = WorkspaceDashboardState.make(from: healthyContext())

        #expect(first == second)
    }

    @Test
    func numberFormattingDoesNotFollowTheHostLocale() {
        // Pinned to en_US so grouping matches the English labels beside it and these
        // expectations hold on any machine, whatever the host locale is set to.
        #expect(WorkspaceDashboardState.formatted(1_780) == "1,780")
        #expect(WorkspaceDashboardState.formatted(0) == "0")
        #expect(WorkspaceDashboardState.formatted(1_000_000) == "1,000,000")
    }
}
