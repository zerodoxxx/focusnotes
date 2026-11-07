import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

enum AppMedia {
    @concurrent
    static func thumbnail(pngData: Data) async -> CGImage? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithData(pngData as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 72,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    @concurrent
    static func imageRepresentations(pngData: Data) async throws -> (png: Data, tiff: Data) {
        let png = pngData
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CocoaError(.fileReadCorruptFile) }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.tiff.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return (png, output as Data)
    }

    @concurrent
    static func demoPNG() async throws -> Data {
        guard let context = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        context.setStrokeColor(CGColor(gray: 0.2, alpha: 1))
        context.setLineWidth(4)
        context.stroke(CGRect(x: 40, y: 60, width: 180, height: 160))
        context.stroke(CGRect(x: 420, y: 60, width: 180, height: 160))
        context.move(to: CGPoint(x: 220, y: 140))
        context.addLine(to: CGPoint(x: 420, y: 140))
        context.strokePath()
        let label = NSAttributedString(string: "demoimagekeyword", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 32, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        context.textPosition = CGPoint(x: 120, y: 280)
        CTLineDraw(CTLineCreateWithAttributedString(label), context)
        let output = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return output as Data
    }
}
