import XCTest
@testable import MyMan

final class SharePublishingTests: XCTestCase {
    @MainActor func testOrdinarySharesStayPublishedWithoutVideoRevisionMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let publishing = SharePublishing(root: root, configuration: StubURLProtocol.configuration,
                                        credential: { _ in "synthetic-publisher-credential-for-tests" })
        for mime in ["text/plain", "image/png", "text/html"] {
            StubURLProtocol.install { request in
                guard request.httpMethod == "POST" else {
                    XCTFail("An unchanged share must not be revoked")
                    return StubURLProtocol.json(["revoked": true])
                }
                let body = StubURLProtocol.jsonBody()
                return StubURLProtocol.json(["id": body["id"] as! String,
                                             "expires_at": "2099-01-01T00:00:00.000Z"], status: 201)
            }
            let receipt = try await publishing.publish(data: Data("Synthetic public content".utf8), mime: mime,
                sourceID: "generated-brief-without-capture-row", title: "Synthetic share", seconds: 3600,
                endpoint: "https://sharing.example")
            XCTAssertEqual(receipt.state, "published")
            XCTAssertNil(receipt.sourceRevision)
            XCTAssertEqual(StubURLProtocol.requests.map { $0.request.httpMethod }, ["POST"])
            XCTAssertEqual(StubURLProtocol.jsonBody()["mime_type"] as? String, mime)
            XCTAssertEqual(SharePublishing(root: root).receipts.first?.state, "published")
        }
    }
}
