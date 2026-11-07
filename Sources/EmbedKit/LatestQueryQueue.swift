import Foundation

/// One transport operation and one replaceable pending query. An operation
/// already on the wire drains its response before the next one is dispatched.
actor LatestQueryQueue {
    private struct Job {
        let id: UUID
        let operation: @Sendable () async throws -> [Float]
        let cancellation: QueryCancellation
        var continuation: CheckedContinuation<[Float], any Error>?
        var task: Task<Void, Never>?
    }
    private var active: Job?
    private var pending: Job?

    func submit(_ operation: @escaping @Sendable () async throws -> [Float]) async throws -> [Float] {
        let id = UUID()
        let cancellation = QueryCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let job = Job(id: id, operation: operation, cancellation: cancellation, continuation: continuation)
                if active == nil { start(job) }
                else {
                    // If the active request is still behind indexing I/O, its
                    // cancellation ticket drops it before it reaches the wire.
                    abandonActive()
                    pending?.continuation?.resume(throwing: CancellationError())
                    pending?.cancellation.cancel()
                    pending = job
                }
            }
        } onCancel: {
            cancellation.cancel()
            Task { await self.cancel(id) }
        }
    }

    private func start(_ job: Job) {
        active = job
        active?.task = Task {
            let result: Result<[Float], any Error>
            do { try Task.checkCancellation(); result = .success(try await job.operation()) }
            catch { result = .failure(error) }
            complete(job.id, result: result)
        }
        if let task = active?.task { job.cancellation.install(task) }
    }

    private func complete(_ id: UUID, result: Result<[Float], any Error>) {
        guard active?.id == id else { return }
        active?.continuation?.resume(with: result)
        active?.cancellation.clear()
        active = nil
        if let next = pending { pending = nil; start(next) }
    }

    private func cancel(_ id: UUID) {
        if active?.id == id {
            abandonActive()
        } else if pending?.id == id {
            pending?.continuation?.resume(throwing: CancellationError())
            pending = nil
        }
    }

    private func abandonActive() {
        active?.continuation?.resume(throwing: CancellationError())
        active?.continuation = nil
        active?.cancellation.cancel()
    }
}

/// Cancellation can arrive before the actor processes its cancel message or
/// before a pending job has a task. Keep that state and cancel synchronously.
private final class QueryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var task: Task<Void, Never>?

    func install(_ task: Task<Void, Never>) {
        let ended = lock.withLock {
            if cancelled { return true }
            self.task = task
            return false
        }
        if ended { task.cancel() }
    }

    func cancel() {
        let running = lock.withLock {
            cancelled = true
            let running = task; task = nil
            return running
        }
        running?.cancel()
    }

    func clear() { lock.withLock { task = nil } }
}
