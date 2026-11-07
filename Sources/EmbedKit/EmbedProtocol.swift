import Foundation

/// Shared by the client and helper so a dimension change is made in one place.
public enum EmbedProtocol {
    public static let supportedDimensions: [Int] = [128, 256, 512, 768]
    public static let defaultDimensions = 256
    public static let maxDimensions = supportedDimensions.max()!
    public static let maxMessageBytes = 64 * 1024 * 1024
    public static let defaultIdleSeconds: Double = 60
    public static let maxIdleSeconds: Double = 86_400
}

/// One JSON object per line. All requests and responses carry the same ID.
public struct EmbedRequest: Codable, Sendable {
    public let id: String
    public let operation: String
    public var text: String?
    public var texts: [String]?
    public var title: String?
    public var imagePNG: String?
    public var dimensions: Int

    public init(id: String = UUID().uuidString, operation: String, text: String? = nil,
                texts: [String]? = nil, title: String? = nil, imagePNG: String? = nil, dimensions: Int = EmbedProtocol.defaultDimensions) {
        self.id = id; self.operation = operation; self.text = text; self.texts = texts
        self.title = title; self.imagePNG = imagePNG; self.dimensions = dimensions
    }
}

public struct EmbedResponse: Codable, Sendable {
    public let id: String
    public let modelID: String
    public let dimensions: Int
    public let vectors: [String]?
    public let error: String?
    public let processID: Int32
    public let visionLoaded: Bool

    public init(id: String, dimensions: Int, vectors: [[Float]]? = nil, error: String? = nil,
                processID: Int32, visionLoaded: Bool) throws {
        self.id = id; self.modelID = Embedder.modelID; self.dimensions = dimensions
        self.vectors = try vectors?.map { try Float16Vectors.encode($0).base64EncodedString() }
        self.error = error; self.processID = processID; self.visionLoaded = visionLoaded
    }
}
