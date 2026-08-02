import XCTest

final class MinuteUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsMeetingListAndOpensSettings() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["Minute"].waitForExistence(timeout: 5))

        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Recording Consent"].waitForExistence(timeout: 2))

        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Minute"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testNewMeetingSheetShowsConsentAndCancels() throws {
        let app = XCUIApplication()
        app.launch()

        app.buttons["New Meeting"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["New Meeting"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Start Recording"].exists)

        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Minute"].waitForExistence(timeout: 5))
    }
}
