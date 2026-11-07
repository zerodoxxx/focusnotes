import Foundation

private actor DeadlineRace<T: Sendable> {
    enum Outcome: Sendable { case finished(T), expired }
    private var outcome: Outcome?
    private var continuation: CheckedContinuation<Outcome, Never>?

    func resolve(_ value: Outcome) {
        guard outcome == nil else { return }
        outcome = value
        continuation?.resume(returning: value)
        continuation = nil
    }

    func wait() async -> Outcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation = $0 }
    }
}

/// Returns `work`'s result, or nil at `deadline` without awaiting it. `work` keeps running either way.
func withDeadline<T: Sendable>(_ deadline: ContinuousClock.Instant,
                               _ work: @escaping @Sendable () async -> T) async -> T? {
    let race = DeadlineRace<T>()
    Task { await race.resolve(.finished(await work())) }
    let timer = Task {
        do { try await Task.sleep(until: deadline, clock: .continuous) }
        catch { return } // An on-time result cancels the one-shot deadline.
        await race.resolve(.expired)
    }
    let outcome = await race.wait()
    timer.cancel()
    guard case .finished(let value) = outcome else { return nil }
    return value
}

@MainActor
func waitForShutdown(_ task: Task<Void, Never>, until deadline: ContinuousClock.Instant) async -> Bool {
    await withDeadline(deadline) { await task.value } != nil
}
