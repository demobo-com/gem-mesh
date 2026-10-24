import Foundation
import XCTest
@testable import GemmaMeshKit

/// The repo root: POLICY_ROOT when set, else five folders up from this file (clients/ios/Kit/Tests/GemmaMeshKitTests).
let repoRoot: URL = {
    if let r = ProcessInfo.processInfo.environment["POLICY_ROOT"] { return URL(fileURLWithPath: r) }
    var u = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { u.deleteLastPathComponent() }
    return u
}()

let policy = Policy.load { name in try? String(contentsOf: repoRoot.appendingPathComponent("policy/\(name)"), encoding: .utf8) }

func golden(_ name: String) throws -> [[String: Any]] {
    let d = try Data(contentsOf: repoRoot.appendingPathComponent("policy/golden/\(name)"))
    return (try JSONSerialization.jsonObject(with: d) as? [String: Any])?["cases"] as? [[String: Any]] ?? []
}

/// The same cases as `eval/test_golden.py` and the Android RouterGoldenTest, read from `policy/golden`.
final class RouterGoldenTests: XCTestCase {
    func testPolicyLoads() {
        XCTAssertFalse(policy.rules.isEmpty, "rules loaded")
        XCTAssertFalse(policy.terms.isEmpty, "terms loaded")
        XCTAssertFalse(policy.classifierPrompt.isEmpty, "classifier prompt loaded")
        XCTAssertEqual(policy.longPromptTokens, 1500)
        XCTAssertTrue(policy.classifier)
        XCTAssertEqual(policy.frontier, "ask")
        XCTAssertNotNil(policy.models["gemma4-e4b"])
        XCTAssertNotNil(policy.models["embeddinggemma-2"])
    }

    func testPrivacy() throws {
        let cases = try golden("privacy.json")
        XCTAssertFalse(cases.isEmpty)
        var fails: [String] = []
        for c in cases {
            let text = c["text"] as! String
            let (label, hits) = Router.classifyRules(text, policy: policy)
            let rules = Array(Set(hits.map { h -> String in
                let after = h.components(separatedBy: "(").last ?? h
                return after.hasSuffix(")") ? String(after.dropLast()) : after
            })).sorted()
            let want = c["expect"] as! [String: Any]
            let wantRules = (want["rules"] as! [String]).sorted()
            if label != want["privacy"] as! String || rules != wantRules {
                fails.append("\(text): got \(label) \(rules), want \(want["privacy"]!) \(wantRules)")
            }
        }
        XCTAssert(fails.isEmpty, "\(fails.count)/\(cases.count) privacy cases fail:\n" + fails.joined(separator: "\n"))
    }

    func testRouting() async throws {
        let cases = try golden("routing.json")
        XCTAssertFalse(cases.isEmpty)
        var fails: [String] = []
        for c in cases {
            let prompt: String
            if let s = c["prompt"] as? String { prompt = s }
            else {
                let p = c["prompt"] as! [String: Any]
                prompt = String(repeating: p["repeat"] as! String, count: p["times"] as! Int)
            }
            let nodes = (c["nodes"] as! [[String: Any]]).map { n in
                Candidate(key: n["key"] as! String, device: n["device"] as! String, tier: n["tier"] as! String,
                          model: n["model"] as! String, local: n["local"] as? Bool ?? false, latencyMs: 5)
            }
            let d = await Router.route(prompt, nodes: nodes, policy: policy, contextTokens: c["context_tokens"] as! Int)
            let want = c["expect"] as! [String: Any]
            let got = [d.privacy, d.chosen?.device ?? "-", d.needs ?? "-", d.floor, d.ceiling]
            let exp = [want["privacy"] as! String, want["chosen"] as? String ?? "-", want["queue_needs"] as? String ?? "-",
                       want["floor"] as! String, want["ceiling"] as! String]
            if got != exp { fails.append("\(c["name"]!): got \(got), want \(exp)") }
        }
        XCTAssert(fails.isEmpty, "\(fails.count)/\(cases.count) routing cases fail:\n" + fails.joined(separator: "\n"))
    }

    func testFrontierIsNeverChosen() async {
        let d = await Router.route("What is 12 times 7?", nodes: [Candidate(key: "g", device: "gemini", tier: "T4", model: "gemini")], policy: policy)
        XCTAssertNil(d.chosen)
        XCTAssertTrue(d.frontierOffer)
    }

    func testSensitiveStaysSensitiveOverTheConversation() async {
        let d = await Router.route("and what is the deadline?", nodes: [Candidate(key: "phone", device: "phone", tier: "T0", model: "gemma4-e4b", local: true)],
                                   policy: policy, scanText: "Summarize the Acme lease\nand what is the deadline?")
        XCTAssertEqual(d.privacy, "sensitive")
        XCTAssertFalse(d.frontierOffer)
    }

    func testUnknownCountsAsSensitive() async {
        let d = await Router.route("hello", nodes: [], policy: policy, classifier: { _ in ("unknown", "can't tell") })
        XCTAssertEqual(d.privacy, "sensitive")
    }

    func testGrouping() {
        XCTAssertEqual(Router.grouped(1500), "1,500")
        XCTAssertEqual(Router.grouped(12345678), "12,345,678")
        XCTAssertEqual(Router.grouped(999), "999")
    }
}
