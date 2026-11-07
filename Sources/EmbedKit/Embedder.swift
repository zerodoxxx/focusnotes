import Foundation
import CORT

public enum EmbeddingKind: Sendable {
    case query
    case document(title: String?)

    func input(_ text: String) -> String {
        switch self {
        case .query: "task: search result | query: " + text
        case .document(let title): "title: \(title ?? "none") | text: " + text
        }
    }
}

private enum GemmaModel {
    static let imagePrefix: [Int64] = [2, 255999]
    static let imageToken: Int64 = 258880
    /// Media placeholder IDs that text input must not contain.
    static let placeholderTokens: Set<Int64> = [imageToken, 258881, 258884]
    static let imageSuffix: [Int64] = [258882, 1]
    static let featureWidth = 512
}

/// Synchronous inference intended for EmbedHelper. Initialization is cheap;
/// the tokenizer, dylib and sessions are created on the first actual request.
/// Calls are serialized by a lock, including lazy initialization.
public final class Embedder: @unchecked Sendable {
    public static let modelID = "onnx-community/embeddinggemma-2-ONNX@daa72c51243991dfcaf9f9137d2c573d8f7790c0:text-q8,vision-q4"
    public let dimensions: Int
    private let directory: URL
    private let lock = NSLock()
    private var tokenizer: Tokenizer?
    private var runtime: ONNXRuntime?
    private var text: ONNXSession?
    private var vision: ONNXSession?
    private var processor: ImagePreprocessor?

    public init(modelsDirectory: URL, dimensions: Int = EmbedProtocol.defaultDimensions) throws {
        guard EmbedProtocol.supportedDimensions.contains(dimensions) else {
            throw EmbeddingError.invalid("Dimensions must be 128, 256, 512 or 768")
        }
        self.directory = modelsDirectory; self.dimensions = dimensions
    }

    public var visionLoaded: Bool { lock.withLock { vision != nil } }

    public func embed(texts: [String], kind: EmbeddingKind) throws -> [[Float]] {
        try lock.withLock {
            guard !texts.isEmpty else { return [] }
            try loadText()
            // Per-item inference avoids quadratic work from padding unrelated
            // document lengths and bounds peak memory independently of batch size.
            return try texts.map { input in
                let ids = try tokenizer!.encode(kind.input(input), maxLength: 2048)
                guard !ids.contains(where: GemmaModel.placeholderTokens.contains) else {
                    throw EmbeddingError.invalid("Text contains a media placeholder; use embed(imagePNG:) for images")
                }
                return try shared(ids: ids, imageFeatures: nil)
            }
        }
    }

    public func embed(imagePNG: Data) throws -> [Float] {
        try lock.withLock {
            try loadText()
            if processor == nil { processor = try ImagePreprocessor(directory: directory) }
            let prepared = try processor!.prepare(imagePNG)
            if vision == nil {
                vision = try ONNXSession(runtime: runtime!, model: directory.appendingPathComponent(ModelManifest.visionModelPath))
            }
            let patches = processor!.patchCount
            let pixels = try runtime!.tensor(prepared.pixels, shape: [1, Int64(patches), Int64(processor!.patchVectorWidth)], type: ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
            let positions = try runtime!.tensor(prepared.positions, shape: [1, Int64(patches), 2], type: ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64)
            let features = try vision!.run([("pixel_values", pixels), ("pixel_position_ids", positions)], output: "image_features")
            let ids: [Int64] = GemmaModel.imagePrefix + [Int64](repeating: GemmaModel.imageToken, count: prepared.tokens) + GemmaModel.imageSuffix
            guard try features.floats().count == prepared.tokens * GemmaModel.featureWidth else {
                throw EmbeddingError.runtime("Vision feature count does not match image token count")
            }
            return try shared(ids: ids, imageFeatures: features)
        }
    }

    private func loadText() throws {
        if runtime == nil { runtime = try ONNXRuntime(directory: directory) }
        if text == nil { text = try ONNXSession(runtime: runtime!, model: directory.appendingPathComponent(ModelManifest.textModelPath)) }
        if tokenizer == nil { tokenizer = try Tokenizer(tokenizerJSON: directory.appendingPathComponent("tokenizer.json")) }
    }

    private func shared(ids: [Int64], imageFeatures: ONNXTensor?) throws -> [Float] {
        let runtime = runtime!
        let tokens = try runtime.tensor(ids, shape: [1, Int64(ids.count)], type: ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64)
        let mask = try runtime.tensor([Int64](repeating: 1, count: ids.count), shape: [1, Int64(ids.count)], type: ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64)
        let empty = try runtime.tensor([Float](), shape: [0, Int64(GemmaModel.featureWidth)], type: ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
        let output = try text!.run([("input_ids", tokens), ("attention_mask", mask),
                                   ("image_features", imageFeatures ?? empty), ("video_features", empty),
                                   ("audio_features", empty)], output: "sentence_embedding")
        let vector = try output.floats()
        guard vector.count == 768 else { throw EmbeddingError.runtime("Expected 768-d shared embedding") }
        let full = try normalized(vector)
        return try normalized(Array(full.prefix(dimensions)))
    }
}
