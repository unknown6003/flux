import Foundation
import Testing
@testable import FluxCore

private final class UsageHTTPFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var body = Data()
    private var requests: [URLRequest] = []

    func prepare(_ value: Data) {
        lock.lock()
        defer { lock.unlock() }
        body = value
        requests.removeAll()
    }

    func accept(_ request: URLRequest) -> Data {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return body
    }

    func snapshot() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private final class UsageHTTPFixture: URLProtocol, @unchecked Sendable {
    static let state = UsageHTTPFixtureState()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.state.accept(request)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class UsageSessionLifecycle: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let invalidated: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    override init() {
        (invalidated, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
        super.init()
    }
    func makeSession() -> URLSession {
        lock.lock(); count += 1; lock.unlock()
        let config = NativeUsageTransport.configuration()
        config.protocolClasses = [UsageHTTPFixture.self]
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    func creations() -> Int { lock.lock(); defer { lock.unlock() }; return count }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        continuation.yield(())
    }
}

@Test(.timeLimit(.minutes(1))) func realURLSessionUsesOnlyTheSelectedHostAndBoundsResponseData() async throws {
    let config = NativeUsageTransport.configuration()
    #expect(config.urlCache == nil)
    #expect(config.httpCookieStorage == nil)
    #expect(config.urlCredentialStorage == nil)
    #expect(!config.httpShouldSetCookies)
    let lifecycle = UsageSessionLifecycle()
    let transport = NativeUsageTransport(region: .eu, makeSession: { lifecycle.makeSession() })
    #expect(lifecycle.creations() == 0)
    var invalidated = lifecycle.invalidated.makeAsyncIterator()

    for endpoint in [UsageEndpoint.events, .flags, .logs] {
        UsageHTTPFixture.state.prepare(Data(#"{"ok":true}"#.utf8))
        let result = try await transport.send(UsageRequest(endpoint: endpoint, body: Data("{}".utf8), projectToken: "phc_fixture"))
        _ = await invalidated.next()
        #expect(result.status == 200)
        let requests = UsageHTTPFixture.state.snapshot()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.host == "eu.i.posthog.com")
        #expect(request.url?.scheme == "https")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Flux")
        #expect(request.url?.absoluteString.contains("phc_fixture") == false)
        if endpoint == .logs {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer phc_fixture")
        } else {
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        }
    }
    UsageHTTPFixture.state.prepare(Data(repeating: 65, count: PostHogWire.maximumResponseBytes + 1))
    await #expect(throws: PostHogWireError.self) {
        try await transport.send(UsageRequest(endpoint: .flags, body: Data("{}".utf8), projectToken: "phc_fixture"))
    }
    _ = await invalidated.next()
    #expect(lifecycle.creations() == 4)
}
