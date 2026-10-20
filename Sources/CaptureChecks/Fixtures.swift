import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Fixture {
    let name: String
    let image: CGImage
    let expectedText: Bool
}

enum Fixtures {
    static func make() throws -> [Fixture] {
        [
            Fixture(name: "paragraph", image: try paragraph(), expectedText: true),
            Fixture(name: "code", image: try code(), expectedText: true),
            Fixture(name: "diagram", image: try diagram(), expectedText: false),
            Fixture(name: "gradient", image: try gradient(), expectedText: false),
            Fixture(name: "table", image: try table(), expectedText: false)
        ]
    }

    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CheckFailure.failed("Could not create PNG encoder")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CheckFailure.failed("Could not encode PNG") }
        return data as Data
    }

    static func exportOCRFixtures(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var fixtures = try make()
        fixtures.append(Fixture(name: "empty", image: try empty(), expectedText: false))
        for fixture in fixtures {
            try png(fixture.image).write(to: directory.appendingPathComponent("\(fixture.name).png"), options: .atomic)
        }
        print("OCR fixtures: exported \(fixtures.count) PNGs to \(directory.path)")
    }

    private static func canvas(width: Int = 720, height: Int = 420, draw: (CGContext, CGFloat) -> Void) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width * 2, height: height * 2, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CheckFailure.failed("Could not create 2x fixture context")
        }
        context.scaleBy(x: 2, y: 2)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context, CGFloat(height))
        guard let image = context.makeImage() else { throw CheckFailure.failed("Could not render fixture") }
        return image
    }

    private static func text(_ text: String, x: CGFloat, top: CGFloat, size: CGFloat = 20,
                             mono: Bool = false, context: CGContext, height: CGFloat) {
        let font = CTFontCreateWithName((mono ? "Menlo" : "Helvetica") as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.08, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: height - top - size)
        CTLineDraw(line, context)
    }

    private static func paragraph() throws -> CGImage {
        try canvas { context, height in
            let paragraphs = [
                ["Capture ideas before they disappear from memory.",
                 "A mountain trail can inspire a fresh perspective.",
                 "Write the details while the moment is still clear.",
                 "Small observations become useful notes over time."],
                ["Keep your attention on the work in front of you.",
                 "Selected words carry their original context along.",
                 "Review the collection when you need inspiration.",
                 "Thoughtful notes help connect ideas across projects."]
            ]
            var top: CGFloat = 34
            for (index, lines) in paragraphs.enumerated() {
                if index > 0 { top += 30 }
                for line in lines {
                    text(line, x: 38, top: top, context: context, height: height)
                    top += 34
                }
            }
        }
    }

    private static func code() throws -> CGImage {
        try canvas(width: 760, height: 430) { context, height in
            let lines = [
                "struct CaptureRecord: Sendable {",
                "    let identifier: String",
                "    let content: String",
                "    let createdAt: Date",
                "}",
                "",
                "func collectRecords() -> [CaptureRecord] {",
                "    let records = loadRecords()",
                "    let sorted = records.sorted { first, second in",
                "        first.createdAt < second.createdAt",
                "    }",
                "    return sorted.filter { !$0.content.isEmpty }",
                "}"
            ]
            for (index, line) in lines.enumerated() {
                text(line, x: 30, top: 28 + CGFloat(index) * 28, size: 18, mono: true, context: context, height: height)
            }
        }
    }

    private static func diagram() throws -> CGImage {
        try canvas { context, height in
            let boxes = [CGRect(x: 40, y: 160, width: 160, height: 100),
                         CGRect(x: 280, y: 160, width: 160, height: 100),
                         CGRect(x: 520, y: 160, width: 160, height: 100)]
            context.setStrokeColor(CGColor(gray: 0.2, alpha: 1))
            context.setLineWidth(2)
            for box in boxes {
                context.setFillColor(CGColor(red: 0.88, green: 0.94, blue: 0.98, alpha: 1))
                context.fill(box)
                context.stroke(box)
            }
            for x: CGFloat in [200, 440] {
                context.move(to: CGPoint(x: x, y: 210))
                context.addLine(to: CGPoint(x: x + 72, y: 210))
                context.move(to: CGPoint(x: x + 62, y: 219))
                context.addLine(to: CGPoint(x: x + 72, y: 210))
                context.addLine(to: CGPoint(x: x + 62, y: 201))
                context.strokePath()
            }
            for (index, label) in ["Input", "Process", "Output"].enumerated() {
                text(label, x: 84 + CGFloat(index) * 240, top: 194, size: 19, context: context, height: height)
            }
        }
    }

    private static func gradient() throws -> CGImage {
        try canvas { context, _ in
            let colors = [CGColor(red: 0.1, green: 0.3, blue: 0.65, alpha: 1),
                          CGColor(red: 0.95, green: 0.55, blue: 0.3, alpha: 1)] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 720, y: 420), options: [])
            }
        }
    }

    private static func empty() throws -> CGImage {
        try canvas { _, _ in }
    }

    private static func table() throws -> CGImage {
        try canvas { context, height in
            let x: CGFloat = 48, bottom: CGFloat = 60, cellWidth: CGFloat = 156, cellHeight: CGFloat = 50
            context.setStrokeColor(CGColor(gray: 0.35, alpha: 1))
            context.setLineWidth(1.5)
            for column in 0...4 {
                context.move(to: CGPoint(x: x + CGFloat(column) * cellWidth, y: bottom))
                context.addLine(to: CGPoint(x: x + CGFloat(column) * cellWidth, y: bottom + 300))
            }
            for row in 0...6 {
                context.move(to: CGPoint(x: x, y: bottom + CGFloat(row) * cellHeight))
                context.addLine(to: CGPoint(x: x + 624, y: bottom + CGFloat(row) * cellHeight))
            }
            context.strokePath()
            let rows = [["Item", "Qty", "Cost", "State"], ["Pen", "12", "3.50", "Ready"],
                        ["Book", "4", "8.00", "Hold"], ["Paper", "20", "2.00", "Ready"],
                        ["Ink", "2", "6.50", "Hold"], ["Clip", "30", "1.00", "Ready"]]
            for (row, cells) in rows.enumerated() {
                for (column, label) in cells.enumerated() {
                    text(label, x: x + CGFloat(column) * cellWidth + 16,
                         top: height - (bottom + 300) + CGFloat(row) * cellHeight + 15,
                         size: 16, context: context, height: height)
                }
            }
        }
    }
}
