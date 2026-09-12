import Foundation
import Darwin

struct AgentError: Error, LocalizedError {
    let code: String
    let message: String
    let details: [String: Any]
    init(_ code: String, _ message: String, details: [String: Any] = [:]) { self.code = code; self.message = message; self.details = details }
    var errorDescription: String? { message }
    var json: [String: Any] { ["code": code, "message": message].merging(details) { original, _ in original } }
}

/// Same-login local IPC. One bounded JSON request per connection; no TCP port,
/// shell execution, or file paths supplied by captured document content.
final class AgentBridge: @unchecked Sendable {
    static var directory: URL { VerificationPaths.root?.appendingPathComponent("IPC", isDirectory: true) ?? URL(fileURLWithPath: "/tmp/myman-\(getuid())", isDirectory: true) }
    static var path: String { directory.appendingPathComponent("control.sock").path }
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "man.agent.accept")
    private let clients = DispatchQueue(label: "man.agent.clients", attributes: .concurrent)
    private let slots = DispatchSemaphore(value: 8)
    private let handler: @MainActor ([String: Any]) -> [String: Any]

    init(handler: @escaping @MainActor ([String: Any]) -> [String: Any]) { self.handler = handler }

    func start() throws {
        let folder = Self.directory.path
        if mkdir(folder, 0o700) != 0 && errno != EEXIST { throw AgentError("IPC_UNAVAILABLE", "Cannot create the local command directory.") }
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700 else { throw AgentError("IPC_UNAVAILABLE", "The command directory must be owned by this login with mode 0700.") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentError("IPC_UNAVAILABLE", "Cannot create local socket.") }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(Self.path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { Darwin.close(fd); throw AgentError("IPC_UNAVAILABLE", "Command socket path is too long.") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        // Never replace a socket belonging to another running copy of My Man.
        let active = withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if active == 0 { Darwin.close(fd); throw AgentError("APP_ALREADY_CONNECTED", "Another My Man instance owns the command socket.") }
        if lstat(Self.path, &info) == 0 {
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else { Darwin.close(fd); throw AgentError("IPC_UNAVAILABLE", "Unexpected command socket file.") }
            unlink(Self.path)
        }
        let bound = withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, chmod(Self.path, 0o600) == 0, listen(fd, 8) == 0 else { Darwin.close(fd); throw AgentError("IPC_UNAVAILABLE", "Cannot listen on local socket.") }
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            guard self.slots.wait(timeout: .now()) == .success else { Darwin.close(client); return }
            self.clients.async { self.serve(client); self.slots.signal() }
        }
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source; source.resume()
    }

    private func serve(_ fd: Int32) {
        defer { Darwin.close(fd) }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return }
        var timeout = timeval(tv_sec: 5, tv_usec: 0), noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        let deadline = Date().addingTimeInterval(5)
        while data.count <= 1024 * 1024, Date() < deadline {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { return }
            data.append(contentsOf: buffer.prefix(count))
            if data.contains(10) { break }
        }
        guard data.count <= 1024 * 1024, data.last == 10, data.dropLast().contains(10) == false,
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let done = DispatchSemaphore(value: 0)
        let reply = AgentReply()
        Task { @MainActor in reply.set(handler(request)); done.signal() }
        guard done.wait(timeout: .now() + 10) == .success,
              let result = try? JSONSerialization.data(withJSONObject: reply.get(), options: [.sortedKeys]) else { return }
        let output = result + Data([10])
        output.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                guard count > 0 else { return }; sent += count
            }
        }
    }
    deinit { source?.cancel() }
}

private final class AgentReply: @unchecked Sendable {
    private let lock = NSLock(); private var value: [String: Any] = [:]
    func set(_ value: [String: Any]) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return value }
}
