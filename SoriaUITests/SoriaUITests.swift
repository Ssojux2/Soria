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
        case analyzing

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

        XCTAssertTrue(element(in: app, identifier: "library-preparation-card").waitForExistence(timeout: 10))
        XCTAssertTrue(element(in: app, identifier: "library-table").waitForExistence(timeout: 10))
    }

    @MainActor
    func testInfoPaneStaysAboveLibraryAndShowsSelectedTabContent() throws {
        let app = launchApp(libraryState: .prepared, startInMixAssistant: true)

        let mixAssistantView = element(in: app, identifier: "mix-assistant-info-view")
        let libraryView = element(in: app, identifier: "library-view")

        XCTAssertTrue(mixAssistantView.waitForExistence(timeout: 10))
        XCTAssertTrue(libraryView.waitForExistence(timeout: 10))
        XCTAssertLessThan(mixAssistantView.frame.minY, libraryView.frame.minY)
    }

    @MainActor
    func testLibraryPreparationOverviewRemovesRecommendationShortcuts() throws {
        let app = launchApp(libraryState: .prepared)

        XCTAssertTrue(element(in: app, identifier: "library-preparation-card").waitForExistence(timeout: 10))
        XCTAssertTrue(element(in: app, identifier: "scope-filter-open-library").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Sync Libraries"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Find Similar Tracks"].exists)
        XCTAssertFalse(app.buttons["Start Mixset From This Track"].exists)
        XCTAssertFalse(app.staticTexts["Select one or more tracks"].exists)
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
        XCTAssertTrue(app.buttons["Hide Filters"].waitForExistence(timeout: 10))

        toggleButton.click()

        XCTAssertFalse(inspector.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Open Filters"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testDJScopeInspectorOpensFromMixAssistant() throws {
        let app = launchApp(libraryState: .prepared, startInMixAssistant: true)

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
    func testCancelingAnalysisReturnsToActionableState() throws {
        let app = launchApp(libraryState: .analyzing)

        let cancelButton = app.buttons.matching(identifier: "library-cancel-button").firstMatch
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 10))
        cancelButton.click()

        XCTAssertTrue(element(in: app, identifier: "library-preparation-notice").waitForExistence(timeout: 10))
        XCTAssertTrue(element(in: app, identifier: "library-prepare-selection-button").waitForExistence(timeout: 10))
        XCTAssertFalse(cancelButton.exists)
    }

    @MainActor
    func testSelectingPlaylistFilterClearsHiddenLibrarySelectionWithoutCrashing() throws {
        let app = launchApp(libraryState: .prepared)

        let readyTrackCell = app.staticTexts["Ready Track"].firstMatch
        XCTAssertTrue(readyTrackCell.waitForExistence(timeout: 10))
        readyTrackCell.click()

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

        XCTAssertTrue(element(in: app, identifier: "library-preparation-card").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No tracks selected"].waitForExistence(timeout: 10))
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
        XCTAssertTrue(app.buttons["Sync Libraries"].waitForExistence(timeout: 10))
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
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = configuredApp(libraryState: .prepared)
            app.launch()
        }
    }

    @MainActor
    private func launchApp(
        libraryState: LibraryState = .prepared,
        startInMixAssistant: Bool = false
    ) -> XCUIApplication {
        let app = configuredApp(libraryState: libraryState, startInMixAssistant: startInMixAssistant)
        app.launch()
        return app
    }

    @MainActor
    private func configuredApp(
        libraryState: LibraryState,
        startInMixAssistant: Bool = false
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

        return app
    }

    @MainActor
    private func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
