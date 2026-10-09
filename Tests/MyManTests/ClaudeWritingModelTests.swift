import XCTest
@testable import MyMan

final class ClaudeWritingModelTests: XCTestCase {
    private func model(key: String = "test-key-not-real", gate: WritingModelGate = WritingModelGate()) -> ClaudeWritingModel {
        ClaudeWritingModel(apiKey: key, configuration: StubURLProtocol.configuration, gate: gate)
    }

    private func request(schema: String? = nil, purpose: WritingPurpose = .meetingNotes) -> WritingRequest {
        WritingRequest(instructions: "Be brief.", input: "Hello", jsonSchema: schema, deadline: 5, purpose: purpose)
    }

    private static func success(text: String = "OK", stop: String = "end_turn", category: String? = nil) -> [String: Any] {
        var message: [String: Any] = ["id": "msg_1", "model": "claude-opus-5-5", "stop_reason": stop,
                                      "content": [["type": "text", "text": text]],
                                      "usage": ["input_tokens": 12, "output_tokens": 3, "cache_read_input_tokens": 0]]
        if let category { message["stop_details"] = ["type": "refusal", "category": category] }
        return message
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

    func testSuccessSendsHeadersAndBodyShape() async throws {
        StubURLProtocol.install { _ in StubURLProtocol.json(Self.success(text: "{\"ok\":true}")) }
        let schema = #"{"type":"object","additionalProperties":false,"required":["ok"],"properties":{"ok":{"type":"boolean"}}}"#
        let result = try await model().generate(request(schema: schema))
        XCTAssertEqual(result.text, "{\"ok\":true}")
        XCTAssertEqual(result.inputTokens, 12)
        XCTAssertEqual(result.outputTokens, 3)
        XCTAssertEqual(result.model, "claude-opus-5-5")
        let captured = StubURLProtocol.requests
        XCTAssertEqual(captured.count, 1)
        let http = captured[0].request
        XCTAssertEqual(http.url, ClaudeWritingModel.endpoint)
        XCTAssertEqual(http.value(forHTTPHeaderField: "x-api-key"), "test-key-not-real")
        XCTAssertEqual(http.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(http.value(forHTTPHeaderField: "content-type"), "application/json")
        let body = StubURLProtocol.jsonBody()
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 16_000)
        XCTAssertNil(body["thinking"])
        let system = body["system"] as? [[String: Any]]
        XCTAssertEqual(system?.first?["text"] as? String, "Be brief.")
        XCTAssertEqual((system?.first?["cache_control"] as? [String: String])?["type"], "ephemeral")
        let messages = body["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 1)
        XCTAssertEqual(messages?.first?["role"] as? String, "user")
        let output = body["output_config"] as? [String: Any]
        XCTAssertEqual(output?["effort"] as? String, "medium")
        let format = output?["format"] as? [String: Any]
        XCTAssertEqual(format?["type"] as? String, "json_schema")
        XCTAssertEqual(((format?["schema"] as? [String: Any])?["required"] as? [String]), ["ok"])
    }

    func testChatUsesLowEffortAndNoFormat() async throws {
        StubURLProtocol.install { _ in StubURLProtocol.json(Self.success()) }
        _ = try await model().generate(request(purpose: .brainChat))
        let output = StubURLProtocol.jsonBody()["output_config"] as? [String: Any]
        XCTAssertEqual(output?["effort"] as? String, "low")
        XCTAssertNil(output?["format"])
    }

    func testEmptyKeyIsNotConfiguredWithoutARequest() async {
        StubURLProtocol.install { _ in StubURLProtocol.json(Self.success()) }
        await expectError({ try await model(key: "").generate(request()) }) { if case .notConfigured = $0 { return true }; return false }
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
    }

    func testUnauthorized() async {
        StubURLProtocol.install { _ in StubURLProtocol.json(["type": "error", "error": ["type": "authentication_error", "message": "invalid x-api-key"]], status: 401) }
        await expectError({ try await model().generate(request()) }) { if case .unauthorized = $0 { return true }; return false }
    }

    func testRateLimitRetriesOnceThenSucceeds() async throws {
        var calls = 0
        StubURLProtocol.install { _ in
            calls += 1
            return calls == 1 ? StubURLProtocol.json(["type": "error", "error": ["type": "rate_limit_error", "message": "slow down"]], status: 429, headers: ["retry-after": "0"])
                : StubURLProtocol.json(Self.success())
        }
        let result = try await model().generate(request())
        XCTAssertEqual(result.text, "OK")
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    func testRateLimitTwiceFails() async {
        StubURLProtocol.install { _ in StubURLProtocol.json(["type": "error", "error": ["type": "rate_limit_error", "message": "slow down"]], status: 429, headers: ["retry-after": "0"]) }
        await expectError({ try await model().generate(request()) }) { if case .rateLimited = $0 { return true }; return false }
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    func testServerErrorRetriesOnceThenSucceeds() async throws {
        var calls = 0
        StubURLProtocol.install { _ in
            calls += 1
            return calls == 1 ? StubURLProtocol.json(["type": "error", "error": ["type": "api_error", "message": "boom"]], status: 500)
                : StubURLProtocol.json(Self.success())
        }
        let result = try await model().generate(request())
        XCTAssertEqual(result.text, "OK")
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    func testServerErrorTwiceFails() async {
        StubURLProtocol.install { _ in StubURLProtocol.json(["type": "error", "error": ["type": "overloaded_error", "message": "busy"]], status: 529) }
        await expectError({ try await model().generate(request()) }) { if case .server(status: 529) = $0 { return true }; return false }
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    func testUnknownModelSurfacesTheAPIMessage() async {
        StubURLProtocol.install { _ in StubURLProtocol.json(["type": "error", "error": ["type": "not_found_error", "message": "model: claude-nope"]], status: 404) }
        await expectError({ try await model().generate(request()) }) {
            if case .badResponse(let status, let type, let message) = $0 {
                return status == 404 && type == "not_found_error" && message == "model: claude-nope" && $0.userMessage.contains("claude-nope")
            }
            return false
        }
    }

    func testRefusal() async {
        StubURLProtocol.install { _ in StubURLProtocol.json(Self.success(text: "", stop: "refusal", category: "cyber")) }
        await expectError({ try await model().generate(request()) }) { if case .refusal(category: "cyber") = $0 { return true }; return false }
    }

    func testMaxTokensIsTruncated() async {
        StubURLProtocol.install { _ in StubURLProtocol.json(Self.success(text: "partial", stop: "max_tokens")) }
        await expectError({ try await model().generate(request()) }) { if case .truncated = $0 { return true }; return false }
    }

    func testMalformedBodyIsDecodeError() async {
        StubURLProtocol.install { _ in (200, [:], Data("not json".utf8)) }
        await expectError({ try await model().generate(request()) }) { if case .decode = $0 { return true }; return false }
    }

    func testTimeout() async {
        StubURLProtocol.install { _ in throw URLError(.timedOut) }
        await expectError({ try await model().generate(request()) }) { if case .timeout = $0 { return true }; return false }
    }

    func testNetworkFailure() async {
        StubURLProtocol.install { _ in throw URLError(.notConnectedToInternet) }
        await expectError({ try await model().generate(request()) }) { if case .network(.notConnectedToInternet) = $0 { return true }; return false }
    }

    func testCancellationPropagates() async {
        StubURLProtocol.install { _ in
            Thread.sleep(forTimeInterval: 0.5)
            return StubURLProtocol.json(Self.success())
        }
        let model = self.model()
        let task = Task { try await model.generate(request()) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? WritingModelError).map { if case .network(.cancelled) = $0 { return true }; return false } == true, "\(error)")
        }
    }

    /// The gate is tested directly: a stub URLProtocol loads requests one at
    /// a time on the session's work queue, so concurrency is invisible there.
    func testGateSerializesNotesAndAllowsChatAlongside() async throws {
        let gate = WritingModelGate()
        let counter = ConcurrencyCounter()
        @Sendable func work(_ purpose: WritingPurpose) async throws {
            try await gate.run(purpose) {
                let lane = purpose.isNotes ? "notes" : "chat"
                counter.enter(lane)
                try await Task.sleep(for: .milliseconds(150))
                counter.leave(lane)
            }
        }
        async let a: Void = work(.meetingNotes)
        async let b: Void = work(.followUps)
        async let c: Void = work(.brainChat)
        async let d: Void = work(.tasks)
        _ = try await (a, b, c, d)
        XCTAssertEqual(counter.peak("notes"), 1, "notes calls must run one at a time")
        XCTAssertGreaterThanOrEqual(counter.peak("all"), 2, "chat/tasks should run alongside a notes call")
        XCTAssertLessThanOrEqual(counter.peak("all"), 2, "never more than two hosted calls in flight")
    }

    func testProbeReportsLatencyAndModel() async throws {
        StubURLProtocol.install { _ in StubURLProtocol.json(Self.success()) }
        let probe = try await model().probe()
        XCTAssertEqual(probe.model, "claude-opus-5-5")
        XCTAssertGreaterThanOrEqual(probe.seconds, 0)
        let messages = StubURLProtocol.jsonBody()["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.first?["content"] as? String, HostedHTTP.probePrompt)
    }
}

final class ConcurrencyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var current: [String: Int] = [:]
    private var peaks: [String: Int] = [:]
    func enter(_ lane: String) {
        lock.lock(); defer { lock.unlock() }
        for key in [lane, "all"] { current[key, default: 0] += 1; peaks[key] = max(peaks[key] ?? 0, current[key]!) }
    }
    func leave(_ lane: String) {
        lock.lock(); defer { lock.unlock() }
        for key in [lane, "all"] { current[key, default: 0] -= 1 }
    }
    func peak(_ lane: String) -> Int { lock.lock(); defer { lock.unlock() }; return peaks[lane] ?? 0 }
}
