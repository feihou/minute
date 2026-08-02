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
        XCTAssertTrue(app.staticTexts["Audio Quality"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.switches["Live Transcription"].exists)

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

    /// Walks record → save → detail → settings, attaching a screenshot at every
    /// stage. Doubles as the visual-regression tour for the redesigned UI.
    @MainActor
    func testFullTourWithScreenshots() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["Minute"].waitForExistence(timeout: 5))
        snap(app, "01-home")

        app.buttons["New Meeting"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["New Meeting"].waitForExistence(timeout: 5))
        snap(app, "02-new-meeting")

        app.buttons["Start Recording"].tap()

        // A fresh environment shows the system microphone-permission alert;
        // grant it so the tour doesn't depend on prior runs' permission state.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permissionAlert = springboard.alerts.firstMatch
        if permissionAlert.waitForExistence(timeout: 3) {
            for label in ["Allow", "OK"] where permissionAlert.buttons[label].exists {
                permissionAlert.buttons[label].tap()
                break
            }
        }

        XCTAssertTrue(app.staticTexts["Recording"].waitForExistence(timeout: 15))
        // Let the level meter and elapsed time move before capturing.
        sleep(3)
        snap(app, "03-recording")

        app.buttons["Stop and save recording"].tap()
        XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 20))
        snap(app, "04-detail-summary")

        app.buttons["Transcript"].tap()
        snap(app, "05-detail-transcript")

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Minute"].waitForExistence(timeout: 5))
        snap(app, "06-home-with-meeting")

        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        snap(app, "07-settings-top")

        app.swipeUp()
        snap(app, "08-settings-bottom")
    }

    @MainActor
    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
