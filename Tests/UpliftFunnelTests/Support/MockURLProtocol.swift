import Foundation
import XCTest
@testable import UpliftFunnel

/// URLProtocol-based HTTP mock. Register a handler per test; every request
/// through a session configured with `MockURLProtocol.sessionConfiguration()`
/// is answered by it and recorded for header assertions.
final class MockURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let headers: [String: String]
        let body: Data

        init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
        }

        init(statusCode: Int, headers: [String: String] = [:], json: String) {
            self.init(statusCode: statusCode, headers: headers, body: Data(json.utf8))
        }
    }

    enum Reply {
        case stub(Stub)
        case error(Error)
    }

    struct Recorded {
        let request: URLRequest
        let body: Data?

        var url: URL? { request.url }
        func header(_ name: String) -> String? {
            request.value(forHTTPHeaderField: name)
        }
        var bodyJSON: JSONValue? {
            body.flatMap { try? JSONValue.parse($0) }
        }
    }

    private static let lock = NSLock()
    private static var _handler: ((URLRequest) -> Reply)?
    private static var _requests: [URLRequest] = []
    private static var _recorded: [Recorded] = []

    static var handler: ((URLRequest) -> Reply)? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); defer { lock.unlock() }; _handler = newValue }
    }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    static var recorded: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return _recorded
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _handler = nil
        _requests = []
        _recorded = []
    }

    private static func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        _requests.append(request)
        _recorded.append(Recorded(request: request, body: extractBody(request)))
    }

    /// URLSession moves httpBody into httpBodyStream before the protocol
    /// sees the request — drain the stream so tests can assert on payloads.
    private static func extractBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 16 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    static func session(timeout: TimeInterval = 8) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.record(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        switch handler(request) {
        case .error(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .stub(let stub):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1", headerFields: stub.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// Polls `condition` until it returns true or the timeout elapses. Used to
/// await fire-and-forget background work (revalidation, event flushes).
func waitUntil(
    timeout: TimeInterval = 2,
    _ condition: @escaping () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}
