import XCTest

/// Screenshots of the main screens, kept in the result bundle (`xcrun xcresulttool export attachments`). Run on its
/// own: xcodebuild test -only-testing:GemmaMeshUITests/Screenshots. Answers come from the mesh (UITEST_NO_LOCAL).
final class Screenshots: XCTestCase {
    private var app: XCUIApplication!

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func any(_ id: String) -> XCUIElementQuery { app.descendants(matching: .any).matching(identifier: id) }

    private func label(_ s: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", s)).firstMatch
    }

    private func send(_ message: String) {
        let input = any("input").firstMatch
        _ = input.waitForExistence(timeout: 10)
        input.tap()
        input.typeText(message)
        any("send").firstMatch.tap()
    }

    private func waitForBadges(_ n: Int, timeout: TimeInterval = 240) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && any("badge").count < n { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
    }

    private func route(_ item: String) {
        any("route").firstMatch.tap()
        let b = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", item)).firstMatch
        _ = b.waitForExistence(timeout: 5)
        b.tap()
    }

    func testScreens() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["UITEST_FRESH", "UITEST_NO_LOCAL"]
        app.launch()
        _ = label("T2 my-workstation").waitForExistence(timeout: 60)
        shot("01-empty-state")

        any("route").firstMatch.tap()
        _ = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Ask Gemini")).firstMatch.waitForExistence(timeout: 5)
        shot("02-route-menu")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Auto")).firstMatch.tap()

        send("Summarize the risks of renewing the Acme contract in two bullets.")
        waitForBadges(1)
        any("badge").firstMatch.tap()
        shot("03-private-answer-with-route")

        app.buttons["Settings"].tap()
        let demo = app.buttons["Demo files"]
        for _ in 0..<6 where !demo.isHittable { app.swipeUp() }
        demo.tap()
        app.swipeDown()
        for _ in 0..<6 where !app.buttons["Scan QR code"].isHittable { app.swipeDown() }
        shot("04-settings")
        app.buttons["Cancel"].tap()

        app.buttons["New chat"].tap()
        route("Prefer T2")
        send("Brighten the milo photos, crop them square and take the location off")
        if app.buttons["Apply"].waitForExistence(timeout: 240) {
            shot("05-photo-change-approval")
            app.buttons["Apply"].tap()
            waitForBadges(1)
            shot("06-photos-changed")
        }

        app.buttons["New chat"].tap()
        route("Ask Gemini")
        send("What is the tallest mountain in Europe?")
        if app.buttons["Keep local"].waitForExistence(timeout: 120) {
            shot("07-gemini-asks-first")
            app.buttons["Keep local"].tap()
        }

        app.buttons["Conversations"].tap()
        _ = label("turns").waitForExistence(timeout: 5)
        shot("08-conversations")
    }
}
