import Foundation
import Darwin
import Dispatch

/// Sendable client with async methods callable from any actor. A private serial
/// I/O queue owns the process and framing state; overlapping calls cannot mix
/// responses. No model or runtime is loaded in the calling process.
public final class EmbedClient: Sendable {
    public let dimensions: Int
    private let transport: HelperTransport
    private let latestQueries = LatestQueryQueue()

    public init(helperExecutable: URL, modelsDirectory: URL, dimensions: Int = 256,
                idleSeconds: Double = 60, requestTimeout: Double = 120) throws {
        guard EmbedProtocol.supportedDimensions.contains(dimensions), idleSeconds.isFinite, idleSeconds > 0, idleSeconds <= 86_400,
              requestTimeout.isFinite, requestTimeout > 0, requestTimeout <= 86_400 else {
            throw EmbeddingError.invalid("Invalid client configuration")
        }
        self.dimensions = dimensions
        self.transport = HelperTransport(executable: helperExecutable, directory: modelsDirectory,
                                         idle: idleSeconds, timeout: requestTimeout)
    }

    public func embedQuery(_ text: String) async throws -> [Float] {
        let vectors = try await perform(EmbedRequest(operation: "embedQuery", text: text, dimensions: dimensions))
        guard vectors.count == 1 else { throw EmbeddingError.transport("Expected one query vector") }
        return vectors[0]
    }

    /// For interactive search: superseded callers are cancelled; only the
    /// latest pending query survives while an in-flight response drains.
    public func embedLatestQuery(_ text: String) async throws -> [Float] {
        try await latestQueries.submit { [self] in try await embedQuery(text) }
    }

    public func embedDocuments(_ texts: [String], title: String? = nil) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let vectors = try await perform(EmbedRequest(operation: "embedDocuments", texts: texts, title: title, dimensions: dimensions))
        guard vectors.count == texts.count else { throw EmbeddingError.transport("Document count mismatch") }
        return vectors
    }

    public func embedImage(_ imagePNG: Data) async throws -> [Float] {
        let vectors = try await perform(EmbedRequest(operation: "embedImage", imagePNG: imagePNG.base64EncodedString(), dimensions: dimensions))
        guard vectors.count == 1 else { throw EmbeddingError.transport("Expected one image vector") }
        return vectors[0]
    }

    /// Ping starts the helper if needed but does not load any model.
    public func ping() async throws -> EmbedResponse {
        try await transport.send(EmbedRequest(operation: "ping", dimensions: dimensions))
    }

    /// Does not launch the helper. Useful to observe idle exit.
    public func processID() async -> Int32? { await transport.processID() }
    public func shutdown() async { await transport.shutdown() }

    /// Permanently rejects new work and stops this client's helper. Unlike
    /// `shutdown()`, a closed client cannot be restarted.
    public func close() async { await transport.close() }

    @_spi(Testing) public func pendingRequestCountForTesting() async -> Int {
        await transport.pendingRequestCount()
    }

    private func perform(_ request: EmbedRequest) async throws -> [[Float]] {
        try Task.checkCancellation()
        let response = try await transport.send(request)
        try Task.checkCancellation()
        guard let vectors = response.vectors else { throw EmbeddingError.transport("Missing vectors") }
        return try vectors.map {
            guard let data = Data(base64Encoded: $0) else { throw EmbeddingError.transport("Invalid vector base64") }
            // Float16 wire quantization loses a little norm; restore unit length.
            return try normalized(Float16Vectors.decode(data, dimensions: dimensions))
        }
    }
}

