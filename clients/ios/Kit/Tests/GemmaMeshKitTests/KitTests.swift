import Foundation
import XCTest
@testable import GemmaMeshKit

final class PairingTests: XCTestCase {
    func testReadsTheCodeGemmaMeshPairPrints() throws {
        let p = try Pairing.parse(#"{"v":1,"app":"gemma-mesh","mesh":"default","nodes":["http://192.168.1.20:9400"],"device":"my-macbook"}"#)
        XCTAssertEqual(p.mesh, "default")
        XCTAssertEqual(p.nodes, ["http://192.168.1.20:9400"])
        XCTAssertEqual(p.device, "my-macbook")
    }

    func testRefusesOtherCodes() {
        XCTAssertThrowsError(try Pairing.parse(#"{"v":1,"app":"other","nodes":["http://x:1"]}"#))
        XCTAssertThrowsError(try Pairing.parse("https://example.com"))
        XCTAssertThrowsError(try Pairing.parse(#"{"v":1,"app":"gemma-mesh","nodes":[]}"#))
        XCTAssertNoThrow(try Pairing.parse(#"{"v":1,"app":"gem-mesh","mesh":"default","nodes":["http://192.168.1.20:9400"],"device":"m"}"#))
    }

    func testNormalizesAddresses() {
        XCTAssertEqual(Node.normalizeUrl("10.0.2.2"), "http://10.0.2.2:9400")
        XCTAssertEqual(Node.normalizeUrl("http://mac.local:9400/v1/"), "http://mac.local:9400")
        XCTAssertEqual(Node.normalizeUrl("h:1234"), "http://h:1234")
        XCTAssertNil(Node.normalizeUrl("  "))
    }
}

final class ToolParseTests: XCTestCase {
    func testReadsAMissingSeparator() {
        // The case seen on the Mac: no comma between two arguments.
        let err = #"Failed to parse tool calls from code block: call:edit_image{name:<|"|>milo-*.jpg<|"|>action:<|"|>rotate<|"|>degrees:90}"#
        let calls = ToolParse.recover(err)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "edit_image")
        let a = calls[0].args()
        XCTAssertEqual(a["name"] as? String, "milo-*.jpg")
        XCTAssertEqual(a["action"] as? String, "rotate")
        XCTAssertEqual(a["degrees"] as? Int, 90)
    }

    func testReadsListsAndSeveralCalls() {
        let err = #"Failed to parse tool calls: call:make_image{name:<|"|>c.png<|"|>,style:<|"|>chart<|"|>,labels:[<|"|>a<|"|>,<|"|>b<|"|>],values:[1,2.5]} call:list_files{}"#
        let calls = ToolParse.recover(err)
        XCTAssertEqual(calls.map(\.name), ["make_image", "list_files"])
        XCTAssertEqual((calls[0].args()["labels"] as? [Any])?.count, 2)
        XCTAssertEqual(((calls[0].args()["values"] as? [Any])?[1] as? NSNumber)?.doubleValue ?? 0, 2.5, accuracy: 1e-9)
    }

    func testIgnoresOtherErrors() {
        XCTAssertTrue(ToolParse.recover("context_length_exceeded").isEmpty)
    }
}

final class ToolDefsTests: XCTestCase {
    func testDefinitionsParseAndAreComplete() {
        let all = ToolDefs.offered(web: true, vision: true)
        XCTAssertEqual(all.count, 12)
        for d in all { XCTAssertNotNil(JSON.object(d), "not JSON: \(d.prefix(60))") }
        XCTAssertEqual(ToolDefs.offered(web: false, vision: false).count, 9)
        XCTAssertTrue(ToolDefs.description("edit_file").contains("find → replace"))
        XCTAssertTrue(ToolDefs.param("pdf_pages", "action").contains("stamp"))
    }
}

final class ClassifierTests: XCTestCase {
    func testLaterTurnsSurviveAnEarlierAttachment() {
        let t = Classifier.text(of: ["Summarize this\n\n--- file: lease.txt ---\nRENT 2000", "ok", "Call Dana at home tonight"])
        XCTAssertTrue(t.contains("Call Dana at home tonight"))
        XCTAssertFalse(t.contains("RENT 2000"))
    }
}

final class MemoryTextTests: XCTestCase {
    func testWords() {
        XCTAssertEqual(MemoryText.words("Where does Mia live?"), ["mia", "live"])
        // The same light stemming as MemoryStore.kt: "lives" loses "es", so it does not meet "live".
        XCTAssertTrue(MemoryText.words("The user's sister Mia lives in Lisbon.").isSuperset(of: ["mia", "liv", "lisbon", "sister"]))
        XCTAssertEqual(MemoryText.score(query: MemoryText.words("Where does Mia live?"), text: "The user's sister Mia lives in Lisbon."), 0.5)
        XCTAssertEqual(MemoryText.score(query: MemoryText.words("Who is Mia in Lisbon?"), text: "The user's sister Mia lives in Lisbon."), 1.0)
    }

    func testFitDropsOldTurnsKeepsSystemAndLast() {
        let big = String(repeating: "x", count: 4000)
        var msgs: [[String: Any]] = [["role": "system", "content": "sys"]]
        for i in 0..<10 { msgs.append(["role": i % 2 == 0 ? "user" : "assistant", "content": big]) }
        msgs.append(["role": "user", "content": "now"])
        let out = Fit.fit(msgs, window: 8192, tools: [])
        XCTAssertEqual(out.first?["content"] as? String, "sys")
        XCTAssertEqual(out.last?["content"] as? String, "now")
        XCTAssertLessThan(out.count, msgs.count)
    }

    func testFacts() {
        XCTAssertEqual(Prompts.facts(in: "Sure:\n[\"The user's sister Mia lives in Lisbon.\"]"), ["The user's sister Mia lives in Lisbon."])
        XCTAssertFalse(Prompts.worthExtracting("What is 12 times 7?"))
        XCTAssertTrue(Prompts.worthExtracting("My sister Mia lives in Lisbon."))
    }
}
