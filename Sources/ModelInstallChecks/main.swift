import CryptoKit
import EmbedKit
import Foundation
import ModelInstall

// Offline checks for ModelInstaller. A fake transport serves local bytes, so nothing touches the network.

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw CheckFailure(message) }
}

/// Lock-guarded value that can be shared with the installer's Sendable callbacks.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func deterministicBytes(count: Int, seed: UInt8) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
}

func writeFile(_ url: URL, _ data: Data) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

func fileSize(_ url: URL) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.size] as? NSNumber)?.int64Value ?? -1
}

func runTar(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CheckFailure("tar \(arguments.joined(separator: " ")) exited with \(process.terminationStatus)")
    }
}

/// Relative paths of every regular file under `directory`.
func regularFiles(under directory: URL) throws -> Set<String> {
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
        return []
    }
    let prefix = directory.resolvingSymlinksInPath().path + "/"
    var names = Set<String>()
    for case let url as URL in enumerator {
        if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let path = url.resolvingSymlinksInPath().path
            try expect(path.hasPrefix(prefix), "\(path) is outside \(prefix)")
            names.insert(String(path.dropFirst(prefix.count)))
        }
    }
    return names
}

func modelsDirectory(_ root: URL) -> URL {
    root.appendingPathComponent("models", isDirectory: true)
}

func stagingDirectory(_ root: URL) -> URL {
    root.appendingPathComponent("models.download", isDirectory: true)
}

// MARK: - Fixture

struct Fixture {
    let manifest: ModelManifest
    let resources: URL
    /// URL string to bytes that the fake server returns.
    let served: [String: Data]
    /// Relative file name in the models directory to its exact bytes after a successful install.
    let expectedFinalFiles: [String: Data]

    static func servedURL(_ path: String) -> String {
        "https://example.test/" + path
    }

    func bytes(for name: String) -> Data {
        expectedFinalFiles[name] ?? Data()
    }
}

func makeFixture(in directory: URL) throws -> Fixture {
    let modelSpecs: [(path: String, size: Int, seed: UInt8)] = [
        ("onnx/a.onnx", 4000, 1),
        ("tokenizer.json", 3000, 2),
        ("vocab.txt", 2000, 3),
    ]
    var artifacts: [ModelArtifact] = []
    var served: [String: Data] = [:]
    var finalFiles: [String: Data] = [:]
    for spec in modelSpecs {
        let bytes = deterministicBytes(count: spec.size, seed: spec.seed)
        let url = Fixture.servedURL(spec.path)
        artifacts.append(ModelArtifact(path: spec.path, url: url, sha256: sha256Hex(bytes), size: Int64(bytes.count)))
        served[url] = bytes
        finalFiles[spec.path] = bytes
    }

    // Runtime archive: real tar.gz built with the system tar, holding the three members the installer extracts.
    let runtimeDirName = "onnxruntime-osx-arm64-9.9.9"
    let dylibMember = runtimeDirName + "/lib/libonnxruntime.9.9.9.dylib"
    let licenseMember = runtimeDirName + "/LICENSE"
    let noticesMember = runtimeDirName + "/ThirdPartyNotices.txt"
    let dylib = deterministicBytes(count: 5000, seed: 90)
    let runtimeLicense = deterministicBytes(count: 300, seed: 91)
    let runtimeNotices = deterministicBytes(count: 200, seed: 92)
    let runtimeSource = directory.appendingPathComponent("runtime-src", isDirectory: true)
    for (member, bytes) in [(dylibMember, dylib), (licenseMember, runtimeLicense), (noticesMember, runtimeNotices)] {
        try writeFile(runtimeSource.appendingPathComponent(member), bytes)
    }
    let archive = directory.appendingPathComponent("runtime.tgz")
    try runTar(["-czf", archive.path, "-C", runtimeSource.path, runtimeDirName])
    let archiveBytes = try Data(contentsOf: archive)
    let runtimeURL = Fixture.servedURL("runtime.tgz")
    served[runtimeURL] = archiveBytes
    let runtime = RuntimeArchive(
        version: "9.9.9", url: runtimeURL, sha256: sha256Hex(archiveBytes), size: Int64(archiveBytes.count),
        dylibMember: dylibMember, dylibSHA256: sha256Hex(dylib),
        licenseMember: licenseMember, licenseSHA256: sha256Hex(runtimeLicense),
        noticesMember: noticesMember, noticesSHA256: sha256Hex(runtimeNotices))
    finalFiles["libonnxruntime.dylib"] = dylib
    finalFiles["ORT-LICENSE"] = runtimeLicense
    finalFiles["ORT-ThirdPartyNotices.txt"] = runtimeNotices

    // Bundled licenses that ship inside the app.
    let resources = directory.appendingPathComponent("resources", isDirectory: true)
    let bundledLicense = deterministicBytes(count: 120, seed: 70)
    let bundledNotice = deterministicBytes(count: 80, seed: 71)
    try writeFile(resources.appendingPathComponent("bundled-model-license.txt"), bundledLicense)
    try writeFile(resources.appendingPathComponent("bundled-model-notice.txt"), bundledNotice)
    finalFiles["model-LICENSE.txt"] = bundledLicense
    finalFiles["model-NOTICE.txt"] = bundledNotice
    let licenses = [
        BundledLicense(resourceName: "bundled-model-license.txt", sha256: sha256Hex(bundledLicense), installedName: "model-LICENSE.txt"),
        BundledLicense(resourceName: "bundled-model-notice.txt", sha256: sha256Hex(bundledNotice), installedName: "model-NOTICE.txt"),
    ]

    let manifest = ModelManifest(
        huggingFaceRepo: "example/checks", huggingFaceRevision: "test",
        modelFiles: artifacts, runtime: runtime, licenses: licenses,
        dylibName: "libonnxruntime.dylib", runtimeLicenseName: "ORT-LICENSE",
        runtimeNoticesName: "ORT-ThirdPartyNotices.txt")
    return Fixture(manifest: manifest, resources: resources, served: served, expectedFinalFiles: finalFiles)
}

