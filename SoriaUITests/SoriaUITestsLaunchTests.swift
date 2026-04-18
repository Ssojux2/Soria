//
//  SoriaUITestsLaunchTests.swift
//  SoriaUITests
//
//  Created by Junseop So on 4/14/26.
//

import XCTest

final class SoriaUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "UITEST_SKIP_INITIAL_SETUP",
            "UITEST_LIBRARY_STATE=prepared",
            "-ApplePersistenceIgnoreState",
            "YES"
        ]
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "library-action-bar").firstMatch
                .waitForExistence(timeout: 10)
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
