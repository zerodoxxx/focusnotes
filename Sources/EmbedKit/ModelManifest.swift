import Foundation

/// One file downloaded from the pinned Hugging Face revision.
public struct ModelArtifact: Sendable, Hashable {
    public let path: String
    public let url: String
    public let sha256: String
    public let size: Int64

    public init(path: String, url: String, sha256: String, size: Int64) {
        self.path = path; self.url = url; self.sha256 = sha256; self.size = size
    }
}

/// The pinned ONNX Runtime release archive and the members extracted from it.
public struct RuntimeArchive: Sendable, Hashable {
    public let version: String
    public let url: String
    public let sha256: String
    public let size: Int64
    public let dylibMember: String
    public let dylibSHA256: String
    public let licenseMember: String
    public let licenseSHA256: String
    public let noticesMember: String
    public let noticesSHA256: String

    public init(version: String, url: String, sha256: String, size: Int64,
                dylibMember: String, dylibSHA256: String,
                licenseMember: String, licenseSHA256: String,
                noticesMember: String, noticesSHA256: String) {
        self.version = version; self.url = url; self.sha256 = sha256; self.size = size
        self.dylibMember = dylibMember; self.dylibSHA256 = dylibSHA256
        self.licenseMember = licenseMember; self.licenseSHA256 = licenseSHA256
        self.noticesMember = noticesMember; self.noticesSHA256 = noticesSHA256
    }
}

/// A license file checked into `licenses/` and copied into the app bundle.
public struct BundledLicense: Sendable, Hashable {
    public let resourceName: String
    public let sha256: String
    public let installedName: String

    public init(resourceName: String, sha256: String, installedName: String) {
        self.resourceName = resourceName; self.sha256 = sha256; self.installedName = installedName
    }
}

/// Single source of truth for semantic-search model artifacts.
/// Mirrored by scripts/fetch-models.sh; EmbedChecks fails when the two drift.
public struct ModelManifest: Sendable {
    public let huggingFaceRepo: String
    public let huggingFaceRevision: String
    public let modelFiles: [ModelArtifact]
    public let runtime: RuntimeArchive
    public let licenses: [BundledLicense]
    public let dylibName: String
    public let runtimeLicenseName: String
    public let runtimeNoticesName: String

    public init(huggingFaceRepo: String, huggingFaceRevision: String, modelFiles: [ModelArtifact],
                runtime: RuntimeArchive, licenses: [BundledLicense], dylibName: String,
                runtimeLicenseName: String, runtimeNoticesName: String) {
        self.huggingFaceRepo = huggingFaceRepo; self.huggingFaceRevision = huggingFaceRevision
        self.modelFiles = modelFiles; self.runtime = runtime; self.licenses = licenses
        self.dylibName = dylibName; self.runtimeLicenseName = runtimeLicenseName
        self.runtimeNoticesName = runtimeNoticesName
    }

    /// Files that must exist in the models directory before semantic search is enabled.
    public var requiredFiles: [String] { modelFiles.map(\.path) + [dylibName] }

    /// Bytes downloaded on a first install (model files plus the runtime archive).
    public var totalDownloadBytes: Int64 { modelFiles.reduce(0) { $0 + $1.size } + runtime.size }

    private static let hfBase = "https://huggingface.co/onnx-community/embeddinggemma-2-ONNX/resolve/daa72c51243991dfcaf9f9137d2c573d8f7790c0"

