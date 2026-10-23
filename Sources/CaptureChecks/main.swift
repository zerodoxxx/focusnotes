import AppKit
@_spi(Testing) import CaptureKit
import Darwin
import Foundation
import Vision

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self { case .failed(let message): message }
    }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure.failed(message) }
}

private struct CorpusManifestEntry: Decodable {
    let file: String
    let category: String
    let language: String
    let scale: Double
    let dark: Bool
    let groundTruth: String
}

private struct OCRBaselineImage: Codable {
    let file: String
    let category: String
    let language: String
    let scale: Double
    let dark: Bool
    let groundTruth: String
    let text: String
    let latencyMs: Double
    let classifierDecision: String
}

private struct OCRBaseline: Codable {
    let schemaVersion: Int
    let operatingSystem: String
    let architecture: String
    let recognitionLevel: String
    let recognitionRevision: Int
    let warmupRuns: Int
    let usesLanguageCorrection: Bool
    let supportedRecognitionLanguages: [String]
    let images: [OCRBaselineImage]
}

private func runOCRCorpus(corpusDirectory: URL, outputFile: URL) async throws {
    let manifestURL = corpusDirectory.appendingPathComponent("manifest.json")
    let manifest = try JSONDecoder().decode([CorpusManifestEntry].self, from: Data(contentsOf: manifestURL))
    try require(!manifest.isEmpty, "OCR corpus manifest is empty")

    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("capture-checks-ocr-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    var combined: OCRBaseline?
    var images: [OCRBaselineImage] = []
    let executablePath = CommandLine.arguments[0]
    let executableURL = URL(fileURLWithPath: executablePath.hasPrefix("/")
        ? executablePath
        : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(executablePath).path)
    let languages = Set(manifest.map(\.language)).sorted()
    for (index, language) in languages.enumerated() {
        let childOutput = temporaryDirectory.appendingPathComponent("language-\(index).json")
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--ocr-corpus-language", corpusDirectory.path, language, childOutput.path]
        try process.run()
        process.waitUntilExit()
        try require(process.terminationStatus == 0, "Vision corpus worker failed for \(language) (exit \(process.terminationStatus))")
        let result = try JSONDecoder().decode(OCRBaseline.self, from: Data(contentsOf: childOutput))
        if let first = combined {
            try require(first.recognitionRevision == result.recognitionRevision
                        && first.supportedRecognitionLanguages == result.supportedRecognitionLanguages,
                        "Vision language or revision metadata changed between corpus workers")
        } else {
            combined = result
        }
        images.append(contentsOf: result.images)
    }

    guard let first = combined else { throw CheckFailure.failed("OCR corpus has no language groups") }
    let baseline = OCRBaseline(schemaVersion: first.schemaVersion, operatingSystem: first.operatingSystem,
                               architecture: first.architecture, recognitionLevel: first.recognitionLevel,
                               recognitionRevision: first.recognitionRevision,
                               warmupRuns: first.warmupRuns,
                               usesLanguageCorrection: first.usesLanguageCorrection,
                               supportedRecognitionLanguages: first.supportedRecognitionLanguages,
                               images: images.sorted { $0.file < $1.file })

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try FileManager.default.createDirectory(at: outputFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(baseline).write(to: outputFile, options: .atomic)
    print("Vision baseline: wrote \(images.count) image results to \(outputFile.path)")
    print("Vision accurate revision \(baseline.recognitionRevision), \(baseline.supportedRecognitionLanguages.count) supported languages")
}

private func runOCRCorpusLanguage(corpusDirectory: URL, language: String, outputFile: URL) async throws {
    // Foundation canonicalizes Norwegian Bokmål `no-NO` to the equivalent `nb-NO` tag.
    let preferredLanguage = language == "no-NO" ? "nb-NO" : language
    UserDefaults.standard.setVolatileDomain(["AppleLanguages": [preferredLanguage]], forName: UserDefaults.argumentDomain)
    try require(Locale.preferredLanguages.first == preferredLanguage, "Could not select Vision language preference \(preferredLanguage)")
    let manifestURL = corpusDirectory.appendingPathComponent("manifest.json")
    let manifest = try JSONDecoder().decode([CorpusManifestEntry].self, from: Data(contentsOf: manifestURL))
        .filter { $0.language == language }
    try require(!manifest.isEmpty, "OCR corpus has no images for \(language)")

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    let languages = try request.supportedRecognitionLanguages()
    try require(languages.contains(preferredLanguage), "Vision .accurate does not support corpus language \(preferredLanguage)")
    let revision = request.revision

    let warmupEntry = manifest[0]
    let warmup = try await OCR.recognize(pngData: Data(contentsOf: corpusDirectory.appendingPathComponent(warmupEntry.file)))
    _ = CaptureClassifier.classify(warmup)

    var images: [OCRBaselineImage] = []
    images.reserveCapacity(manifest.count)
    for entry in manifest {
        let imageURL = corpusDirectory.appendingPathComponent(entry.file)
        let png = try Data(contentsOf: imageURL)
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try await OCR.recognize(pngData: png)
        let classification = CaptureClassifier.classify(result)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        images.append(OCRBaselineImage(file: entry.file, category: entry.category, language: entry.language,
                                       scale: entry.scale, dark: entry.dark, groundTruth: entry.groundTruth,
                                       text: result.text, latencyMs: Double(elapsed) / 1_000_000,
                                       classifierDecision: classification.decision.rawValue))
        print(String(format: "OCR corpus %@: %.1f ms", entry.file, Double(elapsed) / 1_000_000))
    }

    let architecture: String
    #if arch(arm64)
    architecture = "arm64"
    #elseif arch(x86_64)
    architecture = "x86_64"
    #else
    architecture = "unknown"
    #endif
    let baseline = OCRBaseline(schemaVersion: 1, operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                               architecture: architecture,
                               recognitionLevel: "accurate", recognitionRevision: revision,
                               warmupRuns: 1,
                               usesLanguageCorrection: true, supportedRecognitionLanguages: languages, images: images)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(baseline).write(to: outputFile, options: .atomic)
}

if CommandLine.arguments.count > 1 {
    do {
        switch CommandLine.arguments[1] {
        case "--ocr-corpus":
            guard CommandLine.arguments.count == 4 else {
                throw CheckFailure.failed("Usage: CaptureChecks --ocr-corpus <corpusdir> <out.json>")
            }
            try await runOCRCorpus(corpusDirectory: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true),
                                   outputFile: URL(fileURLWithPath: CommandLine.arguments[3]))
        case "--ocr-corpus-language":
            guard CommandLine.arguments.count == 5 else {
                throw CheckFailure.failed("Usage: CaptureChecks --ocr-corpus-language <corpusdir> <language> <out.json>")
            }
            try await runOCRCorpusLanguage(corpusDirectory: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true),
                                           language: CommandLine.arguments[3],
                                           outputFile: URL(fileURLWithPath: CommandLine.arguments[4]))
        case "--export-ocr-fixtures":
            guard CommandLine.arguments.count == 3 else {
                throw CheckFailure.failed("Usage: CaptureChecks --export-ocr-fixtures <dir>")
            }
            try Fixtures.exportOCRFixtures(to: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
        case "--browser-url":
            try checkBrowserAddressURL()
        default:
            throw CheckFailure.failed("Unknown CaptureChecks mode.")
        }
        exit(EXIT_SUCCESS)
    } catch {
        FileHandle.standardError.write(Data("Capture checks failed: \(error)\n".utf8))
        exit(EXIT_FAILURE)
    }
}

@MainActor
func checkHotkeys() throws {
    let defaults: [Hotkey] = [.captureSelection, .captureRegion, .search, .toggleSession, .writeNote, .addSubheading, .openLibrary,
                              .captureSelectionOutsideSession, .captureRegionOutsideSession, .writeNoteOutsideSession]
    let expected = ["⌥⇧C", "⌥⇧S", "⌥⇧F", "⌥⇧A", "⌥⇧N", "⌥⇧H", "⌥⇧L", "⌃⇧C", "⌃⇧S", "⌃⇧N"]
    let expectedDefinitions = [
        Hotkey(keyCode: 8, modifiers: [.option, .shift]), Hotkey(keyCode: 1, modifiers: [.option, .shift]),
        Hotkey(keyCode: 3, modifiers: [.option, .shift]), Hotkey(keyCode: 0, modifiers: [.option, .shift]),
        Hotkey(keyCode: 45, modifiers: [.option, .shift]), Hotkey(keyCode: 4, modifiers: [.option, .shift]),
        Hotkey(keyCode: 37, modifiers: [.option, .shift]),
        Hotkey(keyCode: 8, modifiers: [.control, .shift]), Hotkey(keyCode: 1, modifiers: [.control, .shift]),
        Hotkey(keyCode: 45, modifiers: [.control, .shift])
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
    print("Hotkeys: PASS (nine production definitions, temporary conflict and unregister).")
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

func checkBrowserAddressURL() throws {
    let safari = "com.apple.Safari"
    let chrome = "com.google.Chrome"
    let edge = "com.microsoft.edgemac"
    let field = "AXTextField"
    let safariID = "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"
    let chromeName = "Address and search bar"
    try require(BrowserAddressURL.recognizedField(bundleIdentifier: safari, role: field, identifier: safariID,
                                                  title: nil, description: nil, insideToolbar: true), "Safari address field missed")
    for browser in [chrome, edge] {
        try require(BrowserAddressURL.recognizedField(bundleIdentifier: browser, role: field, identifier: nil,
                                                      title: chromeName, description: nil, insideToolbar: true),
                    "Chromium address field missed: \(browser)")
        try require(BrowserAddressURL.recognizedField(bundleIdentifier: browser, role: field, identifier: nil,
                                                      title: nil, description: chromeName, insideToolbar: true),
                    "Chromium description missed: \(browser)")
    }
    for browser in [safari, chrome, edge, "org.mozilla.firefox", "com.example.editor"] {
        try require(!BrowserAddressURL.recognizedField(bundleIdentifier: browser, role: field, identifier: safariID,
                                                       title: chromeName, description: nil, insideToolbar: false),
                    "Web content must not become a browser address: \(browser)")
    }
    try require(!BrowserAddressURL.recognizedField(bundleIdentifier: safari, role: field, identifier: nil,
                                                   title: chromeName, description: nil, insideToolbar: true),
                "Safari accepted an unrelated toolbar text field")
    try require(!BrowserAddressURL.recognizedField(bundleIdentifier: chrome, role: "AXSearchField", identifier: nil,
                                                   title: chromeName, description: nil, insideToolbar: true),
                "Chrome accepted a search field with the wrong role")
    try require(!BrowserAddressURL.recognizedField(bundleIdentifier: "org.mozilla.firefox", role: field,
                                                   identifier: safariID, title: chromeName, description: nil,
                                                   insideToolbar: true), "Unrecognized browser accepted")

    for address in ["https://example.org/a%20b?q=one&two=three#part", "http://localhost:8080/path", "HTTPS://example.org/"] {
        try require(BrowserAddressURL.validated(address) == address, "Valid HTTP(S) address rejected: \(address)")
    }
    try require(BrowserAddressURL.capturableValue(focused: false, nativeURL: nil,
                                                   displayedValue: "https://example.org/page") == "https://example.org/page",
                "A complete unfocused address was lost")
    try require(BrowserAddressURL.capturableValue(focused: false, nativeURL: "https://example.org/full/path",
                                                   displayedValue: "example.org") == "https://example.org/full/path",
                "A complete native URL should win over abbreviated display text")
    for focused in [true, nil] as [Bool?] {
        try require(BrowserAddressURL.capturableValue(focused: focused, nativeURL: "https://example.org/page",
                                                       displayedValue: "https://example.org/edited") == nil,
                    "Editing or unverified focus must not expose an unsubmitted address")
    }
    try require(BrowserAddressURL.capturableValue(focused: false, nativeURL: nil,
                                                   displayedValue: "example.org/page") == nil,
                "An abbreviated address must not infer its scheme")
    for address in ["example.org", "https://", "http:///path", "ftp://example.org/", "javascript:alert(1)",
                    "https://example.org/a b", "https://example.org/a\nnext", "https://example.org/%ZZ",
                    "https://example.org/%", "https://example.org:65536/", "https://example.org:0/",
                    "https://user:pass@example.org/", "https://example.org\\@evil.test/"] {
        try require(BrowserAddressURL.validated(address) == nil, "Unsafe browser address accepted: \(address)")
    }
    let context = FrontmostContext(appName: "Safari", bundleIdentifier: safari, processIdentifier: 123,
                                   windowTitle: "Page", url: "https://example.org/page")
    try require(context.url == "https://example.org/page" && context.windowTitle == "Page", "Context URL snapshot lost")
    try require(FrontmostContext(appName: nil, bundleIdentifier: nil, processIdentifier: 0,
                                 windowTitle: nil).url == nil, "Context default URL changed")
    print("Browser URL: PASS (recognized address fields, browser and content isolation, strict HTTP(S), context fallback).")
}

// A running app can own the defaults; still exercise pasteboard, OCR and classification.
var hotkeyFailure: Error?
do { try checkHotkeys() } catch { hotkeyFailure = error }
do {
    try checkPasteboard()
    try await checkOCRAndClassifier()
    try checkRegionCaptureProcessDisposition()
    try checkBrowserAddressURL()
    if let hotkeyFailure { throw hotkeyFailure }
} catch {
    FileHandle.standardError.write(Data("Capture checks failed: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
