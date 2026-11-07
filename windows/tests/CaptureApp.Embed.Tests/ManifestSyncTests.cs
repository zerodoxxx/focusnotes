using System.Text.RegularExpressions;
using CaptureApp.ModelInstall;
using Xunit;

namespace CaptureApp.Embed.Tests;

/// Fails CI when the C# manifest drifts from Sources/EmbedKit/ModelManifest.swift.
public sealed partial class ManifestSyncTests
{
    // The path is a string literal or a `static let` constant declared in the same file.
    [GeneratedRegex("""ModelArtifact\(path: (?:"([^"]+)"|([A-Za-z_]\w*)), url: "\\\(hfBase\)/([^"]+)",\s*sha256: "([0-9a-f]{64})", size: (\d+)\)""")]
    private static partial Regex SwiftArtifact();

    [GeneratedRegex("""BundledLicense\(resourceName: "([^"]+)",\s*sha256: "([0-9a-f]{64})",\s*installedName: "([^"]+)"\)""")]
    private static partial Regex SwiftLicense();

    private static string SwiftSource => File.ReadAllText(Path.Combine(Repo.Root(), "Sources", "EmbedKit", "ModelManifest.swift"));

    [Fact]
    public void ModelEntriesMatchTheMacManifest()
    {
        var swift = SwiftSource;
        var repo = Regex.Match(swift, """huggingFaceRepo: "([^"]+)",""").Groups[1].Value;
        var revision = Regex.Match(swift, """huggingFaceRevision: "([^"]+)",""").Groups[1].Value;
        var hfBase = Regex.Match(swift, @"hfBase = ""([^""]+)""").Groups[1].Value;
        var manifest = ModelManifest.Current;
        Assert.Equal(repo, manifest.HuggingFaceRepo);
        Assert.Equal(revision, manifest.HuggingFaceRevision);
        Assert.Equal($"https://huggingface.co/{repo}/resolve/{revision}", hfBase);

        var expected = SwiftArtifacts(swift, hfBase);
        Assert.Equal(10, expected.Count);
        Assert.Equal(expected, manifest.ModelFiles);

        var licenses = SwiftLicense().Matches(swift).Select(m => new BundledLicense(m.Groups[1].Value, m.Groups[2].Value, m.Groups[3].Value)).ToList();
        Assert.Equal(2, licenses.Count);
        Assert.Equal(licenses, manifest.Licenses);
        var swiftModelId = Regex.Match(File.ReadAllText(Path.Combine(Repo.Root(), "Sources", "EmbedKit", "Embedder.swift")), @"modelID = ""([^""]+)""").Groups[1].Value;
        Assert.Contains(revision, swiftModelId);
        Assert.Equal(Embedder.ModelID, swiftModelId);
    }

    private static List<ModelArtifact> SwiftArtifacts(string swift, string hfBase) =>
        SwiftArtifact().Matches(swift)
            .Select(m => new ModelArtifact(SwiftPath(swift, m), $"{hfBase}/{m.Groups[3].Value}", m.Groups[4].Value, long.Parse(m.Groups[5].Value)))
            .ToList();

    private static string SwiftPath(string swift, Match artifact)
    {
        if (artifact.Groups[1].Success) return artifact.Groups[1].Value;
        var name = artifact.Groups[2].Value;
        var constant = Regex.Match(swift, "static let " + Regex.Escape(name) + " = \"([^\"]+)\"");
        Assert.True(constant.Success, $"ModelArtifact path constant {name} is not a string literal in ModelManifest.swift");
        return constant.Groups[1].Value;
    }

    [Fact]
    public void ConstantBackedArtifactPathsResolveToTheirLiterals()
    {
        const string swift = """
            static let textPath = "onnx/a.onnx"
            ModelArtifact(path: textPath, url: "\(hfBase)/onnx/a.onnx",
                          sha256: "%%", size: 1),
            ModelArtifact(path: "b.json", url: "\(hfBase)/b.json", sha256: "%%", size: 2),
            ModelArtifact(path: missingPath, url: "\(hfBase)/c.json", sha256: "%%", size: 3),
            """;
        var source = swift.Replace("%%", new string('0', 64));
        var resolvable = source[..source.IndexOf("ModelArtifact(path: missingPath", StringComparison.Ordinal)];

        Assert.Equal(new[] { "onnx/a.onnx", "b.json" }, SwiftArtifacts(resolvable, "base").Select(a => a.Path));
        Assert.ThrowsAny<Exception>(() => SwiftArtifacts(source, "base"));
    }

    [Fact]
    public void BundledLicenseFilesHaveTheManifestHashes()
    {
        foreach (var license in ModelManifest.Current.Licenses)
        {
            var linked = Path.Combine(AppContext.BaseDirectory, "ModelLicenses", license.ResourceName);
            Assert.True(File.Exists(linked), $"{license.ResourceName} is not copied next to the app");
            Assert.Equal(license.Sha256, Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(linked))).ToLowerInvariant());
            Assert.Equal(File.ReadAllBytes(Path.Combine(Repo.Root(), "licenses", license.ResourceName)), File.ReadAllBytes(linked));
        }
    }

    [Fact]
    public void FetchScriptsReadTheManifestFile()
    {
        foreach (var script in new[] { "fetch-semantic-models.sh", "fetch-semantic-models.ps1" })
        {
            Assert.Contains("ModelManifest.cs", File.ReadAllText(Path.Combine(Repo.Root(), "windows", "scripts", script)));
        }

        Assert.Equal(ModelManifest.Current.ModelFiles.Count, Regex.Matches(File.ReadAllText(Path.Combine(Repo.Root(), "windows", "src", "CaptureApp.ModelInstall", "ModelManifest.cs")), """Artifact\("[^"]+", "[0-9a-f]{64}", \d+\)""").Count);
    }
}
