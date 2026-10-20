using System.Runtime.CompilerServices;
using Xunit;

namespace CaptureApp.Embed.Tests;

internal static class Repo
{
    /// Resolved from this source file's location, not the build output, so artifacts paths do not matter.
    public static string Root([CallerFilePath] string thisFile = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(thisFile)!, "..", "..", ".."));

    public static string Fixtures => Path.Combine(Root(), "Sources", "EmbedChecks", "Fixtures");
}

internal static class Models
{
    private static readonly string[] Required =
    [
        "onnx/model_quantized.onnx", "onnx/model_quantized.onnx_data", "onnx/vision_encoder_q4.onnx", "onnx/vision_encoder_q4.onnx_data",
        "tokenizer.json", "processor_config.json"
    ];

    /// The semantic model directory from CAPTUREAPP_MODELS_DIR. Skips the test with a reason when the models are
    /// unavailable, unless CAPTUREAPP_REQUIRE_MODELS=1 (CI), where that is a failure.
    public static string Require()
    {
        var directory = Environment.GetEnvironmentVariable("CAPTUREAPP_MODELS_DIR");
        var required = Environment.GetEnvironmentVariable("CAPTUREAPP_REQUIRE_MODELS") == "1";
        if (string.IsNullOrWhiteSpace(directory))
        {
            return Unavailable(required, "CAPTUREAPP_MODELS_DIR is not set. Run scripts/fetch-semantic-models.sh <dir> and point it at the directory.");
        }

        var missing = Required.Where(name => !File.Exists(Path.Combine(directory, name))).ToList();
        return missing.Count == 0
            ? directory
            : Unavailable(required, $"Models missing from {directory}: {string.Join(", ", missing)}");
    }

    private static string Unavailable(bool required, string reason)
    {
        Assert.False(required, reason);
        Assert.Skip(reason);
        return "";
    }
}

internal static class Helper
{
    /// The EmbedHelper apphost copied next to the tests, or its dll (the client launches dlls through dotnet).
    public static string Path
    {
        get
        {
            var name = System.IO.Path.Combine(AppContext.BaseDirectory, "CaptureApp.EmbedHelper");
            if (OperatingSystem.IsWindows())
            {
                name += ".exe";
            }

            return File.Exists(name) ? name : System.IO.Path.Combine(AppContext.BaseDirectory, "CaptureApp.EmbedHelper.dll");
        }
    }
}

internal sealed class TempDirectory : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "captureapp-embed-tests-" + Guid.NewGuid().ToString("N"));

    public TempDirectory() => Directory.CreateDirectory(Path);

    public void Dispose()
    {
        try
        {
            Directory.Delete(Path, true);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }
}
