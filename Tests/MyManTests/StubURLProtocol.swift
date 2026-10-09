import Foundation

/// Intercepts every request on a session configured with it. Tests set a
/// handler per scenario; captured requests expose headers and decoded bodies.
final class StubURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (status: Int, headers: [String: String], body: Data)
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var captured: [(request: URLRequest, body: Data)] = []
    private static let lock = NSLock()

    static func install(_ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        captured = []
    }

    static var requests: [(request: URLRequest, body: Data)] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> (status: Int, headers: [String: String], body: Data) {
        (status, headers, try! JSONSerialization.data(withJSONObject: object))
    }

    static func body(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.body(of: request)
        Self.lock.lock()
        Self.captured.append((request, body))
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        do {
            let result = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: result.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension StubURLProtocol {
    /// Decoded JSON body of the n-th captured request.
    static func jsonBody(_ index: Int = 0) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: requests[index].body) as? [String: Any]) ?? [:]
    }
}
