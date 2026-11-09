import CryptoKit
import Darwin
import Foundation
import FluxCore

public enum ReleaseDownloadError: Error, Equatable {
    case response, size, digest, file, redirect
}

/// The redirected asset stays on GitHub's release hosts. Redirects cannot
/// switch schemes, ports or credentials. A transfer admits at most four hops.
enum ReleaseAssetOrigin {
    static func accepts(_ url: URL) -> Bool {
        url.scheme == "https" && (url.port == nil || url.port == 443) &&
        url.user == nil && url.password == nil &&
        ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com",
         "github-releases.githubusercontent.com"].contains(url.host?.lowercased() ?? "")
    }
}

private final class DownloadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionTask?
    func attach(_ task: URLSessionTask) {
        lock.lock(); self.task = task; let cancelled = cancelled; lock.unlock()
        if cancelled { task.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }
}

/// After start, mutable transfer state belongs to its serial utility delegate
/// queue. Cancellation only touches the separately locked task handle.
private final class ReleaseTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let manifest: ReleaseManifest
    private let destination: URL
    private let protocols: [AnyClass]
    private let cancellation = DownloadCancellation()
    private var session: URLSession?
    private var file: FileHandle?
    private var result: CheckedContinuation<Void, any Error>?
    private var hash = SHA256()
    private var received: Int64 = 0
    private var redirects = 0
    private var failure: (any Error)?

    init(manifest: ReleaseManifest, destination: URL, protocols: [AnyClass]) {
        self.manifest = manifest; self.destination = destination; self.protocols = protocols
    }

    func download() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, any Error>) in
                let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
                guard descriptor >= 0 else { result.resume(throwing: ReleaseDownloadError.file); return }
                file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                self.result = result
                let configuration = URLSessionConfiguration.ephemeral
                if !protocols.isEmpty { configuration.protocolClasses = protocols }
                configuration.httpCookieStorage = nil; configuration.urlCache = nil
                configuration.urlCredentialStorage = nil; configuration.httpShouldSetCookies = false
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = 15
                configuration.timeoutIntervalForResource = 180
                configuration.waitsForConnectivity = false
                configuration.httpMaximumConnectionsPerHost = 1
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                var request = URLRequest(url: manifest.downloadURL)
                request.setValue("Flux", forHTTPHeaderField: "User-Agent")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let task = session.dataTask(with: request)
                cancellation.attach(task)
                task.resume()
            }
        } onCancel: { cancellation.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let url = response.url, ReleaseAssetOrigin.accepts(url) else {
            failure = ReleaseDownloadError.response; completionHandler(.cancel); return
        }
        guard response.expectedContentLength < 0 || response.expectedContentLength == manifest.size else {
            failure = ReleaseDownloadError.size; completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        guard Int64(data.count) <= manifest.size - received else {
            failure = ReleaseDownloadError.size; dataTask.cancel(); return
        }
        do {
            try file?.write(contentsOf: data)
            hash.update(data: data)
            received += Int64(data.count)
        } catch { failure = ReleaseDownloadError.file; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 4, let url = request.url, ReleaseAssetOrigin.accepts(url) else {
            failure = ReleaseDownloadError.redirect; completionHandler(nil); return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let result else { return }
        self.result = nil
        defer { self.session = nil; session.invalidateAndCancel() }
        do {
            try file?.synchronize(); try file?.close(); file = nil
            if let failure { throw failure }
            if let error { throw error }
            guard received == manifest.size else { throw ReleaseDownloadError.size }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            if let expected = manifest.sha256, digest != expected { throw ReleaseDownloadError.digest }
            result.resume()
        } catch {
            try? file?.close(); file = nil
            try? FileManager.default.removeItem(at: destination)
            result.resume(throwing: error)
        }
    }
}

public enum ReleaseDownload {
    /// The destination must be a new file in the installer's owned private
    /// workspace. A failed or cancelled transfer removes only that file.
    public static func fetch(_ manifest: ReleaseManifest, to destination: URL) async throws {
        try await fetch(manifest, to: destination, protocols: [])
    }

    static func fetch(_ manifest: ReleaseManifest, to destination: URL, protocols: [AnyClass]) async throws {
        guard destination.isFileURL, manifest.size > 0,
              manifest.size <= ReleaseManifest.maximumDownloadBytes else { throw ReleaseDownloadError.file }
        try await ReleaseTransfer(manifest: manifest, destination: destination, protocols: protocols).download()
    }
}
