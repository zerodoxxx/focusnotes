import Foundation
import Darwin
import EmbedKit

struct TokenFixture: Decodable {
    struct Entry: Decodable { let text: String; let ids: [Int64] }
    let cases: [Entry]
}
struct EmbeddingFixture: Decodable {
    struct Text: Decodable { let text: String; let kind: String; let title: String?; let vector: [Float] }
    struct Image: Decodable { let file: String; let vector: [Float] }
    let texts: [Text]
    let image: Image
}
struct Checks {
    var failures: [String] = []
    mutating func require(_ condition: Bool, _ name: String) {
        print("\(condition ? "PASS" : "FAIL") \(name)")
        fflush(nil)
        if !condition { failures.append(name) }
    }
}
func cosine(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count else { return -.infinity }
    let dot = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
    return dot / sqrt(a.reduce(Float(0)) { $0 + $1 * $1 } * b.reduce(Float(0)) { $0 + $1 * $1 })
}
func unit(_ vector: [Float], dimensions: Int = 256) -> Bool {
    vector.count == dimensions && vector.allSatisfy(\.isFinite) &&
    abs(vector.reduce(Float(0)) { $0 + $1 * $1 } - 1) < 0.0001
}
func makeVectorModelFiles(in directory: URL, sizeOffset: Int) throws -> [URL] {
    let names = [
        "onnx/model_quantized.onnx", "onnx/model_quantized.onnx_data",
        "onnx/vision_encoder_q4.onnx", "onnx/vision_encoder_q4.onnx_data"
    ]
    return try names.enumerated().map { index, name in
        let file = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: UInt8(index + 1), count: 8 + sizeOffset + index).write(to: file)
        return file
    }
}
func rssMiB(_ pid: Int32) throws -> Double {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "rss=", "-p", String(pid)]
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    guard let text = String(data: data, encoding: .utf8), let kb = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw EmbeddingError.invalid("Could not read helper RSS")
    }
    return kb / 1024
}
func installedModelsDirectory() throws -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let config = try String(contentsOf: root.appendingPathComponent("Config/app.env"), encoding: .utf8)
    var values: [String: String] = [:]
    for line in config.split(separator: "\n") {
        let pair = line.split(separator: "=", maxSplits: 1)
        if pair.count == 2 { values[String(pair[0])] = String(pair[1]) }
    }
    guard let name = values["APPNAME"], let prefix = values["BUNDLE_PREFIX"] else {
        throw EmbeddingError.invalid("Config/app.env needs APPNAME and BUNDLE_PREFIX")
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("\(prefix).\(name)/models", isDirectory: true)
}
/// Fails when the pinned values in scripts/fetch-models.sh drift from ModelManifest.current.
/// Runs on every EmbedChecks run, before any model-dependent stage.
func checkManifestSync() throws {
    let scriptPath = FileManager.default.currentDirectoryPath + "/scripts/fetch-models.sh"
    guard FileManager.default.fileExists(atPath: scriptPath) else {
        throw EmbeddingError.invalid("scripts/fetch-models.sh not found; run EmbedChecks from the repository root")
    }
    let text = try String(contentsOfFile: scriptPath, encoding: .utf8)
    let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    var values: [String: String] = [:]
    for line in lines {
        guard let equals = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<equals])
        guard !key.isEmpty, key.allSatisfy({ $0.isUppercase || $0 == "_" || $0.isNumber }) else { continue }
        values[key] = String(line[line.index(after: equals)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
    let manifest = ModelManifest.current
    var mismatches: [String] = []
    func expect(_ field: String, _ manifestValue: String, _ scriptValue: String?) {
        if manifestValue != scriptValue {
            mismatches.append("\(field): manifest=\(manifestValue) script=\(scriptValue ?? "<missing>")")
        }
    }

    let revision = values["HF_REV"]
    expect("huggingFaceRevision (HF_REV)", manifest.huggingFaceRevision, revision)
    let base = values["HF_BASE"].map { $0.replacingOccurrences(of: "$HF_REV", with: revision ?? "") }
    expect("HF_BASE", "https://huggingface.co/\(manifest.huggingFaceRepo)/resolve/\(manifest.huggingFaceRevision)", base)
    let ortVersion = values["ORT_VERSION"]
    expect("runtime.version (ORT_VERSION)", manifest.runtime.version, ortVersion)
    let runtimeURL = ortVersion.map { "https://github.com/microsoft/onnxruntime/releases/download/v\($0)/onnxruntime-osx-arm64-\($0).tgz" }
    expect("runtime.url", manifest.runtime.url, runtimeURL)
    if !lines.contains(where: { $0.contains("releases/download/v$ORT_VERSION/onnxruntime-osx-arm64-$ORT_VERSION.tgz") }) {
        mismatches.append("runtime.url template not found in fetch-models.sh")
    }
    // The archive hash sits on the continuation line of the fetch call: `"$WORK/runtime.tgz" <sha256>`.
    let archiveLines = lines.filter { $0.hasPrefix("\"$WORK/runtime.tgz\" ") }
    if archiveLines.count != 1 {
        mismatches.append("expected exactly one \"$WORK/runtime.tgz\" <sha256> line in fetch-models.sh, found \(archiveLines.count)")
    } else if let hash = archiveLines[0].split(separator: " ").last.map(String.init),
              hash.count == 64, hash.allSatisfy(\.isHexDigit) {
        expect("runtime.sha256 (runtime.tgz)", manifest.runtime.sha256, hash)
    } else {
        mismatches.append("runtime.tgz hash in fetch-models.sh is not 64 hex characters: \(archiveLines[0])")
    }
    expect("runtime.dylibSHA256 (DYLIB_HASH)", manifest.runtime.dylibSHA256, values["DYLIB_HASH"])
    expect("runtime.licenseSHA256 (LICENSE_HASH)", manifest.runtime.licenseSHA256, values["LICENSE_HASH"])
    expect("runtime.noticesSHA256 (NOTICES_HASH)", manifest.runtime.noticesSHA256, values["NOTICES_HASH"])
    expect("license Apache-2.0.txt (EMBEDDINGGEMMA_LICENSE_HASH)",
           manifest.licenses.first { $0.resourceName == "Apache-2.0.txt" }?.sha256 ?? "<none>",
           values["EMBEDDINGGEMMA_LICENSE_HASH"])
    expect("license EmbeddingGemma2-NOTICE.txt (EMBEDDINGGEMMA_NOTICE_HASH)",
           manifest.licenses.first { $0.resourceName == "EmbeddingGemma2-NOTICE.txt" }?.sha256 ?? "<none>",
           values["EMBEDDINGGEMMA_NOTICE_HASH"])

    var scriptModels: [(hash: String, path: String)] = []
    if let start = lines.firstIndex(where: { $0.hasSuffix("<<'ARTIFACTS'") }),
       let end = lines.firstIndex(where: { $0 == "ARTIFACTS" }), start < end {
        for line in lines[(start + 1)..<end] {
            let parts = line.split(separator: " ")
            if parts.count == 2 { scriptModels.append((hash: String(parts[0]), path: String(parts[1]))) }
        }
    }
    if scriptModels.count != manifest.modelFiles.count {
        mismatches.append("model file count: manifest=\(manifest.modelFiles.count) script=\(scriptModels.count)")
    }
    for artifact in manifest.modelFiles {
        let entry = scriptModels.first { $0.path == artifact.path }
        expect("model sha256 \(artifact.path)", artifact.sha256, entry?.hash)
        expect("model url \(artifact.path)", artifact.url, base.map { "\($0)/\(artifact.path)" })
    }
    for entry in scriptModels where !manifest.modelFiles.contains(where: { $0.path == entry.path }) {
        mismatches.append("model \(entry.path) is in fetch-models.sh but not in ModelManifest")
    }
    if manifest.totalDownloadBytes != 492_067_251 {
        mismatches.append("totalDownloadBytes: manifest=\(manifest.totalDownloadBytes) expected=492067251")
    }

    guard mismatches.isEmpty else {
        for mismatch in mismatches { print("FAIL manifest sync: \(mismatch)") }
        throw EmbeddingError.invalid("ModelManifest.swift and scripts/fetch-models.sh disagree on \(mismatches.count) field(s)")
    }
    print("PASS manifest sync")
}

func runChecks() async throws {
    try checkManifestSync()
    var selectedModels: URL?
    var helper: URL?
    var arguments = CommandLine.arguments.dropFirst().makeIterator()
    while let flag = arguments.next() {
        guard let path = arguments.next() else { throw EmbeddingError.invalid("Missing value for \(flag)") }
        switch flag {
        case "--models": selectedModels = URL(fileURLWithPath: path, isDirectory: true)
        case "--helper": helper = URL(fileURLWithPath: path)
        default: throw EmbeddingError.invalid("Unknown flag: \(flag)")
        }
    }
    let models = try selectedModels ?? installedModelsDirectory()
    let own = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
    let helperURL = helper ?? own.deletingLastPathComponent().appendingPathComponent("EmbedHelper")
    guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
        throw EmbeddingError.invalid("Build EmbedHelper first, or pass --helper <executable>: \(helperURL.path)")
    }
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("EmbedChecks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    var checks = Checks()
    try await runRegressionChecks(&checks, root: temp)
    try await checkUnavailableModels(&checks, helper: helperURL, root: temp)
    let required = ModelManifest.current.requiredFiles
    let missing = required.filter { !FileManager.default.fileExists(atPath: models.appendingPathComponent($0).path) }
    guard missing.isEmpty else {
        print("SKIP EmbedChecks: models not present at \(models.path). Missing: \(missing.joined(separator: ", ")). Run scripts/fetch-models.sh <directory>.")
        guard checks.failures.isEmpty else { throw EmbeddingError.invalid("Regression failures: \(checks.failures)") }
        return
    }
    try await checkBusyParentDeath(&checks, helper: helperURL, models: models, root: temp)
    let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    do {
        let fixture = try JSONDecoder().decode(TokenFixture.self, from: Data(contentsOf: fixtures.appendingPathComponent("tokenizer.json")))
        let tokenizer = try Tokenizer(tokenizerJSON: models.appendingPathComponent("tokenizer.json"))
        for (i, item) in fixture.cases.enumerated() {
            let ids = try tokenizer.encode(item.text)
            checks.require(ids == item.ids, "tokenizer case \(i + 1): \(ids.count) IDs match reference")
            if ids != item.ids { print("  expected \(item.ids.prefix(30)); actual \(ids.prefix(30))") }
        }
    }
    let embedder = try Embedder(modelsDirectory: models)
    let parity = try JSONDecoder().decode(EmbeddingFixture.self, from: Data(contentsOf: fixtures.appendingPathComponent("embeddings.json")))
    for (i, item) in parity.texts.enumerated() {
        let vectors = try embedder.embed(texts: [item.text], kind: item.kind == "query" ? .query : .document(title: item.title))
        let score = cosine(vectors[0], item.vector)
        checks.require(score >= 0.99, String(format: "embedding text %d cosine %.6f >= 0.99", i + 1, score))
        checks.require(unit(vectors[0]), "text \(i + 1) finite unit vector, 256 dims")
    }
    checks.require(!embedder.visionLoaded, "text-only inference leaves vision unloaded")
    let diagramData = try Data(contentsOf: fixtures.appendingPathComponent(parity.image.file))
    let diagram = try embedder.embed(imagePNG: diagramData)
    let imageCosine = cosine(diagram, parity.image.vector)
    checks.require(imageCosine >= 0.99, String(format: "embedding image cosine %.6f >= 0.99", imageCosine))
    checks.require(unit(diagram) && embedder.visionLoaded, "image unit vector and lazy vision loading")
    let chart = try embedder.embed(imagePNG: Data(contentsOf: fixtures.appendingPathComponent("bar-chart.png")))
    let storeURL = temp.appendingPathComponent("vectors.sqlite")
    let store = try VectorStore(url: storeURL)
    let corpus = [
        ("rate-limiting", "Rate limiting", "Rate limiting protects APIs from overload by enforcing request quotas, such as fixed windows or sliding windows."),
        ("token-bucket", "Token bucket", "Token buckets limit requests. Tokens refill at a fixed rate into a bucket with a maximum capacity. Each request consumes a token; reject or delay requests when no tokens remain. This permits short bursts while enforcing the average rate."),
        ("react-hooks", "React hooks", "React hooks useState and useEffect manage component state and side effects. Custom hooks reuse logic between functional components."),
        ("rust-lifetimes", "Rust lifetimes", "Async Rust borrow problems arise when references cross await boundaries or async tasks outlive borrowed values. Lifetimes express how long references remain valid; ownership and the borrow checker prevent dangling references."),
        ("sourdough", "Sourdough", "Bread fermentation with sourdough uses wild yeast and lactic acid bacteria. Feed the starter, ferment the dough, proof the loaf and bake. Temperature and time control fermentation."),
        ("kubernetes", "Kubernetes", "Kubernetes schedules container pods on a cluster. Deployments manage replicas, services route traffic, and readiness probes control rolling updates."),
        ("postgres", "Postgres indexes", "PostgreSQL B-tree indexes accelerate selective SQL queries. EXPLAIN ANALYZE reveals query plans. Composite index column order matters."),
        ("cafe", "Café recipes", "Café drinks include espresso, cappuccino, café latte and iced coffee. Steam milk to make microfoam and balance the espresso extraction."),
    ]
    for (key, title, text) in corpus {
        try store.upsert(key: key, vector: embedder.embed(texts: [text], kind: .document(title: title))[0])
    }
    try store.upsert(key: "token-bucket-diagram", vector: diagram)
    try store.upsert(key: "bar-chart", vector: chart)
    checks.require(try store.keys().count == 10, "SQLite has 8 notes + 2 images")
    let queries = [("how do token buckets limit requests", "token-bucket"), ("async rust borrow problems", "rust-lifetimes"), ("bread fermentation", "sourdough")]
    for (query, expected) in queries {
        let vector = try embedder.embed(texts: [query], kind: .query)[0]
        let hits = try store.nearest(to: vector, limit: 10)
        print("RANK \(query): \(hits.prefix(4).map { "\($0.key)=\(String(format: "%.4f", $0.score))" }.joined(separator: ", "))")
        if expected == "token-bucket" {
            let rank = hits.firstIndex { $0.key == "token-bucket-diagram" }.map { $0 + 1 } ?? 99
            checks.require(hits.first?.key == expected || hits.first?.key == "token-bucket-diagram", "token bucket top-1 relevant")
            checks.require(rank <= 3, "token bucket diagram rank \(rank) <= 3")
        } else { checks.require(hits.first?.key == expected, "\(expected) top-1") }
    }
    let reopened = try VectorStore(url: storeURL)
    checks.require(try reopened.nearest(to: diagram, limit: 1).first?.key == "token-bucket-diagram", "SQLite persistence + Float16 self-match")
    var basis = [Float](repeating: 0, count: 256); basis[0] = 1
    let identityURL = temp.appendingPathComponent("model-identity.sqlite")
    let modelFilesA = try makeVectorModelFiles(in: temp.appendingPathComponent("model-a"), sizeOffset: 0)
    let modelFilesB = try makeVectorModelFiles(in: temp.appendingPathComponent("model-b"), sizeOffset: 5)
    let identityA = try VectorStore(url: identityURL, modelFiles: modelFilesA)
    try identityA.upsert(key: "identity-vector", vector: basis)
    let identityB = try VectorStore(url: identityURL, modelFiles: modelFilesB)
    checks.require(try identityB.keys().isEmpty, "changed ONNX file sizes clear vectors")
    try identityB.upsert(key: "identity-vector", vector: basis)
    let stableIdentityB = try VectorStore(url: identityURL, modelFiles: modelFilesB)
    checks.require(try stableIdentityB.keys() == ["identity-vector"], "unchanged model identity keeps vectors")
    try store.upsert(key: "mutation", vector: basis)
    checks.require(try reopened.keys().contains("mutation"), "cache sees another connection's upsert")
    basis[0] = 0; basis[1] = 1
    try store.upsert(key: "mutation", vector: basis)
    checks.require(try store.nearest(to: basis, limit: 1).first?.key == "mutation", "upsert invalidates contiguous cache")
    try store.remove(keys: ["mutation", "absent"])
    checks.require(try !reopened.keys().contains("mutation"), "remove persists and invalidates other connection's cache")
    checks.require(try VectorStore(url: storeURL, modelID: "different-model").keys().isEmpty, "model isolation")
    checks.require(try VectorStore(url: storeURL, dimensions: 128).keys().isEmpty, "dimension isolation")
    do { _ = try store.nearest(to: [1], limit: 1); checks.require(false, "reject mismatched query dimensions") }
    catch { checks.require(true, "reject mismatched query dimensions") }
    checks.require(try store.nearest(to: diagram, limit: 0).isEmpty, "zero result limit")
    let client = try EmbedClient(helperExecutable: helperURL, modelsDirectory: models, idleSeconds: 3)
    let coldStart = Date()
    let first = try await client.embedQuery("how do token buckets limit requests")
    let cold = Date().timeIntervalSince(coldStart)
    let textInfo = try await client.ping()
    checks.require(unit(first) && !textInfo.visionLoaded, "client starts helper, query Float16 round-trip, text-only")
    checks.require(cosine(first, try embedder.embed(texts: ["how do token buckets limit requests"], kind: .query)[0]) > 0.9999, "client/direct cosine > 0.9999")
    let rssText = try rssMiB(textInfo.processID)
    var warm: [Double] = []
    for _ in 0..<5 {
        let start = Date(); _ = try await client.embedQuery("async rust borrow problems")
        warm.append(Date().timeIntervalSince(start))
    }
    let imageStart = Date()
    let viaClient = try await client.embedImage(diagramData)
    let imageLatency = Date().timeIntervalSince(imageStart)
    checks.require(cosine(viaClient, diagram) > 0.9999, "client image cosine > 0.9999")
    let visionInfo = try await client.ping(), rssVision = try rssMiB(visionInfo.processID)
    checks.require(visionInfo.visionLoaded, "helper now has vision loaded")
    let clientDocuments = try await client.embedDocuments(["Café recipes", "Sourdough bread"], title: "Kitchen")
    checks.require(clientDocuments.count == 2 && clientDocuments.allSatisfy { unit($0) }, "client embedDocuments with title")
    async let a = client.embedQuery("React hooks")
    async let b = client.embedQuery("Rust lifetimes")
    let concurrent = try await [a, b]
    checks.require(concurrent.allSatisfy { unit($0) } && cosine(concurrent[0], concurrent[1]) < 0.99, "concurrent callers receive their own vectors")
    do { _ = try await client.embedImage(Data("invalid PNG".utf8)); checks.require(false, "helper error response") }
    catch { checks.require(true, "helper error response") }
    let afterError = try await client.ping()
    checks.require(afterError.processID == visionInfo.processID, "helper remains alive after invalid request")
    let idleStart = Date()
    while await client.processID() != nil && Date().timeIntervalSince(idleStart) < 10 {
        try await Task.sleep(for: .milliseconds(100))
    }
    let idleExit = Date().timeIntervalSince(idleStart)
    checks.require(await client.processID() == nil, String(format: "helper exits after idle timeout (observed %.2f s; override 3 s)", idleExit))
    _ = try await client.embedQuery("restart after idle exit")
    let restarted = try await client.ping()
    checks.require(restarted.processID != visionInfo.processID && !restarted.visionLoaded, "client restarts after idle exit")
    _ = kill(restarted.processID, SIGKILL)
    try await Task.sleep(for: .milliseconds(100))
    _ = try await client.embedQuery("restart after unexpected death")
    let recovered = try await client.ping()
    checks.require(recovered.processID != restarted.processID, "client restarts after unexpected death")
    await client.shutdown()
    print(String(format: "PERF cold-start %.3f s; warm-query median %.3f s (n=5); image-first-use %.3f s; helper RSS text %.1f MiB / text+vision %.1f MiB", cold, warm.sorted()[2], imageLatency, rssText, rssVision))
    guard checks.failures.isEmpty else { throw EmbeddingError.invalid("\(checks.failures.count) checks failed: \(checks.failures.joined(separator: "; "))") }
    print("PASS all semantic engine checks")
}

do {
    if CommandLine.arguments.dropFirst().first == "--fixture-helper" { try runFixtureHelper() }
    else if CommandLine.arguments.dropFirst().first == "--orphan-parent" { try runOrphanParent() }
    else { try await runChecks() }
}
catch {
    try? FileHandle.standardError.write(contentsOf: Data("FAIL EmbedChecks: \(error)\n".utf8))
    exit(1)
}
