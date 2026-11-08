import Foundation

public enum UsageEndpoint: Sendable, Equatable {
    case events, flags, logs
}

public struct UsageRequest: Sendable {
    public let endpoint: UsageEndpoint
    public let body: Data
    public let projectToken: String
}

public struct UsageResponse: Sendable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data = Data()) {
        self.status = status
        self.body = body
    }
}

public protocol UsageTransport: Sendable {
    func send(_ request: UsageRequest) async throws -> UsageResponse
}

private final class RefuseUsageRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Project tokens and payloads must never follow an HTTP redirect.
        completionHandler(nil)
    }
}

public actor NativeUsageTransport: UsageTransport {
    private let region: PostHogRegion
    private let session: URLSession
    private let redirects = RefuseUsageRedirects()

    public init(region: PostHogRegion) {
        self.region = region
        session = URLSession(configuration: Self.configuration())
    }

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 1
        config.allowsConstrainedNetworkAccess = false
        config.httpAdditionalHeaders = ["User-Agent": "Flux", "Cache-Control": "no-store"]
        return config
    }

    init(region: PostHogRegion, session: URLSession) {
        self.region = region
        self.session = session
    }

    deinit { session.invalidateAndCancel() }

    public func send(_ payload: UsageRequest) async throws -> UsageResponse {
        try Task.checkCancellation()
        var components = URLComponents(url: region.host, resolvingAgainstBaseURL: false)!
        switch payload.endpoint {
        case .events: components.path = "/batch/"
        case .flags:
            components.path = "/flags/"
            components.queryItems = [URLQueryItem(name: "v", value: "2")]
        case .logs: components.path = "/i/v1/logs"
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.httpBody = payload.body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if case .logs = payload.endpoint {
            request.setValue("Bearer " + payload.projectToken, forHTTPHeaderField: "Authorization")
        }
        let (bytes, response) = try await session.bytes(for: request, delegate: redirects)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw PostHogWireError.invalidResponse }
        guard response.expectedContentLength <= Int64(PostHogWire.maximumResponseBytes) else {
            throw PostHogWireError.oversizedResponse
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < PostHogWire.maximumResponseBytes else { throw PostHogWireError.oversizedResponse }
            data.append(byte)
        }
        return UsageResponse(status: response.statusCode, body: data)
    }
}
