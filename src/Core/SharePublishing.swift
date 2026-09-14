import AppKit
import Combine
import Security
import CryptoKit

private final class ShareRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor final class SharePublishing: ObservableObject {
    static let shared = SharePublishing()
    struct Receipt: Codable, Identifiable {
        var id: String
        var endpoint: String
        var owner: String
        var sourceIDs: [String]
        var sourceID: String
        var title: String
        var expiresAt: Date
        var state: String
        var url: String { endpoint + "/s/" + id }
    }
    @Published private(set) var receipts: [Receipt] = []
    private let file: URL
    private let session = URLSession(configuration: .ephemeral, delegate: ShareRedirectPolicy(), delegateQueue: nil)
    var endpoint: String { UserDefaults.standard.string(forKey: "shareServiceEndpoint") ?? "" }
    init(root: URL? = nil) {
        let root = root ?? VerificationPaths.root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyMan")
        file = root.appendingPathComponent("Shares/receipts.json")
        receipts = (try? JSONDecoder().decode([Receipt].self, from: Data(contentsOf: file))) ?? []
    }
    static func validEndpoint(_ value: String) throws -> String {
        guard let url = URL(string: value), url.scheme == "https", let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, ["", "/"].contains(url.path) else { throw AgentError("INVALID_ARGUMENTS", "Enter the HTTPS address of your My Man sharing service.") }
        return String(value.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
    private static func account(_ endpoint: String) -> String { SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined() }
    func configure(endpoint: String, token: String) throws {
        let endpoint = try Self.validEndpoint(endpoint)
        guard token.utf8.count >= 32, token.utf8.count <= 1024, !token.contains("\n") else { throw AgentError("INVALID_ARGUMENTS", "Enter the publishing credential from your service settings.") }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.muckstack.myman.share", kSecAttrAccount as String: Self.account(endpoint)]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(token.utf8)] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = Data(token.utf8); item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AgentError("KEYCHAIN_FAILED", "Could not save the sharing credential.") }
        } else if status != errSecSuccess { throw AgentError("KEYCHAIN_FAILED", "Could not update the sharing credential.") }
        UserDefaults.standard.set(endpoint, forKey: "shareServiceEndpoint")
    }
    private func token(for endpoint: String) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.muckstack.myman.share", kSecAttrAccount as String: Self.account(endpoint), kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw AgentError("SHARING_NOT_CONFIGURED", "Configure sharing in Workflows → Sharing first.") }
        return value
    }
    private func request(endpoint: String, method: String, id: String? = nil, body: [String: Any]? = nil) async throws -> [String: Any] {
        let endpoint = try Self.validEndpoint(endpoint)
        var url = URLComponents(string: endpoint + "/api/shares")!
        if let id { url.queryItems = [.init(name: "id", value: id)] }
        var request = URLRequest(url: url.url!, timeoutInterval: 30); request.httpMethod = method
        request.setValue("Bearer " + (try token(for: endpoint)), forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode), let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AgentError("SHARING_FAILED", "The sharing service did not confirm this operation. Inspect its status before trying again.") }
        return result
    }
    func publish(item: CaptureItem, seconds: Int, human: Bool = true) async throws -> Receipt {
        guard !item.excluded, CaptureIndex.item(item.id)?.revision == item.revision else { throw AgentError("EDIT_CONFLICT", "Read the current capture before sharing.") }
        let endpoint = try Self.validEndpoint(endpoint)
        _ = try token(for: endpoint)
        let data: Data, mime: String
        if item.kind == "screenshot" {
            guard let size = try URL(fileURLWithPath: item.sourcePath).resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 3_000_000 else { throw AgentError("TOO_LARGE", "This screenshot exceeds the 3 MB share limit. Export a smaller image first.") }
            data = try Data(contentsOf: URL(fileURLWithPath: item.sourcePath)); mime = "image/png"
        } else { data = Data((item.title + "\n\n" + item.body).utf8); mime = "text/plain" }
        let receipt = try await publish(data: data, mime: mime, sourceID: item.id, title: item.title, seconds: seconds, endpoint: endpoint, human: human)
        guard let current = CaptureIndex.item(item.id), !current.excluded, current.kind == item.kind,
              (item.kind == "screenshot" ? (try? Data(contentsOf: URL(fileURLWithPath: current.sourcePath))) == data : current.body == item.body && current.title == item.title) else {
            try await revoke(receipt.id, human: human)
            throw AgentError("CONTENT_CHANGED", "The source changed during publication. The link was revoked.")
        }
        return receipt
    }
    func publish(data: Data, mime: String, sourceID: String, title: String, seconds: Int, endpoint: String? = nil, human: Bool = true, sourceIDs: [String] = []) async throws -> Receipt {
        guard data.count <= 3_000_000, !data.isEmpty, (60...604800).contains(seconds) else { throw AgentError("TOO_LARGE", "Choose up to 3 MB and expiration from one minute to seven days.") }
        let endpoint = try Self.validEndpoint(endpoint ?? self.endpoint)
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AgentError("SHARING_FAILED", "Could not create a share identifier.") }
        let id = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let receipt = Receipt(id: id, endpoint: endpoint, owner: human ? "human" : AgentContext.principal.id, sourceIDs: Array(Set(sourceIDs + [sourceID])), sourceID: sourceID, title: title, expiresAt: Date().addingTimeInterval(Double(seconds)), state: "pending")
        try save(receipt) // Persist the identifier before sending, including uncertain network outcomes.
        do {
            let result = try await request(endpoint: endpoint, method: "POST", body: ["id": id, "content": data.base64EncodedString(), "mime_type": mime, "ttl_seconds": seconds])
            guard result["id"] as? String == id, let timestamp = result["expires_at"] as? String, let expiry = Self.parseDate(timestamp) else { throw AgentError("SHARING_FAILED", "The service returned an invalid receipt.") }
            if receipts.first(where: { $0.id == id })?.state != "pending" {
                try await revoke(id, human: human)
                throw AgentError("CONTENT_CHANGED", "Sharing was cancelled while publication was in progress. The link was revoked.")
            }
            var final = receipt; final.state = "published"; final.expiresAt = expiry; try save(final); return final
        } catch {
            if receipts.first(where: { $0.id == id })?.state == "pending" { var uncertain = receipt; uncertain.state = "unconfirmed"; try? save(uncertain) }
            throw error
        }
    }
    private static func parseDate(_ value: String) -> Date? { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: value) ?? ISO8601DateFormatter().date(from: value) }
    func revoke(_ id: String, human: Bool = true) async throws {
        guard var value = receipts.first(where: { $0.id == id }) else { throw AgentError("NOT_FOUND", "Unknown share.") }
        guard human || value.owner == AgentContext.principal.id else { throw AgentError("NOT_OWNER", "This share belongs to another publisher.") }
        value.state = "revoking"; try save(value)
        do {
            let result = try await request(endpoint: value.endpoint, method: "DELETE", id: id)
            guard result["revoked"] as? Bool == true else { throw AgentError("SHARING_FAILED", "Revocation was not confirmed.") }
            value.state = "revoked"; try save(value)
        } catch { value.state = "revocation_failed"; try? save(value); throw error }
    }
    func purge(sourceID: String?) {
        let values = receipts.filter { (sourceID == nil || $0.sourceIDs.contains(sourceID!)) && $0.state != "revoked" }
        Task { for value in values { do { try await revoke(value.id) } catch { Toast.show("A shared link could not be revoked. Retry in Workflows → Sharing.", actionLabel: "Review", action: { WorkflowCenter.shared.open(tab: "sharing") }, duration: 12) } } }
    }
    private func save(_ receipt: Receipt) throws {
        var values = receipts.filter { $0.id != receipt.id }; values.insert(receipt, at: 0)
        guard values.count <= 1000 else { throw AgentError("TOO_LARGE", "Share history is full.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(values).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path); receipts = values
    }
}
