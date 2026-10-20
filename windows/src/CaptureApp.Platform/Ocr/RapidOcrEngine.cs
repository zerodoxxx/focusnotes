using System.Diagnostics;
using RapidOcrNet;
using SkiaSharp;

namespace CaptureApp.Platform.Ocr;

/// <summary>Offline RapidOcrNet engine for the bundled PP-OCRv5 Latin models.</summary>
public sealed class RapidOcrEngine : IOcrEngine, IDisposable
{
    private static readonly TimeSpan IdleLifetime = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan EvictionPeriod = TimeSpan.FromSeconds(10);
    // English-first OCR is Nehul's decision to get the Windows POC working ASAP.
    private const string DetectorFile = "ch_PP-OCRv5_mobile_det.onnx";
    private const string ClassifierFile = "ch_PP-LCNet_x0_25_textline_ori_cls_mobile.onnx";
    private const string RecognizerFile = "latin_PP-OCRv5_rec_mobile_infer.onnx";
    private const string DictionaryFile = "ppocrv5_latin_dict.txt";
    private static readonly string ModelDirectory = Path.Combine(AppContext.BaseDirectory, "models", "v5");

    private readonly object _gate = new();
    private ModelSlot? _loadedModel;
    private readonly System.Threading.Timer _evictionTimer;
    private bool _disposed;

    public RapidOcrEngine()
    {
        _evictionTimer = new System.Threading.Timer(EvictIdleModels, null, EvictionPeriod, EvictionPeriod);
    }

    public bool IsAvailable => GetMissingModelFiles().Count == 0;

    public string MissingModelReason
    {
        get
        {
            var missing = GetMissingModelFiles();
            return missing.Count == 0
                ? string.Empty
                : $"RapidOcrNet's bundled PP-OCRv5 Latin models are missing from {ModelDirectory}: {string.Join(", ", missing)}.";
        }
    }

    public OcrResult Recognize(byte[] png, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(png);
        cancellationToken.ThrowIfCancellationRequested();
        using var bitmap = SKBitmap.Decode(png);
        if (bitmap is null || bitmap.Width <= 0 || bitmap.Height <= 0)
        {
            throw new InvalidDataException("The input is not a decodable PNG image.");
        }

        return Recognize(bitmap, cancellationToken);
    }

    public OcrResult Recognize(SKBitmap bitmap, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(bitmap);
        cancellationToken.ThrowIfCancellationRequested();
        EnsureAvailable();

        var slot = AcquireSlot();
        var acquired = false;
        try
        {
            slot.Gate.Wait(cancellationToken);
            acquired = true;
            ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed), this);

