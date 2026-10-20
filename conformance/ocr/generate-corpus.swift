import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct CorpusEntry: Encodable {
    let file: String
    let category: String
    let language: String
    let scale: Double
    let dark: Bool
    let groundTruth: String
}

struct Sample {
    let category: String
    let lines: [String]
    let fontSize: CGFloat
}

struct LanguageSpec {
    let tag: String
    let font: String
    let samples: [Sample]
}

let languageSpecs = [
    LanguageSpec(tag: "en-US", font: "Helvetica Neue", samples: [
        Sample(category: "ui", lines: ["Project library", "Search your notes", "Recent captures", "Open folder", "Saved just now"], fontSize: 22),
        Sample(category: "ui", lines: ["Quick note", "Add a heading", "Start a session", "Cancel     Save note", "Changes are synced"], fontSize: 22),
        Sample(category: "code", lines: ["// Keep the newest capture", "struct CaptureRecord {", "    let title: String", "    func save() { writeVault() }", "}"], fontSize: 19),
        Sample(category: "code", lines: ["func collectRecords() -> [CaptureRecord] {", "    let recent = loadRecords()", "    return recent.sorted { $0.date > $1.date }", "}"], fontSize: 18),
        Sample(category: "docs", lines: ["A clearer view of the work", "Capture useful details while they are fresh.", "Small observations can connect distant ideas.", "Review these notes before the next session."], fontSize: 21),
        Sample(category: "docs", lines: ["Project notes", "Use a short title for each new thought.", "Keep related decisions in the same section.", "Updated October 19, 2026"], fontSize: 21),
        Sample(category: "chat", lines: ["Mira  09:42", "The new capture flow is ready to review.", "Jon  09:46", "I will test it after the design check."], fontSize: 21),
        Sample(category: "chat", lines: ["Team channel  #planning", "Mira: Please keep the first screen simple.", "Jon: The table now includes source links.", "2 replies     Add a reaction"], fontSize: 21),
        Sample(category: "table", lines: ["Item        Count        Status", "Drafts      12           Ready", "Images      4            Review", "Exports     2            Complete"], fontSize: 20),
        Sample(category: "table", lines: ["Task        Owner        Due", "OCR review  Mira         Today", "CI runner   Jon          Friday", "Release     Team         Oct 28"], fontSize: 20)
    ])
]

func pngData(for image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "Corpus", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create PNG destination"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "Corpus", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not finalize PNG"])
    }
    return data as Data
}

func cgColor(_ color: NSColor) -> CGColor {
    color.usingColorSpace(.deviceRGB)!.cgColor
}

func render(_ sample: Sample, language: LanguageSpec, scale: Double, dark: Bool) throws -> CGImage {
    let logicalWidth = 960
    let logicalHeight = 540
    let pixelWidth = Int(Double(logicalWidth) * scale)
    let pixelHeight = Int(Double(logicalHeight) * scale)
    guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "Corpus", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create canvas"])
    }
    context.scaleBy(x: scale, y: scale)
    let width = CGFloat(logicalWidth)
    let height = CGFloat(logicalHeight)
    context.setFillColor(cgColor(dark ? NSColor(calibratedWhite: 0.105, alpha: 1) : .white))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let foreground = cgColor(dark ? NSColor(calibratedWhite: 0.93, alpha: 1) : NSColor(calibratedWhite: 0.1, alpha: 1))
    let muted = cgColor(dark ? NSColor(calibratedWhite: 0.67, alpha: 1) : NSColor(calibratedWhite: 0.38, alpha: 1))
    context.setFillColor(cgColor(dark ? NSColor(calibratedWhite: 0.16, alpha: 1) : NSColor(calibratedWhite: 0.96, alpha: 1)))
    context.fill(CGRect(x: 32, y: 32, width: width - 64, height: height - 64))

    let category = sample.category
    let bodyFamily = category == "code" ? "Menlo" : language.font
    let bodySize = sample.fontSize
    let lineStep: CGFloat = category == "table" ? 54 : 49
    var top: CGFloat = 98
    for (index, string) in sample.lines.enumerated() {
        let size = bodySize
        let baseFont = CTFontCreateWithName(bodyFamily as CFString, size, nil)
        let fullRange = CFRange(location: 0, length: (string as NSString).length)
        let font = CTFontCreateForString(baseFont, string as CFString, fullRange)
        let color = (category == "chat" && index % 2 == 0) || (category == "table" && index == 0) ? foreground : muted
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: 62, y: height - top - size)
        CTLineDraw(line, context)
        top += lineStep
    }
    guard let image = context.makeImage() else {
        throw NSError(domain: "Corpus", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not render image"])
    }
    return image
}

do {
    guard CommandLine.arguments.count == 2 else {
        throw NSError(domain: "Corpus", code: 5, userInfo: [NSLocalizedDescriptionKey: "Usage: swift conformance/ocr/generate-corpus.swift <outdir>"])
    }
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    if FileManager.default.fileExists(atPath: output.path) {
        try FileManager.default.removeItem(at: output)
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var entries: [CorpusEntry] = []
    let scales = [1.0, 1.5, 2.0]
    for language in languageSpecs {
        for (index, sample) in language.samples.enumerated() {
            let scale = scales[(index + language.tag.utf8.count) % scales.count]
            let dark = (index + language.tag.utf8.count).isMultiple(of: 2)
            let suffix = dark ? "dark" : "light"
            let filename = String(format: "%@/%@-%02d@%.1f-%@.png", language.tag, sample.category, index % 2 + 1, scale, suffix)
            let fileURL = output.appendingPathComponent(filename)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let image = try render(sample, language: language, scale: scale, dark: dark)
            try pngData(for: image).write(to: fileURL, options: .atomic)
            entries.append(CorpusEntry(file: filename, category: sample.category, language: language.tag,
                                       scale: scale, dark: dark, groundTruth: sample.lines.joined(separator: "\n")))
        }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let manifest = try encoder.encode(entries)
    try manifest.write(to: output.appendingPathComponent("manifest.json"), options: .atomic)
    print("Generated \(entries.count) OCR samples in \(output.path)")
} catch {
    FileHandle.standardError.write(Data("Corpus generation failed: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
