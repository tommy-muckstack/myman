import Foundation

// Hosted writing model: an OPT-IN seam for the final meeting-notes pass,
// task extraction and Brain chat. Off by default. When `WritingModels.current`
// returns nil every call site runs its existing on-device path untouched.
// The user picks Claude or OpenAI in Settings → AI and pastes their own key,
// which lives only in this Mac's Keychain. Live meeting drafts, dictation
// cleanup, scheduling intent, themes and launcher intent never use this.

enum WritingPurpose: String, Sendable {
    case meetingNotes, followUps, overview, tasks, brainChat

    /// Notes work is large and serialized; chat and tasks share a second lane.
    var isNotes: Bool { self == .meetingNotes || self == .followUps || self == .overview }
}

struct WritingRequest: Sendable {
    var instructions: String
    var input: String
    /// JSON Schema text. When set the provider returns JSON matching it.
    var jsonSchema: String?
    var deadline: TimeInterval
    var purpose: WritingPurpose
}

struct WritingResult: Sendable {
    var text: String
    var inputTokens: Int
    var outputTokens: Int
    var model: String
}

protocol WritingModelProvider: Sendable {
    /// "claude:<model>" or "openai:<model>"; part of notes cache keys.
    var id: String { get }
    func generate(_ request: WritingRequest) async throws -> WritingResult
}

enum WritingModelError: Error, Sendable {
    case notConfigured
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int)
    case network(URLError.Code)
    case timeout
    case refusal(category: String?)
    case truncated
    /// Any other non-success status. `message` is the API's own text so the
    /// Settings "Test" button can show an unknown-model error verbatim.
    case badResponse(status: Int, type: String?, message: String?)
    case decode(String)

    /// Analytics-safe kind: no key, model output or message text.
    var reason: String {
        switch self {
        case .notConfigured: return "not_configured"
        case .unauthorized: return "unauthorized"
        case .rateLimited: return "rate_limited"
        case .server: return "server"
        case .network: return "network"
        case .timeout: return "timeout"
        case .refusal: return "refusal"
        case .truncated: return "truncated"
        case .badResponse: return "bad_response"
        case .decode: return "decode"
        }
    }

    /// What the Settings page shows after a failed test.
    var userMessage: String {
        switch self {
        case .notConfigured: return "No API key saved for this provider."
        case .unauthorized: return "The API rejected this key. Check it and save again."
        case .rateLimited: return "Rate limited by the API. Try again in a moment."
        case .server(let status): return "The API returned a server error (\(status))."
        case .network: return "Couldn’t reach the API. Check your connection."
        case .timeout: return "The request timed out."
        case .refusal: return "The model declined this request."
        case .truncated: return "The reply was cut off."
        case .badResponse(let status, _, let message): return message.map { "\(status): \($0)" } ?? "Unexpected response (\(status))."
        case .decode(let detail): return "Unexpected reply: \(detail)"
        }
    }
}

enum WritingVendor: String, CaseIterable, Sendable {
    case claude, openai

    var label: String {
        switch self {
        case .claude: return "Claude"
        case .openai: return "OpenAI"
        }
    }

    var providerName: String {
        switch self {
        case .claude: return "Anthropic"
        case .openai: return "OpenAI"
        }
    }

    var defaultModel: String {
        switch self {
        case .claude: return ClaudeWritingModel.defaultModel
        case .openai: return OpenAIWritingModel.defaultModel
        }
    }

    var keychainService: String {
        switch self {
        case .claude: return "com.muckstack.myman.claude"
        case .openai: return "com.muckstack.myman.openai"
        }
    }

    static let keychainAccount = "api-key"
}

/// Hosted calls in flight: notes purposes hold an exclusive slot (one notes
/// request at a time), and at most two requests run overall.
actor WritingModelGate {
    static let shared = WritingModelGate()
    private var inFlight = 0
    private var notesInFlight = 0
    private var waiters: [(purpose: WritingPurpose, continuation: CheckedContinuation<Void, Never>)] = []
    private let limit: Int

    init(limit: Int = 2) { self.limit = limit }

    func run<T: Sendable>(_ purpose: WritingPurpose, _ body: @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        await acquire(purpose)
        defer { release(purpose) }
        return try await body()
    }

    private func canStart(_ purpose: WritingPurpose) -> Bool {
        inFlight < limit && (!purpose.isNotes || notesInFlight == 0)
    }

    private func acquire(_ purpose: WritingPurpose) async {
        if canStart(purpose) { start(purpose); return }
        await withCheckedContinuation { continuation in
            waiters.append((purpose, continuation))
        }
    }

    private func start(_ purpose: WritingPurpose) {
        inFlight += 1
        if purpose.isNotes { notesInFlight += 1 }
    }

    private func release(_ purpose: WritingPurpose) {
        inFlight -= 1
        if purpose.isNotes { notesInFlight -= 1 }
        while let index = waiters.firstIndex(where: { canStart($0.purpose) }) {
            let waiter = waiters.remove(at: index)
            start(waiter.purpose)
            waiter.continuation.resume()
        }
    }
}

