import XCTest

final class LaunchTests: XCTestCase {
    func testFreshLaunchShowsMachineEmptyState() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["machines.empty"]
                .waitForExistence(timeout: 5)
        )
    }
}

