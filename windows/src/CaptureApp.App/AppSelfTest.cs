using System.IO;
using System.Runtime.InteropServices;
using CaptureApp.AppCore;
using CaptureApp.AppCore.Shell;
using CaptureApp.Embed;
using CaptureApp.Platform.Hotkeys;
using CaptureApp.Platform.Ocr;
using CaptureApp.Platform.Tray;
using SkiaSharp;
using Velopack;
using Velopack.Locators;

namespace CaptureApp.App;

/// The platform sections of --self-test: menu, architecture, helper background status, OCR and semantic embedding.
/// The controller sections (staging, journaling, sessions, notes, shutdown) run in AppCore.Shell.ControllerSelfTest.
internal static class AppSelfTest
{
    public static async Task RunAsync(SelfTestContext context)
    {
        var output = context.Output;
        Menu();
        await output.WriteLineAsync("PASS  tray menu model and shortcut texts").ConfigureAwait(false);
        await Architecture(output).ConfigureAwait(false);
        await HelperStatus(output, context.CancellationToken).ConfigureAwait(false);
        await Ocr(output, context.CancellationToken).ConfigureAwait(false);
        await Semantic(context).ConfigureAwait(false);
    }

    private static void Menu()
    {
        var bindings = new Dictionary<string, string>
        {
            [MenuIds.CaptureSelection] = HotkeyDefaults.For(HotkeyAction.CaptureSelection).DisplayString,
            [MenuIds.CaptureArea] = HotkeyDefaults.For(HotkeyAction.CaptureArea).DisplayString,
            [MenuIds.CaptureSelectionOutsideSession] = HotkeyDefaults.For(HotkeyAction.CaptureSelectionOutsideSession).DisplayString,
            [MenuIds.CaptureAreaOutsideSession] = HotkeyDefaults.For(HotkeyAction.CaptureAreaOutsideSession).DisplayString,
            [MenuIds.Search] = HotkeyDefaults.For(HotkeyAction.SearchNotes).DisplayString,
            [MenuIds.Session] = HotkeyDefaults.For(HotkeyAction.ToggleSession).DisplayString,
            [MenuIds.WriteNote] = HotkeyDefaults.For(HotkeyAction.WriteNote).DisplayString,
            [MenuIds.AddSubheading] = HotkeyDefaults.For(HotkeyAction.AddSubheading).DisplayString,
            [MenuIds.OpenFolder] = HotkeyDefaults.For(HotkeyAction.OpenNotesFolder).DisplayString
        };
        var entries = TrayMenuBuilder.Build(new MenuState(true, 0, null, bindings, 0, new(SemanticMenuPhase.NotInstalled), new(UpdateMenuKind.Idle)));
        _ = new TrayMenuModel(entries.Select(Convert));
        if (bindings.Values.Any(string.IsNullOrEmpty) || entries.Count(e => e.Shortcut.Length > 0) != bindings.Count)
        {
            throw new InvalidOperationException("The tray menu did not show all command shortcut texts.");
        }
    }

    private static TrayMenuItem Convert(MenuEntry entry) => entry.IsSeparator
        ? TrayMenuItem.Separator()
        : new TrayMenuItem(entry.Id, entry.Title, entry.Shortcut, entry.Enabled, entry.Checked, entry.Children?.Select(Convert).ToArray());