    public static let current = ModelManifest(
        huggingFaceRepo: "onnx-community/embeddinggemma-2-ONNX",
        huggingFaceRevision: "daa72c51243991dfcaf9f9137d2c573d8f7790c0",
        modelFiles: [
            ModelArtifact(path: "onnx/model_quantized.onnx", url: "\(hfBase)/onnx/model_quantized.onnx",
                          sha256: "d06edd601f851c633a2519304cbeb8dc6170d7ceb61b436625c17fb9b6e74953", size: 495165),
            ModelArtifact(path: "onnx/model_quantized.onnx_data", url: "\(hfBase)/onnx/model_quantized.onnx_data",
                          sha256: "278a7ff1248c3618e4bd11a607fc54f7bdc7778854230f3956d3f86bd9db4f3b", size: 313724928),
            ModelArtifact(path: "onnx/vision_encoder_q4.onnx", url: "\(hfBase)/onnx/vision_encoder_q4.onnx",
                          sha256: "7ea284226d4938f0ad921ab091f1d80a9ca699aa802984ef5cd5eec4f4761d96", size: 159400),
            ModelArtifact(path: "onnx/vision_encoder_q4.onnx_data", url: "\(hfBase)/onnx/vision_encoder_q4.onnx_data",
                          sha256: "0a9d6c927334f152a33dd90874f65d6ea5228999abe6a450d3f7813677fa704c", size: 108957696),
            ModelArtifact(path: "tokenizer.json", url: "\(hfBase)/tokenizer.json",
                          sha256: "4d777ef5bdc1aa36227abdfb77c3e49e7b9c892d16e1b6bda41c393504828be4", size: 32170510),
            ModelArtifact(path: "tokenizer_config.json", url: "\(hfBase)/tokenizer_config.json",
                          sha256: "17bd5d6e9364ca49a534e1502076593317c298d4a663623091ed45388f004874", size: 1599),
            ModelArtifact(path: "config.json", url: "\(hfBase)/config.json",
                          sha256: "8d011bfe08b5e345bbe0b81e5c6fd02c381920b345b986047bc2a33ce7b90d1d", size: 5031),
            ModelArtifact(path: "processor_config.json", url: "\(hfBase)/processor_config.json",
                          sha256: "168f6a08522f3ce5dea596d94d003af2fd691742d4f41fe1f9d8cce76bfbf69c", size: 1788),
            ModelArtifact(path: "preprocessor_config.json", url: "\(hfBase)/preprocessor_config.json",
                          sha256: "9344893f8d0573a46ebb2ca54c03f56d044cea194c8dcfb1f4d652240ac21daa", size: 560),
            ModelArtifact(path: "config_sentence_transformers.json", url: "\(hfBase)/config_sentence_transformers.json",
                          sha256: "031e56a498d33c349ab489a21885bcfe25b4fcba841149dc99e1e90d4a7c28f5", size: 1565),
        ],
        runtime: RuntimeArchive(
            version: "1.31.0",
            url: "https://github.com/microsoft/onnxruntime/releases/download/v1.31.0/onnxruntime-osx-arm64-1.31.0.tgz",
            sha256: "1031b36dd3bdaa8d976a6130d9cf2a05e9be320b93ae804f8427b91dc3432afc",
            size: 36549009,
            dylibMember: "onnxruntime-osx-arm64-1.31.0/lib/libonnxruntime.1.31.0.dylib",
            dylibSHA256: "2a50a63e7f41f8d4d551d3ee47248df3864f6540109fce8ad520ca3b51af4b70",
            licenseMember: "onnxruntime-osx-arm64-1.31.0/LICENSE",
            licenseSHA256: "2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c",
            noticesMember: "onnxruntime-osx-arm64-1.31.0/ThirdPartyNotices.txt",
            noticesSHA256: "143764b952fdb1a7c69ce653bfba74a7744d6a8a573bfb73e235fba356c83de3"),
        licenses: [
            BundledLicense(resourceName: "Apache-2.0.txt",
                           sha256: "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30",
                           installedName: "EMBEDDINGGEMMA-APACHE-2.0-LICENSE.txt"),
            BundledLicense(resourceName: "EmbeddingGemma2-NOTICE.txt",
                           sha256: "354b2cec84f3ee07c6102571a08af0d8c6262208f11087effb554e559b0f5138",
                           installedName: "EMBEDDINGGEMMA-NOTICE.txt"),
        ],
        dylibName: "libonnxruntime.dylib",
        runtimeLicenseName: "ORT-LICENSE",
        runtimeNoticesName: "ORT-ThirdPartyNotices.txt")
}