// MARK: - Fake transport

/// Serves `served` bytes with the same Range semantics as the production transport.
actor FakeTransport: ModelTransport {
    enum Mode: Sendable {
        /// First attempt only: write N bytes, then fail with a network error.
        case failAfter(Int64)
        /// First attempt only: serve corrupted bytes.
        case corruptOnce
        /// Every attempt: serve corrupted bytes.
        case alwaysCorrupt
        /// Write N bytes, then wait until the task is cancelled.
        case suspendAfter(Int64)
        /// First attempt with a non-zero offset: delete the .part file and fail with a network error.
        case staleOnce
        /// The first N attempts fail with HTTP 503 and write nothing.
        case unavailableTimes(Int)
        /// Every attempt fails with a network error and writes nothing.
        case networkDown
    }

    private let served: [String: Data]
    private let modes: [String: Mode]
    private var attempts: [String: Int] = [:]
    private var log: [(url: String, offset: Int64)] = []
    private var suspendedURLs: Set<String> = []
    private var staleFired: Set<String> = []

    init(served: [String: Data], modes: [String: Mode] = [:]) {
        self.served = served
        self.modes = modes
    }

    func offsets(for url: String) -> [Int64] {
        log.filter { $0.url == url }.map(\.offset)
    }

    func totalRequests() -> Int {
        log.count
    }

    func hasSuspended(_ url: String) -> Bool {
        suspendedURLs.contains(url)
    }

    func download(from url: URL, appendingTo file: URL, offset: Int64,
                  progress: @escaping @Sendable (Int64) -> Void) async throws {
        let key = url.absoluteString
        log.append((url: key, offset: offset))
        let attempt = (attempts[key] ?? 0) + 1
        attempts[key] = attempt
        guard let body = served[key] else {
            throw ModelInstallError.httpStatus(404, host: url.host ?? "")
        }
        // 416: the file is already complete, so nothing is written.
        guard offset < Int64(body.count) else { return }
        let rest = Data(body.subdata(in: Int(offset)..<body.count))
        let mode = modes[key]
        let firstAttempt = attempt == 1

        if case .networkDown? = mode {
            throw ModelInstallError.network("simulated outage")
        }
        if case .unavailableTimes(let n)? = mode, attempt <= n {
            throw ModelInstallError.httpStatus(503, host: url.host ?? "")
        }
        if case .staleOnce? = mode, offset > 0, !staleFired.contains(key) {
            staleFired.insert(key)
            try? FileManager.default.removeItem(at: file)
            throw ModelInstallError.network("simulated stale partial")
        }

        if case .suspendAfter(let n)? = mode {
            try Self.append(Data(rest.prefix(Int(n))), to: file, base: offset, progress: progress)
            suspendedURLs.insert(key)
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                throw ModelInstallError.cancelled
            }
            throw ModelInstallError.network("suspended transfer was not cancelled")
        }

        var payload = rest
        if case .alwaysCorrupt? = mode {
            payload = Data(rest.map { $0 ^ 0xFF })
        } else if case .corruptOnce? = mode, firstAttempt {
            payload = Data(rest.map { $0 ^ 0xFF })
        }

        if case .failAfter(let n)? = mode, firstAttempt {
            try Self.append(Data(rest.prefix(Int(n))), to: file, base: offset, progress: progress)
            throw ModelInstallError.network("simulated")
        }
        try Self.append(payload, to: file, base: offset, progress: progress)
    }

    private static func append(_ data: Data, to file: URL, base: Int64,
                               progress: @escaping @Sendable (Int64) -> Void) throws {
        if !FileManager.default.fileExists(atPath: file.path) {
            _ = FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        var written = 0
        while written < data.count {
            let end = min(written + 1024, data.count)
            try handle.write(contentsOf: data.subdata(in: written..<end))
            written = end
            progress(base + Int64(written))
        }
    }
}

