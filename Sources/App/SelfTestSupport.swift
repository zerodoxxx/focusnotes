import AppKit
import Foundation

/// Passes only when `operation` throws an `E` that `matching` accepts. Success, or any other error, fails the check.
func expectRejection<E: Error>(_ type: E.Type, _ description: String, isolation: isolated (any Actor)? = #isolation,
                               matching: (E) -> Bool = { _ in true }, _ operation: () async throws -> Void) async throws {
    do {
        try await operation()
    } catch let error as E where matching(error) {
        return
    } catch {
        throw SelfTestFailure("\(description): unexpected error \(error)")
    }
    throw SelfTestFailure(description)
}

/// Polls `condition` until it holds. The deadline is checked after one more poll, so a condition that becomes true
/// right at the timeout still passes.
func waitUntil(_ description: String, timeout: Duration = .seconds(3), poll: Duration = .milliseconds(10),
               isolation: isolated (any Actor)? = #isolation, _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while true {
        if try await condition() { return }
        if ContinuousClock.now >= deadline { break }
        try await Task.sleep(for: poll)
    }
    throw SelfTestFailure("Timed out waiting for \(description)")
}

func keyDownEvent(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                       windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                       isARepeat: false, keyCode: keyCode) else {
        throw SelfTestFailure("Could not create key event \(keyCode)")
    }
    return event
}
