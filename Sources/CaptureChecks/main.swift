import AppKit
@_spi(Testing) import CaptureKit
import Darwin
import Foundation

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self { case .failed(let message): message }
    }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure.failed(message) }
}

@MainActor
func checkHotkeys() throws {
    let defaults: [Hotkey] = [.captureSelection, .captureRegion, .search, .toggleSession, .writeNote, .addSubheading, .openLibrary]
    let expected = ["⌥⇧C", "⌥⇧S", "⌥⇧F", "⌥⇧A", "⌥⇧N", "⌥⇧H", "⌥⇧L"]
    let expectedDefinitions = [
        Hotkey(keyCode: 8, modifiers: [.option, .shift]), Hotkey(keyCode: 1, modifiers: [.option, .shift]),
        Hotkey(keyCode: 3, modifiers: [.option, .shift]), Hotkey(keyCode: 0, modifiers: [.option, .shift]),
        Hotkey(keyCode: 45, modifiers: [.option, .shift]), Hotkey(keyCode: 4, modifiers: [.option, .shift]),
        Hotkey(keyCode: 37, modifiers: [.option, .shift])
    ]
    for (index, hotkey) in defaults.enumerated() {
        try require(hotkey == expectedDefinitions[index] && hotkey.displayString == expected[index],
                    "Wrong production hotkey definition: \(hotkey.displayString)")
    }
    let testCenter = HotkeyCenter()
    defer { testCenter.unregisterAll() }
    var testHotkey: Hotkey?
    for keyCode in UInt32(0)...UInt32(127) {
        let candidate = Hotkey(keyCode: keyCode, modifiers: [.control, .option, .shift])
        switch testCenter.register(candidate, id: 1, handler: {}) {
        case .success:
            testHotkey = candidate
        case .failure(.conflict):
            continue
        case .failure(let error):
            throw CheckFailure.failed("Could not install a temporary hotkey test chord: \(error)")
        }
        if testHotkey != nil { break }
    }
    guard let testHotkey else { throw CheckFailure.failed("Hotkey checks inconclusive: every temporary test chord is occupied") }
    guard case .failure(.duplicateID) = testCenter.register(testHotkey, id: 1, handler: {}) else {
        throw CheckFailure.failed("Reusing a hotkey registration ID did not report duplicateID")
    }
    let otherCenter = HotkeyCenter()
    defer { otherCenter.unregisterAll() }
    guard case .failure(.conflict) = otherCenter.register(testHotkey, id: 2, handler: {}) else {
        throw CheckFailure.failed("A temporary shortcut conflict across centers was not detected")
    }
    testCenter.unregister(id: 1)
    if case .failure(let error) = otherCenter.register(testHotkey, id: 2, handler: {}) {
        throw CheckFailure.failed("Unregistered test shortcut was not released: \(error)")
    }
    print("Hotkeys: PASS (seven production definitions, temporary conflict and unregister).")
}

