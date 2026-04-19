//
//  SoriaUITests.swift
//  SoriaUITests
//
//  Created by Junseop So on 4/14/26.
//

import XCTest

final class SoriaUITests: XCTestCase {
    private enum LibraryState: String {
        case empty
        case prepared
        case readySelection = "ready_selection"
        case multiSelection = "multi_selection"
        case analyzing
        case generated
        case generating
        case buildingPlaylist = "building_playlist"

        var launchArgument: String {
            "UITEST_LIBRARY_STATE=\(rawValue)"
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testExample() throws {
        let app = launchApp(libraryState: .prepared)

        XCTAssertTrue(element(in: app, identifier: "library-action-bar").waitForExistence(timeout: 10))
        XCTAssertTrue(element(in: app, identifier: "library-table").waitForExistence(timeout: 10))
        XCTAssertFalse(element(in: app, identifier: "library-preparation-card").exists)
    }

    @MainActor
    func testInfoPaneStaysAboveLibraryAndShowsSelectedTabContent() throws {
        let app = launchApp(libraryState: .prepared, startInMixAssistant: true)

        let mixAssistantPane = element(in: app, identifier: "right-pane-mix-assistant")

        XCTAssertTrue(mixAssistantPane.waitForExistence(timeout: 10))
        XCTAssertTrue(element(in: app, identifier: "advanced-score-controls").waitForExistence(timeout: 10))
        XCTAssertFalse(element(in: app, identifier: "right-pane-library").exists)
    }

    @MainActor
    func testLibraryPreparationOverviewRemovesRecommendationShortcuts() throws {
        let app = launchApp(libraryState: .prepared)
        let pendingTrackCell = app.staticTexts["Pending Track"].firstMatch
        XCTAssertTrue(pendingTrackCell.waitForExistence(timeout: 10))
        forceClick(pendingTrackCell)

        let analyzeSelectionButton = element(in: app, identifier: "library-analyze-selection-button")
        let recommendationSearchButton = element(in: app, identifier: "library-recommendation-search-button")

        XCTAssertTrue(element(in: app, identifier: "library-action-bar").waitForExistence(timeout: 10))
        XCTAssertTrue(element(in: app, identifier: "scope-filter-open-library").waitForExistence(timeout: 10))
        XCTAssertTrue(analyzeSelectionButton.waitForExistence(timeout: 10))
        XCTAssertTrue(recommendationSearchButton.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForEnabled(analyzeSelectionButton))
        XCTAssertTrue(waitForEnabled(recommendationSearchButton))
        XCTAssertFalse(element(in: app, identifier: "library-preparation-card").exists)
    }

    @MainActor
    func testEmptyLibraryShowsSetupPrompt() throws {
        let app = launchApp(libraryState: .empty)

        XCTAssertTrue(element(in: app, identifier: "library-setup-card").waitForExistence(timeout: 10))
        XCTAssertTrue(element(in: app, identifier: "library-setup-button").waitForExistence(timeout: 10))
        XCTAssertTrue(element(in: app, identifier: "library-empty-state").waitForExistence(timeout: 10))
    }

    @MainActor
    func testStartupPromptsForGoogleAPIKeyWhenMissing() throws {
        let app = launchApp(libraryState: .prepared, forceInitialSetup: true)

        let initialSetupSheet = element(in: app, identifier: "initial-setup-sheet")
        let keyField = element(in: app, identifier: "initial-setup-google-api-key-field")
        let primaryButton = app.buttons["Validate and Start Setup"].firstMatch

        XCTAssertTrue(initialSetupSheet.waitForExistence(timeout: 10))
        XCTAssertTrue(keyField.waitForExistence(timeout: 10))
        XCTAssertTrue(primaryButton.waitForExistence(timeout: 10))
        XCTAssertFalse(primaryButton.isEnabled)

        keyField.click()
        keyField.typeText("test-google-key")

        XCTAssertTrue(primaryButton.isEnabled)
    }

    @MainActor
    func testSyncSheetShowsCloseButtonFromSettings() throws {
        let app = launchApp(libraryState: .prepared)

        element(in: app, identifier: "sidebar-settings").click()

        XCTAssertTrue(element(in: app, identifier: "settings-library-sources").waitForExistence(timeout: 10))

        let syncButton = app.buttons["Refresh Vendor Metadata"].firstMatch
        XCTAssertTrue(syncButton.waitForExistence(timeout: 10))
        syncButton.click()

        let closeButton = element(in: app, identifier: "library-sync-close-button")
        XCTAssertTrue(closeButton.waitForExistence(timeout: 10))
    }

    @MainActor
    func testAdvancedFiltersOpenInspectorFromLibrary() throws {
        let app = launchApp(libraryState: .prepared)

        let openFiltersButton = element(in: app, identifier: "scope-filter-open-library")
        XCTAssertTrue(openFiltersButton.waitForExistence(timeout: 10))
        openFiltersButton.click()

        let inspector = element(in: app, identifier: "scope-filter-inspector-library")
        XCTAssertTrue(inspector.waitForExistence(timeout: 10))
        XCTAssertTrue(element(in: app, identifier: "scope-filter-search-serato").waitForExistence(timeout: 10))

        let seratoSearch = element(in: app, identifier: "scope-filter-search-serato")
        seratoSearch.click()
        seratoSearch.typeText("Edits")

        XCTAssertTrue(
            element(in: app, identifier: "scope-filter-facet-serato-disco-edits").waitForExistence(timeout: 10)
        )
    }

    @MainActor
    func testAdvancedFiltersButtonTogglesInspectorFromLibrary() throws {
        let app = launchApp(libraryState: .prepared)

        let toggleButton = element(in: app, identifier: "scope-filter-open-library")
        XCTAssertTrue(toggleButton.waitForExistence(timeout: 10))
        toggleButton.click()

        let inspector = element(in: app, identifier: "scope-filter-inspector-library")
        XCTAssertTrue(inspector.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Hide References"].waitForExistence(timeout: 10))

        toggleButton.click()

        XCTAssertFalse(inspector.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Open References"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testDJScopeInspectorOpensFromMixAssistant() throws {
        let app = launchApp(libraryState: .prepared, startInMixAssistant: true)

        XCTAssertTrue(element(in: app, identifier: "right-pane-mix-assistant").waitForExistence(timeout: 10))
        XCTAssertFalse(element(in: app, identifier: "right-pane-library").exists)
        XCTAssertTrue(element(in: app, identifier: "advanced-score-controls").waitForExistence(timeout: 10))
        XCTAssertFalse(element(in: app, identifier: "score-weight-embedding").exists)
        XCTAssertFalse(app.buttons["Find Similar Tracks"].exists)

        let advancedControlsButton = element(in: app, identifier: "advanced-score-controls-toggle")
        XCTAssertTrue(advancedControlsButton.waitForExistence(timeout: 10))
        advancedControlsButton.click()
        XCTAssertTrue(element(in: app, identifier: "score-weight-embedding").waitForExistence(timeout: 10))

        let openFiltersButton = element(in: app, identifier: "scope-filter-open-recommendation")
        XCTAssertTrue(openFiltersButton.waitForExistence(timeout: 10))
        openFiltersButton.click()

        XCTAssertTrue(element(in: app, identifier: "scope-filter-inspector-recommendation").waitForExistence(timeout: 10))
    }

    @MainActor
    func testRecommendationSearchFromLibraryAutoGeneratesWhenReadySelectionExists() throws {
        let app = launchApp(libraryState: .readySelection)

        let recommendationButton = element(in: app, identifier: "library-recommendation-search-button")
        XCTAssertTrue(recommendationButton.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForEnabled(recommendationButton))
        recommendationButton.click()

        let curationSummary = element(in: app, identifier: "recommendation-curation-summary")
        let queryField = element(in: app, identifier: "recommendation-query-field")

        XCTAssertTrue(element(in: app, identifier: "right-pane-mix-assistant").waitForExistence(timeout: 10))
        XCTAssertFalse(element(in: app, identifier: "right-pane-library").exists)
        XCTAssertTrue(curationSummary.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(of: curationSummary, toContain: "Showing 2"))
        XCTAssertTrue(queryField.waitForExistence(timeout: 10))
        XCTAssertNotEqual(queryField.value as? String, "Warmup journey")
    }

    @MainActor
    func testPendingOnlyRecommendationSearchStillNavigatesWithoutAutoGenerate() throws {
        let app = launchApp(libraryState: .prepared)

        let pendingTrackCell = app.staticTexts["Pending Track"].firstMatch
        XCTAssertTrue(pendingTrackCell.waitForExistence(timeout: 10))
        forceClick(pendingTrackCell)

        let recommendationButton = element(in: app, identifier: "library-recommendation-search-button")
        XCTAssertTrue(recommendationButton.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForEnabled(recommendationButton))
        recommendationButton.click()

        let curationSummary = element(in: app, identifier: "recommendation-curation-summary")

        XCTAssertTrue(element(in: app, identifier: "right-pane-mix-assistant").waitForExistence(timeout: 10))
        XCTAssertFalse(element(in: app, identifier: "right-pane-library").exists)
        XCTAssertTrue(curationSummary.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(of: curationSummary, toContain: "Generate matches"))
    }

    @MainActor
    func testRecommendationSearchFromLibraryClearsPreviousQueryBeforeAutoRun() throws {
        let app = launchApp(libraryState: .generated)

        let recommendationButton = element(in: app, identifier: "library-recommendation-search-button")
        XCTAssertTrue(recommendationButton.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForEnabled(recommendationButton))
        recommendationButton.click()

        let queryField = element(in: app, identifier: "recommendation-query-field")
        let curationSummary = element(in: app, identifier: "recommendation-curation-summary")

        XCTAssertTrue(element(in: app, identifier: "right-pane-mix-assistant").waitForExistence(timeout: 10))
        XCTAssertTrue(queryField.waitForExistence(timeout: 10))
        XCTAssertNotEqual(queryField.value as? String, "Warmup journey")
        XCTAssertTrue(waitForLabel(of: curationSummary, toContain: "Showing 2"))
    }

    @MainActor
    func testGeneratedRecommendationsCanBeRemovedAndRestored() throws {
        let app = launchApp(libraryState: .generated, startInMixAssistant: true)

        let pendingToggle = element(in: app, identifier: "recommendation-curation-toggle-pending-track")
        let removeButton = element(in: app, identifier: "recommendation-remove-selected-button")
        let restoreButton = element(in: app, identifier: "recommendation-restore-all-button")

        XCTAssertTrue(pendingToggle.waitForExistence(timeout: 10))
        XCTAssertTrue(removeButton.waitForExistence(timeout: 10))
        XCTAssertTrue(restoreButton.waitForExistence(timeout: 10))

        pendingToggle.click()
        removeButton.click()

        XCTAssertFalse(pendingToggle.waitForExistence(timeout: 2))
        XCTAssertTrue(waitForLabel(of: element(in: app, identifier: "recommendation-curation-summary"), toContain: "hidden"))

        restoreButton.click()

        XCTAssertTrue(pendingToggle.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(of: element(in: app, identifier: "recommendation-curation-summary"), toContain: "Showing 3"))
    }

    @MainActor
    func testBuildingPlaylistShowsProgressAndDisablesActions() throws {
        let app = launchApp(libraryState: .buildingPlaylist, startInMixAssistant: true)

        let progressCard = element(in: app, identifier: "playlist-build-progress-card")
        let progressHeadline = element(in: app, identifier: "playlist-build-progress-headline")
        let generateButton = element(in: app, identifier: "recommendation-generate-button")
        let buildButton = element(in: app, identifier: "recommendation-build-playlist-button")

        XCTAssertTrue(progressCard.waitForExistence(timeout: 10))
        XCTAssertTrue(progressHeadline.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(of: progressHeadline, toContain: "Ordering track"))
        XCTAssertTrue(generateButton.waitForExistence(timeout: 10))
        XCTAssertTrue(buildButton.waitForExistence(timeout: 10))
        XCTAssertFalse(generateButton.isEnabled)
        XCTAssertFalse(buildButton.isEnabled)
    }

    @MainActor
    func testGeneratingRecommendationsShowsBusyStateAndDisablesControls() throws {
        let app = launchApp(libraryState: .generating, startInMixAssistant: true)

        let generateButton = element(in: app, identifier: "recommendation-generate-button")
        let buildButton = element(in: app, identifier: "recommendation-build-playlist-button")
        let queryField = element(in: app, identifier: "recommendation-query-field")
        let resultLimitPicker = element(in: app, identifier: "recommendation-result-limit-picker")
        let statusMessage = element(in: app, identifier: "recommendation-status-message")

        XCTAssertTrue(generateButton.waitForExistence(timeout: 10))
        XCTAssertTrue(buildButton.waitForExistence(timeout: 10))
        XCTAssertTrue(queryField.waitForExistence(timeout: 10))
        XCTAssertTrue(resultLimitPicker.waitForExistence(timeout: 10))
        XCTAssertTrue(statusMessage.waitForExistence(timeout: 10))
        XCTAssertEqual(resolvedText(of: generateButton), "Generating...")
        XCTAssertTrue(waitForLabel(of: statusMessage, toContain: "Generating matches from current library selection"))
        XCTAssertFalse(generateButton.isEnabled)
        XCTAssertFalse(buildButton.isEnabled)
        XCTAssertFalse(queryField.isEnabled)
        XCTAssertFalse(resultLimitPicker.isEnabled)
    }

    @MainActor
    func testCancelingAnalysisReturnsToActionableState() throws {
        let app = launchApp(libraryState: .analyzing)

        let cancelButton = app.buttons.matching(identifier: "library-cancel-button").firstMatch
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 10))
        cancelButton.click()

        XCTAssertTrue(element(in: app, identifier: "library-preparation-notice").waitForExistence(timeout: 10))
        XCTAssertTrue(element(in: app, identifier: "library-analyze-selection-button").waitForExistence(timeout: 10))
        XCTAssertFalse(cancelButton.exists)
    }

    @MainActor
    func testSelectingPlaylistFilterClearsHiddenLibrarySelectionWithoutCrashing() throws {
        let app = launchApp(libraryState: .prepared)

        let readyTrackCell = app.staticTexts["Ready Track"].firstMatch
        XCTAssertTrue(readyTrackCell.waitForExistence(timeout: 10))
        forceClick(readyTrackCell)

        let openFiltersButton = element(in: app, identifier: "scope-filter-open-library")
        XCTAssertTrue(openFiltersButton.waitForExistence(timeout: 10))
        openFiltersButton.click()

        let seratoSearch = element(in: app, identifier: "scope-filter-search-serato")
        XCTAssertTrue(seratoSearch.waitForExistence(timeout: 10))
        seratoSearch.click()
        seratoSearch.typeText("Edits")

        let playlistFacet = element(in: app, identifier: "scope-filter-facet-serato-disco-edits")
        XCTAssertTrue(playlistFacet.waitForExistence(timeout: 10))
        playlistFacet.click()

        XCTAssertTrue(element(in: app, identifier: "library-action-bar").waitForExistence(timeout: 10))
        XCTAssertTrue(element(in: app, identifier: "library-selection-headline").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No tracks selected"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testLibrarySearchFiltersTracksAcrossTitleAndArtistTokens() throws {
        let app = launchApp(libraryState: .prepared)

        let searchField = librarySearchField(in: app)
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.click()
        searchField.typeText("ready")

        XCTAssertTrue(waitForNonExistence(of: element(in: app, identifier: "library-search-empty-state")))
    }

    @MainActor
    func testLibrarySearchShowsEmptyStateWhenNoTracksMatch() throws {
        let app = launchApp(libraryState: .prepared)

        let searchField = librarySearchField(in: app)
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.click()
        searchField.typeText("zzz-no-match")

        XCTAssertTrue(element(in: app, identifier: "library-search-empty-state").waitForExistence(timeout: 10))
        XCTAssertTrue(waitForNonExistence(of: app.staticTexts["Ready Track"].firstMatch))
    }

    @MainActor
    func testLibraryHeadersAreSimplifiedAndSettingsKeepSourceDetails() throws {
        let app = launchApp(libraryState: .prepared)

        XCTAssertTrue(element(in: app, identifier: "library-table").waitForExistence(timeout: 10))
        XCTAssertTrue(element(in: app, identifier: "library-column-title").waitForExistence(timeout: 10))
        XCTAssertTrue(element(in: app, identifier: "library-column-artist").exists)
        XCTAssertTrue(element(in: app, identifier: "library-column-bpm-key").exists)
        XCTAssertTrue(element(in: app, identifier: "library-column-status").exists)
        XCTAssertFalse(element(in: app, identifier: "library-column-duration").exists)
        XCTAssertFalse(element(in: app, identifier: "library-column-genre").exists)

        element(in: app, identifier: "sidebar-settings").click()

        XCTAssertTrue(element(in: app, identifier: "settings-library-sources").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Refresh Vendor Metadata"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testLibraryPreviewStripAppearsForSingleSelection() throws {
        let app = launchApp(libraryState: .readySelection)

        XCTAssertTrue(element(in: app, identifier: "library-preview-strip").waitForExistence(timeout: 10))
        XCTAssertTrue(element(in: app, identifier: "library-preview-toggle").waitForExistence(timeout: 10))
        XCTAssertTrue(element(in: app, identifier: "library-preview-progress").waitForExistence(timeout: 10))
        XCTAssertTrue(element(in: app, identifier: "library-preview-time").waitForExistence(timeout: 10))
    }

    @MainActor
    func testLibraryPreviewStripHidesForMultiSelection() throws {
        let app = launchApp(libraryState: .multiSelection)

        XCTAssertFalse(element(in: app, identifier: "library-preview-strip").waitForExistence(timeout: 2))
    }

    @MainActor
    func testLibraryPreviewToggleButtonUpdatesPlaybackState() throws {
        let app = launchApp(libraryState: .readySelection)
        let previewToggle = element(in: app, identifier: "library-preview-toggle")

        XCTAssertTrue(previewToggle.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(of: previewToggle, toEqual: "Play Preview"))

        previewToggle.click()
        XCTAssertTrue(waitForLabel(of: previewToggle, toEqual: "Pause Preview"))

        previewToggle.click()
        XCTAssertTrue(waitForLabel(of: previewToggle, toEqual: "Play Preview"))
    }

    @MainActor
    func testLibraryPreviewWaveformClickSeeksAndUpdatesTimeLabel() throws {
        let app = launchApp(libraryState: .readySelection)
        let waveform = element(in: app, identifier: "library-preview-progress")
        let timeLabel = element(in: app, identifier: "library-preview-time")
        let previewToggle = element(in: app, identifier: "library-preview-toggle")

        XCTAssertTrue(waveform.waitForExistence(timeout: 10))
        XCTAssertTrue(timeLabel.waitForExistence(timeout: 10))

        waveform.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        XCTAssertTrue(waitForLabel(of: timeLabel, toContain: "2:01 / 4:03"))
        XCTAssertTrue(waitForLabel(of: previewToggle, toEqual: "Pause Preview"))
    }

    @MainActor
    func testLibraryPreviewRapidWaveformClicksKeepLatestPosition() throws {
        let app = launchApp(libraryState: .readySelection)
        let waveform = element(in: app, identifier: "library-preview-progress")
        let timeLabel = element(in: app, identifier: "library-preview-time")
        let previewToggle = element(in: app, identifier: "library-preview-toggle")

        XCTAssertTrue(waveform.waitForExistence(timeout: 10))
        XCTAssertTrue(timeLabel.waitForExistence(timeout: 10))

        waveform.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).click()
        waveform.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).click()

        XCTAssertTrue(waitForLabel(of: timeLabel, toContain: "3:02 / 4:03"))
        XCTAssertTrue(waitForLabel(of: previewToggle, toEqual: "Pause Preview"))
    }

    @MainActor
    func testLibraryPreviewCueMarkerExistsAndSeeksToCueTime() throws {
        let app = launchApp(libraryState: .readySelection)
        let cueMarker = element(in: app, identifier: "library-preview-cue-1")
        let timeLabel = element(in: app, identifier: "library-preview-time")

        XCTAssertTrue(cueMarker.waitForExistence(timeout: 10))
        XCTAssertTrue(timeLabel.waitForExistence(timeout: 10))

        cueMarker.click()

        XCTAssertTrue(waitForLabel(of: timeLabel, toContain: "0:24 / 4:03"))
    }

    @MainActor
    func testSpaceTogglesLibraryPreviewWhenSearchIsNotFocused() throws {
        let app = launchApp(libraryState: .readySelection)
        let previewToggle = element(in: app, identifier: "library-preview-toggle")

        XCTAssertTrue(previewToggle.waitForExistence(timeout: 10))
        element(in: app, identifier: "library-action-bar").click()
        app.typeKey(XCUIKeyboardKey.space, modifierFlags: [])

        XCTAssertTrue(waitForLabel(of: previewToggle, toEqual: "Pause Preview"))
    }

    @MainActor
    func testSpaceDoesNotToggleLibraryPreviewWhileSearchIsFocused() throws {
        let app = launchApp(libraryState: .readySelection)
        let previewToggle = element(in: app, identifier: "library-preview-toggle")
        let searchField = librarySearchField(in: app)

        XCTAssertTrue(previewToggle.waitForExistence(timeout: 10))
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.click()
        app.typeKey(XCUIKeyboardKey.space, modifierFlags: [])

        XCTAssertTrue(waitForLabel(of: previewToggle, toEqual: "Play Preview"))
    }

    @MainActor
    func testLibraryPreviewStopsImmediatelyWhenSearchGetsFocus() throws {
        let app = launchApp(libraryState: .readySelection)
        let waveform = element(in: app, identifier: "library-preview-progress")
        let previewToggle = element(in: app, identifier: "library-preview-toggle")
        let searchField = librarySearchField(in: app)

        XCTAssertTrue(waveform.waitForExistence(timeout: 10))
        XCTAssertTrue(previewToggle.waitForExistence(timeout: 10))
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))

