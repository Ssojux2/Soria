//
//  SoriaUITests.swift
//  SoriaUITests
//
//  Created by Junseop So on 4/14/26.
//

import XCTest

final class SoriaUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testInfoPaneStaysAboveLibraryAndShowsSelectedTabContent() throws {
        let app = XCUIApplication()
        app.launchArguments += ["UITEST_SKIP_INITIAL_SETUP", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        let infoPane = app.otherElements["right-pane-info"]
        let libraryPane = app.otherElements["right-pane-library"]
        XCTAssertTrue(infoPane.waitForExistence(timeout: 10))
        XCTAssertTrue(libraryPane.waitForExistence(timeout: 10))
        XCTAssertLessThan(infoPane.frame.minY, libraryPane.frame.minY)

        let searchSidebarButton = app.buttons["sidebar-search"]
        XCTAssertTrue(searchSidebarButton.waitForExistence(timeout: 5))
        searchSidebarButton.click()

        let searchInfoView = app.otherElements["search-info-view"]
        XCTAssertTrue(searchInfoView.waitForExistence(timeout: 5))
        XCTAssertLessThan(searchInfoView.frame.minY, libraryPane.frame.minY)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
