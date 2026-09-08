import XCTest
final class HealthMCPUITests:XCTestCase {
    func app(_ flags:[String]=[]) -> XCUIApplication { let app=XCUIApplication();app.launchArguments=["-ui-testing"]+flags;app.launch();return app }
    func testOnboardingStartsWithReadOnlyHealthAccess() {
        let app=app(["-onboarding"])
        XCTAssertTrue(app.buttons["begin-onboarding"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["Your health.\nIn your hands."].exists)
        XCTAssertFalse(app.staticTexts["private-key"].exists)
    }
    func testOverviewHistoryAndAgentNavigation() {
        let app=app()
        XCTAssertTrue(app.buttons["sync-now"].waitForExistence(timeout:10))
        app.swipeUp()
        app.buttons["sync-history"].tap()
        XCTAssertTrue(app.navigationBars["Sync history"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["Health data changed"].exists)
        app.buttons["Done"].tap()
        app.tabBars.buttons["Agents"].tap()
        XCTAssertTrue(app.staticTexts["https://mcp.healthmcp.cc/mcp"].exists)
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Reveal private key"].exists)
        XCTAssertFalse(app.staticTexts["private-key"].exists)
    }
    func testBackfillProgressAndPauseAreVisible() {
        let app=app(["-ui-syncing"])
        XCTAssertTrue(app.buttons["pause-sync"].waitForExistence(timeout:10))
        XCTAssertTrue(app.progressIndicators["Sync progress"].exists)
        XCTAssertTrue(app.staticTexts["LIVE"].exists)
        XCTAssertTrue(app.staticTexts["17 of 53 data types scanned · recent uploads are available as they finish"].exists)
        XCTAssertTrue(app.staticTexts["Encrypting and uploading"].exists)
    }
}
