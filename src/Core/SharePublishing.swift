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
        var videoPath: String? = nil
        var fingerprint: String? = nil
        var sourceRevision: Int? = nil
        var engagement: Bool? = nil
        var url: String { endpoint + "/s/" + id }
    }
    @Published private(set) var receipts: [Receipt] = []
    @Published private(set) var uploadProgress: [String: Double] = [:]
    private var uploads: [String: Task<Receipt, Error>] = [:]
    private var loadFailed = false
    private let file: URL
    private let session = URLSession(configuration: .ephemeral, delegate: ShareRedirectPolicy(), delegateQueue: nil)
    var endpoint: String { UserDefaults.standard.string(forKey: "shareServiceEndpoint") ?? "" }
    init(root: URL? = nil) {
        let root = root ?? VerificationPaths.root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyMan")
        file = root.appendingPathComponent("Shares/receipts.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { receipts = try JSONDecoder().decode([Receipt].self, from: Data(contentsOf: file)) }
            catch { loadFailed = true }
        }
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
    private func request(endpoint: String, method: String, id: String? = nil, body: [String: Any]? = nil, videoAction: String? = nil) async throws -> [String: Any] {
        let endpoint = try Self.validEndpoint(endpoint)
        var url = URLComponents(string: endpoint + (videoAction == nil ? "/api/shares" : "/api/videos"))!
        url.queryItems = []
        if let id { url.queryItems?.append(.init(name: "id", value: id)) }
        if let videoAction { url.queryItems?.append(.init(name: "action", value: videoAction)) }
        var request = URLRequest(url: url.url!, timeoutInterval: 30); request.httpMethod = method
        request.setValue("Bearer " + (try token(for: endpoint)), forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode), let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AgentError("SHARING_FAILED", "The sharing service did not confirm this operation. Inspect its status before trying again.") }
        return result
    }
    func publish(item: CaptureItem, seconds: Int, human: Bool = true) async throws -> Receipt {
        guard !item.excluded, CaptureIndex.item(item.id)?.revision == item.revision else { throw AgentError("EDIT_CONFLICT", "Read the current capture before sharing.") }
        if human && item.kind == "recording" { return try await publishVideo(item: item, seconds: seconds, human: human) }
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
            try Task.checkCancellation()
                guard let current = CaptureIndex.item(receipt.sourceID), !current.excluded, current.revision == receipt.sourceRevision else {
                    try await revoke(id, human: human)
                    throw AgentError("CONTENT_CHANGED", "The source changed during publication. The link was revoked.")
                }
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
        guard !loadFailed else { throw AgentError("RECOVERY_UNAVAILABLE", "Existing share history could not be read. It has been preserved; repair it before publishing.") }
        var values = receipts.filter { $0.id != receipt.id }; values.insert(receipt, at: 0)
        guard values.count <= 1000 else { throw AgentError("TOO_LARGE", "Share history is full.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(values).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path); receipts = values
    }
}

private final class VideoUploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let update: @Sendable (Double) -> Void
    init(update: @escaping @Sendable (Double) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 { update(Double(totalBytesSent) / Double(totalBytesExpectedToSend)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

extension SharePublishing {
    nonisolated static func fileFingerprint(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { try Task.checkCancellation(); digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func publishVideo(item: CaptureItem, seconds: Int, human: Bool = true, engagement: Bool = false) async throws -> Receipt {
        guard !item.excluded, item.kind == "recording", CaptureIndex.item(item.id)?.revision == item.revision,
              (60...604800).contains(seconds) else { throw AgentError("EDIT_CONFLICT", "Read the current recording before sharing.") }
        let endpoint = try Self.validEndpoint(endpoint); _ = try token(for: endpoint)
        let fileURL = URL(fileURLWithPath: item.sourcePath)
        let bytes = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (1...524_288_000).contains(bytes), ["mp4", "mov"].contains(fileURL.pathExtension.lowercased()) else { throw AgentError("TOO_LARGE", "Choose an MP4 or MOV recording up to 500 MB.") }
        let fingerprint = try await Task.detached { try Self.fileFingerprint(fileURL) }.value
        try Task.checkCancellation()
        var random = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
        let id = Data(random).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let receipt = Receipt(id: id, endpoint: endpoint, owner: human ? "human" : AgentContext.principal.id,
                              sourceIDs: [item.id], sourceID: item.id, title: item.title, expiresAt: Date().addingTimeInterval(Double(seconds)),
                              state: "uploading", videoPath: item.sourcePath, fingerprint: fingerprint, sourceRevision: item.revision, engagement: engagement)
        try save(receipt)
        return try await uploadVideo(receipt, seconds: seconds, human: human)
    }
    func retryVideo(_ id: String) async throws -> Receipt {
        guard let receipt = receipts.first(where: { $0.id == id }), receipt.videoPath != nil,
              ["upload_interrupted", "uploading", "unconfirmed"].contains(receipt.state), receipt.expiresAt > Date() else { throw AgentError("NOT_FOUND", "This upload cannot be resumed. Start a new share.") }
        return try await uploadVideo(receipt, seconds: max(60, Int(receipt.expiresAt.timeIntervalSinceNow)), human: true)
    }
    func cancelUpload(_ id: String) {
        uploads[id]?.cancel()
        Task { do { try await revoke(id) } catch { Toast.show("Upload stopped. Revocation needs a retry in Sharing.") } }
    }
    private func uploadVideo(_ receipt: Receipt, seconds: Int, human: Bool) async throws -> Receipt {
        if let active = uploads[receipt.id] { return try await active.value }
        let task = Task { @MainActor [self] () throws -> Receipt in
            let id = receipt.id
            uploadProgress[id] = 0
            defer { uploadProgress.removeValue(forKey: id) }
            guard let path = receipt.videoPath, let expectedHash = receipt.fingerprint else { throw CocoaError(.fileReadCorruptFile) }
            let url = URL(fileURLWithPath: path)
            do {
                let fingerprint = try await Task.detached { try Self.fileFingerprint(url) }.value
                try Task.checkCancellation()
                guard fingerprint == expectedHash, let item = CaptureIndex.item(receipt.sourceID), !item.excluded,
                      item.revision == receipt.sourceRevision else { throw AgentError("CONTENT_CHANGED", "The recording changed. Revoke this upload and start a new share.") }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                let mime = url.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4"
                var state = receipt; state.state = "uploading"; try save(state)
                let grant = try await request(endpoint: receipt.endpoint, method: "POST", id: id,
                    body: ["size": size, "mime": mime, "ttl_seconds": seconds, "title": String(receipt.title.prefix(300)), "fingerprint": fingerprint, "engagement": receipt.engagement ?? false], videoAction: "begin")
                if grant["published"] as? Bool != true && grant["uploaded"] as? Bool != true {
                    guard let token = grant["clientToken"] as? String, let pathname = grant["pathname"] as? String,
                          pathname == "videos/\(id).\(mime == "video/mp4" ? "mp4" : "mov")" else { throw AgentError("UPLOAD_FAILED", "The upload grant did not match this recording.") }
                    var upload = URLRequest(url: URL(string: "https://blob.vercel-storage.com/")!.appendingPathComponent(pathname), timeoutInterval: 3600)
                    upload.httpMethod = "PUT"; upload.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                    upload.setValue("7", forHTTPHeaderField: "x-api-version"); upload.setValue("private", forHTTPHeaderField: "x-access")
                    upload.setValue(mime, forHTTPHeaderField: "x-content-type"); upload.setValue(String(size), forHTTPHeaderField: "x-content-length")
                    let delegate = VideoUploadProgress { [weak self] progress in Task { @MainActor in self?.uploadProgress[id] = progress * 0.95 } }
                    let (_, response) = try await session.upload(for: upload, fromFile: url, delegate: delegate)
                    guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { throw AgentError("UPLOAD_FAILED", "Upload was not confirmed. Retry uses the same publication ID.") }
                }
                try Task.checkCancellation()
                let finalHash = try await Task.detached { try Self.fileFingerprint(url) }.value
                try Task.checkCancellation()
                guard finalHash == expectedHash, CaptureIndex.item(receipt.sourceID)?.revision == receipt.sourceRevision,
                      CaptureIndex.item(receipt.sourceID)?.excluded == false, receipts.first(where: { $0.id == id })?.state == "uploading" else {
                    try await revoke(id, human: human); throw AgentError("CONTENT_CHANGED", "The source changed during upload. The link was revoked.")
                }
                var body: [String: Any] = [:]
                if let transcript = RecordingTranscript.load(for: url) {
                    body["captions"] = RecordingTranscript.subtitles(RecordingTranscript.captions(transcript.segments), webVTT: true)
                }
                let result = try await request(endpoint: receipt.endpoint, method: "POST", id: id, body: body, videoAction: "complete")
                try Task.checkCancellation()
                guard let current = CaptureIndex.item(receipt.sourceID), !current.excluded, current.revision == receipt.sourceRevision else {
                    try await revoke(id, human: human)
                    throw AgentError("CONTENT_CHANGED", "The source changed during publication. The link was revoked.")
                }
                guard result["id"] as? String == id, let timestamp = result["expires_at"] as? String, let expiry = Self.parseDate(timestamp),
                      receipts.first(where: { $0.id == id })?.state == "uploading" else { throw AgentError("UPLOAD_FAILED", "Publication was not confirmed. Review the saved receipt before retrying.") }
                state.state = "published"; state.expiresAt = expiry; try save(state); return state
            } catch {
                if receipts.first(where: { $0.id == id })?.state == "uploading" { var failed = receipt; failed.state = "upload_interrupted"; try? save(failed) }
                throw error
            }
        }
        uploads[receipt.id] = task
        defer { uploads.removeValue(forKey: receipt.id) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