@MainActor
func checkPasteboard() throws {
    let pasteboard = NSPasteboard(name: .init("capture-checks-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let binaryType = NSPasteboard.PasteboardType("org.capture-checks.binary")
    let first = NSPasteboardItem()
    first.setString("First item", forType: .string)
    first.setData(Data([0, 255, 17, 42]), forType: binaryType)
    let second = NSPasteboardItem()
    second.setString("Second item", forType: .string)
    second.setData(Data("{\\rtf1 Second item}".utf8), forType: .rtf)
    pasteboard.clearContents()
    try require(pasteboard.writeObjects([first, second]), "Could not seed private pasteboard")
    let snapshot = try PasteboardSnapshot(pasteboard: pasteboard)
    // macOS may add compatibility representations alongside the explicitly written types.
    try require(snapshot.items.count == 2 && snapshot.items.allSatisfy { $0.count >= 2 }, "Snapshot missed items or types")
    try require(snapshot.items[0][binaryType.rawValue] == Data([0, 255, 17, 42])
                && snapshot.items[1][NSPasteboard.PasteboardType.rtf.rawValue] == Data("{\\rtf1 Second item}".utf8),
                "Snapshot missed explicit binary or rich-text data")
    pasteboard.clearContents()
    pasteboard.setString("Temporary copied text", forType: .string)
    let copyCount = pasteboard.changeCount
    try require(snapshot.restore(to: pasteboard, ifUnchangedSince: copyCount), "Could not restore private pasteboard")
    let restored = try PasteboardSnapshot(pasteboard: pasteboard)
    try require(restored.items == snapshot.items, "Pasteboard data did not round-trip")

    pasteboard.clearContents()
    pasteboard.setString("A newer user copy", forType: .string)
    try require(!snapshot.restore(to: pasteboard, ifUnchangedSince: copyCount), "Stale restoration overwrote a newer copy")
    try require(pasteboard.string(forType: .string) == "A newer user copy", "Newer copy changed")
    pasteboard.clearContents()
    let empty = try PasteboardSnapshot(pasteboard: pasteboard)
    pasteboard.setString("Temporary", forType: .string)
    try require(empty.restore(to: pasteboard, ifUnchangedSince: pasteboard.changeCount), "Empty pasteboard restore failed")
    try require((pasteboard.pasteboardItems ?? []).isEmpty, "Empty snapshot restored items")
    print("Pasteboard: PASS (multiple items/types, newer-copy guard, empty snapshot; private board only).")
}

func checkOCRAndClassifier() async throws {
    let fixtures = try Fixtures.make()
    // GitHub's macOS VMs have no working Vision text recognizer. CI opts in to skipping
    // only when recognition itself is unavailable; wrong OCR results still fail.
    if ProcessInfo.processInfo.environment["CAPTURE_CHECKS_ALLOW_OCR_SKIP"] == "1" {
        do {
            _ = try await OCR.recognize(image: fixtures[0].image)
        } catch {
            print("OCR: SKIP (Vision text recognition is unavailable here: \(error))")
            print("Classifier: SKIP (needs OCR results)")
            return
        }
    }
    var results: [(Fixture, OCRResult, CaptureClassification)] = []
    for fixture in fixtures {
        // Exercise both the PNG-data and CGImage public entry points.
        let result: OCRResult
        if fixture.name == "paragraph" {
            result = try await OCR.recognize(pngData: Fixtures.png(fixture.image))
        } else {
            result = try await OCR.recognize(image: fixture.image)
        }
        if fixture.name == "paragraph" {
            let text = result.text.lowercased()
            try require(text.contains("mountain") && text.contains("capture"), "Paragraph OCR missed expected words: \(result.text)")
            try require(result.text.contains("\n\n"), "Paragraph OCR lost the blank-line break")
            try require(text.range(of: "capture")!.lowerBound < text.range(of: "mountain")!.lowerBound, "Paragraph reading order is wrong")
        }
        if fixture.name == "code" {
            try require(result.text.contains("CaptureRecord") && result.text.contains("collectRecords"), "Code OCR missed expected words: \(result.text)")
        }
        let classification = CaptureClassifier.classify(result)
        let metrics = classification.metrics
        print(String(format: "Fixture %@: %@ coverage=%.5f confidence=%.5f lines=%d",
                     fixture.name, classification.decision.rawValue, metrics.textCoverage, metrics.meanConfidence, metrics.lineCount))
        results.append((fixture, result, classification))
    }
    print("OCR: PASS (paragraph/code words, reading order, paragraph break, PNG/CGImage inputs).")
    for (fixture, _, classification) in results {
        try require(classification.decision == (fixture.expectedText ? .text : .image),
                    "Classifier chose \(classification.decision) for \(fixture.name)")
    }
    let empty = CaptureClassifier.classify(lines: [], imageSize: .zero)
    try require(empty.decision == .image && empty.metrics.textCoverage == 0, "Empty/zero-size classifier result is invalid")
    print("Classifier: PASS (paragraph/code text; diagram/gradient/table image).")
}

func checkRegionCaptureProcessDisposition() throws {
    try require(RegionCapturer.processDisposition(status: 0, outputExists: false) == .cancelled,
                "An interactive Escape result without a file should remain silent cancellation")
    try require(RegionCapturer.processDisposition(status: 1, outputExists: false) == .failed(status: 1),
                "A failed screenshot process without output must be reported")
    try require(RegionCapturer.processDisposition(status: 0, outputExists: true) == .captured,
                "A successful screenshot process with output should continue to image loading")
    print("Region capture: PASS (cancel, process failure, and captured result classification).")
}

// A running app can own the defaults; still exercise pasteboard, OCR and classification.
var hotkeyFailure: Error?
do { try checkHotkeys() } catch { hotkeyFailure = error }
do {
    try checkPasteboard()
    try await checkOCRAndClassifier()
    try checkRegionCaptureProcessDisposition()
    if let hotkeyFailure { throw hotkeyFailure }
} catch {
    FileHandle.standardError.write(Data("Capture checks failed: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
