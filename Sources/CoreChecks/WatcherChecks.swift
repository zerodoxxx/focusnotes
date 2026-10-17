import Core
import Foundation

private final class VaultChangeRecorder: @unchecked Sendable {
    private let condition = NSCondition()
    private var recorded: [VaultChange] = []

    func append(_ change: VaultChange) {
        condition.lock()
        recorded.append(change)
        condition.broadcast()
        condition.unlock()
    }

    func changes() -> [VaultChange] {
        condition.lock()
        defer { condition.unlock() }
        return recorded
    }

    func waitForChange(timeout: TimeInterval, matching predicate: (VaultChange) -> Bool) -> VaultChange? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while let change = recorded.first(where: predicate) {
            return change
        }
        while condition.wait(until: deadline) {
            if let change = recorded.first(where: predicate) {
                return change
            }
        }
        return nil
    }

    func waitForQuiet(for interval: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let initialCount = recorded.count
        let deadline = Date().addingTimeInterval(interval)
        while Date() < deadline {
            guard condition.wait(until: deadline) else { break }
            if recorded.count != initialCount { return false }
        }
        return recorded.count == initialCount
    }
}

func checkVaultWatcher() throws {
    let root = try checkMakeDirectory("vault-watcher")
    defer { checkRemoveDirectory(root) }
    let vault = Vault(root: root)
    try vault.prepare()
    let recorder = VaultChangeRecorder()
    let watcher = VaultWatcher(vault: vault, latency: 0.1) { recorder.append($0) }
    try require(!watcher.isRunning, "VaultWatcher should not report running before start")
    watcher.start()
    try require(watcher.isRunning, "VaultWatcher should report a successfully started stream")

    try checkWrite("# Foo\n", to: root.appendingPathComponent("Foo.md"))
    let fooChange = recorder.waitForChange(timeout: 3.0) { $0.notesChanged.contains("Foo.md") }
    try require(fooChange != nil, "VaultWatcher did not report Foo.md within 3 seconds")

    try checkWrite("# S\n", to: vault.sessionsURL.appendingPathComponent("S.md"))
    let sessionChange = recorder.waitForChange(timeout: 2.5) { $0.notesChanged.contains("Sessions/S.md") }
    try require(sessionChange != nil, "VaultWatcher did not report Sessions/S.md within 3 seconds")

    try checkWrite("# Nested\n", to: root.appendingPathComponent("science/math/Trigonometry.md"))
    let nestedChange = recorder.waitForChange(timeout: 2.5) { $0.notesChanged.contains("science/math/Trigonometry.md") }
    try require(nestedChange != nil, "VaultWatcher did not report a note nested under user folders")

    try checkWrite("metadata", to: root.appendingPathComponent(".DS_Store"))
    try checkWrite("temporary", to: root.appendingPathComponent("Foo.md.swp"))
    try checkWrite("lock", to: root.appendingPathComponent("~$draft.md"))
    try require(recorder.waitForQuiet(for: 0.5), "VaultWatcher reported a hidden or swap file")

    try checkWrite("# Bar\n", to: root.appendingPathComponent("Bar.md"))
    let barChange = recorder.waitForChange(timeout: 2.5) { $0.notesChanged.contains("Bar.md") }
    try require(barChange != nil, "own writes must reach fingerprint-based sync")

    // FSEvents may merge both writes into one path event; it must still reach sync.
    let coalesced = root.appendingPathComponent("Coalesced.md")
    try checkWrite("# Coalesced\n\napp append\n", to: coalesced)
    try checkWrite("# Coalesced\n\napp append\nexternal edit\n", to: coalesced)
    let mergedChange = recorder.waitForChange(timeout: 2.5) { $0.notesChanged.contains("Coalesced.md") }
    try require(mergedChange != nil, "coalesced own and external writes must never be suppressed")

    try checkWrite("image bytes", to: vault.assetsURL.appendingPathComponent("image.png"))
    let assetChange = recorder.waitForChange(timeout: 2.25) { $0.assetsChanged.contains("assets/image.png") }
    try require(assetChange != nil, "VaultWatcher did not report assets/image.png")

    watcher.stop()
    try require(!watcher.isRunning, "VaultWatcher should report stopped after stop()")
    let countAfterStop = recorder.changes().count
    try checkWrite("# After stop\n", to: root.appendingPathComponent("After stop.md"))
    try require(recorder.waitForQuiet(for: 0.5), "VaultWatcher delivered a change after stop()")
    try require(recorder.changes().count == countAfterStop, "VaultWatcher callback count changed after stop()")
    print("Vault watcher checks passed.")
}
