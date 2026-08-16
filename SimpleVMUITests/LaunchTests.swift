import XCTest

final class LaunchTests: XCTestCase {
    func testFreshLaunchShowsMachineEmptyState() {
        let app = XCUIApplication()
        app.launchEnvironment["SIMPLEVM_STORAGE_ROOT"] =
            FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString)
                .path
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["machines.empty"]
                .waitForExistence(timeout: 5)
        )
    }

    func testEmptyStateOpensGenericCreationSheet() {
        let app = XCUIApplication()
        app.launchEnvironment["SIMPLEVM_STORAGE_ROOT"] =
            FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString)
                .path
        app.launch()

        let createButton = app.buttons["New Machine…"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 5))
        createButton.click()

        XCTAssertTrue(app.staticTexts["New Machine"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Source"].exists)
        XCTAssertTrue(app.buttons["Create"].exists)
    }
}
