import Core
import Foundation
import os

/// Drafts and saves for per-capture thoughts. Every call is keyed by the capture the editor opened for.
@MainActor
final class ThoughtComposer {
    typealias Write = (_ text: String, _ captureID: UUID, _ note: URL) async throws -> Void
    typealias Destination = () async throws -> URL

    enum SaveOutcome: Equatable { case saved, failed(String) }
    static let saveFailedMessage = "Couldn't save your thought. Your text is kept."
    static let captureMissingMessage = "Couldn't find that capture in its note. Your text is kept."

    private let write: Write
    private let logger = Logger(subsystem: AppInfo.bundleIdentifier, category: "thoughts")
    private(set) var drafts: [UUID: String] = [:]
    private var savedThoughts: [UUID: String] = [:]
    private var destinations: [UUID: Destination] = [:]

    init(write: @escaping Write) { self.write = write }

    /// Binds the capture to its note and returns the editor text: draft, else saved thought, else empty.
    func begin(_ captureID: UUID, savedThought: String?, destination: @escaping Destination) -> String {
        if let savedThought { savedThoughts[captureID] = savedThought }
        destinations[captureID] = destination
        return drafts[captureID] ?? savedThoughts[captureID] ?? ""
    }

    func close(_ captureID: UUID, text: String) {
        if text == savedThoughts[captureID] ?? "" { drafts[captureID] = nil } else { drafts[captureID] = text }
    }

    func save(_ captureID: UUID, text: String) async -> SaveOutcome {
        do {
            guard let destination = destinations[captureID] else { throw ThoughtWriteError.captureNotFound }
            try await write(text, captureID, try await destination())
            drafts[captureID] = nil
            savedThoughts[captureID] = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
            return .saved
        } catch {
            logger.error("Couldn't save thought (\(AppErrorLog.summary(error), privacy: .public)): \(String(describing: error), privacy: .private)")
            drafts[captureID] = text
            return .failed(error as? ThoughtWriteError == .captureNotFound ? Self.captureMissingMessage : Self.saveFailedMessage)
        }
    }
}
