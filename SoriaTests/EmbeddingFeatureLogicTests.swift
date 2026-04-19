import Foundation
import Testing
@testable import Soria

extension SoriaTests {
    @Test
    func validationStatusResetsWhenKeyChanges() {
        let profile = EmbeddingProfile.googleGeminiEmbedding2Preview
        let validatedAt = Date(timeIntervalSince1970: 1_716_000_000)
        let storedHash = AppSettingsStore.hashAPIKey("valid-key")

        #expect(
            AppSettingsStore.computeValidationStatus(
                apiKey: "valid-key",
                profile: profile,
                storedKeyHash: storedHash,
                storedProfileID: profile.id,
                storedAt: validatedAt
            ) == .validated(validatedAt)
        )

        #expect(
            AppSettingsStore.computeValidationStatus(
                apiKey: "changed-key",
                profile: profile,
                storedKeyHash: storedHash,
                storedProfileID: profile.id,
                storedAt: validatedAt
            ) == .unvalidated
        )
    }

    @Test
    func validationStatusResetsWhenProfileChanges() {
        let validatedAt = Date(timeIntervalSince1970: 1_716_000_000)
        let storedHash = AppSettingsStore.hashAPIKey("same-key")

        #expect(
            AppSettingsStore.computeValidationStatus(
                apiKey: "same-key",
                profile: .clapHTSATUnfused,
                storedKeyHash: storedHash,
                storedProfileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id,
                storedAt: validatedAt
            ) == .unvalidated
        )
    }

    @Test
    func legacyProfileIDsResolveToGeminiPreview() {
        #expect(
            EmbeddingProfile.resolve(id: EmbeddingProfile.legacyGoogleTextEmbedding004ID)
                == .googleGeminiEmbedding2Preview
        )
        #expect(
            EmbeddingProfile.resolve(id: EmbeddingProfile.legacyGeminiEmbedding001ID)
                == .googleGeminiEmbedding2Preview
        )
    }

    @Test
    func analysisScopeMappingFollowsSelectedUnanalyzedAndAllRules() {
        let selectedID = UUID()
        let currentProfile = EmbeddingProfile.googleGeminiEmbedding2Preview.id
        let selectedTrack = makeTrack(
            id: selectedID,
            analyzedAt: Date(timeIntervalSince1970: 10),
            embeddingProfileID: currentProfile,
            embeddingUpdatedAt: Date(timeIntervalSince1970: 20)
        )
        let staleTrack = makeTrack(
            analyzedAt: Date(timeIntervalSince1970: 10),
            embeddingProfileID: EmbeddingProfile.clapHTSATUnfused.id,
            embeddingUpdatedAt: Date(timeIntervalSince1970: 20)
        )
        let neverAnalyzedTrack = makeTrack(analyzedAt: nil, embeddingProfileID: nil, embeddingUpdatedAt: nil)
        let tracks = [selectedTrack, staleTrack, neverAnalyzedTrack]

        #expect(
            AnalysisScope.selectedTrack.resolveTracks(
                from: tracks,
                selectedTrackID: selectedID,
                readyTrackIDs: Set([selectedTrack.id]),
                activeProfileID: currentProfile
            ) == [selectedTrack]
        )

        #expect(
            Set(
                AnalysisScope.unanalyzedTracks.resolveTracks(
                    from: tracks,
                    selectedTrackID: selectedID,
                    readyTrackIDs: Set([selectedTrack.id]),
                    activeProfileID: currentProfile
                ).map(\.id)
            ) == Set([staleTrack.id, neverAnalyzedTrack.id])
        )

        #expect(
            AnalysisScope.allIndexedTracks.resolveTracks(
                from: tracks,
                selectedTrackID: selectedID,
                readyTrackIDs: Set([selectedTrack.id]),
                activeProfileID: currentProfile
            ).count == 3
        )
    }

    @Test
    func libraryTrackFilterMatchesWorkflowStatusBuckets() {
        #expect(LibraryTrackFilter.all.matches(.ready))
        #expect(LibraryTrackFilter.all.matches(.needsAnalysis))
        #expect(LibraryTrackFilter.ready.matches(.ready))
        #expect(LibraryTrackFilter.ready.matches(.needsRefresh) == false)
        #expect(LibraryTrackFilter.needsPreparation.matches(.needsAnalysis))
        #expect(LibraryTrackFilter.needsPreparation.matches(.needsRefresh))
        #expect(LibraryTrackFilter.needsPreparation.matches(.ready) == false)
    }

    @Test
    func librarySearchMatchesTrackTitle() {
        let track = makeTrack(
            title: "Ready Track",
            analyzedAt: nil,
            embeddingProfileID: nil,
            embeddingUpdatedAt: nil
        )

        #expect(AppViewModel.libraryTrackMatchesSearch(track, queryText: "ready"))
    }

    @Test
    func librarySearchMatchesTrackArtist() {
        let track = makeTrack(
            title: "Unknown",
            artist: "Fixture Artist",
            analyzedAt: nil,
            embeddingProfileID: nil,
            embeddingUpdatedAt: nil
        )

        #expect(AppViewModel.libraryTrackMatchesSearch(track, queryText: "fixture"))
    }

    @Test
    func librarySearchMatchesTokensAcrossTitleAndArtist() {
        let track = makeTrack(
            title: "Ready Track",
            artist: "Fixture Artist",
            analyzedAt: nil,
            embeddingProfileID: nil,
            embeddingUpdatedAt: nil
        )

        #expect(AppViewModel.libraryTrackMatchesSearch(track, queryText: "fixture ready"))
    }

    @Test
    func librarySearchRejectsPartialTokenMatches() {
        let track = makeTrack(
            title: "Ready Track",
            artist: "Fixture Artist",
            analyzedAt: nil,
            embeddingProfileID: nil,
            embeddingUpdatedAt: nil
        )

        #expect(AppViewModel.libraryTrackMatchesSearch(track, queryText: "fixture pending") == false)
    }

    @Test
    func librarySearchTokensNormalizeWhitespaceAndCase() {
        let track = makeTrack(
            title: "Ready Track",
            artist: "Fixture Artist",
            analyzedAt: nil,
            embeddingProfileID: nil,
            embeddingUpdatedAt: nil
        )

        #expect(AppViewModel.librarySearchTokens(from: "  FiXture   READY \n") == ["fixture", "ready"])
        #expect(AppViewModel.libraryTrackMatchesSearch(track, queryText: "  FiXture   READY \n"))
    }

    @Test
    @MainActor
    func librarySearchClearsSelectionWhenSelectedTrackBecomesHidden() {
        let viewModel = AppViewModel(skipAsyncBootstrap: true)
        let selectedTrack = makeTrack(
            title: "Ready Track",
            artist: "Fixture Artist",
            analyzedAt: nil,
            embeddingProfileID: nil,
            embeddingUpdatedAt: nil
        )
        let visibleTrack = makeTrack(
            title: "Pending Track",
            artist: "Fixture Artist",
            analyzedAt: nil,
            embeddingProfileID: nil,
            embeddingUpdatedAt: nil
        )

        viewModel.tracks = [selectedTrack, visibleTrack]
        viewModel.selectedTrackIDs = [selectedTrack.id]
        viewModel.librarySearchText = "pending"

        #expect(viewModel.selectedTrackIDs.isEmpty)
        #expect(viewModel.filteredTracks.map(\.id) == [visibleTrack.id])
    }

    @Test
    @MainActor
    func libraryTrackSortCyclesTitleDescendingAscendingAndClear() {
        let viewModel = AppViewModel(skipAsyncBootstrap: true)
        let bravo = makeTrack(
            title: "Bravo",
            analyzedAt: nil,
            embeddingProfileID: nil,
            embeddingUpdatedAt: nil
        )
        let alpha = makeTrack(
            title: "Alpha",
            analyzedAt: nil,
            embeddingProfileID: nil,
            embeddingUpdatedAt: nil
        )
        let charlie = makeTrack(
            title: "Charlie",
            analyzedAt: nil,
            embeddingProfileID: nil,
            embeddingUpdatedAt: nil
        )

        viewModel.tracks = [bravo, alpha, charlie]

        viewModel.applyLibraryTrackSortOrder([LibraryTrackSortComparator(column: .title)])
        #expect(viewModel.libraryTrackSortState == LibraryTrackSortState(column: .title, direction: .reverse))
        #expect(viewModel.filteredTracks.map(\.title) == ["Charlie", "Bravo", "Alpha"])

        viewModel.applyLibraryTrackSortOrder([LibraryTrackSortComparator(column: .title, order: .forward)])
        #expect(viewModel.libraryTrackSortState == LibraryTrackSortState(column: .title, direction: .forward))
        #expect(viewModel.filteredTracks.map(\.title) == ["Alpha", "Bravo", "Charlie"])

        viewModel.applyLibraryTrackSortOrder([LibraryTrackSortComparator(column: .title, order: .reverse)])
        #expect(viewModel.libraryTrackSortState == nil)
        #expect(viewModel.filteredTracks.map(\.title) == ["Bravo", "Alpha", "Charlie"])
    }

    @Test
    @MainActor
    func libraryTrackSortStartsNewColumnInDescendingOrder() {
        let viewModel = AppViewModel(skipAsyncBootstrap: true)
        let alpha = makeTrack(
            title: "Alpha",
            artist: "Zulu",
            analyzedAt: nil,
            embeddingProfileID: nil,
            embeddingUpdatedAt: nil
        )
        let bravo = makeTrack(
            title: "Bravo",
            artist: "Alpha",
            analyzedAt: nil,
            embeddingProfileID: nil,
            embeddingUpdatedAt: nil
        )
        let charlie = makeTrack(
            title: "Charlie",
            artist: "Mike",
            analyzedAt: nil,
            embeddingProfileID: nil,
            embeddingUpdatedAt: nil
        )

        viewModel.tracks = [alpha, bravo, charlie]
        viewModel.applyLibraryTrackSortOrder([LibraryTrackSortComparator(column: .title)])
        viewModel.applyLibraryTrackSortOrder([LibraryTrackSortComparator(column: .artist)])

        #expect(viewModel.libraryTrackSortState == LibraryTrackSortState(column: .artist, direction: .reverse))
        #expect(viewModel.filteredTracks.map(\.artist) == ["Zulu", "Mike", "Alpha"])
    }

    @Test
    @MainActor
    func libraryTrackSortKeepsMissingBPMAtBottom() {
        let viewModel = AppViewModel(skipAsyncBootstrap: true)
        let missing = makeTrack(
            title: "Missing",
            analyzedAt: nil,
            embeddingProfileID: nil,
            embeddingUpdatedAt: nil,
            bpm: nil
        )
        let low = makeTrack(
            title: "Low",
            analyzedAt: nil,
            embeddingProfileID: nil,
            embeddingUpdatedAt: nil,
            bpm: 120
        )
        let high = makeTrack(
            title: "High",
            analyzedAt: nil,
            embeddingProfileID: nil,
            embeddingUpdatedAt: nil,
            bpm: 128
        )

        viewModel.tracks = [missing, low, high]

        viewModel.applyLibraryTrackSortOrder([LibraryTrackSortComparator(column: .bpm)])
        #expect(viewModel.filteredTracks.map(\.title) == ["High", "Low", "Missing"])

        viewModel.applyLibraryTrackSortOrder([LibraryTrackSortComparator(column: .bpm, order: .forward)])
        #expect(viewModel.filteredTracks.map(\.title) == ["Low", "High", "Missing"])
    }

    @Test
    @MainActor
    func libraryTrackSortSupportsStatusColumn() {
        let viewModel = AppViewModel(skipAsyncBootstrap: true)
        let ready = makeTrack(
            title: "Ready",
            analyzedAt: Date(),
            embeddingProfileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id,
            embeddingUpdatedAt: Date()
        )
        let needsRefresh = makeTrack(
            title: "Needs Refresh",
            analyzedAt: Date(),
            embeddingProfileID: EmbeddingProfile.clapHTSATUnfused.id,
            embeddingUpdatedAt: Date()
        )
        let needsAnalysis = makeTrack(
            title: "Needs Analysis",
            analyzedAt: nil,
            embeddingProfileID: nil,
            embeddingUpdatedAt: nil
        )

        viewModel.configureRecommendationSearchStateForTesting(
            tracks: [needsAnalysis, ready, needsRefresh],
            selectedTrackIDs: [],
            readyTrackIDs: [ready.id],
            validationStatus: .validated(Date())
        )

        viewModel.applyLibraryTrackSortOrder([LibraryTrackSortComparator(column: .status)])
        #expect(viewModel.libraryTrackSortState == LibraryTrackSortState(column: .status, direction: .reverse))
        #expect(viewModel.filteredTracks.map(\.title) == ["Ready", "Needs Refresh", "Needs Analysis"])

        viewModel.applyLibraryTrackSortOrder([LibraryTrackSortComparator(column: .status, order: .forward)])
        #expect(viewModel.filteredTracks.map(\.title) == ["Needs Analysis", "Needs Refresh", "Ready"])

        viewModel.applyLibraryTrackSortOrder([LibraryTrackSortComparator(column: .status, order: .reverse)])
        #expect(viewModel.libraryTrackSortState == nil)
        #expect(viewModel.filteredTracks.map(\.title) == ["Needs Analysis", "Ready", "Needs Refresh"])
    }

    @Test
    func selectionReadinessSummarizesBlendReferenceState() {
        let readiness = SelectionReadiness(
            signature: "a|b|c|d|e",
            selectedCount: 5,
            readyCount: 3,
            needsAnalysisCount: 1,
            needsRefreshCount: 1
        )

        #expect(readiness.pendingCount == 2)
        #expect(readiness.hasReadyTracks)
        #expect(readiness.isPartiallyReady)
        #expect(readiness.referenceSummaryText.contains("5-track blend reference"))
        #expect(readiness.bannerMessage.contains("3"))
        #expect(readiness.bannerMessage.contains("2"))
    }

    @Test
    func mixAssistantModeDescribesBuildMixsetFlow() {
        #expect(MixAssistantMode.buildMixset.displayName == "Build Mixset")
        #expect(MixAssistantMode.allCases == [.buildMixset])
        #expect(MixAssistantMode.buildMixset.helperText.contains("selected library tracks"))
        #expect(MixAssistantMode.buildMixset.helperText.contains("automatic mix paths"))
    }

    @Test
    func unvalidatedStateDisablesAnalysisAndSearch() {
        let selectedTrack = makeTrack(
            analyzedAt: Date(timeIntervalSince1970: 10),
            embeddingProfileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id,
            embeddingUpdatedAt: Date(timeIntervalSince1970: 20)
        )
        let tracks = [selectedTrack]

        #expect(ValidationStatus.unvalidated.allowsSemanticActions(isBusy: false) == false)
        #expect(ValidationStatus.validated(Date()).allowsSemanticActions(isBusy: false))

        #expect(
            AnalysisScope.selectedTrack.canRun(
                validationStatus: .unvalidated,
                isBusy: false,
                tracks: tracks,
                selectedTrackID: selectedTrack.id,
                readyTrackIDs: Set([selectedTrack.id]),
                activeProfileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id
            ) == false
        )

        #expect(
            SearchMode.text.canSubmit(
                validationStatus: .unvalidated,
                isBusy: false,
                queryText: "warm melodic house",
                hasReferenceTrackEmbedding: false
            ) == false
        )
    }

    @Test
    func searchModeStateChangesBetweenTextAndReferenceModes() {
        let validated = ValidationStatus.validated(Date())

        #expect(SearchMode.text.isQueryEditable)
        #expect(SearchMode.text.queryPlaceholder == "Describe the sound or transition you want")
        #expect(
            SearchMode.text.canSubmit(
                validationStatus: validated,
                isBusy: false,
                queryText: "  deep rolling bass  ",
                hasReferenceTrackEmbedding: false
            )
        )
        #expect(
            SearchMode.text.canSubmit(
                validationStatus: validated,
                isBusy: false,
                queryText: "   ",
                hasReferenceTrackEmbedding: false
            ) == false
        )

        #expect(SearchMode.referenceTrack.isQueryEditable == false)
        #expect(SearchMode.referenceTrack.queryPlaceholder == "Reference track mode uses selected tracks")
        #expect(
            SearchMode.referenceTrack.canSubmit(
                validationStatus: validated,
                isBusy: false,
                queryText: "",
                hasReferenceTrackEmbedding: false
            ) == false
        )
        #expect(
            SearchMode.referenceTrack.canSubmit(
                validationStatus: validated,
                isBusy: false,
                queryText: "",
                hasReferenceTrackEmbedding: true
            )
        )
    }

    @Test
    func recommendationInputStateResolvesTextReferenceHybridAndEmptyCases() {
        #expect(
            RecommendationInputState.resolve(queryText: " warm sunrise ", readyReferenceCount: 0)?.mode == .text
        )
        #expect(
            RecommendationInputState.resolve(queryText: "", readyReferenceCount: 1)?.mode == .reference
        )
        #expect(
            RecommendationInputState.resolve(queryText: "deep opener", readyReferenceCount: 2)?.mode == .hybrid
        )
        #expect(
            RecommendationInputState.resolve(queryText: "   ", readyReferenceCount: 0) == nil
        )
    }

    @Test
    func recommendationInputStateChoosesDirectSeedOnlyForSingleReferenceMode() {
        #expect(
            RecommendationInputState.resolve(queryText: "", readyReferenceCount: 1)?.seedSource == .selectedReference
        )
        #expect(
            RecommendationInputState.resolve(queryText: "", readyReferenceCount: 2)?.seedSource == .semanticMatch
        )
        #expect(
            RecommendationInputState.resolve(queryText: "peak time", readyReferenceCount: 0)?.seedSource == .semanticMatch
        )
        #expect(
            RecommendationInputState.resolve(queryText: "peak time", readyReferenceCount: 1)?.seedSource == .semanticMatch
        )
    }

    @Test
    @MainActor
    func libraryRecommendationSearchPreparationClearsTextAndResolvesSelectionOnlyMode() {
        let viewModel = AppViewModel(skipAsyncBootstrap: true)
        let ready = makeTrack(
            title: "Ready",
            analyzedAt: Date(),
            embeddingProfileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id,
            embeddingUpdatedAt: Date()
        )
        let pending = makeTrack(
            title: "Pending",
            analyzedAt: nil,
            embeddingProfileID: nil,
            embeddingUpdatedAt: nil
        )

        viewModel.configureRecommendationSearchStateForTesting(
            tracks: [ready, pending],
            selectedTrackIDs: [ready.id, pending.id],
            readyTrackIDs: [ready.id],
            validationStatus: .validated(Date()),
            recommendationQueryText: "peak opener"
        )

        let action = viewModel.prepareRecommendationSearchFromLibrary()

        #expect(action == .autoGenerate)
        #expect(viewModel.selectedSection == .mixAssistant)
        #expect(viewModel.recommendationQueryText.isEmpty)
        #expect(viewModel.recommendationInputState?.mode == .reference)
        #expect(viewModel.recommendationInputState?.readyReferenceCount == 1)
    }

    @Test
    @MainActor
    func libraryRecommendationSearchAutoGeneratesResultsWhenReadySelectionIsRunnable() async throws {
        let viewModel = AppViewModel(skipAsyncBootstrap: true)
        let ready = makeTrack(
            title: "Ready",
            analyzedAt: Date(),
            embeddingProfileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id,
            embeddingUpdatedAt: Date()
        )
        let candidate = makeRecommendationCandidate(title: "Generated Candidate")

        viewModel.configureRecommendationSearchStateForTesting(
            tracks: [ready],
            selectedTrackIDs: [ready.id],
            readyTrackIDs: [ready.id],
            validationStatus: .validated(Date()),
            recommendationQueryText: "carryover text"
        )
        viewModel.setRecommendationGenerationStubForTesting(
            results: [candidate],
            delayNanoseconds: 50_000_000,
            completionStatusMessage: "Generated 1 matches. Curate the list before building the playlist."
        )

        viewModel.openRecommendationSearchFromLibrary()

        #expect(viewModel.selectedSection == .mixAssistant)
        #expect(viewModel.recommendationQueryText.isEmpty)
        #expect(viewModel.isGeneratingRecommendations)
        #expect(viewModel.recommendationStatusMessage == "Generating matches from current library selection...")

        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(viewModel.isGeneratingRecommendations == false)
        #expect(viewModel.generatedRecommendations.map(\.track.id) == [candidate.track.id])
        #expect(viewModel.recommendations.map(\.track.id) == [candidate.track.id])
    }

    @Test
    @MainActor
    func pendingOnlyLibraryRecommendationSearchNavigatesWithoutAutoGenerate() {
        let viewModel = AppViewModel(skipAsyncBootstrap: true)
        let pending = makeTrack(
            title: "Pending",
            analyzedAt: nil,
            embeddingProfileID: nil,
            embeddingUpdatedAt: nil
        )

        viewModel.configureRecommendationSearchStateForTesting(
            tracks: [pending],
            selectedTrackIDs: [pending.id],
            readyTrackIDs: [],
            validationStatus: .validated(Date()),
            recommendationQueryText: "carryover text"
        )

        let action = viewModel.prepareRecommendationSearchFromLibrary()

        #expect(action == .navigateOnly)
        #expect(viewModel.selectedSection == .mixAssistant)
        #expect(viewModel.recommendationQueryText.isEmpty)
        #expect(viewModel.isGeneratingRecommendations == false)
        #expect(viewModel.generatedRecommendations.isEmpty)
        #expect(viewModel.recommendationInputState == nil)
    }

    @Test
    @MainActor
    func libraryRecommendationSearchReusesExistingGeneratedResultsForSelectionOnlyState() {
        let viewModel = AppViewModel(skipAsyncBootstrap: true)
        let ready = makeTrack(
            title: "Ready",
            analyzedAt: Date(),
            embeddingProfileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id,
            embeddingUpdatedAt: Date()
        )
        let candidate = makeRecommendationCandidate(title: "Reusable Candidate")

        viewModel.configureRecommendationSearchStateForTesting(
            tracks: [ready],
            selectedTrackIDs: [ready.id],
            readyTrackIDs: [ready.id],
            validationStatus: .validated(Date()),
            recommendationQueryText: "   ",
            recommendationStatusMessage: "Generated 1 matches. Curate the list before building the playlist.",
            generatedRecommendations: [candidate]
        )

        let action = viewModel.prepareRecommendationSearchFromLibrary()

        #expect(action == .reuseExistingResults)
        #expect(viewModel.recommendationQueryText.isEmpty)
        #expect(viewModel.isGeneratingRecommendations == false)
        #expect(viewModel.generatedRecommendations.map(\.track.id) == [candidate.track.id])
        #expect(viewModel.recommendations.map(\.track.id) == [candidate.track.id])
    }

    @Test
    func recommendationResultLimitClampsToSupportedOptions() {
        #expect(RecommendationInputState.clampedResultLimit(3) == 30)
        #expect(RecommendationInputState.clampedResultLimit(42) == 30)
        #expect(RecommendationInputState.clampedResultLimit(61) == 60)
        #expect(RecommendationInputState.clampedResultLimit(120) == 120)
        #expect(RecommendationInputState.clampedResultLimit(999) == 120)
    }

    @Test
    @MainActor
    func playlistPathTargetCountFollowsRecommendationResultLimit() {
        let viewModel = AppViewModel(skipAsyncBootstrap: true)

        viewModel.recommendationResultLimit = 20
        #expect(viewModel.playlistPathTargetCount == 30)

        viewModel.recommendationResultLimit = 61
        #expect(viewModel.playlistPathTargetCount == 60)

        viewModel.recommendationResultLimit = 120
        #expect(viewModel.playlistPathTargetCount == 120)
    }

    @Test
    func playlistPathStatusMessageIncludesRequestedCountWhenPartial() {
        #expect(
            AppViewModel.playlistPathStatusMessage(
                builtCount: 14,
                requestedCount: 20,
                seedTitle: "Warmup Seed"
            ) == "Built 14/20-track path from seed: Warmup Seed"
        )
        #expect(
            AppViewModel.playlistPathStatusMessage(
                builtCount: 20,
                requestedCount: 20,
                seedTitle: "Warmup Seed"
            ) == "Built 20-track path from seed: Warmup Seed"
        )
    }

    @Test
    @MainActor
    func generatedRecommendationsSupportCuratedRemovalRestoreAndInvalidation() {
        let viewModel = AppViewModel(skipAsyncBootstrap: true)
        let first = makeRecommendationCandidate(title: "First Candidate")
        let second = makeRecommendationCandidate(title: "Second Candidate")

        viewModel.applyGeneratedRecommendationsForTesting([first, second])
        viewModel.setRecommendationSelectedForCuration(first.track.id, isSelected: true)
        viewModel.removeSelectedGeneratedRecommendations()

        #expect(viewModel.generatedRecommendations.count == 2)
        #expect(viewModel.recommendations.map(\.track.id) == [second.track.id])
        #expect(viewModel.excludedGeneratedTrackIDs.contains(first.track.id))

        viewModel.restoreGeneratedRecommendations()

        #expect(viewModel.recommendations.map(\.track.id) == [first.track.id, second.track.id])
        #expect(viewModel.excludedGeneratedTrackIDs.isEmpty)

        viewModel.recommendationQueryText = "new direction"

        #expect(viewModel.generatedRecommendations.isEmpty)
        #expect(viewModel.recommendations.isEmpty)
        #expect(viewModel.recommendationStatusMessage.contains("Generate again"))
    }

    @Test
    @MainActor
    func generateRecommendationsTogglesBusyStateAndBlocksDuplicateRequests() async throws {
        let viewModel = AppViewModel(skipAsyncBootstrap: true)
        let ready = makeTrack(
            title: "Ready",
            analyzedAt: Date(),
            embeddingProfileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id,
            embeddingUpdatedAt: Date()
        )
        let candidate = makeRecommendationCandidate(title: "Busy Candidate")

        viewModel.configureRecommendationSearchStateForTesting(
            tracks: [ready],
            selectedTrackIDs: [ready.id],
            readyTrackIDs: [ready.id],
            validationStatus: .validated(Date())
        )
        viewModel.setRecommendationGenerationStubForTesting(
            results: [candidate],
            delayNanoseconds: 100_000_000,
            completionStatusMessage: "Generated 1 matches. Curate the list before building the playlist."
        )

        viewModel.generateRecommendations()

        #expect(viewModel.isGeneratingRecommendations)
        #expect(viewModel.recommendationStatusMessage == "Generating matches...")

        viewModel.generateRecommendations()

        #expect(viewModel.recommendationStatusMessage == "Recommendation search is already running.")

        try await Task.sleep(nanoseconds: 150_000_000)

        #expect(viewModel.isGeneratingRecommendations == false)
        #expect(viewModel.generatedRecommendations.map(\.track.id) == [candidate.track.id])
        #expect(viewModel.recommendations.map(\.track.id) == [candidate.track.id])
    }

    @Test
    @MainActor
    func curatedPlaylistBuilderUsesOnlyProvidedCandidatesAndExcludesSeedTrack() throws {
        let seed = makeTrack(
            title: "Seed",
            analyzedAt: Date(),
            embeddingProfileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id,
            embeddingUpdatedAt: Date()
        )
        let first = makeTrack(
            title: "First",
            analyzedAt: Date(),
            embeddingProfileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id,
            embeddingUpdatedAt: Date()
        )
        let second = makeTrack(
            title: "Second",
            analyzedAt: Date(),
            embeddingProfileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id,
            embeddingUpdatedAt: Date()
        )

        let ordered = try AppViewModel.buildCuratedPlaylistCandidates(
            seed: seed,
            curatedCandidates: [
                makeRecommendationCandidate(track: first, score: 0.85),
                makeRecommendationCandidate(track: second, score: 0.80)
            ],
            embeddingsByTrackID: [
                seed.id: [1.0, 0.0, 0.0],
                first.id: [0.95, 0.05, 0.0],
                second.id: [0.60, 0.40, 0.0]
            ],
            summariesByTrackID: [:],
            libraryRoots: [],
            constraints: RecommendationConstraints(),
            weights: RecommendationWeights(),
            vectorWeights: MixsetVectorWeights(),
            vectorBreakdownProvider: { _, _ in [:] }
        )

        #expect(ordered.map(\.track.id) == [first.id, second.id])
        #expect(ordered.contains(where: { $0.track.id == seed.id }) == false)
    }

    @Test
    func playlistBuildProgressHeadlineTracksOrderingStage() {
        let progress = PlaylistBuildProgress(
            stage: .orderingTrack,
            completedCount: 2,
            totalCount: 5,
            progress: 0.48,
            currentSeedTitle: "Seed",
            latestTrackTitle: "Third",
            message: "Evaluating remaining curated tracks."
        )

        #expect(progress.headlineText == "Ordering track 3/5")
        #expect(abs(progress.clampedProgress - 0.48) < 0.0001)
    }

    @Test
    func hybridTrackSearchPayloadCarriesTextAndReferenceInputs() {
        let segment = TrackSegment(
            id: UUID(),
            trackID: UUID(),
            type: .intro,
            startSec: 0,
            endSec: 32,
            energyScore: 0.4,
            descriptorText: "warm opener",
            vector: [0.3, 0.7]
        )
        let payload = PythonWorkerClient.makeTrackSearchPayload(
            mode: .hybrid,
            queryText: "warmup journey",
            trackEmbedding: [0.25, 0.75],
            segments: [segment],
            limit: 25,
            excludeTrackPaths: ["/tmp/ref.mp3"],
            filters: WorkerSimilarityFilters()
        )

        #expect(payload.mode == .hybrid)
        #expect(payload.queryText == "warmup journey")
        #expect(payload.queryTrackEmbedding == [0.25, 0.75])
        #expect(payload.querySegments == [
            WorkerQuerySegment(segmentType: "intro", embedding: [0.3, 0.7])
        ])
    }

    @Test
    func legacyAnalysisSummaryDecodesWithNewDefaults() throws {
        let trackID = UUID()
        let json = """
        {
          "trackID": "\(trackID.uuidString)",
          "segments": [],
          "trackEmbedding": [0.2, 0.3],
          "estimatedBPM": 124.0,
          "estimatedKey": "8A",
          "brightness": 0.5,
          "onsetDensity": 0.4,
          "rhythmicDensity": 0.6,
          "lowMidHighBalance": [0.2, 0.5, 0.3],
          "waveformPreview": [0.1, 0.2, 0.3]
        }
        """

        let summary = try JSONDecoder().decode(TrackAnalysisSummary.self, from: Data(json.utf8))

        #expect(summary.analysisFocus == .balanced)
        #expect(summary.introLengthSec == 0)
        #expect(summary.outroLengthSec == 0)
        #expect(summary.energyArc.isEmpty)
        #expect(summary.mixabilityTags.isEmpty)
        #expect(summary.confidence == 0.5)
    }

    private func makeTrack(
        id: UUID = UUID(),
        title: String? = nil,
        artist: String = "Artist",
        analyzedAt: Date?,
        embeddingProfileID: String?,
        embeddingUpdatedAt: Date?,
        bpm: Double? = 124
    ) -> Track {
        Track(
            id: id,
            filePath: "/tmp/\(id.uuidString).mp3",
            fileName: "\(id.uuidString).mp3",
            title: title ?? "Track \(id.uuidString.prefix(4))",
            artist: artist,
            album: "Album",
            genre: "House",
            duration: 240,
            sampleRate: 44_100,
            bpm: bpm,
            musicalKey: "8A",
            modifiedTime: Date(timeIntervalSince1970: 1_700_000_000),
            contentHash: id.uuidString,
            analyzedAt: analyzedAt,
            embeddingProfileID: embeddingProfileID,
            embeddingUpdatedAt: embeddingUpdatedAt,
            hasSeratoMetadata: false,
            hasRekordboxMetadata: false,
            bpmSource: nil,
            keySource: nil
        )
    }

    private func makeRecommendationCandidate(
        track: Track? = nil,
        title: String = "Candidate",
        score: Double = 0.9
    ) -> RecommendationCandidate {
        let resolvedTrack = track ?? makeTrack(
            title: title,
            analyzedAt: Date(),
            embeddingProfileID: EmbeddingProfile.googleGeminiEmbedding2Preview.id,
            embeddingUpdatedAt: Date()
        )

        return RecommendationCandidate(
            id: resolvedTrack.id,
            track: resolvedTrack,
            score: score,
            breakdown: ScoreBreakdown(
                embeddingSimilarity: score,
                bpmCompatibility: 0.8,
                harmonicCompatibility: 0.8,
                energyFlow: 0.8,
                transitionRegionMatch: 0.8,
                externalMetadataScore: 0.6
            ),
            vectorBreakdown: VectorScoreBreakdown(
                fusedScore: score,
                trackScore: score,
                introScore: score * 0.95,
                middleScore: score * 0.9,
                outroScore: score * 0.85,
                bestMatchedCollection: "tracks"
            ),
            analysisFocus: .balanced,
            mixabilityTags: [],
            matchReasons: [],
            matchedMemberships: [],
            scoreSessionID: nil
        )
    }
}