// MARK: - Helpers for cases

func makeInstaller(root: URL, fixture: Fixture, transport: any ModelTransport, resources: URL? = nil,
                   freeSpace: @escaping @Sendable (URL) throws -> Int64 = { _ in Int64.max / 2 }) -> ModelInstaller {
    ModelInstaller(modelsDirectory: modelsDirectory(root), bundledResources: resources ?? fixture.resources,
                   manifest: fixture.manifest, transport: transport, freeSpace: freeSpace)
}

/// Starts an install whose transfer for `url` suspends after 1000 bytes, and returns once it has suspended.
func startSuspendedInstall(_ root: URL, _ fixture: Fixture,
                           url: String) async throws -> (task: Task<Void, Error>, installer: ModelInstaller) {
    let transport = FakeTransport(served: fixture.served, modes: [url: .suspendAfter(1000)])
    let installer = makeInstaller(root: root, fixture: fixture, transport: transport)
    let task = Task { try await installer.install { _ in } }
    for _ in 0..<500 {
        if await transport.hasSuspended(url) { return (task, installer) }
        try await Task.sleep(for: .milliseconds(20))
    }
    task.cancel()
    throw CheckFailure("the transfer never reached the suspension point")
}

func expectError(_ label: String, _ matches: (ModelInstallError) -> Bool,
                 _ body: () async throws -> Void) async throws {
    do {
        try await body()
    } catch let error as ModelInstallError {
        guard matches(error) else { throw CheckFailure("\(label): wrong error \(error)") }
        return
    } catch {
        throw CheckFailure("\(label): unexpected error \(error)")
    }
    throw CheckFailure("\(label): nothing was thrown")
}

/// Checks that the models directory holds exactly the expected files with the right bytes, and no staging directory.
func expectFinalLayout(_ root: URL, _ fixture: Fixture) throws {
    let models = modelsDirectory(root)
    let actual = try regularFiles(under: models)
    let expected = Set(fixture.expectedFinalFiles.keys)
    try expect(actual == expected, "models directory holds \(actual.sorted()), expected \(expected.sorted())")
    for (name, bytes) in fixture.expectedFinalFiles {
        let data = try Data(contentsOf: models.appendingPathComponent(name))
        try expect(data == bytes, "\(name) has the wrong bytes")
    }
    try expect(!exists(stagingDirectory(root)), "staging directory is still present")
}

// MARK: - Cases

