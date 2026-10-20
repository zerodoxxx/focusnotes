using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using CaptureApp.Platform.Ocr;
using Xunit;

namespace CaptureApp.Platform.Tests.Ocr;

// Runs alone so latency measurements are not taken while other test classes compete for CPU.
[CollectionDefinition("OcrFixtures", DisableParallelization = true)]
public sealed class OcrFixtureCollection;

[Collection("OcrFixtures")]
public sealed class OcrFixtureTests
{
    private const double MaximumEnglishCer = 0.02;
    private const double MaximumCerRegressionPoints = 0.02;
    private const double MaximumWarmP95Ms = 1500;
    private const double MaximumFirstRecognitionMs = 3000;
    private const int WarmRuns = 5;
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    [Fact]
    [Trait("Needs", "OcrModels")]
    public void EnglishCorpusMatchesGroundTruthAndStaysCloseToVision()
    {
        using var engine = CreateEngineAndRequireModels();
        var repositoryRoot = FindRepositoryRoot();
        var corpusDirectory = Path.Combine(repositoryRoot, "conformance", "ocr", "corpus");
        var corpus = ReadEnglishCorpus(corpusDirectory);
        var baselinePath = Path.Combine(repositoryRoot, "conformance", "ocr", "mac-baseline.json");
        var baseline = JsonSerializer.Deserialize<MacBaseline>(File.ReadAllText(baselinePath), JsonOptions)
                       ?? throw new InvalidDataException("The Mac OCR baseline is empty.");
        var baselineByFile = baseline.Images.ToDictionary(image => image.File, StringComparer.Ordinal);

        Assert.Equal(corpus.Length, baselineByFile.Count);
        var actualByFile = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var entry in corpus)
        {
            var path = Path.Combine(corpusDirectory, entry.File);
            actualByFile.Add(entry.File,
                engine.Recognize(File.ReadAllBytes(path), TestContext.Current.CancellationToken).Text);
        }

        var actualCer = CharacterErrorRate(corpus.Select(entry => (entry.GroundTruth, actualByFile[entry.File])));
        var visionCer = CharacterErrorRate(corpus.Select(entry => (entry.GroundTruth, baselineByFile[entry.File].Text)));
        Assert.True(actualCer <= MaximumEnglishCer,
            $"English CER was {actualCer:P2}; expected at most {MaximumEnglishCer:P0} over {corpus.Length} samples.");
        Assert.True(actualCer - visionCer <= MaximumCerRegressionPoints,
            $"English CER was {actualCer:P2} vs Vision {visionCer:P2}; expected no more than {MaximumCerRegressionPoints:P0} regression.");