        waveform.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(waitForLabel(of: previewToggle, toEqual: "Pause Preview"))

        searchField.click()
        XCTAssertTrue(waitForLabel(of: previewToggle, toEqual: "Play Preview"))
    }

    @MainActor
    func testSettingsExposeAutoImportAndManualImportActions() throws {
        let app = launchApp(libraryState: .prepared)

        element(in: app, identifier: "sidebar-settings").click()

        XCTAssertTrue(element(in: app, identifier: "settings-library-sources").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Auto-Import Rekordbox XML"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Import File…"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testSyncLibrariesFromSettingsShowsSyncSheet() throws {
        let app = launchApp(libraryState: .prepared)

        element(in: app, identifier: "sidebar-settings").click()

        XCTAssertTrue(element(in: app, identifier: "settings-library-sources").waitForExistence(timeout: 10))

        let syncButton = app.buttons["Refresh Vendor Metadata"].firstMatch
        XCTAssertTrue(syncButton.waitForExistence(timeout: 10))
        syncButton.click()

        XCTAssertTrue(element(in: app, identifier: "library-sync-sheet").waitForExistence(timeout: 10))
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = configuredApp(libraryState: .prepared)
            app.launch()
        }
    }

    @MainActor
    private func launchApp(
        libraryState: LibraryState = .prepared,
        startInMixAssistant: Bool = false,
        forceInitialSetup: Bool = false
    ) -> XCUIApplication {
        let app = configuredApp(
            libraryState: libraryState,
            startInMixAssistant: startInMixAssistant,
            forceInitialSetup: forceInitialSetup
        )
        app.launch()
        return app
    }

    @MainActor
    private func configuredApp(
        libraryState: LibraryState,
        startInMixAssistant: Bool = false,
        forceInitialSetup: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "UITEST_SKIP_INITIAL_SETUP",
            libraryState.launchArgument,
            "-ApplePersistenceIgnoreState",
            "YES"
        ]

        if startInMixAssistant {
            app.launchArguments.append("UITEST_START_IN_MIX_ASSISTANT")
        }

        if forceInitialSetup {
            app.launchArguments.append("UITEST_FORCE_INITIAL_SETUP")
        }

        return app
    }

