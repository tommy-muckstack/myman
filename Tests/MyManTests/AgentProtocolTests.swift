import XCTest
import Foundation
@testable import MyMan

final class AgentProtocolTests: XCTestCase {
    @MainActor func testCatalogRejectsUnknownKeysAndUnsafeShapes() throws {
        let actions = try XCTUnwrap(AgentActions.catalog["actions"] as? [[String: Any]])
        XCTAssertGreaterThan(actions.count, 40)
        let schema = try XCTUnwrap(actions.first { $0["name"] as? String == "screenshot.edit" }?["inputSchema"] as? [String: Any])
        try AgentSchema.validate(["id":"shot-fixture", "annotations":[["type":"box","rect":[0,0,100,50]]]], schema:schema)
        for invalid: [String: Any] in [
            ["id":"shot-fixture","shell":"echo bad"],
            ["id":"shot-fixture","annotations":[["type":"shell"]]],
            ["id":"shot-fixture","crop":[0,0,Double.infinity,20]],
            ["id":"shot-fixture","crop":[0,0,20]],
            ["id":"shot-fixture","clipboard":1],
            ["id":"shot-fixture","color":"red"],
        ] { XCTAssertThrowsError(try AgentSchema.validate(invalid,schema:schema)) }
    }
    func testNewOwnedFontPathResolvesBeforeItExists() throws {
        let folder = URL(fileURLWithPath:"/private/tmp/man-asset-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let assets = DocumentAssets(root:folder)
        XCTAssertNotNil(assets.resolve("../assets/note-fixture/font.otf"))
        XCTAssertNil(assets.resolve("../assets/../font.otf"))
        let escape = folder.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at:escape,withDestinationURL:URL(fileURLWithPath:"/etc"))
        XCTAssertNil(assets.resolve("../assets/escape/passwd"))
    }
    func testRectAndImageLimitsAreExplicit() throws {
        XCTAssertThrowsError(try AgentImages.rect([0,0,-10,20]))
        XCTAssertThrowsError(try AgentImages.rect([0,0,10,0]))
        XCTAssertEqual(try AgentImages.rect([10,20,30,40]).maxY,60)
        XCTAssertThrowsError(try FontProjectStore.validateState(["version":1,"samples":[]]))
    }
}
