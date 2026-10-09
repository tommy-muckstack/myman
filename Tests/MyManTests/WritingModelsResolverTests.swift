import XCTest
@testable import MyMan

final class WritingModelsResolverTests: XCTestCase {
    private struct Fake: WritingModelProvider {
        let id = "fake:test"
        func generate(_ request: WritingRequest) async throws -> WritingResult { WritingResult(text: "", inputTokens: 0, outputTokens: 0, model: "fake") }
    }

    override func tearDown() { WritingModels.override = nil }

    private func keys(_ claude: String?, _ openai: String?) -> (WritingVendor) -> String? {
        { $0 == .claude ? claude : openai }
    }

    func testDisabledReturnsNil() {
        let settings = WritingModelSettings(enabled: false)
        XCTAssertNil(WritingModels.current(for: .meetingNotes, settings: settings, apiKey: keys("k", "k")))
    }

    func testEnabledWithoutKeyReturnsNil() {
        let settings = WritingModelSettings(enabled: true)
        XCTAssertNil(WritingModels.current(for: .meetingNotes, settings: settings, apiKey: keys(nil, nil)))
        XCTAssertNil(WritingModels.current(for: .meetingNotes, settings: settings, apiKey: keys("  ", nil)))
    }

    func testSelectedVendorWithoutKeyIgnoresTheOtherVendorsKey() {
        let claude = WritingModelSettings(enabled: true, vendor: .claude)
        XCTAssertNil(WritingModels.current(for: .brainChat, settings: claude, apiKey: keys(nil, "openai-key")))
        let openai = WritingModelSettings(enabled: true, vendor: .openai)
        XCTAssertNil(WritingModels.current(for: .brainChat, settings: openai, apiKey: keys("claude-key", nil)))
    }

    func testPerPurposeTogglesGateEachPurpose() {
        var settings = WritingModelSettings(enabled: true, meetingNotes: false, tasks: true, brainChat: true)
        XCTAssertNil(WritingModels.current(for: .meetingNotes, settings: settings, apiKey: keys("k", nil)))
        XCTAssertNil(WritingModels.current(for: .followUps, settings: settings, apiKey: keys("k", nil)))
        XCTAssertNil(WritingModels.current(for: .overview, settings: settings, apiKey: keys("k", nil)))
        XCTAssertNotNil(WritingModels.current(for: .tasks, settings: settings, apiKey: keys("k", nil)))
        settings.tasks = false
        XCTAssertNil(WritingModels.current(for: .tasks, settings: settings, apiKey: keys("k", nil)))
        settings.brainChat = false
        XCTAssertNil(WritingModels.current(for: .brainChat, settings: settings, apiKey: keys("k", nil)))
    }

    func testVendorSwitchReturnsTheOtherProviderType() {
        let claude = WritingModels.current(for: .meetingNotes, settings: WritingModelSettings(enabled: true, vendor: .claude, model: "claude-opus-5-5"), apiKey: keys("k", "o"))
        XCTAssertTrue(claude is ClaudeWritingModel)
        XCTAssertEqual(claude?.id, "claude:claude-opus-5-5")
        let openai = WritingModels.current(for: .meetingNotes, settings: WritingModelSettings(enabled: true, vendor: .openai, model: "gpt-5-mini"), apiKey: keys("k", "o"))
        XCTAssertTrue(openai is OpenAIWritingModel)
        XCTAssertEqual(openai?.id, "openai:gpt-5-mini")
    }

    func testEmptyModelFallsBackToVendorDefault() {
        let provider = WritingModels.current(for: .tasks, settings: WritingModelSettings(enabled: true, vendor: .openai, model: " "), apiKey: keys(nil, "o"))
        XCTAssertEqual(provider?.id, "openai:" + OpenAIWritingModel.defaultModel)
    }

    func testOverrideWinsEvenWhenDisabled() {
        WritingModels.override = { _ in Fake() }
        XCTAssertEqual(WritingModels.current(for: .meetingNotes, settings: WritingModelSettings(enabled: false), apiKey: keys(nil, nil))?.id, "fake:test")
        WritingModels.override = { $0 == .tasks ? Fake() : nil }
        XCTAssertNil(WritingModels.current(for: .meetingNotes, settings: WritingModelSettings(enabled: true), apiKey: keys("k", nil)))
    }

    func testBucketsAndVendorNames() {
        XCTAssertEqual(WritingModels.bucket(10), "lt_1k")
        XCTAssertEqual(WritingModels.bucket(1_000), "1k_4k")
        XCTAssertEqual(WritingModels.bucket(5_000), "4k_16k")
        XCTAssertEqual(WritingModels.bucket(20_000), "16k_64k")
        XCTAssertEqual(WritingModels.bucket(70_000), "gt_64k")
        XCTAssertEqual(WritingModels.vendor(of: Fake()), "fake")
    }

    func testSettingsDefaultsAreOff() {
        let settings = WritingModelSettings()
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.vendor, .claude)
        XCTAssertEqual(settings.model, "claude-opus-5-5")
        XCTAssertTrue(settings.meetingNotes && settings.tasks && settings.brainChat)
    }
}