            var recognized = slot.Ocr.DetectAsync(bitmap, RapidOcrOptions.Default, progress: null,
                    cancellationToken: cancellationToken)
                .ConfigureAwait(false).GetAwaiter().GetResult();
            cancellationToken.ThrowIfCancellationRequested();
            var lines = recognized.TextBlocks
                .Where(block => !string.IsNullOrWhiteSpace(block.Text))
                .Select(block => ToLine(block.Text, block.BoxPoints, block.CharScores, bitmap.Width, bitmap.Height))
                .ToArray();
            var orderedLines = OcrTextLayout.ReadingOrder(lines);
            var text = OcrTextLayout.JoinText(orderedLines);
            var coverage = CaptureClassifier.Classify(lines, bitmap.Width, bitmap.Height).Metrics.TextCoverage;
            return new OcrResult(text, orderedLines, coverage, bitmap.Width, bitmap.Height);
        }
        finally
        {
            if (acquired)
            {
                slot.Gate.Release();
            }

            ReleaseSlot(slot);
        }
    }

    public void Dispose()
    {
        ModelSlot? slot;
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }

            Volatile.Write(ref _disposed, true);
            _evictionTimer.Dispose();
            while (_loadedModel is { Leases: > 0 })
            {
                Monitor.Wait(_gate);
            }

            slot = _loadedModel;
            _loadedModel = null;
        }

        if (slot is not null)
        {
            slot.Ocr.Dispose();
            slot.Gate.Dispose();
        }
    }

    private ModelSlot AcquireSlot()
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            var slot = _loadedModel ??= CreateSlot();
            slot.Leases++;
            return slot;
        }
    }

    private void ReleaseSlot(ModelSlot slot)
    {
        lock (_gate)
        {
            slot.LastUsedTimestamp = Stopwatch.GetTimestamp();
            slot.Leases--;
            Monitor.PulseAll(_gate);
        }
    }

    private ModelSlot CreateSlot()
    {
        var detectorPath = Path.Combine(ModelDirectory, DetectorFile);
        var classifierPath = Path.Combine(ModelDirectory, ClassifierFile);
        var recognizerPath = Path.Combine(ModelDirectory, RecognizerFile);
        var dictionaryPath = Path.Combine(ModelDirectory, DictionaryFile);
        var ocr = new RapidOcr();
        try
        {
            // Default thread count (ONNX Runtime picks per physical core), matching the measured spike; forcing
            // logical-core threads oversubscribed small CI runners.
            ocr.InitModels(detectorPath, classifierPath, recognizerPath, dictionaryPath);
            return new ModelSlot(ocr, Stopwatch.GetTimestamp());
        }
        catch
        {
            ocr.Dispose();
            throw;
        }
    }

    private void EvictIdleModels(object? state)
    {
        ModelSlot? expired = null;
        lock (_gate)
        {
            if (_disposed || _loadedModel is not { } slot)
            {
                return;
            }

            var now = Stopwatch.GetTimestamp();
            if (slot.Leases == 0 && Stopwatch.GetElapsedTime(slot.LastUsedTimestamp, now) >= IdleLifetime)
            {
                _loadedModel = null;
                expired = slot;
            }
        }

        if (expired is not null)
        {
            expired.Ocr.Dispose();
            expired.Gate.Dispose();
        }
    }

    private void EnsureAvailable()
    {
        if (!IsAvailable)
        {
            throw new OcrModelsMissingException(MissingModelReason);
        }
    }

    private IReadOnlyList<string> GetMissingModelFiles()
    {
        var missing = new List<string>();
        var files = new[]
        {
            Path.Combine(ModelDirectory, DetectorFile),
            Path.Combine(ModelDirectory, ClassifierFile),
            Path.Combine(ModelDirectory, RecognizerFile),
            Path.Combine(ModelDirectory, DictionaryFile)
        };
        foreach (var path in files)
        {
            if (!File.Exists(path))
            {
                missing.Add(Path.GetFileName(path));
            }
        }

        return missing;
    }

    private OcrLine ToLine(string text, IReadOnlyList<SKPointI> points, IReadOnlyList<float>? charScores,
        int imageWidth, int imageHeight)
    {
        if (points.Count == 0)
        {
            return new OcrLine(text, 0, 0, 0, 0, 0);
        }

        double minPixelX = points.Min(point => point.X);
        double maxPixelX = points.Max(point => point.X);
        double minPixelY = points.Min(point => point.Y);
        double maxPixelY = points.Max(point => point.Y);
        // The detector dilates boxes by UnClipRatio; Vision returns glyph-tight boxes, so undo the dilation
        // to keep the geometry-only classifier coverage comparable.
        var inset = UnclipInset(maxPixelX - minPixelX, maxPixelY - minPixelY);
        minPixelX += inset;
        maxPixelX -= inset;
        minPixelY += inset;
        maxPixelY -= inset;
        var confidence = charScores is { Count: > 0 } ? charScores.Average() : 0;
        return new OcrLine(text,
            minPixelX / imageWidth,
            1.0 - maxPixelY / imageHeight,
            maxPixelX / imageWidth,
            1.0 - minPixelY / imageHeight,
            confidence);
    }

    /// <summary>Per-side inset that inverts the detector's DB unclip (distance = area * ratio / perimeter).</summary>
    private static double UnclipInset(double width, double height)
    {
        var ratio = RapidOcrOptions.Default.UnClipRatio;
        var distance = 0.0;
        for (var i = 0; i < 24; i++)
        {
            var w = Math.Max(1.0, width - 2 * distance);
            var h = Math.Max(1.0, height - 2 * distance);
            distance = w * h * ratio / (2 * (w + h));
        }

        return Math.Min(distance, Math.Max(0, Math.Min(width, height) / 2 - 0.5));
    }

    private sealed class ModelSlot(RapidOcr ocr, long lastUsedTimestamp)
    {
        public RapidOcr Ocr { get; } = ocr;
        public SemaphoreSlim Gate { get; } = new(1, 1);
        public long LastUsedTimestamp { get; set; } = lastUsedTimestamp;
        public int Leases { get; set; }
    }
}
