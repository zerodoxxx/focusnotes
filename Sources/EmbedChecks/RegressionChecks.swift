import Darwin
import Foundation
@_spi(Testing) import EmbedKit
import SQLite3

private struct FixtureConfiguration: Codable { var mode: String }

private func append(_ data: Data, to url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
}

/// Invoked only by the temporary test launcher. No models or runtime are used.
func runFixtureHelper() throws {
    _ = signal(SIGPIPE, SIG_IGN)
    guard let flag = CommandLine.arguments.firstIndex(of: "--models"),
          CommandLine.arguments.indices.contains(flag + 1) else { throw EmbeddingError.invalid("Fixture models flag") }
    let directory = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    let config = try JSONDecoder().decode(FixtureConfiguration.self, from: Data(contentsOf: directory.appendingPathComponent("settings.json")))
    try append(Data("\(getpid())\n".utf8), to: directory.appendingPathComponent("spawns"))
    if config.mode == "crash" { _exit(1) }
    while let line = readLine() {
        let request = try JSONDecoder().decode(EmbedRequest.self, from: Data(line.utf8))
        var logged = try JSONEncoder().encode(request); logged.append(10)
        try append(logged, to: directory.appendingPathComponent("requests.jsonl"))
        let text = request.text ?? request.texts?.first ?? ""
        if text.hasPrefix("hold") { usleep(700_000) }
        let response: EmbedResponse
        if config.mode == "error", request.operation != "ping" {
            response = try EmbedResponse(id: request.id, dimensions: request.dimensions, error: "Corrupt fixture model",
                                         processID: getpid(), visionLoaded: false)
        } else {
            let texts = request.texts ?? [text]
            let vectors = texts.map { text in
                var vector = [Float](repeating: 0, count: request.dimensions)
                vector[text.utf8.reduce(0) { ($0 + Int($1)) % request.dimensions }] = 1
                return vector
            }
            response = try EmbedResponse(id: request.id, dimensions: request.dimensions,
                                         vectors: request.operation == "ping" ? nil : vectors,
                                         processID: getpid(), visionLoaded: false)
        }
        var wire = try JSONEncoder().encode(response); wire.append(10)
        try FileHandle.standardOutput.write(contentsOf: wire)
    }
}

private func readResponse(_ handle: FileHandle) throws -> EmbedResponse {
    var data = Data()
    while let byte = try handle.read(upToCount: 1), !byte.isEmpty {
        if byte[0] == 10 { return try JSONDecoder().decode(EmbedResponse.self, from: data) }
        data.append(byte)
    }
    throw EmbeddingError.transport("Intermediate parent's helper exited early")
}

/// A separate parent makes SIGKILL reproducible without harming the check runner.
func runOrphanParent() throws {
    let arguments = Array(CommandLine.arguments.dropFirst(2))
    guard arguments.count == 3 else { throw EmbeddingError.invalid("Orphan parent arguments") }
    let helper = Process(), input = Pipe(), output = Pipe()
    helper.executableURL = URL(fileURLWithPath: arguments[0])
    helper.arguments = ["--models", arguments[1]]
    helper.standardInput = input; helper.standardOutput = output
    helper.standardError = FileHandle.nullDevice
    try helper.run()
    try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
    func send(_ request: EmbedRequest) throws {
        var wire = try JSONEncoder().encode(request); wire.append(10)
        try input.fileHandleForWriting.write(contentsOf: wire)
    }
    try send(EmbedRequest(operation: "ping"))
    _ = try readResponse(output.fileHandleForReading) // Watcher is installed; models are still cold.
    let state = URL(fileURLWithPath: arguments[2])
    try Data(String(helper.processIdentifier).utf8).write(to: state.appendingPathComponent("pid"))
    try send(EmbedRequest(operation: "embedDocuments", texts: Array(repeating: String(repeating: "token buckets allow bursts ", count: 120), count: 16)))
    try Data().write(to: state.appendingPathComponent("busy"))
    _ = try readResponse(output.fileHandleForReading)
    try Data().write(to: state.appendingPathComponent("completed"))
    try input.fileHandleForWriting.close()
    helper.waitUntilExit()
}

private func requests(in directory: URL) throws -> [EmbedRequest] {
    let url = directory.appendingPathComponent("requests.jsonl")
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
        try JSONDecoder().decode(EmbedRequest.self, from: Data($0.utf8))
    }
}