    private static async Task Architecture(TextWriter output)
    {
        var architecture = RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant();
        var runtime = RuntimeInformation.RuntimeIdentifier;
        // A published self-contained build names its RID; CI asserts it equals the job's architecture.
        if (!runtime.EndsWith(architecture, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException($"The process architecture {architecture} does not match the runtime identifier {runtime}.");
        }

        string channel;
        try { channel = VelopackLocator.Current?.Channel ?? "not installed"; }
        catch (Exception) { channel = "not installed"; }
        var expectedChannel = "win-" + architecture;
        if (channel != "not installed" && !string.Equals(channel, expectedChannel, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException($"The installed channel {channel} does not match {expectedChannel}.");
        }

        await output.WriteLineAsync($"PASS  architecture {architecture} (runtime {runtime}), channel {channel}").ConfigureAwait(false);
    }

    private static async Task HelperStatus(TextWriter output, CancellationToken token)
    {
        var helper = AppController.HelperPath();
        if (!File.Exists(helper))
        {
            throw new FileNotFoundException("The embedding helper was not found next to the app.", helper);
        }

        await using var client = new EmbedClient(helper, Path.Combine(Path.GetTempPath(), "captureapp-selftest-models"));
        var status = await client.StatusAsync(token).ConfigureAwait(false);
        if (status.EcoQos != true || status.BelowNormal != true || status.BackgroundMode != true)
        {
            throw new InvalidOperationException(
                $"The helper did not apply background mode (EcoQoS={status.EcoQos}, below normal={status.BelowNormal}, background={status.BackgroundMode}).");
        }

        await output.WriteLineAsync("PASS  helper runs with EcoQoS, below-normal priority and background mode").ConfigureAwait(false);
    }

    private static async Task Ocr(TextWriter output, CancellationToken token)
    {
        using var engine = new RapidOcrEngine();
        if (!engine.IsAvailable)
        {
            if (Environment.GetEnvironmentVariable("CAPTUREAPP_REQUIRE_OCR_MODELS") == "1") { throw new InvalidOperationException(engine.MissingModelReason); }
            await output.WriteLineAsync("SKIPPED  OCR (models not installed)").ConfigureAwait(false);
            return;
        }

        var png = DemoPng();
        var result = engine.Recognize(png, token);
        var decision = CaptureClassifier.Classify(result).Decision;
        if (!result.Text.Contains("demoimagekeyword", StringComparison.OrdinalIgnoreCase) || decision != CaptureDecision.Image)
        {
            throw new InvalidOperationException($"OCR or classification of the sparse diagram failed (decision {decision}, text '{result.Text}').");
        }

        await output.WriteLineAsync("PASS  OCR read the demo image and classified it as an image").ConfigureAwait(false);
    }

    /// A sparse diagram with one label, like the Mac's AppMedia.demoPNG.
    private static byte[] DemoPng()
    {
        using var bitmap = new SKBitmap(640, 360);
        using var canvas = new SKCanvas(bitmap);
        canvas.Clear(SKColors.White);
        using var stroke = new SKPaint { Color = new SKColor(51, 51, 51), Style = SKPaintStyle.Stroke, StrokeWidth = 4, IsAntialias = true };
        canvas.DrawRect(40, 140, 180, 160, stroke);
        canvas.DrawRect(420, 140, 180, 160, stroke);
        canvas.DrawLine(220, 220, 420, 220, stroke);
        using var font = new SKFont(SKTypeface.FromFamilyName("Arial"), 32);
        using var text = new SKPaint { Color = SKColors.Black, IsAntialias = true };
        canvas.DrawText("demoimagekeyword", 120, 80, font, text);
        using var image = SKImage.FromBitmap(bitmap);
        using var data = image.Encode(SKEncodedImageFormat.Png, 100);
        return data.ToArray();
    }

    private static async Task Semantic(SelfTestContext context)
    {
        if (context.ModelsDirectory is not { } models || !AppController.ModelsInstalled(models))
        {
            if (Environment.GetEnvironmentVariable("CAPTUREAPP_REQUIRE_MODELS") == "1") { throw new InvalidOperationException("Semantic models are required but not installed."); }
            await context.Output.WriteLineAsync("SKIPPED  semantic embedding (models not installed)").ConfigureAwait(false);
            return;
        }

        await using var client = new EmbedClient(AppController.HelperPath(), models);
        var query = await client.EmbedQueryAsync("throttling API traffic", context.CancellationToken).ConfigureAwait(false);
        var documents = await client.EmbedDocumentsAsync(["Token buckets allow bursts", "A recipe for lentil soup"], null, context.CancellationToken).ConfigureAwait(false);
        float Dot(float[] a, float[] b) => a.Zip(b, (x, y) => x * y).Sum();
        if (query.Length != 256 || documents.Count != 2 || Dot(query, documents[0]) <= Dot(query, documents[1]))
        {
            throw new InvalidOperationException("Semantic embedding did not rank the related document first.");
        }

        await context.Output.WriteLineAsync("PASS  semantic embedding ranked the related document first").ConfigureAwait(false);
    }
}
