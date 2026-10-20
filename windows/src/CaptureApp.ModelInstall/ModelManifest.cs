namespace CaptureApp.ModelInstall;

/// One file downloaded from the pinned Hugging Face revision.
public sealed record ModelArtifact(string Path, string Url, string Sha256, long Size);

/// A license file shipped with the app and copied next to the installed models.
public sealed record BundledLicense(string ResourceName, string Sha256, string InstalledName);

/// Single source of truth for the Windows semantic-search model artifacts. ONNX Runtime ships inside the
/// app, so unlike the macOS manifest there is no runtime archive. scripts/fetch-semantic-models.* read the
/// Artifact(...) lines below and a test compares them with Sources/EmbedKit/ModelManifest.swift.
public sealed class ModelManifest
{
    private const string Repo = "onnx-community/embeddinggemma-2-ONNX";
    private const string Revision = "daa72c51243991dfcaf9f9137d2c573d8f7790c0";
    private const string BaseUrl = "https://huggingface.co/" + Repo + "/resolve/" + Revision;

    public string HuggingFaceRepo { get; init; } = Repo;

    public string HuggingFaceRevision { get; init; } = Revision;

    public IReadOnlyList<ModelArtifact> ModelFiles { get; init; } = [];

    public IReadOnlyList<BundledLicense> Licenses { get; init; } = [];

    /// Files that must exist in the models directory before semantic search is enabled.
    public IEnumerable<string> RequiredFiles => ModelFiles.Select(file => file.Path);

    public long TotalDownloadBytes => ModelFiles.Sum(file => file.Size);

    public static ModelManifest Current { get; } = new()
    {
        ModelFiles =
        [
            Artifact("onnx/model_quantized.onnx", "d06edd601f851c633a2519304cbeb8dc6170d7ceb61b436625c17fb9b6e74953", 495165),
            Artifact("onnx/model_quantized.onnx_data", "278a7ff1248c3618e4bd11a607fc54f7bdc7778854230f3956d3f86bd9db4f3b", 313724928),
            Artifact("onnx/vision_encoder_q4.onnx", "7ea284226d4938f0ad921ab091f1d80a9ca699aa802984ef5cd5eec4f4761d96", 159400),
            Artifact("onnx/vision_encoder_q4.onnx_data", "0a9d6c927334f152a33dd90874f65d6ea5228999abe6a450d3f7813677fa704c", 108957696),
            Artifact("tokenizer.json", "4d777ef5bdc1aa36227abdfb77c3e49e7b9c892d16e1b6bda41c393504828be4", 32170510),
            Artifact("tokenizer_config.json", "17bd5d6e9364ca49a534e1502076593317c298d4a663623091ed45388f004874", 1599),
            Artifact("config.json", "8d011bfe08b5e345bbe0b81e5c6fd02c381920b345b986047bc2a33ce7b90d1d", 5031),
            Artifact("processor_config.json", "168f6a08522f3ce5dea596d94d003af2fd691742d4f41fe1f9d8cce76bfbf69c", 1788),
            Artifact("preprocessor_config.json", "9344893f8d0573a46ebb2ca54c03f56d044cea194c8dcfb1f4d652240ac21daa", 560),
            Artifact("config_sentence_transformers.json", "031e56a498d33c349ab489a21885bcfe25b4fcba841149dc99e1e90d4a7c28f5", 1565),
        ],
        Licenses =
        [
            new BundledLicense("Apache-2.0.txt", "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30", "EMBEDDINGGEMMA-APACHE-2.0-LICENSE.txt"),
            new BundledLicense("EmbeddingGemma2-NOTICE.txt", "354b2cec84f3ee07c6102571a08af0d8c6262208f11087effb554e559b0f5138", "EMBEDDINGGEMMA-NOTICE.txt"),
        ]
    };

    private static ModelArtifact Artifact(string path, string sha256, long size) => new(path, $"{BaseUrl}/{path}", sha256, size);
}
