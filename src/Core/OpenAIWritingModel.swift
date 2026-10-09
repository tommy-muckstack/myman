import Foundation

/// OpenAI Chat Completions (`POST /v1/chat/completions`) with the user's own
/// key. Same request/result shape as `ClaudeWritingModel`; strict JSON-schema
/// `response_format` when a schema is given.
struct OpenAIWritingModel: WritingModelProvider {
    /// PLACEHOLDER: not verified against `GET /v1/models` (no key at
    /// implementation time). The Settings model field is editable and the
    /// Test button shows the API's own "unknown model" message verbatim.
    static let defaultModel = "gpt-5-mini"
    static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    static let maxTokens = 16_000

    let apiKey: String
    let model: String
    private let session: URLSession
    private let gate: WritingModelGate

    init(apiKey: String, model: String = OpenAIWritingModel.defaultModel,
         configuration: URLSessionConfiguration? = nil, gate: WritingModelGate = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = HostedHTTP.session(configuration: configuration)
        self.gate = gate
    }

    var id: String { "openai:" + model }

    func generate(_ request: WritingRequest) async throws -> WritingResult {
        guard !apiKey.isEmpty else { throw WritingModelError.notConfigured }
        let urlRequest = try makeRequest(request)
        return try await gate.run(request.purpose) {
            let start = ProcessInfo.processInfo.systemUptime
            let response = try await HostedHTTP.send(urlRequest, session: session, errorDetails: Self.errorDetails)
            let result = try Self.parse(response.data)
            HostedHTTP.log("openai", request.purpose, start: start, result: result)
            return result
        }
    }

    func probe() async throws -> (seconds: Double, model: String) {
        let start = Date()
        let result = try await generate(WritingRequest(instructions: "You are a connectivity check.", input: HostedHTTP.probePrompt,
                                                       jsonSchema: nil, deadline: 30, purpose: .brainChat))
        return (Date().timeIntervalSince(start), result.model)
    }

    func makeRequest(_ request: WritingRequest) throws -> URLRequest {
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": request.instructions], ["role": "user", "content": request.input]],
            "max_completion_tokens": Self.maxTokens,
        ]
        if let schema = request.jsonSchema {
            guard let object = try? JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any] else {
                throw WritingModelError.decode("schema is not a JSON object")
            }
            body["response_format"] = ["type": "json_schema", "json_schema": ["name": "result", "strict": true, "schema": object]]
        }
        var urlRequest = URLRequest(url: Self.endpoint, timeoutInterval: request.deadline)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    private struct Completion: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String?; let refusal: String? }
            let message: Message
            let finish_reason: String?
        }
        struct Usage: Decodable { let prompt_tokens: Int?; let completion_tokens: Int? }
        let model: String?
        let choices: [Choice]
        let usage: Usage?
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable { let message: String?; let type: String?; let code: String? }
        let error: Detail
    }

    static func errorDetails(_ data: Data) -> (type: String?, message: String?) {
        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        return (body?.error.code ?? body?.error.type, body?.error.message)
    }

    static func parse(_ data: Data) throws -> WritingResult {
        let completion: Completion
        do { completion = try JSONDecoder().decode(Completion.self, from: data) }
        catch { throw WritingModelError.decode("completion body") }
        guard let choice = completion.choices.first else { throw WritingModelError.decode("no choices") }
        if choice.message.refusal != nil { throw WritingModelError.refusal(category: nil) }
        switch choice.finish_reason {
        case "length": throw WritingModelError.truncated
        case "content_filter": throw WritingModelError.refusal(category: "content_filter")
        default: break
        }
        guard let text = choice.message.content else { throw WritingModelError.decode("no content") }
        return WritingResult(text: text, inputTokens: completion.usage?.prompt_tokens ?? 0,
                             outputTokens: completion.usage?.completion_tokens ?? 0, model: completion.model ?? "")
    }
}
