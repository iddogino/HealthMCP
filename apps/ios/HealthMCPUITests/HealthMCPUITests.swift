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
        XCTAssertTrue(app.staticTexts["Connect your agents to Apple Health"].exists)
        for _ in 0..<4 where !app.buttons["sync-history"].isHittable { app.swipeUp() }
        app.buttons["sync-history"].tap()
        XCTAssertTrue(app.navigationBars["Sync history"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["Health data changed"].exists)
        app.buttons["Done"].tap()
        app.tabBars.buttons["Agents"].tap()
        XCTAssertTrue(app.staticTexts["Connect your agent to HealthMCP"].exists)
        XCTAssertTrue(app.staticTexts["https://mcp.healthmcp.cc/mcp"].exists)
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Reveal private key"].exists)
        XCTAssertFalse(app.staticTexts["private-key"].exists)
    }
    func testBackfillProgressAndPauseAreVisible() {
        let app=app(["-ui-syncing"])
        XCTAssertTrue(app.staticTexts["availability-ready"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["Synced all shared data since"].exists)
        XCTAssertTrue(app.staticTexts["availability-since"].exists)
        XCTAssertTrue(app.staticTexts["Start using your agent now. Older history is still syncing."].exists)
        XCTAssertTrue(app.buttons["availability-agents"].isHittable)
        for _ in 0..<3 where !app.buttons["pause-sync"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["pause-sync"].waitForExistence(timeout:10))
        XCTAssertTrue(app.progressIndicators["Sync progress"].exists)
        XCTAssertFalse(app.staticTexts["LIVE"].exists)
        XCTAssertTrue(app.staticTexts["17 of 53 data types scanned for older changes"].exists)
        XCTAssertTrue(app.staticTexts["Encrypting and uploading"].exists)
    }
    func testFreshCatchupKeepsOlderUploadedHistoryVisible() {
        let app = app(["-ui-syncing", "-ui-catchup"])
        XCTAssertTrue(app.staticTexts["availability-ready"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["availability-since"].exists)
        XCTAssertTrue(app.staticTexts["availability-uploaded-history"].label.contains("2025") || app.staticTexts["availability-uploaded-history"].label.contains("2024"))
        XCTAssertTrue(app.staticTexts["Updating your newest data first. Older history resumes afterward."].exists)
        for _ in 0..<3 where !app.staticTexts["Syncing recent data"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Syncing recent data"].exists)
        XCTAssertFalse(app.staticTexts["Adding older history"].exists)
    }
    func testReadyRangeRemainsVisibleWhenPausedAndOpensAgents() {
        let app=app(["-ui-syncing", "-ui-paused"])
        XCTAssertTrue(app.staticTexts["availability-ready"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["Start using your agent now. Resume sync to add older history."].exists)
        app.buttons["availability-agents"].tap()
        XCTAssertTrue(app.staticTexts["Connect your agent to HealthMCP"].waitForExistence(timeout:5))
    }
    func testUnconfirmedRecentScanDoesNotClaimACompleteRange() {
        let app=app(["-ui-syncing", "-ui-recent-pending"])
        XCTAssertTrue(app.staticTexts["Recent data comes first"].waitForExistence(timeout:10))
        XCTAssertFalse(app.staticTexts["availability-ready"].exists)
        XCTAssertFalse(app.staticTexts["availability-since"].exists)
        XCTAssertFalse(app.staticTexts["LIVE"].exists)
    }
    func testExistingUploadsShowDatesImmediatelyDuringAnUnconfirmedScan() {
        let app=app(["-ui-syncing", "-ui-existing-cache"])
        XCTAssertTrue(app.staticTexts["published-range-ready"].waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["published-range-dates"].label.contains("–"))
        XCTAssertTrue(app.staticTexts["published-range-dates"].label.contains("2026"))
        XCTAssertTrue(app.staticTexts["Last updated"].exists)
        XCTAssertTrue(app.staticTexts["Start using your agent now. Some dates and data types are still syncing."].exists)
        XCTAssertFalse(app.staticTexts["Synced all shared data since"].exists)
        XCTAssertFalse(app.staticTexts["Recent data comes first"].exists)
    }
    func testExistingRangeRemainsVisibleWhenPausedAndOpensAgents() {
        let app=app(["-ui-syncing", "-ui-existing-cache", "-ui-paused"])
        XCTAssertTrue(app.staticTexts["published-range-dates"].waitForExistence(timeout:10))
        for _ in 0..<3 where !app.buttons["availability-agents"].isHittable { app.swipeUp() }
        app.buttons["availability-agents"].tap()
        XCTAssertTrue(app.staticTexts["Connect your agent to HealthMCP"].waitForExistence(timeout:5))
    }
}