func caseHappyPath(_ root: URL, _ fixture: Fixture) async throws {
    let fractions = Locked<[Double]>([])
    let installer = makeInstaller(root: root, fixture: fixture, transport: FakeTransport(served: fixture.served))
    try await installer.install { progress in
        fractions.withValue { $0.append(progress.fraction) }
    }
    try expectFinalLayout(root, fixture)
    let last = fractions.withValue { $0.last }
    try expect(last == 1.0, "last progress fraction was \(String(describing: last)), expected 1.0")
}

func caseResumeWithinInstall(_ root: URL, _ fixture: Fixture) async throws {
    let url = Fixture.servedURL("onnx/a.onnx")
    let transport = FakeTransport(served: fixture.served, modes: [url: .failAfter(1500)])
    let installer = makeInstaller(root: root, fixture: fixture, transport: transport)
    try await installer.install { _ in }
    try expectFinalLayout(root, fixture)
    let offsets = await transport.offsets(for: url)
    try expect(offsets == [0, 1500], "requests for onnx/a.onnx had offsets \(offsets), expected [0, 1500]")
}

func caseResumeAcrossInstances(_ root: URL, _ fixture: Fixture) async throws {
    let url = Fixture.servedURL("onnx/a.onnx")
    let (task, _) = try await startSuspendedInstall(root, fixture, url: url)
    task.cancel()
    try await expectError("first install cancelled", { $0 == .cancelled }) {
        try await task.value
    }
    let part = stagingDirectory(root).appendingPathComponent("onnx/a.onnx.part")
    try expect(exists(part), "no .part file survived the cancel")
    let partBytes = try fileSize(part)
    try expect(partBytes == 1000, ".part holds \(partBytes) bytes, expected 1000")

    let transport = FakeTransport(served: fixture.served)
    let installer = makeInstaller(root: root, fixture: fixture, transport: transport)
    try await installer.install { _ in }
    try expectFinalLayout(root, fixture)
    let offsets = await transport.offsets(for: url)
    try expect((offsets.first ?? 0) > 0, "the resumed request started at offset \(offsets.first ?? -1), expected > 0")
}

func caseCorruptOnceThenOK(_ root: URL, _ fixture: Fixture) async throws {
    let url = Fixture.servedURL("tokenizer.json")
    let transport = FakeTransport(served: fixture.served, modes: [url: .corruptOnce])
    let installer = makeInstaller(root: root, fixture: fixture, transport: transport)
    try await installer.install { _ in }
    try expectFinalLayout(root, fixture)
    let offsets = await transport.offsets(for: url)
    try expect(offsets == [0, 0], "tokenizer.json requests had offsets \(offsets), expected [0, 0]")
}

func caseAlwaysCorrupt(_ root: URL, _ fixture: Fixture) async throws {
    let models = modelsDirectory(root)
    try writeFile(models.appendingPathComponent("marker.txt"), Data("kept".utf8))
    let transport = FakeTransport(served: fixture.served,
                                  modes: [Fixture.servedURL("tokenizer.json"): .alwaysCorrupt])
    let installer = makeInstaller(root: root, fixture: fixture, transport: transport)
    try await expectError("always corrupt", { error in
        if case .checksumMismatch(file: "tokenizer.json") = error { return true }
        return false
    }) {
        try await installer.install { _ in }
    }
    let marker = try String(contentsOf: models.appendingPathComponent("marker.txt"), encoding: .utf8)
    try expect(marker == "kept", "marker.txt in the models directory was changed")
}

func caseCancel(_ root: URL, _ fixture: Fixture) async throws {
    let models = modelsDirectory(root)
    try writeFile(models.appendingPathComponent("marker.txt"), Data("kept".utf8))
    let (task, _) = try await startSuspendedInstall(root, fixture, url: Fixture.servedURL("onnx/a.onnx"))
    task.cancel()
    try await expectError("cancel", { $0 == .cancelled }) {
        try await task.value
    }
    let files = try regularFiles(under: models)
    try expect(files == ["marker.txt"], "models directory changed on cancel: \(files.sorted())")
    try expect(exists(stagingDirectory(root)), "staging directory was removed on cancel")
}