        var code = actualByFile["en-US/code-02@2.0-dark.png"];
        Assert.Contains("return recent.sorted { $0.date > $1.date }", code, StringComparison.Ordinal);
    }

    [Fact]
    [Trait("Needs", "OcrModels")]
    public void ParagraphAndCodeFixturesPreserveTextAndPunctuation()
    {
        using var engine = CreateEngineAndRequireModels();
        var fixtures = Path.Combine(FindRepositoryRoot(), "conformance", "ocr", "fixtures");

        var paragraph = engine.Recognize(File.ReadAllBytes(Path.Combine(fixtures, "paragraph.png")),
            TestContext.Current.CancellationToken);
        var normalizedParagraph = paragraph.Text.ToLowerInvariant();
        var capture = normalizedParagraph.IndexOf("capture", StringComparison.Ordinal);
        var mountain = normalizedParagraph.IndexOf("mountain", StringComparison.Ordinal);
        Assert.True(capture >= 0 && mountain > capture, paragraph.Text);
        Assert.Contains("\n\n", paragraph.Text);

        var code = engine.Recognize(File.ReadAllBytes(Path.Combine(fixtures, "code.png")),
            TestContext.Current.CancellationToken);
        Assert.Contains("CaptureRecord: Sendable {", code.Text, StringComparison.Ordinal);
        Assert.Contains("collectRecords() -> [CaptureRecord] {", code.Text, StringComparison.Ordinal);
        Assert.Contains("return sorted.filter { !$0.content.isEmpty }", code.Text, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("diagram.png")]
    [InlineData("gradient.png")]
    [InlineData("table.png")]
    [Trait("Needs", "OcrModels")]
    public void DiagramGradientAndTableFixturesStayImages(string fixtureName)
    {
        using var engine = CreateEngineAndRequireModels();
        var path = Path.Combine(FindRepositoryRoot(), "conformance", "ocr", "fixtures", fixtureName);
        var result = engine.Recognize(File.ReadAllBytes(path), TestContext.Current.CancellationToken);

        Assert.Equal(CaptureDecision.Image, CaptureClassifier.Classify(result).Decision);
    }

    [Fact]
    [Trait("Needs", "OcrModels")]
    public void EmptyFixtureStaysImageWithZeroCoverage()
    {
        using var engine = CreateEngineAndRequireModels();
        var path = Path.Combine(FindRepositoryRoot(), "conformance", "ocr", "fixtures", "empty.png");
        var result = engine.Recognize(File.ReadAllBytes(path), TestContext.Current.CancellationToken);

        Assert.Empty(result.Lines);
        Assert.Equal(0.0, result.Coverage);
        Assert.Equal(CaptureDecision.Image, CaptureClassifier.Classify(result).Decision);
    }

    [Fact]
    [Trait("Needs", "OcrModels")]
    [Trait("Category", "Perf")]
    public void EnglishFullHdRecognitionHasFastFirstCallAndWarmP95()
    {
        using var engine = CreateEngineAndRequireModels();
        var corpusDirectory = Path.Combine(FindRepositoryRoot(), "conformance", "ocr", "corpus");
        var fullHd = ReadEnglishCorpus(corpusDirectory).Where(entry => entry.Scale == 2.0).ToArray();
        Assert.NotEmpty(fullHd);

        var firstImage = File.ReadAllBytes(Path.Combine(corpusDirectory, fullHd[0].File));
        var coldTimer = Stopwatch.StartNew();
        _ = engine.Recognize(firstImage, TestContext.Current.CancellationToken);
        coldTimer.Stop();
        Assert.True(coldTimer.Elapsed.TotalMilliseconds <= MaximumFirstRecognitionMs,
            $"First OCR recognition took {coldTimer.Elapsed.TotalMilliseconds:F1} ms; expected at most {MaximumFirstRecognitionMs:F0} ms.");

        var measurements = new List<double>(fullHd.Length * WarmRuns);
        for (var run = 0; run < WarmRuns; run++)
        {
            foreach (var entry in fullHd)
            {
                var png = File.ReadAllBytes(Path.Combine(corpusDirectory, entry.File));
                var timer = Stopwatch.StartNew();
                _ = engine.Recognize(png, TestContext.Current.CancellationToken);
                timer.Stop();
                measurements.Add(timer.Elapsed.TotalMilliseconds);
            }
        }

        measurements.Sort();
        var p95 = measurements[(int)Math.Ceiling(measurements.Count * 0.95) - 1];
        Assert.True(p95 <= MaximumWarmP95Ms,
            $"Warm English OCR p95 was {p95:F1} ms across {measurements.Count} 1920×1080 samples; expected at most {MaximumWarmP95Ms:F0} ms.");
    }

    private static CorpusManifestEntry[] ReadEnglishCorpus(string corpusDirectory)
    {
        var manifestPath = Path.Combine(corpusDirectory, "manifest.json");
        var entries = JsonSerializer.Deserialize<CorpusManifestEntry[]>(File.ReadAllText(manifestPath), JsonOptions)
                      ?? throw new InvalidDataException("The English OCR corpus is empty.");
        Assert.Equal(10, entries.Length);
        Assert.All(entries, entry => Assert.Equal("en-US", entry.Language));
        return entries;
    }

    private static double CharacterErrorRate(IEnumerable<(string Reference, string Hypothesis)> pairs)
    {
        long errors = 0;
        long referenceCharacters = 0;
        foreach (var (reference, hypothesis) in pairs)
        {
            var referenceRunes = Normalize(reference).EnumerateRunes().ToArray();
            var hypothesisRunes = Normalize(hypothesis).EnumerateRunes().ToArray();
            errors += Levenshtein(referenceRunes, hypothesisRunes);
            referenceCharacters += referenceRunes.Length;
        }

        return referenceCharacters == 0 ? 0 : errors / (double)referenceCharacters;
    }

    private static string Normalize(string text) => Regex.Replace(text.Normalize(NormalizationForm.FormC), @"\s+", " ").Trim();

    private static int Levenshtein<T>(IReadOnlyList<T> source, IReadOnlyList<T> target)
        where T : IEquatable<T>
    {
        var previous = Enumerable.Range(0, target.Count + 1).ToArray();
        var current = new int[target.Count + 1];
        for (var sourceIndex = 1; sourceIndex <= source.Count; sourceIndex++)
        {
            current[0] = sourceIndex;
            for (var targetIndex = 1; targetIndex <= target.Count; targetIndex++)
            {
                var substitution = previous[targetIndex - 1]
                    + (source[sourceIndex - 1].Equals(target[targetIndex - 1]) ? 0 : 1);
                current[targetIndex] = Math.Min(Math.Min(previous[targetIndex] + 1, current[targetIndex - 1] + 1), substitution);
            }

            (previous, current) = (current, previous);
        }

        return previous[target.Count];
    }

    private static RapidOcrEngine CreateEngineAndRequireModels()
    {
        var engine = new RapidOcrEngine();
        if (engine.IsAvailable)
        {
            return engine;
        }

        var reason = engine.MissingModelReason;
        engine.Dispose();
        if (Environment.GetEnvironmentVariable("CAPTUREAPP_REQUIRE_OCR_MODELS") == "1")
        {
            Assert.Fail(reason);
        }

        Assert.Skip(reason);
        throw new InvalidOperationException("Assert.Skip should have stopped the test.");
    }

    private static string FindRepositoryRoot()
    {
        foreach (var startingDirectory in new[] { Environment.CurrentDirectory, AppContext.BaseDirectory })
        {
            var directory = new DirectoryInfo(startingDirectory);
            while (directory is not null)
            {
                if (Directory.Exists(Path.Combine(directory.FullName, "conformance", "ocr", "fixtures")))
                {
                    return directory.FullName;
                }

                directory = directory.Parent;
            }
        }

        throw new DirectoryNotFoundException("Could not locate the repository conformance/ocr directory.");
    }

    private sealed record CorpusManifestEntry(
        [property: JsonPropertyName("file")] string File,
        [property: JsonPropertyName("category")] string Category,
        [property: JsonPropertyName("language")] string Language,
        [property: JsonPropertyName("scale")] double Scale,
        [property: JsonPropertyName("dark")] bool Dark,
        [property: JsonPropertyName("groundTruth")] string GroundTruth);

    private sealed record MacBaseline(
        [property: JsonPropertyName("images")] MacBaselineImage[] Images);

    private sealed record MacBaselineImage(
        [property: JsonPropertyName("file")] string File,
        [property: JsonPropertyName("text")] string Text);
}