private func waitUntil(_ condition: () throws -> Bool, timeout: Duration = .seconds(3)) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !(try condition()) {
        guard ContinuousClock.now < deadline else { throw EmbeddingError.invalid("Regression fixture did not become ready") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func waitUntilAsync(_ condition: () async -> Bool, timeout: Duration = .seconds(3)) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw EmbeddingError.invalid("Regression fixture did not become ready") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func makeFixture(in root: URL, mode: String) throws -> (URL, URL) {
    let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(FixtureConfiguration(mode: mode)).write(to: directory.appendingPathComponent("settings.json"))
    let executable = directory.appendingPathComponent("helper")
    let own = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
    let quoted = "'" + own.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    try Data("#!/bin/sh\nexec \(quoted) --fixture-helper \"$@\"\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return (executable, directory)
}

private final class StageMarker: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var started: Bool { lock.withLock { value } }
    func mark() { lock.withLock { value = true } }
}
private actor BusyStage {
    func hold(_ marker: StageMarker) { marker.mark(); usleep(700_000) }
    func lookup() -> String { "complete" }
}
private func slowSynchronousStage() -> String { usleep(700_000); return "complete" }

func runRegressionChecks(_ checks: inout Checks, root: URL) async throws {
    let actor = BusyStage(), marker = StageMarker()
    let holding = Task.detached { await actor.hold(marker) }
    try await waitUntil { marker.started }
    var start = ContinuousClock.now
    let blocked = await SemanticDeadline.run(timeout: .milliseconds(350), fallback: "empty") { await actor.lookup() }
    checks.require(blocked == "empty" && start.duration(to: .now) < .milliseconds(500), "whole-search 350 ms deadline includes actor contention")
    await holding.value
    for stage in ["resource initialization", "post-embedding ranking/hit lookup"] {
        start = ContinuousClock.now
        let result = await SemanticDeadline.run(timeout: .milliseconds(350), fallback: "empty") { slowSynchronousStage() }
        let elapsed = start.duration(to: .now)
        let passed = result == "empty" && elapsed < .milliseconds(500)
        let diagnostic = passed ? "" : " (returned \(result) after \(elapsed))"
        checks.require(passed, "whole-search deadline includes \(stage)\(diagnostic)")
    }
    let healthy = await SemanticDeadline.run(timeout: .milliseconds(350), fallback: "empty") { "complete" }
    checks.require(healthy == "complete", "healthy semantic work wins deadline")
    let cancelled = Task {
        await SemanticDeadline.run(timeout: .seconds(5), fallback: "empty") { slowSynchronousStage() }
    }
    try await Task.sleep(for: .milliseconds(20))
    start = .now; cancelled.cancel()
    let cancelledResult = await cancelled.value
    checks.require(cancelledResult == "empty" && start.duration(to: .now) < .milliseconds(100), "search cancellation returns without draining synchronous work")

    // Old stores have no model identity, so their vectors cannot be safely reused.
    let legacyURL = root.appendingPathComponent("legacy.sqlite")
    var connection: OpaquePointer?
    guard sqlite3_open(legacyURL.path, &connection) == SQLITE_OK, let db = connection else { throw EmbeddingError.database("Legacy fixture open") }
    var basis = [Float](repeating: 0, count: 256); basis[0] = 1
    let hex = try Float16Vectors.encode(basis).map { String(format: "%02x", $0) }.joined()
    let sql = "CREATE TABLE embeddings(key TEXT PRIMARY KEY NOT NULL,model_id TEXT NOT NULL,dims INTEGER NOT NULL,vector BLOB NOT NULL) WITHOUT ROWID; INSERT INTO embeddings VALUES('legacy','\(Embedder.modelID)',256,x'\(hex)');"
    let code = sqlite3_exec(db, sql, nil, nil, nil); sqlite3_close(db)
    guard code == SQLITE_OK else { throw EmbeddingError.database("Legacy fixture schema") }
    let migrated = try VectorStore(url: legacyURL)
    checks.require(try migrated.keys().isEmpty, "legacy vectors without model identity are cleared")
    checks.require(try migrated.fingerprints().isEmpty, "legacy fingerprint migration remains safe")

    let (executable, directory) = try makeFixture(in: root, mode: "healthy")
    let client = try EmbedClient(helperExecutable: executable, modelsDirectory: directory)
    let editedStore = try VectorStore(url: root.appendingPathComponent("edit.sqlite"))
    let key = "Note.md#same-capture-uuid"
    var embedded = 0
    for body in ["old body", "edited body", "edited body"] {
        let fingerprint = EmbeddingFingerprint.document(body, title: "Title")
        if try editedStore.fingerprints()[key] != fingerprint {
            let vector = try await client.embedDocuments([body], title: "Title")[0]
            try editedStore.upsert(key: key, vector: vector, fingerprint: fingerprint)
            embedded += 1
        }
    }
    let edited = try await client.embedDocuments(["edited body"], title: "Title")[0]
    checks.require(try embedded == 2 && editedStore.keys() == [key] && editedStore.nearest(to: edited, limit: 1).first?.score == 1,
                   "edit body under same key re-embeds; unchanged input is reused")
    let editedFingerprint = EmbeddingFingerprint.document("edited body", title: "Title")
    checks.require(try VectorStore(url: root.appendingPathComponent("edit.sqlite")).fingerprints()[key] == editedFingerprint,
                   "input fingerprint persists across reopen")
    checks.require(EmbeddingFingerprint.document("edited body", title: "Renamed") != editedFingerprint,
                   "title changes invalidate document/OCR fingerprint")
    let asset = root.appendingPathComponent("image.png")
    try Data("first".utf8).write(to: asset)
    let imageFingerprint = try EmbeddingFingerprint.image(at: asset)
    try Data("replacement bytes".utf8).write(to: asset)
    checks.require(try EmbeddingFingerprint.image(at: asset) != imageFingerprint, "replacement image invalidates fingerprint")

    var baseline = try requests(in: directory).count
    let indexing = Task { try await client.embedDocuments(["hold-indexing"]) }
    try await waitUntil { try requests(in: directory).count > baseline }
    var queued = [Task<[Float]?, Never>]()
    queued.append(Task { try? await client.embedLatestQuery("obsolete-0") })
    // The indexing request and first query are both registered with the
    // transport, so the first query is now the active coalesced operation.
    try await waitUntilAsync { await client.pendingRequestCountForTesting() >= 2 }
    for i in 1..<20 {
        let next = Task { try? await client.embedLatestQuery("obsolete-\(i)") }
        if let previous = queued.last { _ = await previous.value }
        queued.append(next)
    }
    let latest = Task { try await client.embedLatestQuery("latest") }
    // The last obsolete caller returns only after latest reaches the
    // coalescing actor, while indexing still holds the transport queue.
    if let previous = queued.last { _ = await previous.value }
    _ = try await indexing.value
    let latestVector = try await latest.value
    let afterBurst = try requests(in: directory).dropFirst(baseline).filter { $0.operation == "embedQuery" }.compactMap(\.text)
    checks.require(afterBurst == ["latest"] && unit(latestVector), "query burst behind indexing sends only latest pending query")

    baseline = try requests(in: directory).count
    let inFlight = Task { try? await client.embedLatestQuery("hold-inflight") }
    try await waitUntil { try requests(in: directory).count > baseline }
    queued = []
    for i in 0..<10 {
        queued.append(Task { try? await client.embedLatestQuery("superseded-\(i)") })
        try await Task.sleep(for: .milliseconds(5))
    }
    let final = Task { try await client.embedLatestQuery("latest-inflight") }
    _ = await inFlight.value
    _ = try await final.value
    for task in queued { _ = await task.value }
    let afterFlight = try requests(in: directory).dropFirst(baseline).compactMap(\.text)
    checks.require(afterFlight == ["hold-inflight", "latest-inflight"], "in-flight inference drains with only one latest pending query")

    baseline = try requests(in: directory).count
    let anotherIndexing = Task { try await client.embedDocuments(["hold-cancellation"]) }
    try await waitUntil { try requests(in: directory).count > baseline }
    let direct = Task { try? await client.embedQuery("cancelled-direct") }
    try await Task.sleep(for: .milliseconds(10)); direct.cancel()
    start = .now
    let expired = await SemanticDeadline.run(timeout: .milliseconds(100), fallback: false) {
        do { _ = try await client.embedLatestQuery("expired-query"); return true }
        catch { return false }
    }
    checks.require(!expired && start.duration(to: .now) < .milliseconds(250), "search deadline returns while indexing transport is busy")
    _ = try await anotherIndexing.value; _ = await direct.value
    _ = try await client.ping() // Drain the serial queue before checking the wire log.
    checks.require(try requests(in: directory).dropFirst(baseline).allSatisfy { $0.operation != "embedQuery" },
                   "cancelled and timed-out queued queries never reach transport")

    baseline = try requests(in: directory).count
    let draining = Task { try? await client.embedLatestQuery("hold-pending-cancel") }
    try await waitUntil { try requests(in: directory).count > baseline }
    let pending = Task { try? await client.embedLatestQuery("cancelled-pending") }
    try await Task.sleep(for: .milliseconds(20)); pending.cancel()
    _ = await pending.value; _ = await draining.value
    _ = try await client.ping()
    let afterPendingCancel = try requests(in: directory).dropFirst(baseline).filter { $0.operation == "embedQuery" }.compactMap(\.text)
    checks.require(afterPendingCancel == ["hold-pending-cancel"], "cancelled latest pending query is dropped during in-flight inference")
    checks.require(try String(contentsOf: directory.appendingPathComponent("spawns"), encoding: .utf8).split(separator: "\n").count == 1,
                   "query cancellation drains framing without restarting a healthy helper")
    await client.shutdown()

    let restartSpawnCount = try String(contentsOf: directory.appendingPathComponent("spawns"), encoding: .utf8).split(separator: "\n").count
    _ = try await client.ping()
    checks.require(try String(contentsOf: directory.appendingPathComponent("spawns"), encoding: .utf8).split(separator: "\n").count == restartSpawnCount + 1,
                   "reversible shutdown still permits a later helper restart")
    await client.shutdown()

    baseline = try requests(in: directory).count
    let closeActive = Task { () -> Bool in
        do { _ = try await client.embedDocuments(["hold-close"]) ; return true }
        catch { return false }
    }
    try await waitUntil { try requests(in: directory).count > baseline }
    let closeQueued = Task { () -> Bool in
        do { _ = try await client.embedQuery("must-not-start-after-close"); return true }
        catch { return false }
    }
    let closeDeadline = ContinuousClock.now.advanced(by: .seconds(3))
    while await client.pendingRequestCountForTesting() < 2, ContinuousClock.now < closeDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard await client.pendingRequestCountForTesting() == 2 else {
        throw EmbeddingError.invalid("Close fixture did not queue both requests")
    }
    let closeSpawnCount = try String(contentsOf: directory.appendingPathComponent("spawns"), encoding: .utf8).split(separator: "\n").count
    await client.close()
    let activeSucceeded = await closeActive.value
    let queuedSucceeded = await closeQueued.value
    let closeRequests = try requests(in: directory).dropFirst(baseline).compactMap { $0.text ?? $0.texts?.first }
    let closeSpawnCountAfter = try String(contentsOf: directory.appendingPathComponent("spawns"), encoding: .utf8).split(separator: "\n").count
    let closePendingCount = await client.pendingRequestCountForTesting()
    checks.require(!activeSucceeded && !queuedSucceeded && closeRequests == ["hold-close"] &&
                   closeSpawnCountAfter == closeSpawnCount && closePendingCount == 0,
                   "permanent close cancels active and queued work without starting another helper")
    do {
        _ = try await client.ping()
        checks.require(false, "closed client rejects new work")
    } catch {
        checks.require(String(describing: error).contains("closed"), "closed client rejects new work")
    }
    checks.require(try String(contentsOf: directory.appendingPathComponent("spawns"), encoding: .utf8).split(separator: "\n").count == closeSpawnCountAfter,
                   "closed client cannot respawn its helper")

    let (errorExecutable, errorDirectory) = try makeFixture(in: root, mode: "error")
    let errorClient = try EmbedClient(helperExecutable: errorExecutable, modelsDirectory: errorDirectory)
    for i in 0..<3 {
        do { _ = try await errorClient.embedQuery("broken"); checks.require(false, "runtime failure degrades gracefully") }
        catch { }
        if i < 2 { _ = try await errorClient.ping() }
    }
    do { _ = try await errorClient.embedQuery("paused"); checks.require(false, "runtime failure cooldown") }
    catch { checks.require(String(describing: error).contains("retry paused"), "model failures trigger backoff despite successful warmup pings") }
    checks.require(try requests(in: errorDirectory).filter { $0.operation == "embedQuery" }.count == 3, "corrupt-model circuit drops further requests")
    await errorClient.shutdown()

    let (crashExecutable, crashDirectory) = try makeFixture(in: root, mode: "crash")
    let crashClient = try EmbedClient(helperExecutable: crashExecutable, modelsDirectory: crashDirectory)
    var failures: [Task<Bool, Never>] = []
    for _ in 0..<12 {
        failures.append(Task {
            do { _ = try await crashClient.embedQuery("crash"); return false }
            catch { return true }
        })
    }
    var allFailed = true
    for task in failures { if !(await task.value) { allFailed = false } }
    let spawnURL = crashDirectory.appendingPathComponent("spawns")
    let spawnCount = try String(contentsOf: spawnURL, encoding: .utf8).split(separator: "\n").count
    checks.require(allFailed && spawnCount == 3, "crash burst spawns at most three helpers before 30 s backoff")
    try JSONEncoder().encode(FixtureConfiguration(mode: "healthy")).write(to: crashDirectory.appendingPathComponent("settings.json"))
    start = .now
    do { _ = try await crashClient.ping(); checks.require(false, "restart fails fast during cooldown") }
    catch { checks.require(String(describing: error).contains("retry paused") && start.duration(to: .now) < .milliseconds(100), "restart fails fast during cooldown") }
    print("WAIT checking recovery after the 30 s helper cooldown"); fflush(nil)
    try await Task.sleep(for: .milliseconds(30_100))
    let recovered = try await crashClient.embedQuery("recovered")
    checks.require(unit(recovered), "transport retries successfully after cooldown")
    await crashClient.shutdown()
}

func checkUnavailableModels(_ checks: inout Checks, helper: URL, root: URL) async throws {
    for mode in ["missing", "corrupt"] {
        let directory = root.appendingPathComponent(mode, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if mode == "corrupt" {
            try Data("invalid dylib".utf8).write(to: directory.appendingPathComponent("libonnxruntime.dylib"))
        }
        let client = try EmbedClient(helperExecutable: helper, modelsDirectory: directory)
        let info = try await client.ping()
        var failed = false
        var errorText = ""
        do { _ = try await client.embedQuery("query") }
        catch { failed = true; errorText = String(describing: error) }
        let after = try await client.ping()
        checks.require(failed && after.processID == info.processID, "\(mode) models return an error and leave helper protocol usable")
        if mode == "corrupt" {
            checks.require(errorText.contains("failed integrity check"), "corrupt runtime is rejected by the integrity check")
        }
        await client.shutdown()
    }
}

func checkBusyParentDeath(_ checks: inout Checks, helper: URL, models: URL, root: URL) async throws {
    let state = root.appendingPathComponent("orphan-parent", isDirectory: true)
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    let parent = Process()
    parent.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
    parent.arguments = ["--orphan-parent", helper.path, models.path, state.path]
    parent.standardOutput = FileHandle.nullDevice; parent.standardError = FileHandle.nullDevice
    try parent.run()
    var helperPID: Int32?
    defer {
        if parent.isRunning { _ = kill(parent.processIdentifier, SIGKILL) }
        if let helperPID, kill(helperPID, 0) == 0 { _ = kill(helperPID, SIGKILL) }
    }
    try await waitUntil({ FileManager.default.fileExists(atPath: state.appendingPathComponent("busy").path) }, timeout: .seconds(10))
    guard let pid = Int32(try String(contentsOf: state.appendingPathComponent("pid"), encoding: .utf8)) else {
        throw EmbeddingError.invalid("Missing orphan fixture helper PID")
    }
    helperPID = pid
    try await Task.sleep(for: .milliseconds(150))
    checks.require(parent.isRunning && kill(pid, 0) == 0 && !FileManager.default.fileExists(atPath: state.appendingPathComponent("completed").path),
                   "intermediate parent is SIGKILLed during cold model work")
    let start = ContinuousClock.now
    _ = kill(parent.processIdentifier, SIGKILL)
    while kill(pid, 0) == 0 && start.duration(to: .now) < .seconds(2) {
        try await Task.sleep(for: .milliseconds(20))
    }
    checks.require(kill(pid, 0) != 0, "busy helper exits within 2 s of parent's SIGKILL")
    parent.waitUntilExit()
}
