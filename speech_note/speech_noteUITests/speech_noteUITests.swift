//
//  speech_noteUITests.swift
//  speech_noteUITests
//
//  Created by scott on 2026/8/3.
//

import XCTest

final class speech_noteUITests: XCTestCase {

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
    func testRecordsScreenExposesTheRecordingEntryPointAndDirectStartSheet() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        let skipOnboarding = app.buttons["暂时跳过"]
        if skipOnboarding.waitForExistence(timeout: 3) {
            skipOnboarding.tap()
        }

        let startRecording = app.buttons["开始录音"]
        XCTAssertTrue(startRecording.waitForExistence(timeout: 5))

        startRecording.tap()
        XCTAssertTrue(app.navigationBars["开始记录"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["直接开始录音"].exists)
        XCTAssertTrue(app.switches["这是一次会议"].exists)

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testFailedRecordingOpensItsDetailAndExposesTheProcessingError() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestingResetOnboarding", "-uiTestingSeedRecordingDetail"]
        app.launch()

        let skipOnboarding = app.buttons["暂时跳过"]
        if skipOnboarding.waitForExistence(timeout: 3) {
            skipOnboarding.tap()
        }

        let row = app.buttons["recording-row-00000000-0000-0000-0000-000000000042"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        XCTAssertTrue(app.navigationBars["录音详情"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["处理失败"].exists)
        XCTAssertTrue(app.staticTexts["Silero VAD 未形成语音片段"].exists)
        XCTAssertTrue(app.buttons["重新处理"].exists)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