    @MainActor
    private func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func librarySearchField(in app: XCUIApplication) -> XCUIElement {
        let identified = element(in: app, identifier: "library-search-field")
        if identified.exists {
            return identified
        }

        let labeledField = app.textFields["Library Search"].firstMatch
        if labeledField.exists {
            return labeledField
        }

        return app.textFields["Search title or artist"].firstMatch
    }

    @MainActor
    private func marker(in app: XCUIApplication, identifier: String) -> XCUIElement {
        let matches = app.staticTexts.matching(identifier: identifier)
        return matches.allElementsBoundByIndex.last ?? matches.firstMatch
    }

    @MainActor
    private func waitForLabel(of element: XCUIElement, toEqual value: String, timeout: TimeInterval = 10) -> Bool {
        waitForText(of: element, timeout: timeout) { $0 == value }
    }

    @MainActor
    private func waitForLabel(of element: XCUIElement, toContain value: String, timeout: TimeInterval = 10) -> Bool {
        waitForText(of: element, timeout: timeout) { $0.contains(value) }
    }

    @MainActor
    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if element.exists && element.isEnabled {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return element.exists && element.isEnabled
    }

    @MainActor
    private func waitForNonExistence(of element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if !element.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return !element.exists
    }

    @MainActor
    private func waitForText(
        of element: XCUIElement,
        timeout: TimeInterval = 10,
        matches predicate: (String) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            let resolved = resolvedText(of: element)
            if predicate(resolved) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return predicate(resolvedText(of: element))
    }

    @MainActor
    private func resolvedText(of element: XCUIElement) -> String {
        let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty {
            return label
        }

        if let value = element.value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return ""
    }

    @MainActor
    private func forceClick(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }
}
