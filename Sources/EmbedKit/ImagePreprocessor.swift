import Foundation
import CoreGraphics
import ImageIO

struct ImagePreprocessor {
    let patch: Int
    let pooling: Int
    let budget: Int
    let rescale: Float

    init(directory: URL) throws {
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent("processor_config.json"))) as? [String: Any],
              let image = root["image_processor"] as? [String: Any],
              image["image_processor_type"] as? String == "Gemma4ImageProcessor",
              image["do_resize"] as? Bool == true, image["resample"] as? Int == 3,
              image["do_convert_rgb"] as? Bool == true, image["do_rescale"] as? Bool == true,
              image["do_normalize"] as? Bool == false,
              let patch = image["patch_size"] as? Int, patch == 16,
              let pooling = image["pooling_kernel_size"] as? Int, pooling == 3,
              let budget = image["max_soft_tokens"] as? Int, [70, 140, 280, 560, 1120].contains(budget),
              let factor = image["rescale_factor"] as? Double else {
            throw EmbeddingError.invalid("Unsupported image processor configuration")
        }
        self.patch = patch; self.pooling = pooling; self.budget = budget; self.rescale = Float(factor)
    }

    /// Patches in one image tensor.
    var patchCount: Int { budget * pooling * pooling }
    /// Floats per patch (RGB).
    var patchVectorWidth: Int { patch * patch * 3 }

    func prepare(_ data: Data) throws -> (pixels: [Float], positions: [Int64], tokens: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.png",
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0, image.width <= 16_384, image.height <= 16_384,
              image.width * image.height <= 32_000_000 else {
            throw EmbeddingError.invalid("Expected a PNG image of at most 32 megapixels")
        }
        let width = image.width, height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let success = rgba.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { throw EmbeddingError.invalid("Could not decode PNG pixels") }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            let alpha = Int(rgba[i * 4 + 3])
            for c in 0..<3 {
                // Drop alpha after un-premultiplication, matching RGB conversion.
                rgb[i * 3 + c] = alpha == 0 ? 0 : UInt8(min(255, (Int(rgba[i * 4 + c]) * 255 + alpha / 2) / alpha))
            }
        }
        let maxPatches = patchCount
        let side = patch * pooling
        let factor = sqrt(Double(maxPatches * patch * patch) / Double(width * height))
        var targetH = Int(floor(Double(height) * factor / Double(side))) * side
        var targetW = Int(floor(Double(width) * factor / Double(side))) * side
        if targetH == 0 { targetH = side; targetW = min(width / height * side, budget * side) }
        if targetW == 0 { targetW = side; targetH = min(height / width * side, budget * side) }
        guard targetH * targetW <= maxPatches * patch * patch else {
            throw EmbeddingError.invalid("Image patch budget exceeded")
        }
        let resized = Self.resize(rgb, width: width, height: height, targetW: targetW, targetH: targetH)
        let rows = targetH / patch, columns = targetW / patch
        var pixels = [Float](repeating: 0, count: patchCount * patchVectorWidth)
        var positions = [Int64](repeating: -1, count: maxPatches * 2)
        for y in 0..<rows {
            for x in 0..<columns {
                let p = y * columns + x
                positions[2 * p] = Int64(x); positions[2 * p + 1] = Int64(y)
                for dy in 0..<patch {
                    for dx in 0..<patch {
                        let src = ((y * patch + dy) * targetW + x * patch + dx) * 3
                        let dst = (p * patch * patch + dy * patch + dx) * 3
                        for c in 0..<3 { pixels[dst + c] = Float(resized[src + c]) * rescale }
                    }
                }
            }
        }
        return (pixels, positions, rows * columns / (pooling * pooling))
    }

    private struct Coefficients { let start: Int; let weights: [Int64] }

    // Pillow-compatible separable antialiased bicubic interpolation: half-pixel
    // centers, a=-0.5, widened support for downsampling, 22-bit coefficients,
    // rounding/clamping after each pass. No platform-dependent CG resize filter.
    private static func coefficients(from: Int, to: Int) -> [Coefficients] {
        let scale = Double(from) / Double(to), filterScale = max(1, scale)
        let support = 2 * filterScale
        return (0..<to).map { i in
            let center = (Double(i) + 0.5) * scale
            let start = max(0, Int(center - support + 0.5))
            let end = min(from, Int(center + support + 0.5))
            let weights = (start..<end).map { j -> Double in
                let x = abs((Double(j) - center + 0.5) / filterScale)
                if x < 1 { return (1.5 * x - 2.5) * x * x + 1 }
                if x < 2 { return (((x - 5) * x + 8) * x - 4) * -0.5 }
                return 0
            }
            let sum = weights.reduce(0, +)
            return Coefficients(start: start, weights: weights.map {
                let v = $0 / sum * Double(1 << 22)
                return Int64(v < 0 ? v - 0.5 : v + 0.5)
            })
        }
    }

    private static func resize(_ rgb: [UInt8], width: Int, height: Int, targetW: Int, targetH: Int) -> [UInt8] {
        var intermediate = rgb
        if targetW != width {
            let weights = coefficients(from: width, to: targetW)
            intermediate = [UInt8](repeating: 0, count: targetW * height * 3)
            for y in 0..<height {
                for x in 0..<targetW {
                    let coefficient = weights[x]
                    for c in 0..<3 {
                        var sum: Int64 = 1 << 21
                        for (k, weight) in coefficient.weights.enumerated() {
                            sum += Int64(rgb[(y * width + coefficient.start + k) * 3 + c]) * weight
                        }
                        intermediate[(y * targetW + x) * 3 + c] = UInt8(clamping: sum >> 22)
                    }
                }
            }
        }
        if targetH == height { return intermediate }
        let weights = coefficients(from: height, to: targetH)
        var result = [UInt8](repeating: 0, count: targetW * targetH * 3)
        for y in 0..<targetH {
            let coefficient = weights[y]
            for x in 0..<targetW {
                for c in 0..<3 {
                    var sum: Int64 = 1 << 21
                    for (k, weight) in coefficient.weights.enumerated() {
                        sum += Int64(intermediate[((coefficient.start + k) * targetW + x) * 3 + c]) * weight
                    }
                    result[(y * targetW + x) * 3 + c] = UInt8(clamping: sum >> 22)
                }
            }
        }
        return result
    }
}
