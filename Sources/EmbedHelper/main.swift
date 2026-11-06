import Foundation
import Darwin
import Dispatch
import EmbedKit

// Capture before parsing arguments or loading anything. Unlike stdin EOF this
// event is delivered even while the request thread is blocked in model/ORT work.
let parentPID = getppid()

// poll() makes idle exit independent of Foundation run loops and blocks only
// this short-lived helper. Timeout counts idle time after a complete response.
func runHelper() throws {
    guard parentPID > 1 else { _exit(0) }
    let parentExit = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit,
                                                     queue: DispatchQueue.global(qos: .userInitiated))
    parentExit.setEventHandler { _exit(0) }
    parentExit.resume()
    defer { parentExit.cancel() }
    // Close the race between capturing the parent and installing the source.
    if getppid() != parentPID { _exit(0) }
    var directory: URL?, idle: Double = 60
    var arguments = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = arguments.next() {
        switch argument {
        case "--models":
            guard let path = arguments.next() else { throw EmbeddingError.invalid("--models requires a directory") }
            directory = URL(fileURLWithPath: path, isDirectory: true)
        case "--idle-seconds":
            guard let text = arguments.next(), let seconds = Double(text), seconds.isFinite,
                  seconds > 0, seconds <= 86_400 else { throw EmbeddingError.invalid("Invalid idle timeout") }
            idle = seconds
        default: throw EmbeddingError.invalid("Unknown argument: \(argument)")
        }
    }
    guard let directory else { throw EmbeddingError.invalid("Usage: EmbedHelper --models <dir> [--idle-seconds 60]") }
    _ = signal(SIGPIPE, SIG_IGN)
    var embedders: [Int: Embedder] = [:]
    var pending = Data()
    var deadline = DispatchTime.now().uptimeNanoseconds + UInt64(idle * 1_000_000_000)
    while true {
        if let newline = pending.firstIndex(of: 10) {
            let line = Data(pending[..<newline]); pending.removeSubrange(...newline)
            let response: EmbedResponse
            var request: EmbedRequest?
            do {
                let decoded = try JSONDecoder().decode(EmbedRequest.self, from: line)
                request = decoded
                guard EmbedProtocol.supportedDimensions.contains(decoded.dimensions) else { throw EmbeddingError.invalid("Unsupported dimensions") }
                let embedder: Embedder
                if let existing = embedders[decoded.dimensions] { embedder = existing }
                else {
                    embedder = try Embedder(modelsDirectory: directory, dimensions: decoded.dimensions)
                    embedders[decoded.dimensions] = embedder
                }
                let vectors: [[Float]]?
                switch decoded.operation {
                case "ping": vectors = nil
                case "embedQuery":
                    guard let text = decoded.text else { throw EmbeddingError.invalid("embedQuery needs text") }
                    vectors = try embedder.embed(texts: [text], kind: .query)
                case "embedDocuments":
                    guard let texts = decoded.texts, texts.count <= 1024 else { throw EmbeddingError.invalid("embedDocuments needs at most 1024 texts") }
                    vectors = try embedder.embed(texts: texts, kind: .document(title: decoded.title))
                case "embedImage":
                    guard let base64 = decoded.imagePNG, let image = Data(base64Encoded: base64) else { throw EmbeddingError.invalid("embedImage needs base64 imagePNG") }
                    vectors = [try embedder.embed(imagePNG: image)]
                default: throw EmbeddingError.invalid("Unknown operation: \(decoded.operation)")
                }
                response = try EmbedResponse(id: decoded.id, dimensions: decoded.dimensions, vectors: vectors,
                                             processID: getpid(), visionLoaded: embedder.visionLoaded)
            } catch {
                response = try EmbedResponse(id: request?.id ?? "", dimensions: request?.dimensions ?? EmbedProtocol.defaultDimensions,
                                             error: String(describing: error), processID: getpid(),
                                             visionLoaded: embedders.values.contains { $0.visionLoaded })
            }
            var wire = try JSONEncoder().encode(response); wire.append(10)
            try FileHandle.standardOutput.write(contentsOf: wire)
            deadline = DispatchTime.now().uptimeNanoseconds + UInt64(idle * 1_000_000_000)
            continue
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if now >= deadline { return }
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(max(1, min(1000, (deadline - now) / 1_000_000)))
        let result = poll(&descriptor, 1, milliseconds)
        if result < 0 && errno == EINTR { continue }
        guard result >= 0 else { throw EmbeddingError.transport("stdin poll failed") }
        if result == 0 { continue }
        // POLLHUP can accompany final bytes, which must be consumed first.
        if descriptor.revents & Int16(POLLIN) == 0 { return }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
        if count < 0 && errno == EINTR { continue }
        if count <= 0 { return }
        pending.append(contentsOf: bytes.prefix(count))
        guard pending.count <= 64 * 1024 * 1024 else { throw EmbeddingError.invalid("Request exceeds 64 MiB") }
    }
}

do { try runHelper() }
catch {
    try? FileHandle.standardError.write(contentsOf: Data("EmbedHelper: \(error)\n".utf8))
    exit(1)
}