struct WritingModelSettings: Sendable, Equatable {
    var enabled = false
    var vendor: WritingVendor = .claude
    var model: String = WritingVendor.claude.defaultModel
    /// Only used by Claude; empty unless the key is a user-level key.
    var claudeWorkspaceID = ""
    var meetingNotes = true
    var tasks = true
    var brainChat = true

    func allows(_ purpose: WritingPurpose) -> Bool {
        switch purpose {
        case .meetingNotes, .followUps, .overview: return meetingNotes
        case .tasks: return tasks
        case .brainChat: return brainChat
        }
    }
}

enum WritingModels {
    /// Tests substitute a fake provider here; it wins over settings.
    nonisolated(unsafe) static var override: (@Sendable (WritingPurpose) -> WritingModelProvider?)?

    /// nil unless the setting is on, the purpose is allowed and the selected
    /// vendor has a key in the Keychain. The other vendor's key never counts.
    static func current(for purpose: WritingPurpose,
                        settings: WritingModelSettings = SettingsStore.shared.writingModel,
                        apiKey: (WritingVendor) -> String? = { Keychain.read(service: $0.keychainService, account: WritingVendor.keychainAccount) }) -> WritingModelProvider? {
        if let override { return override(purpose) }
        guard settings.enabled, settings.allows(purpose),
              let key = apiKey(settings.vendor)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        switch settings.vendor {
        case .claude: return ClaudeWritingModel(apiKey: key, model: model.isEmpty ? ClaudeWritingModel.defaultModel : model,
                                                workspaceID: settings.claudeWorkspaceID)
        case .openai: return OpenAIWritingModel(apiKey: key, model: model.isEmpty ? OpenAIWritingModel.defaultModel : model)
        }
    }

    /// Analytics buckets: token counts are reported as ranges, never exact.
    static func bucket(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "lt_1k"
        case ..<4_000: return "1k_4k"
        case ..<16_000: return "4k_16k"
        case ..<64_000: return "16k_64k"
        default: return "gt_64k"
        }
    }

    /// "claude" from "claude:claude-opus-5-5" for analytics properties.
    static func vendor(of provider: WritingModelProvider) -> String {
        String(provider.id.split(separator: ":", maxSplits: 1).first ?? "unknown")
    }
}

/// Shared HTTP plumbing for both vendors: status mapping, one retry on 429
/// (honoring retry-after, capped) and one retry on 5xx after 2 s. Bodies and
/// keys are never logged.
enum HostedHTTP {
    struct Response { let status: Int; let data: Data; let headers: [AnyHashable: Any] }
    static let retryAfterCap: TimeInterval = 30

    static func send(_ request: URLRequest, session: URLSession,
                     errorDetails: (Data) -> (type: String?, message: String?)) async throws -> Response {
        var rateRetried = false, serverRetried = false
        while true {
            try Task.checkCancellation()
            let data: Data, response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError {
                if error.code == .timedOut { throw WritingModelError.timeout }
                if error.code == .cancelled { throw CancellationError() }
                throw WritingModelError.network(error.code)
            }
            guard let http = response as? HTTPURLResponse else { throw WritingModelError.decode("no HTTP response") }
            switch http.statusCode {
            case 200..<300:
                return Response(status: http.statusCode, data: data, headers: http.allHeaderFields)
            case 401, 403:
                throw WritingModelError.unauthorized
            case 429:
                let retryAfter = (http.value(forHTTPHeaderField: "retry-after")).flatMap(TimeInterval.init)
                guard !rateRetried else { throw WritingModelError.rateLimited(retryAfter: retryAfter) }
                rateRetried = true
                try await Task.sleep(for: .seconds(min(retryAfter ?? 2, retryAfterCap)))
            case 500...:
                guard !serverRetried else { throw WritingModelError.server(status: http.statusCode) }
                serverRetried = true
                try await Task.sleep(for: .seconds(2))
            default:
                let details = errorDetails(data)
                throw WritingModelError.badResponse(status: http.statusCode, type: details.type, message: details.message)
            }
        }
    }

    static func session(configuration: URLSessionConfiguration?) -> URLSession {
        configuration.map { URLSession(configuration: $0) } ?? .shared
    }

    /// `NSLog("My Man [Writing model] claude meetingNotes 1830 ms in=12000 out=900")`
    static func log(_ vendor: String, _ purpose: WritingPurpose, start: TimeInterval, result: WritingResult) {
        let ms = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
        NSLog("My Man [Writing model] %@ %@ %d ms in=%d out=%d", vendor, purpose.rawValue, ms, result.inputTokens, result.outputTokens)
    }

    static let probePrompt = "Reply with the single word OK."
}
