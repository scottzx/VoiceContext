import XCTest

final class OnboardingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFirstLaunchCanDeclinePermissionAndStillEnterRecords() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingResetOnboarding"]
        addUIInterruptionMonitor(withDescription: "Microphone permission") { alert in
            for title in ["不允许", "Don't Allow", "Don’t Allow"] {
                let button = alert.buttons[title]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
        app.launch()

        XCTAssertTrue(app.staticTexts["把一个念头，留在你的设备上。"].waitForExistence(timeout: 3))
        app.buttons["继续"].tap()
        XCTAssertTrue(app.staticTexts["让 VoiceContext 听见你主动开始的记录。"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["允许麦克风"].exists)
        XCTAssertFalse(app.buttons["暂不允许"].exists)

        app.buttons["继续"].tap()
        // Needed so XCTest delivers the system permission alert to the monitor.
        app.tap()

        if app.buttons["前往系统设置"].waitForExistence(timeout: 3) {
            app.buttons["继续"].tap()
        }

        XCTAssertTrue(app.switches["同步 Markdown 与 JSON 文档"].waitForExistence(timeout: 5))
        app.buttons["开始使用"].tap()
        XCTAssertTrue(app.navigationBars["记录"].waitForExistence(timeout: 3))
    }
}
