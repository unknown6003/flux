import Foundation

public enum ReleaseClientError: Error { case busy, invalidResponse, unavailable, oversized }

private final class ReleaseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Construct on the first requested check. No timer, cookies, cache or
/// credentials. The caller owns automatic check timing and installation.
public actor ReleaseClient {
    private static let endpoint = URL(string: "https://api.github.com/repos/unknown6003/flux/releases/latest")!
    private let session: URLSession
    private let redirects = ReleaseRedirects()
    private var busy = false

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.allowsConstrainedNetworkAccess = false
        session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    public func latest() async throws -> ReleaseManifest {
        try Task.checkCancellation()
        guard !busy else { throw ReleaseClientError.busy }
        busy = true
        defer { busy = false }
        var request = URLRequest(url: Self.endpoint)
        request.setValue("Flux", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (bytes, response) = try await session.bytes(for: request, delegate: redirects)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw ReleaseClientError.invalidResponse }
        guard http.statusCode == 200 else { throw ReleaseClientError.unavailable }
        guard response.expectedContentLength <= Int64(ReleaseManifest.maximumResponseBytes) else {
            throw ReleaseClientError.oversized
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < ReleaseManifest.maximumResponseBytes else { throw ReleaseClientError.oversized }
            data.append(byte)
        }
        return try ReleaseManifest(data: data)
    }
}
