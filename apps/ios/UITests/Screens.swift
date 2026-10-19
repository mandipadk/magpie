// Opens each screen with sample data and keeps a screenshot of it, light
// and dark, as test attachments (CI exports them).
import XCTest

final class Screens: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func launch(_ env: [String: String] = [:], dark: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = ["MAGPIE_SAMPLE": "1"].merging(env) { $1 }
        XCUIDevice.shared.appearance = dark ? .dark : .light
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testScreens() {
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            let app = launch(dark: dark)
            XCTAssert(app.staticTexts["Up to date"].waitForExistence(timeout: 10))
            shot(app, "home-\(mode)")

            app.buttons.matching(NSPredicate(format: "label CONTAINS 'Budget.numbers'")).firstMatch.tap()
            XCTAssert(app.buttons["Keep both"].waitForExistence(timeout: 5))
            shot(app, "conflict-\(mode)")
            app.swipeDown(velocity: .fast)

            app.buttons.matching(NSPredicate(format: "label CONTAINS 'Devices'")).firstMatch.tap()
            XCTAssert(app.navigationBars["Devices"].waitForExistence(timeout: 5))
            shot(app, "devices-\(mode)")
            app.buttons.matching(NSPredicate(format: "label CONTAINS 'Add a device'")).firstMatch.tap()
            _ = app.buttons["Share link"].waitForExistence(timeout: 5)
            shot(app, "add-device-\(mode)")
            app.terminate()

            let join = launch(["MAGPIE_SAMPLE_JOIN": "1"], dark: dark)
            XCTAssert(join.staticTexts["Join your Magpie"].waitForExistence(timeout: 10))
            shot(join, "join-\(mode)")
            join.terminate()
        }
    }
}