func caseDiskSpace(_ root: URL, _ fixture: Fixture) async throws {
    let transport = FakeTransport(served: fixture.served)
    let installer = makeInstaller(root: root, fixture: fixture, transport: transport, freeSpace: { _ in 1 })
    try await expectError("disk space", { error in
        if case .insufficientDiskSpace = error { return true }
        return false
    }) {
        try await installer.install { _ in }
    }
    let requests = await transport.totalRequests()
    try expect(requests == 0, "\(requests) requests were made before the disk check")
}

func caseReuseValidFile(_ root: URL, _ fixture: Fixture) async throws {
    let url = Fixture.servedURL("tokenizer.json")
    try writeFile(modelsDirectory(root).appendingPathComponent("tokenizer.json"), fixture.bytes(for: "tokenizer.json"))
    let transport = FakeTransport(served: fixture.served)
    let installer = makeInstaller(root: root, fixture: fixture, transport: transport)
    try await installer.install { _ in }
    let offsets = await transport.offsets(for: url)
    try expect(offsets.isEmpty, "tokenizer.json was requested \(offsets.count) times despite a valid copy")
    try expectFinalLayout(root, fixture)
}

func caseReplaceExisting(_ root: URL, _ fixture: Fixture) async throws {
    let models = modelsDirectory(root)
    try writeFile(models.appendingPathComponent("old.txt"), Data("old".utf8))
    let installer = makeInstaller(root: root, fixture: fixture, transport: FakeTransport(served: fixture.served))
    try await installer.install { _ in }
    try expect(!exists(models.appendingPathComponent("old.txt")), "old.txt survived the replace")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("models.old-") }
    try expect(leftovers.isEmpty, "backup directories left behind: \(leftovers)")
    try expectFinalLayout(root, fixture)
}

func caseMissingBundledLicense(_ root: URL, _ fixture: Fixture) async throws {
    let resources = root.appendingPathComponent("resources", isDirectory: true)
    try writeFile(resources.appendingPathComponent("bundled-model-license.txt"), fixture.bytes(for: "model-LICENSE.txt"))
    let installer = makeInstaller(root: root, fixture: fixture, transport: FakeTransport(served: fixture.served),
                                  resources: resources)
    try await expectError("missing bundled license", { error in
        if case .missingBundledResource = error { return true }
        return false
    }) {
        try await installer.install { _ in }
    }
}

func caseRemove(_ root: URL, _ fixture: Fixture) async throws {
    try writeFile(modelsDirectory(root).appendingPathComponent("file.txt"), Data("a".utf8))
    try writeFile(stagingDirectory(root).appendingPathComponent("partial.part"), Data("b".utf8))
    let installer = makeInstaller(root: root, fixture: fixture, transport: FakeTransport(served: fixture.served))
    try await installer.remove()
    try expect(!exists(modelsDirectory(root)), "models directory survived remove()")
    try expect(!exists(stagingDirectory(root)), "staging directory survived remove()")
}

func caseInsecureURL(_ root: URL, _ fixture: Fixture) async throws {
    let target = root.appendingPathComponent("x.part")
    try await expectError("insecure URL", { error in
        if case .insecureRedirect = error { return true }
        return false
    }) {
        try await URLSessionTransport().download(from: URL(string: "http://example.test/x")!,
                                                 appendingTo: target, offset: 0, progress: { _ in })
    }
    try expect(!exists(target), "a file was written for an insecure URL")
}

func caseStalePartialRemoved(_ root: URL, _ fixture: Fixture) async throws {
    let url = Fixture.servedURL("onnx/a.onnx")
    let part = stagingDirectory(root).appendingPathComponent("onnx/a.onnx.part")
    try writeFile(part, Data(fixture.bytes(for: "onnx/a.onnx").prefix(1000)))
    let transport = FakeTransport(served: fixture.served, modes: [url: .staleOnce])
    let installer = makeInstaller(root: root, fixture: fixture, transport: transport)
    try await installer.install { _ in }
    try expectFinalLayout(root, fixture)
    let offsets = await transport.offsets(for: url)
    try expect(offsets == [1000, 0], "onnx/a.onnx requests had offsets \(offsets), expected [1000, 0]")
}

