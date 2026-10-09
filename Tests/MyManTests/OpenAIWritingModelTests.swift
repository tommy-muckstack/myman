import XCTest
@testable import MyMan

final class OpenAIWritingModelTests: XCTestCase {
    private func model(key: String = "test-key-not-real") -> OpenAIWritingModel {
        OpenAIWritingModel(apiKey: key, configuration: StubURLProtocol.configuration, gate: WritingModelGate())
    }

    private func request(schema: String? = nil) -> WritingRequest {
        WritingRequest(instructions: "Be brief.", input: "Hello", jsonSchema: schema, deadline: 5, purpose: .tasks)
    }

    private static func success(text: String? = "OK", finish: String = "stop", refusal: String? = nil) -> [String: Any] {
        var message: [String: Any] = [:]
        if let text { message["content"] = text }
        if let refusal { message["refusal"] = refusal }
        message["role"] = "assistant"
        return ["id": "chatcmpl_1", "model": "gpt-5-mini-2026", "choices": [["index": 0, "message": message, "finish_reason": finish]],
                "usage": ["prompt_tokens": 20, "completion_tokens": 4]]
    }

    private func expectError(_ body: () async throws -> WritingResult, _ check: (WritingModelError) -> Bool,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("Expected an error", file: file, line: line)
        } catch let error as WritingModelError {
            XCTAssertTrue(check(error), "Unexpected error \(error)", file: file, line: line)
        } catch {
            XCTFail("Unexpected error type \(error)", file: file, line: line)
        }
    }

    func testSuccessSendsBearerAndStrictSchema() async throws {
        StubURLProtocol.install { _ in StubURLProtocol.json(Self.success(text: "{\"ok\":true}")) }
        let schema = #"{"type":"object","additionalProperties":false,"required":["ok"],"properties":{"ok":{"type":"boolean"}}}"#
        let result = try await model().generate(request(schema: schema))
        XCTAssertEqual(result.text, "{\"ok\":true}")
        XCTAssertEqual(result.inputTokens, 20)
        XCTAssertEqual(result.outputTokens, 4)
        XCTAssertEqual(result.model, "gpt-5-mini-2026")
        let http = StubURLProtocol.requests[0].request
        XCTAssertEqual(http.url, OpenAIWritingModel.endpoint)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Authorization"), "Bearer test-key-not-real")
        let body = StubURLProtocol.jsonBody()
        XCTAssertEqual(body["model"] as? String, OpenAIWritingModel.defaultModel)
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 16_000)
        let messages = body["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.map { $0["role"] as? String }, ["system", "user"])
        let format = body["response_format"] as? [String: Any]
        XCTAssertEqual(format?["type"] as? String, "json_schema")
        let jsonSchema = format?["json_schema"] as? [String: Any]
        XCTAssertEqual(jsonSchema?["strict"] as? Bool, true)
        XCTAssertEqual(jsonSchema?["name"] as? String, "result")
        XCTAssertNotNil(jsonSchema?["schema"])
    }

    func testEmptyKeyIsNotConfigured() async {
        StubURLProtocol.install { _ in StubURLProtocol.json(Self.success()) }
        await expectError({ try await model(key: "").generate(request()) }) { if case .notConfigured = $0 { return true }; return false }
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
    }

    func testUnauthorized() async {
        StubURLProtocol.install { _ in StubURLProtocol.json(["error": ["message": "Incorrect API key", "type": "invalid_request_error", "code": "invalid_api_key"]], status: 401) }
        await expectError({ try await model().generate(request()) }) { if case .unauthorized = $0 { return true }; return false }
    }

    func testRateLimited() async {
        StubURLProtocol.install { _ in StubURLProtocol.json(["error": ["message": "Rate limit", "type": "rate_limit_error", "code": NSNull()]], status: 429, headers: ["retry-after": "0"]) }
        await expectError({ try await model().generate(request()) }) { if case .rateLimited = $0 { return true }; return false }
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    func testServerError() async {
        StubURLProtocol.install { _ in StubURLProtocol.json(["error": ["message": "down", "type": "server_error", "code": NSNull()]], status: 503) }
        await expectError({ try await model().generate(request()) }) { if case .server(status: 503) = $0 { return true }; return false }
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    func testUnknownModelSurfacesTheAPIMessageVerbatim() async {
        StubURLProtocol.install { _ in StubURLProtocol.json(["error": ["message": "The model `gpt-5-mini` does not exist or you do not have access to it.", "type": "invalid_request_error", "code": "model_not_found"]], status: 404) }
        await expectError({ try await model().generate(request()) }) {
            if case .badResponse(404, "model_not_found", let message) = $0 {
                return message == "The model `gpt-5-mini` does not exist or you do not have access to it." && $0.userMessage.contains("does not exist")
            }
            return false
        }
    }

    func testFinishReasonLengthIsTruncated() async {
        StubURLProtocol.install { _ in StubURLProtocol.json(Self.success(text: "partial", finish: "length")) }
        await expectError({ try await model().generate(request()) }) { if case .truncated = $0 { return true }; return false }
    }

    func testMessageRefusal() async {
        StubURLProtocol.install { _ in StubURLProtocol.json(Self.success(text: nil, refusal: "I can't help with that.")) }
        await expectError({ try await model().generate(request()) }) { if case .refusal = $0 { return true }; return false }
    }

    func testContentFilterIsRefusal() async {
        StubURLProtocol.install { _ in StubURLProtocol.json(Self.success(text: "", finish: "content_filter")) }
        await expectError({ try await model().generate(request()) }) { if case .refusal(category: "content_filter") = $0 { return true }; return false }
    }

    func testMalformedBodyIsDecodeError() async {
        StubURLProtocol.install { _ in (200, [:], Data("<html>".utf8)) }
        await expectError({ try await model().generate(request()) }) { if case .decode = $0 { return true }; return false }
    }

    func testTimeout() async {
        StubURLProtocol.install { _ in throw URLError(.timedOut) }
        await expectError({ try await model().generate(request()) }) { if case .timeout = $0 { return true }; return false }
    }

    func testDefaultModelIsThePlaceholderConstant() {
        XCTAssertEqual(WritingVendor.openai.defaultModel, "gpt-5-mini")
        XCTAssertEqual(WritingVendor.claude.defaultModel, "claude-opus-5-5")
    }
}
