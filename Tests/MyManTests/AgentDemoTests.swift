import XCTest
import CoreGraphics
@testable import MyMan

final class AgentDemoTests: XCTestCase {
    private func code(_ script: Any, app: String? = nil) -> String? {
        do { _ = try DemoScript.parse(script, app: app); return nil } catch { return (error as? AgentError)?.code }
    }

    func testStepsFileParsesLikeLinux() throws {
        let plan = try DemoScript.parse(["steps": [["click": [120, 80]], ["type": "hello", "cps": 20] as [String: Any], ["key": "cmd+s"],
                                                   ["scroll": 3], ["wait": 0.5], ["move": [10, 10], "seconds": 1] as [String: Any]],
                                         "title": "Spotify in 20 seconds"], app: "Spotify")
        XCTAssertEqual(plan.app, "Spotify"); XCTAssertEqual(plan.region, "window")
        XCTAssertTrue(plan.focus, "other apps are hidden by default"); XCTAssertTrue(plan.close)
        XCTAssertEqual(plan.steps.first, .click(CGPoint(x: 120, y: 80), seconds: 0.6, button: 1, double: false))
        XCTAssertEqual(plan.steps[1], .type("hello", cps: 20, at: nil))
        XCTAssertEqual(plan.polish?["zoom"] as? String, "steps", "zoom where the demo acted")
        XCTAssertEqual(plan.polish?["music"] as? String, "upbeat")
        XCTAssertEqual(plan.polish?["title"] as? String, "Spotify in 20 seconds")
        XCTAssertEqual(plan.json["hides_other_apps"] as? Bool, true)
        XCTAssertEqual(plan.estimatedSeconds, 5.5, accuracy: 0.01)
        let quiet = try DemoScript.parse(["app": "MyMan", "focus": false, "polish": false, "steps": [["wait": 1]]])
        XCTAssertFalse(quiet.focus); XCTAssertNil(quiet.polish)
    }

    func testBadScriptsFailBeforeAnythingOpens() {
        XCTAssertEqual(code(["steps": [["click": [1, 2]]], "speed": 2] as [String: Any]), "INVALID_ARGUMENTS", "unknown keys are errors")
        XCTAssertEqual(code(["steps": []]), "INVALID_ARGUMENTS")
        XCTAssertEqual(code(["steps": [["click": [1, 2], "type": "x"] as [String: Any]]], app: "X"), "INVALID_ARGUMENTS", "one kind per step")
        XCTAssertEqual(code(["steps": [["key": "hyper+q"]]], app: "X"), "INVALID_ARGUMENTS")
        XCTAssertEqual(code(["steps": [["scroll": 0]]], app: "X"), "INVALID_ARGUMENTS")
        XCTAssertEqual(code(["steps": [["click": [1, 2]]], "region": "window"] as [String: Any]), "INVALID_ARGUMENTS", "a window needs an app")
        XCTAssertEqual(code(["steps": [["wait": 30]], "max_duration": 10] as [String: Any], app: "X"), "INVALID_ARGUMENTS")
        XCTAssertEqual(code(["steps": [["wait": 1]], "polish": true] as [String: Any], app: "X"), "INVALID_ARGUMENTS")
        XCTAssertEqual(code(["steps": [["wait": 1]], "focus": "yes"] as [String: Any], app: "X"), "INVALID_ARGUMENTS")
        XCTAssertNil(code(["steps": [["wait": 1]]]), "no app records the whole display")
    }

    func testKeysUseMacNames() throws {
        let (code, flags) = try DemoInput.chord("cmd+shift+s")
        XCTAssertEqual(code, 1); XCTAssertTrue(flags.contains(.maskCommand)); XCTAssertTrue(flags.contains(.maskShift))
        XCTAssertEqual(try DemoInput.chord("Return").0, 36)
        XCTAssertThrowsError(try DemoInput.chord("cmd+nope"))
    }

    func testZoomMomentsFollowWhatTheDemoDid() {
        let acted = [DemoScript.Acted(click: (t: 2, p: CGPoint(x: 50, y: 40))),
                     DemoScript.Acted(typing: (from: 3, to: 4, p: CGPoint(x: 50, y: 40)))]
        let moments = DemoScript.moments(acted, scale: 2)
        XCTAssertEqual(moments.count, 2)
        XCTAssertEqual(moments[0]["x"] as? Double, 100, "points become source pixels")
        XCTAssertEqual(moments[0]["start"] as? Double, 1.5); XCTAssertEqual(moments[1]["end"] as? Double, 4.8)
    }

    @MainActor func testControlIsItsOwnGrantAndStartsOff() throws {
        XCTAssertEqual(AgentConsent.keys["control"], "agentControlEnabled")
        let name = "demo-consent-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "agentRecordingEnabled")
        XCTAssertThrowsError(try AgentConsent.validate("demo.run", args: [:], defaults: defaults), "recording access alone cannot drive the mouse") {
            XCTAssertEqual(($0 as? AgentError)?.code, "AGENT_DISABLED")
        }
        defaults.set(true, forKey: "agentControlEnabled")
        try AgentConsent.validate("demo.run", args: [:], defaults: defaults)
    }

    func testLookNamesElementsLikePeopleReadThem() {
        XCTAssertEqual(DemoLook.label(title: " ", description: "Play", placeholder: nil, help: "Starts playback", value: nil), "Play")
        XCTAssertEqual(DemoLook.label(title: nil, description: nil, placeholder: "Search songs", help: nil, value: "lofi"), "Search songs")
        XCTAssertNil(DemoLook.label(title: nil, description: "", placeholder: nil, help: nil, value: nil))
    }

    func testLookKeepsControlsAndAddsOnlyUncoveredText() {
        let play = DemoLook.Element(kind: "button", label: "Play", rect: CGRect(x: 10, y: 100, width: 60, height: 24))
        let playText = DemoLook.Element(kind: "text", label: "Play", rect: CGRect(x: 22, y: 104, width: 30, height: 14))
        let title = DemoLook.Element(kind: "text", label: "Tunes", rect: CGRect(x: 12, y: 10, width: 50, height: 16))
        let bar = DemoLook.Element(kind: "text", label: "|", rect: CGRect(x: 200, y: 10, width: 2, height: 16))
        XCTAssertEqual(DemoLook.merge([play], [playText, title, bar]), [title, play])
        let json = play.json(2)
        XCTAssertEqual(json["n"] as? Int, 2)
        XCTAssertEqual(json["click"] as? [Int], [40, 112])
        XCTAssertEqual(json["source"] as? String, "accessibility")
        XCTAssertEqual(title.json(1)["source"] as? String, "text")
    }
}
