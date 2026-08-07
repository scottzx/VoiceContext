import XCTest

final class OnboardingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFirstLaunchCanDeclinePermissionAndStillEnterRecords() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingResetOnboarding"]
        app.launch()

        XCTAssertTrue(app.staticTexts["把一个念头，留在你的设备上。"].waitForExistence(timeout: 3))
        app.buttons["继续"].tap()
        XCTAssertTrue(app.staticTexts["让 VoiceContext 听见你主动开始的记录。"].waitForExistence(timeout: 3))

        app.buttons["暂不允许"].tap()
        XCTAssertTrue(app.switches["同步 Markdown 与 JSON 文档"].waitForExistence(timeout: 3))
        app.buttons["继续"].tap()

        XCTAssertTrue(app.staticTexts["60 分钟免费本地转写。"].waitForExistence(timeout: 3))
        app.buttons["开始使用"].tap()
        XCTAssertTrue(app.navigationBars["记录"].waitForExistence(timeout: 3))
    }
}