func caseServerErrorThenOK(_ root: URL, _ fixture: Fixture) async throws {
    let url = Fixture.servedURL("onnx/a.onnx")
    let transport = FakeTransport(served: fixture.served, modes: [url: .unavailableTimes(2)])
    let installer = makeInstaller(root: root, fixture: fixture, transport: transport)
    try await installer.install { _ in }
    try expectFinalLayout(root, fixture)
    let offsets = await transport.offsets(for: url)
    try expect(offsets == [0, 0, 0], "onnx/a.onnx requests had offsets \(offsets), expected [0, 0, 0]")
}

func caseNetworkExhausted(_ root: URL, _ fixture: Fixture) async throws {
    let modes: [String: FakeTransport.Mode] = Dictionary(uniqueKeysWithValues: fixture.served.keys.map { ($0, .networkDown) })
    let transport = FakeTransport(served: fixture.served, modes: modes)
    let installer = makeInstaller(root: root, fixture: fixture, transport: transport)
    try await expectError("network exhausted", { error in
        if case .network = error { return true }
        return false
    }) {
        try await installer.install { _ in }
    }
    // One attempt plus maxNetworkRetries (3) retries, all against the first file.
    let requests = await transport.totalRequests()
    try expect(requests == 4, "\(requests) requests were made, expected 4 (1 attempt + 3 retries)")
}

func caseRemoveDuringInstall(_ root: URL, _ fixture: Fixture) async throws {
    let (task, installer) = try await startSuspendedInstall(root, fixture, url: Fixture.servedURL("onnx/a.onnx"))
    do {
        try await installer.remove()
        task.cancel()
        _ = try? await task.value
        throw CheckFailure("remove() succeeded while an install was running")
    } catch let error as ModelInstallError {
        guard case .unavailable = error else { throw CheckFailure("remove() during install threw \(error), expected .unavailable") }
    }
    task.cancel()
    try await expectError("install cancelled after refused remove", { $0 == .cancelled }) {
        try await task.value
    }
    let part = stagingDirectory(root).appendingPathComponent("onnx/a.onnx.part")
    try expect(exists(part), "the .part file did not survive the refused remove()")
    try await installer.remove()
    try expect(!exists(stagingDirectory(root)), "staging directory survived remove() after the cancel")
}

// MARK: - Runner

func runCase(_ name: String, fixture: Fixture, _ body: (URL, Fixture) async throws -> Void) async -> Bool {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("modelinstall-check-\(UUID().uuidString)", isDirectory: true)
    var failure: String?
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await body(root, fixture)
    } catch {
        failure = "\(error)"
    }
    try? FileManager.default.removeItem(at: root)
    if let failure {
        print("FAIL \(name): \(failure)")
        return false
    }
    print("PASS \(name)")
    return true
}

func runAllCases(_ fixture: Fixture) async -> Bool {
    let cases: [(name: String, body: (URL, Fixture) async throws -> Void)] = [
        ("happy path", caseHappyPath),
        ("resume within one install", caseResumeWithinInstall),
        ("resume across instances", caseResumeAcrossInstances),
        ("corrupt once, then OK", caseCorruptOnceThenOK),
        ("always corrupt", caseAlwaysCorrupt),
        ("cancel", caseCancel),
        ("disk space", caseDiskSpace),
        ("reuse valid model file", caseReuseValidFile),
        ("replace existing models directory", caseReplaceExisting),
        ("missing bundled license", caseMissingBundledLicense),
        ("remove()", caseRemove),
        ("insecure URL rejected", caseInsecureURL),
        ("stale partial removed mid-resume", caseStalePartialRemoved),
        ("503 twice, then OK", caseServerErrorThenOK),
        ("network failure exhausts retries", caseNetworkExhausted),
        ("remove() refused during install", caseRemoveDuringInstall),
    ]
    for (name, body) in cases {
        guard await runCase(name, fixture: fixture, body) else { return false }
    }
    return true
}

let fixtureDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("modelinstall-checks-fixtures-\(UUID().uuidString)", isDirectory: true)
var allPassed = false
do {
    try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
    let fixture = try makeFixture(in: fixtureDirectory)
    allPassed = await runAllCases(fixture)
} catch {
    print("FAIL fixture setup: \(error)")
}
try? FileManager.default.removeItem(at: fixtureDirectory)
if allPassed {
    print("ModelInstall checks passed.")
} else {
    exit(1)
}
