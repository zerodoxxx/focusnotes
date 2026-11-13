import Core
import Foundation

@MainActor
func checkThoughtComposer() async throws {
    let a = UUID(), b = UUID()
    let noteA = URL(fileURLWithPath: "/vault/A.md"), noteB = URL(fileURLWithPath: "/vault/B.md")
    var writes: [(String, UUID, URL)] = []
    var failure: Error?
    let composer = ThoughtComposer { text, id, note in
        if let failure { throw failure }
        writes.append((text, id, note))
    }

    // Escape keeps a draft; reopening prefers it over the saved thought.
    guard composer.begin(a, savedThought: "saved", destination: { noteA }) == "saved" else {
        throw SelfTestFailure("Thought editor did not start from the saved thought")
    }
    composer.close(a, text: "draft")
    guard composer.begin(a, savedThought: "saved elsewhere", destination: { noteA }) == "draft" else {
        throw SelfTestFailure("Thought draft was not restored on reopen")
    }
    composer.close(a, text: "saved elsewhere")
    guard composer.drafts[a] == nil else { throw SelfTestFailure("Unchanged thought left a draft") }

    // A save stays bound to its own capture after another capture opens.
    _ = composer.begin(a, savedThought: nil, destination: { noteA })
    _ = composer.begin(b, savedThought: nil, destination: { noteB })
    composer.close(a, text: "for A")
    failure = CocoaError(.fileWriteNoPermission)
    guard await composer.save(a, text: "for A") == .failed(ThoughtComposer.saveFailedMessage),
          composer.drafts[a] == "for A", writes.isEmpty else {
        throw SelfTestFailure("Failed thought save did not keep the draft")
    }
    failure = ThoughtWriteError.captureNotFound
    guard await composer.save(a, text: "for A") == .failed(ThoughtComposer.captureMissingMessage) else {
        throw SelfTestFailure("Missing capture reported the wrong message")
    }
    failure = nil
    guard await composer.save(a, text: "for A") == .saved, composer.drafts[a] == nil,
          writes.count == 1, writes[0].0 == "for A", writes[0].1 == a, writes[0].2 == noteA else {
        throw SelfTestFailure("Thought save did not write to its own capture and clear the draft")
    }
}