private final class HelperTransport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "EmbedClient.io", qos: .userInitiated)
    private let executable: URL
    private let directory: URL
    private let idle: Double
    private let timeout: Double
    private let lifecycleLock = NSLock()
    private var permanentlyClosed = false
    private var requests: [ObjectIdentifier: TransportCancellation] = [:]
    // Accessed only on queue (or in deinit, once queue's retaining calls finish).
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var pending = Data()
    private var failures: [UInt64] = []
    private var retryAfter: UInt64 = 0

    init(executable: URL, directory: URL, idle: Double, timeout: Double) {
        self.executable = executable; self.directory = directory; self.idle = idle; self.timeout = timeout
    }
    deinit { stop() }

    private func release(_ cancellation: TransportCancellation) {
        _ = lifecycleLock.withLock { requests.removeValue(forKey: ObjectIdentifier(cancellation)) }
    }

    private func ensureOpen(_ cancellation: TransportCancellation) throws {
        let isClosed = lifecycleLock.withLock { permanentlyClosed }
        guard !isClosed else { throw CancellationError() }
        try cancellation.check()
    }

    private func ensureTransportOpen(_ cancellation: TransportCancellation) throws {
        let isClosed = lifecycleLock.withLock { permanentlyClosed }
        guard !isClosed else { throw CancellationError() }
        try cancellation.checkAbort()
    }

    func send(_ request: EmbedRequest) async throws -> EmbedResponse {
        let cancellation = TransportCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let accepted = lifecycleLock.withLock { () -> Bool in
                    guard !permanentlyClosed else { return false }
                    requests[ObjectIdentifier(cancellation)] = cancellation
                    queue.async { [self] in
                        defer { release(cancellation) }
                        do {
                            try ensureOpen(cancellation)
                            // Embedding requests are pure, so retry once if the idle
                            // deadline races a write or the helper dies unexpectedly.
                            var response: EmbedResponse?
                            for attempt in 0..<2 {
                                try ensureOpen(cancellation)
                                try checkBackoff()
                                do {
                                    response = try exchange(request, cancellation: cancellation)
                                    break
                                } catch is CancellationError { throw CancellationError() }
                                catch {
                                    recordFailure()
                                    stop()
                                    try ensureOpen(cancellation)
                                    if attempt == 1 { throw error }
                                }
                            }
                            guard let response else { throw EmbeddingError.transport("No response") }
                            if let error = response.error {
                                // Runtime/model failures also need a cooldown. A bad
                                // install can fail every request without exiting.
                                recordFailure()
                                throw EmbeddingError.runtime(error)
                            }
                            // A ping never loads models, so it cannot prove recovery
                            // from model errors. Actual inference resets the streak.
                            if request.operation != "ping" { failures.removeAll(); retryAfter = 0 }
                            try ensureOpen(cancellation)
                            continuation.resume(returning: response)
                        } catch { continuation.resume(throwing: error) }
                    }
                    return true
                }
                if !accepted { continuation.resume(throwing: EmbeddingError.transport("Embed client is closed")) }
            }
        } onCancel: { cancellation.cancel() }
    }

    private func checkBackoff() throws {
        guard DispatchTime.now().uptimeNanoseconds >= retryAfter else {
            throw EmbeddingError.transport("Helper failures: retry paused for 30 seconds")
        }
        if retryAfter != 0 { retryAfter = 0; failures.removeAll() }
    }

    private func recordFailure() {
        let now = DispatchTime.now().uptimeNanoseconds
        failures.removeAll { now - $0 > 60_000_000_000 }
        failures.append(now)
        if failures.count >= 3 { retryAfter = now + 30_000_000_000 }
    }

    func processID() async -> Int32? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: process?.isRunning == true ? process?.processIdentifier : nil) }
        }
    }

    func shutdown() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in stop(); continuation.resume() }
        }
    }

    func close() async {
        let active = lifecycleLock.withLock { () -> [TransportCancellation] in
            permanentlyClosed = true
            return Array(requests.values)
        }
        active.forEach { $0.abort() }
        await withCheckedContinuation { continuation in
            queue.async { [self] in stop(); continuation.resume() }
        }
    }

    func pendingRequestCount() async -> Int {
        lifecycleLock.withLock { requests.count }
    }

    private func start() throws {
        if process?.isRunning == true { return }
        stop()
        let task = Process(), stdin = Pipe(), stdout = Pipe()
        task.executableURL = executable
        task.arguments = ["--models", directory.path, "--idle-seconds", String(idle)]
        task.standardInput = stdin; task.standardOutput = stdout; task.standardError = FileHandle.standardError
        try lifecycleLock.withLock {
            guard !permanentlyClosed else { throw CancellationError() }
            try task.run()
            process = task; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        }
        // Foundation keeps parent copies of child pipe ends; close them so EOF
        // is observable even when the process exits between two requests.
        try? stdin.fileHandleForReading.close(); try? stdout.fileHandleForWriting.close()
        guard fcntl(input!.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            stop(); throw EmbeddingError.transport("Could not suppress SIGPIPE on helper stdin")
        }
        for handle in [input!, output!] {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                stop(); throw EmbeddingError.transport("Could not configure helper pipes")
            }
        }
    }

    private func stop() {
        try? input?.close(); try? output?.close()
        if let process, process.isRunning {
            process.terminate()
            // waitUntilExit() can stall its worker-thread run loop even after
            // the child is reaped. Let Foundation's process monitor observe
            // exit, with a bounded grace period and SIGKILL fallback.
            let deadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
            while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline { usleep(5_000) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
        process = nil; input = nil; output = nil; pending.removeAll(keepingCapacity: false)
    }

    private func ready(_ fd: Int32, events: Int16, deadline: UInt64,
                       cancellation: TransportCancellation) throws {
        while true {
            // Ordinary query cancellation still drains the in-flight response
            // to preserve the request/response framing. Permanent close aborts
            // the poll so its queued stop can terminate the helper promptly.
            try ensureTransportOpen(cancellation)
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw EmbeddingError.transport("Helper request timed out") }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let milliseconds = Int32(min(1000, max(1, (deadline - now) / 1_000_000)))
            let result = poll(&descriptor, 1, milliseconds)
            if result < 0 && errno == EINTR { continue }
            if result < 0 { throw EmbeddingError.transport("Helper pipe poll failed") }
            if result == 0 { continue }
            if descriptor.revents & events != 0 { try ensureTransportOpen(cancellation); return }
            throw EmbeddingError.transport("Helper closed its pipe")
        }
    }

    private func exchange(_ request: EmbedRequest, cancellation: TransportCancellation) throws -> EmbedResponse {
        var wire = try JSONEncoder().encode(request); wire.append(10)
        guard wire.count <= 64 * 1024 * 1024 else { throw EmbeddingError.invalid("Request exceeds 64 MiB") }
        try start()
        try cancellation.check()
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        let writeFD = input!.fileDescriptor, readFD = output!.fileDescriptor
        try wire.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try ready(writeFD, events: Int16(POLLOUT), deadline: deadline, cancellation: cancellation)
                let count = Darwin.write(writeFD, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && [EAGAIN, EINTR].contains(errno) { continue }
                guard count > 0 else { throw EmbeddingError.transport("Helper stdin write failed") }
                offset += count
            }
        }
        while pending.firstIndex(of: 10) == nil {
            try ready(readFD, events: Int16(POLLIN), deadline: deadline, cancellation: cancellation)
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(readFD, &bytes, bytes.count)
            if count < 0 && [EAGAIN, EINTR].contains(errno) { continue }
            guard count > 0 else { throw EmbeddingError.transport("Helper stdout closed") }
            pending.append(contentsOf: bytes.prefix(count))
            guard pending.count <= 64 * 1024 * 1024 else { throw EmbeddingError.transport("Helper response exceeds 64 MiB") }
        }
        let newline = pending.firstIndex(of: 10)!
        let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
        let response = try JSONDecoder().decode(EmbedResponse.self, from: line)
        guard response.id == request.id, response.modelID == Embedder.modelID, response.dimensions == request.dimensions else {
            throw EmbeddingError.transport("Helper response ID, model or dimensions mismatch")
        }
        return response
    }
}

private final class TransportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var abortRequested = false
    func cancel() { lock.withLock { cancelled = true } }
    func abort() { lock.withLock { cancelled = true; abortRequested = true } }
    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
    func checkAbort() throws {
        if lock.withLock({ abortRequested }) { throw CancellationError() }
    }
}
