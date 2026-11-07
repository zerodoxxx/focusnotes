namespace CaptureApp.Embed;

/// Constants of the pinned EmbeddingGemma ONNX model. The revision lives in this assembly because
/// CaptureApp.ModelInstall depends on it, and CaptureApp.Embed cannot depend back on ModelInstall.
public static class GemmaModelConfig
{
    public const string Revision = "daa72c51243991dfcaf9f9137d2c573d8f7790c0";

    public const int MaxTokens = 2048;

    public const long BosTokenId = 2;

    public const long EosTokenId = 1;

    public const long ImageStartTokenId = 255999;

    public const long ImageSoftTokenId = 258880;

    public const long ImageEndTokenId = 258882;

    /// Text containing any of these ids is rejected because images must go through the vision path.
    public static readonly IReadOnlySet<long> ImagePlaceholderTokenIds = new HashSet<long> { 258880, 258881, 258884 };

    /// Flattened RGB 16x16 patch; ImagePreprocessor only accepts patch size 16.
    public const int VisionPatchWidth = 768;

    /// Not the same quantity as VisionPatchWidth; both happen to be 768.
    public const int EmbeddingWidth = 768;

    /// Shared by image, video and audio inputs; the empty video and audio placeholders must match it.
    public const long MediaFeatureWidth = 512;
}
