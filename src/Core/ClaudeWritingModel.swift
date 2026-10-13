import Foundation

/// Claude Messages API (`POST /v1/messages`) with the user's own key. One
/// request per call: a cached system block, the input as a single user turn,
/// `output_config` for effort and (optionally) a JSON schema. Thinking is
/// left at the model default (no `thinking` key); there is no prefill.
struct ClaudeWritingModel: WritingModelProvider {
    static let defaultModel = "claude-opus-5-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"
    static let maxTokens = 16_000

    let apiKey: String
    let model: String
    /// Console workspace id (`wrkspc_…`). Required by the API for user-level
    /// keys (`sk-ant-usr-…`), which aren't bound to a workspace; ignored for
    /// workspace-scoped keys. Sent as the `anthropic-workspace-id` header.
    let workspaceID: String
    private let session: URLSession
    private let gate: WritingModelGate

    init(apiKey: String, model: String = ClaudeWritingModel.defaultModel, workspaceID: String = "",
         configuration: URLSessionConfiguration? = nil, gate: WritingModelGate = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.workspaceID = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = HostedHTTP.session(configuration: configuration)
        self.gate = gate
    }

    var id: String { "claude:" + model }

    func generate(_ request: WritingRequest) async throws -> WritingResult {
        guard !apiKey.isEmpty else { throw WritingModelError.notConfigured }
        let urlRequest = try makeRequest(request)
        return try await gate.run(request.purpose) {
            let start = ProcessInfo.processInfo.systemUptime
            let response = try await HostedHTTP.send(urlRequest, session: session, errorDetails: Self.errorDetails)
            let result = try Self.parse(response.data)
            HostedHTTP.log("claude", request.purpose, start: start, result: result)
            return result
        }
    }

    /// Settings → AI → Test. Surfaces the API's own error for a bad model id.
    func probe() async throws -> (seconds: Double, model: String) {
        let start = Date()
        let result = try await generate(WritingRequest(instructions: "You are a connectivity check.", input: HostedHTTP.probePrompt,
                                                       jsonSchema: nil, deadline: 30, purpose: .brainChat))
        return (Date().timeIntervalSince(start), result.model)
    }

    func makeRequest(_ request: WritingRequest) throws -> URLRequest {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": Self.maxTokens,
            "system": [["type": "text", "text": request.instructions, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": request.input]],
        ]
        var outputConfig: [String: Any] = ["effort": request.purpose == .brainChat ? "low" : "medium"]
        if let schema = request.jsonSchema {
            guard let object = try? JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any] else {
                throw WritingModelError.decode("schema is not a JSON object")
            }
            outputConfig["format"] = ["type": "json_schema", "schema": object]
        }
        body["output_config"] = outputConfig
        var urlRequest = URLRequest(url: Self.endpoint, timeoutInterval: request.deadline)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if !workspaceID.isEmpty { urlRequest.setValue(workspaceID, forHTTPHeaderField: "anthropic-workspace-id") }
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    private struct Message: Decodable {
        struct Block: Decodable { let type: String; let text: String? }
        struct Usage: Decodable { let input_tokens: Int; let output_tokens: Int }
        struct StopDetails: Decodable { let category: String? }
        let model: String
        let stop_reason: String?
        let content: [Block]
        let usage: Usage
        let stop_details: StopDetails?
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable { let type: String?; let message: String? }
        let error: Detail
    }

    static func errorDetails(_ data: Data) -> (type: String?, message: String?) {
        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        return (body?.error.type, body?.error.message)
    }

    static func parse(_ data: Data) throws -> WritingResult {
        let message: Message
        do { message = try JSONDecoder().decode(Message.self, from: data) }
        catch { throw WritingModelError.decode("message body") }
        switch message.stop_reason {
        case "refusal": throw WritingModelError.refusal(category: message.stop_details?.category)
        case "max_tokens": throw WritingModelError.truncated
        default: break
        }
        guard let text = message.content.first(where: { $0.type == "text" })?.text else { throw WritingModelError.decode("no text block") }
        return WritingResult(text: text, inputTokens: message.usage.input_tokens, outputTokens: message.usage.output_tokens, model: message.model)
    }
}
