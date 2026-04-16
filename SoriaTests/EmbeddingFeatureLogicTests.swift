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
    func recommendationResultLimitClampsToSupportedRange() {
        #expect(RecommendationInputState.clampedResultLimit(3) == 10)
        #expect(RecommendationInputState.clampedResultLimit(42) == 42)
        #expect(RecommendationInputState.clampedResultLimit(120) == 100)
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
        analyzedAt: Date?,
        embeddingProfileID: String?,
        embeddingUpdatedAt: Date?
    ) -> Track {
        Track(
            id: id,
            filePath: "/tmp/\(id.uuidString).mp3",
            fileName: "\(id.uuidString).mp3",
            title: "Track \(id.uuidString.prefix(4))",
            artist: "Artist",
            album: "Album",
            genre: "House",
            duration: 240,
            sampleRate: 44_100,
            bpm: 124,
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
}
