import XCTest

@MainActor
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
        XCTAssertTrue(app.staticTexts["Desktop and input profile"].exists)
        XCTAssertTrue(app.buttons["Create"].exists)
    }

    func testMachineISOButtonOpensNativeFilePanel() {
        let app = XCUIApplication()
        app.launchEnvironment["SIMPLEVM_STORAGE_ROOT"] =
            FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString)
                .path
        app.launch()

        app.buttons["New Machine…"].click()
        let importButton = app.buttons["Import Local ISO…"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 3))
        importButton.click()

        XCTAssertTrue(app.buttons["Open"].waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
    }

    func testLibraryISOButtonOpensNativeFilePanel() {
        let app = XCUIApplication()
        app.launchEnvironment["SIMPLEVM_STORAGE_ROOT"] =
            FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString)
                .path
        app.launch()

        app.staticTexts["Images"].click()
        let importButton = app.buttons["Import ISO"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 3))
        importButton.click()

        XCTAssertTrue(app.buttons["Open"].waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
    }

    func testGuestToolsSetupShowsTruthfulDeliveryFlow() {
        let app = XCUIApplication()
        let storageRoot = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        app.launchEnvironment["SIMPLEVM_STORAGE_ROOT"] = storageRoot.path
        app.launchEnvironment["SIMPLEVM_UI_TEST_GUEST_TOOLS"] = "1"
        app.launch()

        let machine = app.staticTexts["Guest Tools Fixture"]
        XCTAssertTrue(machine.waitForExistence(timeout: 5))
        machine.click()

        let status = app.buttons["guestTools.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        status.click()
        XCTAssertTrue(
            app.staticTexts["guestTools.panel"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.buttons["guestTools.export"].exists)
        XCTAssertTrue(app.buttons["guestTools.copyToShare"].exists)
        XCTAssertTrue(app.staticTexts["guestTools.installCommand"].exists)

        app.buttons["guestTools.copyToShare"].click()
        XCTAssertTrue(
            app.staticTexts["guestTools.deliveryStatus"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: storageRoot
                    .appending(path: "GuestToolsTestShare")
                    .appending(path: "simplevm-guest-tools.tar.gz")
                    .path
            )
        )
    }
}
