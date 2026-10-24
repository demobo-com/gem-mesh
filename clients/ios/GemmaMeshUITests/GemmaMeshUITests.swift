import XCTest

/// The app driven from outside, as the Android bench does with adb: launch, type, tap, read the badge.
/// Needs a mesh node on the network (my-workstation or a Mac running meshnode). The phone's own model is kept off
/// (UITEST_NO_LOCAL), so answers come from the mesh and do not depend on the simulator's GPU.
final class GemmaMeshUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["UITEST_FRESH", "UITEST_NO_LOCAL"]
        app.launch()
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for b in ["Allow", "OK", "Allow While Using App"] where alert.buttons[b].exists { alert.buttons[b].tap(); return true }
            return false
        }
    }

    // ---- helpers ---------------------------------------------------------------------------------

    private func any(_ id: String) -> XCUIElementQuery { app.descendants(matching: .any).matching(identifier: id) }

    private func last(_ id: String) -> XCUIElement {
        let q = any(id)
        return q.element(boundBy: max(q.count - 1, 0))
    }

    private func text(containing s: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", s)).firstMatch
    }

    /// Waits until the mesh node shows as reachable in the tier strip (Bonjour, then /health).
    private func waitForNode(_ timeout: TimeInterval = 60) {
        XCTAssertTrue(text(containing: "T2 my-workstation").waitForExistence(timeout: timeout) || text(containing: "T1 ").waitForExistence(timeout: 5),
                      "no mesh node found: is my-workstation or a Mac running meshnode on this network?")
    }

    private func send(_ message: String) {
        let input = any("input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText(message)
        any("send").firstMatch.tap()
    }

    /// Waits for the n-th badge (one per finished answer) and returns it.
    @discardableResult
    private func waitForAnswer(_ n: Int = 1, timeout: TimeInterval = 240) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if any("badge").count >= n { return last("badge") }
            if any("notice").count > 0, last("notice").label.hasPrefix("Error") { XCTFail("error: \(last("notice").label)") }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTFail("no answer within \(Int(timeout)) s")
        return last("badge")
    }

    private func chooseRoute(_ item: String) {
        any("route").firstMatch.tap()
        let b = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", item)).firstMatch
        XCTAssertTrue(b.waitForExistence(timeout: 5), "no route menu item \(item)")
        b.tap()
    }

    private func addDemoFiles() {
        app.buttons["Settings"].tap()
        let demo = app.buttons["Demo files"]
        for _ in 0..<6 where !demo.isHittable { app.swipeUp() }
        demo.tap()
        app.buttons["Cancel"].tap()
    }

    // ---- tests -----------------------------------------------------------------------------------

    func test1_LaunchShowsEmptyStateAndFindsTheMesh() {
        XCTAssertTrue(text(containing: "Ask anything").waitForExistence(timeout: 10))
        XCTAssertTrue(text(containing: "T0 phone").exists)
        waitForNode()
    }

    func test2_PublicQuestionAnsweredOnTheWorkstation() {
        waitForNode()
        chooseRoute("Prefer T2")
        send("What is 12 times 7? Answer with the number only.")
        let badge = waitForAnswer()
        XCTAssertTrue(badge.label.contains("my-workstation"), "badge: \(badge.label)")
        XCTAssertTrue(badge.label.contains("0 bytes left the mesh"), "badge: \(badge.label)")
        XCTAssertTrue(last("answer").label.contains("84"), "answer: \(last("answer").label)")
    }

    func test3_ClientNameIsPrivateAndStaysInTheMesh() {
        waitForNode()
        send("What should I check before renewing the Acme contract? One sentence.")
        let badge = waitForAnswer()
        XCTAssertTrue(badge.label.contains("Private"), "a client name must make the conversation private: \(badge.label)")
        XCTAssertFalse(badge.label.contains("frontier"))
    }

    func test4_GeminiRefusesASensitiveConversation() {
        chooseRoute("Ask Gemini")
        send("Email bob@example.com about lunch")
        XCTAssertTrue(text(containing: "Not sent to Gemini").waitForExistence(timeout: 60))
    }

    func test5_GeminiAsksFirstAndKeepLocalSendsNothing() {
        waitForNode()
        chooseRoute("Ask Gemini")
        send("What is the capital of France?")
        let keep = app.buttons["Keep local"]
        XCTAssertTrue(keep.waitForExistence(timeout: 120), "the frontier sheet did not appear")
        XCTAssertTrue(text(containing: "What is the capital of France?").exists, "the sheet shows the exact text")
        keep.tap()
        XCTAssertTrue(text(containing: "Kept local. Nothing was sent.").waitForExistence(timeout: 10))
    }

    func test6_RememberThenRecallInANewConversation() {
        waitForNode()
        send("Please remember: my sister Mia lives in Lisbon.")
        waitForAnswer()
        app.buttons["New chat"].tap()
        send("Where does Mia live? One word.")
        waitForAnswer()
        XCTAssertTrue(last("answer").label.localizedCaseInsensitiveContains("Lisbon"), "answer: \(last("answer").label)")
    }

    func test7_FileChangeNeedsApprovalAndNoDeclines() {
        waitForNode()
        addDemoFiles()
        chooseRoute("Prefer T2")
        send("Stamp DRAFT on every page of q3-update.pdf")
        let no = app.buttons["No"]
        XCTAssertTrue(no.waitForExistence(timeout: 240), "no approval sheet: the model did not call pdf_pages")
        XCTAssertTrue(app.buttons["Apply"].exists)
        no.tap()
        waitForAnswer()
        XCTAssertFalse(text(containing: "Done: stamped").exists, "nothing may be written after No")
    }

    func test8_FileChangeAppliedAfterYes() {
        waitForNode()
        addDemoFiles()
        chooseRoute("Prefer T2")
        send("Stamp DRAFT on every page of q3-update.pdf")
        let apply = app.buttons["Apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 240), "no approval sheet: the model did not call pdf_pages")
        apply.tap()
        waitForAnswer()
        XCTAssertTrue(text(containing: "Done: stamped").waitForExistence(timeout: 10), "the change line under the answer")
    }

    func test9_BadPairingCodeIsRefused() {
        app.buttons["Settings"].tap()
        let field = app.textViews.matching(NSPredicate(format: "placeholderValue CONTAINS %@", "gemma-mesh")).firstMatch
        let code = field.exists ? field : app.textFields.matching(NSPredicate(format: "placeholderValue CONTAINS %@", "gemma-mesh")).firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        code.tap()
        code.typeText("{\"v\":1,\"app\":\"other\"}")
        app.buttons["Pair"].tap()
        XCTAssertTrue(text(containing: "Not paired").waitForExistence(timeout: 5))
    }

    /// The test acts as the Mac's mirror: it pushes a conversation to the phone's memory server on :9401 (the
    /// simulator shares the Mac's network), finds it in the drawer, then pulls the phone's events back.
    func test10_MacConversationSyncsIntoTheDrawer() throws {
        let session = "uitest" + String(Int(Date().timeIntervalSince1970))
        let t = Date().timeIntervalSince1970
        let events: [[String: Any]] = [
            ["id": "my-macbook:\(session)-1", "device": "my-macbook", "seq": Int(t), "ts": t, "kind": "chat", "session": session, "role": "user",
             "text": "What should I pack for Porto in May?", "meta": [:]],
            ["id": "my-macbook:\(session)-2", "device": "my-macbook", "seq": Int(t) + 1, "ts": t + 1, "kind": "chat", "session": session, "role": "assistant",
             "text": "Light layers and a rain jacket.", "meta": ["node": "my-macbook", "model": "gemma4-26b"]],
        ]
        var req = URLRequest(url: URL(string: "http://127.0.0.1:9401/memory/push")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["events": events])
        let pushed = try sync(req)
        XCTAssertEqual(pushed["accepted"] as? Int, 2, "push: \(pushed)")

        let pulled = try sync(URLRequest(url: URL(string: "http://127.0.0.1:9401/memory/pull?after=0&limit=2000")!))
        let ids = (pulled["events"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        XCTAssertTrue(ids.contains("my-macbook:\(session)-1"), "pull returns what was pushed")

        app.buttons["Conversations"].tap()
        XCTAssertTrue(text(containing: "What should I pack for Porto").waitForExistence(timeout: 10), "the Mac conversation is in the drawer")
        XCTAssertTrue(text(containing: "on my-macbook").exists)
        text(containing: "What should I pack for Porto").tap()
        XCTAssertTrue(text(containing: "typed on my-macbook").waitForExistence(timeout: 5))
    }

    private func sync(_ req: URLRequest) throws -> [String: Any] {
        var out: Data?
        let done = expectation(description: "http")
        URLSession.shared.dataTask(with: req) { d, _, _ in out = d; done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
        return (try JSONSerialization.jsonObject(with: out ?? Data("{}".utf8))) as? [String: Any] ?? [:]
    }

    /// The phone's own model (E4B, or E2B), on the simulator's CPU: a short public question stays on the phone.
    func test11_PhoneModelAnswersOnTheDevice() {
        app.terminate()
        app.launchArguments = ["UITEST_FRESH"]
        app.launch()
        let ready = app.descendants(matching: .any).matching(NSPredicate(format: "label MATCHES %@", ".*E[24]B · (CPU|GPU).*")).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 300), "the phone's model did not load")
        send("What is 2 plus 3? Answer with the number only.")
        let badge = waitForAnswer(timeout: 300)
        XCTAssertTrue(badge.label.contains("phone"), "badge: \(badge.label)")
        XCTAssertTrue(badge.label.contains("nothing left the phone"), "badge: \(badge.label)")
        XCTAssertTrue(last("answer").label.contains("5"), "answer: \(last("answer").label)")
    }

    /// The message field is multi-line, so Return never closes the keyboard: a tap above the field, a drag down
    /// the chat, and turning to the Mesh page each must. No mesh node needed. Needs the simulator's on-screen
    /// keyboard (I/O → Keyboard → uncheck Connect Hardware Keyboard): with a hardware keyboard it stays offscreen.
    func test12_KeyboardGoesAway() {
        let input = any("input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        let keyboardGone = NSPredicate(format: "count == 0")

        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the keyboard did not open")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        expectation(for: keyboardGone, evaluatedWith: app.keyboards); waitForExpectations(timeout: 5)

        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.swipeDown()
        expectation(for: keyboardGone, evaluatedWith: app.keyboards); waitForExpectations(timeout: 5)

        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // Turn the page with the edge swipe (the Mesh › button sits at the far end of the tier strip).
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.4))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)))
        expectation(for: keyboardGone, evaluatedWith: app.keyboards); waitForExpectations(timeout: 5)
        XCTAssertTrue(text(containing: "Tokens processed").waitForExistence(timeout: 5), "the Mesh page did not open")
    }

    /// The Memory page: a fact added there is listed, and swiping it away forgets it. No mesh node needed.
    func test13_RememberAndForgetOnTheMemoryPage() {
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.4))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)))
        XCTAssertTrue(any("meshMemory").firstMatch.waitForExistence(timeout: 5))
        any("meshMemory").firstMatch.tap()
        let field = any("newFact").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the Memory page did not open")
        let fact = "My bike is a green Brompton \(Int(Date().timeIntervalSince1970) % 10000)."
        field.tap()
        field.typeText(fact)
        any("rememberFact").firstMatch.tap()
        let row = text(containing: fact)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the fact is not listed")
        row.swipeLeft()
        app.buttons["Forget"].firstMatch.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: row)
        waitForExpectations(timeout: 5)
    }
}
