import XCTest

/// Automated screenshot capture for App Store submission.
///
/// Run on a **physical device** only:
/// ```
/// xcodebuild test \
///   -project speech_note.xcodeproj \
///   -scheme speech_note \
///   -destination 'platform=iOS,name=<YOUR_DEVICE>' \
///   -only-testing:speech_noteUITests/AppStoreScreenshots
/// ```
///
/// Screenshots are saved as test attachments in the `.xcresult` bundle.
final class AppStoreScreenshots: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uiTestingSeedRecordingDetail"]
    }

    // MARK: - Capture

    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        app.launch()

        // --- Pass through onboarding ---
        let skip = app.buttons["暂时跳过"]
        if skip.waitForExistence(timeout: 3) {
            skip.tap()
        }

        // 1️⃣ Records list (main screen)
        let startBtn = app.buttons["开始录音"]
        XCTAssertTrue(startBtn.waitForExistence(timeout: 5))
        takeScreenshot("01_RecordsList")

        // 2️⃣ Recording detail
        let row = app.buttons["recording-row-00000000-0000-0000-0000-000000000042"]
        if row.waitForExistence(timeout: 3) {
            row.tap()
            let nav = app.navigationBars["录音详情"]
            XCTAssertTrue(nav.waitForExistence(timeout: 3))
            takeScreenshot("02_RecordingDetail")
            // Go back
            nav.buttons.firstMatch.tap()
            _ = startBtn.waitForExistence(timeout: 3)
        }

        // 3️⃣ Transcription Center
        let menu = app.buttons["功能菜单"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        menu.tap()
        let transcriptionCenter = app.buttons["转写任务中心"]
        if transcriptionCenter.waitForExistence(timeout: 3) {
            transcriptionCenter.tap()
            XCTAssertTrue(app.navigationBars["转写任务中心"].waitForExistence(timeout: 3))
            takeScreenshot("03_TranscriptionCenter")
            // Dismiss
            app.swipeDown(velocity: .fast)
            _ = startBtn.waitForExistence(timeout: 3)
        }

        // 4️⃣ Settings
        menu.tap()
        let settings = app.buttons["我的"]
        if settings.waitForExistence(timeout: 3) {
            settings.tap()
            sleep(1) // let sheet animate
            takeScreenshot("04_Settings")
            app.swipeDown(velocity: .fast)
        }
    }

    // MARK: - Helpers

    private func takeScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
