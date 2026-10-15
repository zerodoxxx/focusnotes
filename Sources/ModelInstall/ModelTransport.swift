import Foundation

/// Fetches one URL into a file. The installer resumes partial files through `offset`.
public protocol ModelTransport: Sendable {
    /// Downloads `url` into `file`.
    ///
    /// - When `offset` is greater than zero, sends `Range: bytes=<offset>-`.
    /// - A 206 appends to `file`. A 200 truncates `file` and writes the full body.
    /// - A 416 writes nothing; the caller verifies the hash.
    /// - Any other non-2xx status throws `ModelInstallError.httpStatus`.
    /// - `progress` receives the file's total length on disk after each chunk is written.
    func download(from url: URL, appendingTo file: URL, offset: Int64,
                  progress: @escaping @Sendable (Int64) -> Void) async throws
}

/// Production transport: HTTPS only, no cookies or cache, resumes with Range requests.
public final class URLSessionTransport: ModelTransport, Sendable {
    private let userAgent: String

    public init() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "ModelInstall"
        userAgent = "\(name)/\(version)"
    }

    public func download(from url: URL, appendingTo file: URL, offset: Int64,
                         progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard url.scheme?.lowercased() == "https" else {
            throw ModelInstallError.insecureRedirect(url.absoluteString)
        }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60

        let delegate = DownloadDelegate(file: file, offset: offset, progress: progress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.start(task, continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }
}

// URLSession calls this on its own serial queue, so the lock guards the state shared with the awaiting task.
private final class DownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let file: URL
    private let offset: Int64
    private let progress: @Sendable (Int64) -> Void
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelRequested = false
    private var failure: ModelInstallError?
    private var handle: FileHandle?
    private var ignoreBody = false
    private var written: Int64 = 0

    init(file: URL, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.file = file
        self.offset = offset
        self.progress = progress
        super.init()
    }

    /// Called by the awaiting task. The data task starts only if cancellation has not already been requested.
    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelRequested else {
            continuation.resume(throwing: ModelInstallError.cancelled)
            return
        }
        self.task = task
        self.continuation = continuation
        task.resume()
    }

    /// Cancels the data task. The awaiting continuation resumes when URLSession reports completion.
    func cancel() {
        lock.lock()
        cancelRequested = true
        let running = task
        lock.unlock()
        running?.cancel()
    }

    private func fail(_ error: ModelInstallError) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
    }

    private func attach(_ newHandle: FileHandle, startingAt length: Int64) {
        lock.lock()
        handle = newHandle
        written = length
        lock.unlock()
    }

    private func ignoreResponseBody() {
        lock.lock()
        ignoreBody = true
        lock.unlock()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let alreadyFailed = failure != nil
        lock.unlock()
        guard !alreadyFailed else {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            fail(.network("The server sent an unexpected response."))
            completionHandler(.cancel)
            return
        }
        do {
            switch http.statusCode {
            case 206:
                if !FileManager.default.fileExists(atPath: file.path) {
                    _ = FileManager.default.createFile(atPath: file.path, contents: nil)
                }
                let resumed = try FileHandle(forWritingTo: file)
                let end = try Int64(resumed.seekToEnd())
                guard end == offset else {
                    try? resumed.close()
                    // Retryable: the installer re-reads the partial's real size and resumes from there, or starts over.
                    throw ModelInstallError.network("the partial download changed while it was being resumed")
                }
                attach(resumed, startingAt: end)
            case 416:
                ignoreResponseBody()
            case 200..<300:
                _ = FileManager.default.createFile(atPath: file.path, contents: nil)
                let fresh = try FileHandle(forWritingTo: file)
                attach(fresh, startingAt: 0)
            default:
                fail(.httpStatus(http.statusCode, host: http.url?.host ?? "the server"))
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        } catch let error as ModelInstallError {
            fail(error)
            completionHandler(.cancel)
        } catch {
            fail(.io(error.localizedDescription))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !ignoreBody, failure == nil, let handle else {
            lock.unlock()
            return
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = .io(error.localizedDescription)
            lock.unlock()
            dataTask.cancel()
            return
        }
        written += Int64(data.count)
        let total = written
        lock.unlock()
        progress(total)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme?.lowercased() == "https" else {
            fail(.insecureRedirect(request.url?.absoluteString ?? ""))
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let waiter = continuation
        continuation = nil
        self.task = nil
        let closing = handle
        handle = nil
        let failed = failure
        let wasCancelled = cancelRequested
        lock.unlock()

        if let closing {
            try? closing.close()
        }
        guard let waiter else { return }
        if let failed {
            waiter.resume(throwing: failed)
        } else if let error {
            let cancelled = wasCancelled || (error as? URLError)?.code == .cancelled
            let mapped: ModelInstallError = cancelled ? .cancelled : .network(error.localizedDescription)
            waiter.resume(throwing: mapped)
        } else {
            waiter.resume()
        }
    }
}
