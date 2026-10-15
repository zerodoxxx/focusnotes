import Foundation

/// Bounds the entire operation, including waiting to enter another actor. The
/// losing task is cancelled without awaiting non-cancellable helper I/O.
public enum SemanticDeadline {
    public static func run<Value: Sendable>(timeout: Duration, fallback: Value,
                                            operation: @escaping @Sendable () async -> Value) async -> Value {
        let race = DeadlineRace(fallback: fallback)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.install(continuation)
                // The timer lives on GCD, not the cooperative pool, so synchronous
                // work that saturates the pool cannot delay the fallback. Firing
                // after the race has finished is a no-op.
                let (seconds, attoseconds) = timeout.components
                let nanoseconds = max(0, seconds) * 1_000_000_000 + max(0, attoseconds) / 1_000_000_000
                DispatchQueue.global(qos: .userInitiated)
                    .asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) { race.finish(fallback) }
                let work = Task.detached(priority: .userInitiated) {
                    guard !Task.isCancelled, !race.isFinished else { return }
                    race.finish(await operation())
                }
                race.track { work.cancel() }
            }
        } onCancel: { race.finish(fallback) }
    }
}

private final class DeadlineRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let fallback: Value
    private var continuation: CheckedContinuation<Value, Never>?
    private var finished = false
    private var cancellers: [@Sendable () -> Void] = []

    init(fallback: Value) { self.fallback = fallback }
    var isFinished: Bool { lock.withLock { finished } }

    func install(_ continuation: CheckedContinuation<Value, Never>) {
        let ended = lock.withLock {
            if finished { return true }
            self.continuation = continuation
            return false
        }
        if ended { continuation.resume(returning: fallback) }
    }

    func track(_ cancel: @escaping @Sendable () -> Void) {
        let ended = lock.withLock {
            if finished { return true }
            cancellers.append(cancel)
            return false
        }
        if ended { cancel() }
    }

    func finish(_ value: Value) {
        let state = lock.withLock { () -> (CheckedContinuation<Value, Never>?, [@Sendable () -> Void]) in
            guard !finished else { return (nil, []) }
            finished = true
            let state = (continuation, cancellers)
            continuation = nil; cancellers = []
            return state
        }
        state.1.forEach { $0() }
        state.0?.resume(returning: value)
    }
}
