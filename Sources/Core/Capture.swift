import Foundation

public struct CaptureSource: Codable, Sendable, Equatable {
    public var appName: String?
    public var windowTitle: String?
    public var url: String?
    public var documentURL: String?
    public var page: Int?

    public init(appName: String? = nil, windowTitle: String? = nil, url: String? = nil,
                documentURL: String? = nil, page: Int? = nil) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.url = url
        self.documentURL = documentURL
        self.page = page
    }
}

public enum CaptureContent: Codable, Sendable, Equatable {
    case text(String)
    case subheading(String)
    case note(String)
    /// Vault-relative path, for example `assets/2026-10-13-100712-ab12.png`.
    case image(assetPath: String)
}

public struct Capture: Codable, Sendable, Equatable {
    public var id: UUID
    public var createdAt: Date
    public var content: CaptureContent
    public var source: CaptureSource

    public init(id: UUID, createdAt: Date, content: CaptureContent, source: CaptureSource) {
        self.id = id
        self.createdAt = createdAt
        self.content = content
        self.source = source
    }
}
