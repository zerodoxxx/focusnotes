using System.Globalization;
using CaptureApp.Core;

namespace CaptureApp.AppCore.Shell;

public enum AppToastStyle { Success, Warning, Session, Copied }

/// A UI-neutral toast; the App maps it onto the Overlay toast.
public sealed record AppToast(AppToastStyle Style, string Title, string? Subtitle = null, string? HintKey = null,
    string? HintLabel = null, double? Duration = null);

/// What the capture coordinator needs from the UI layer. All methods may be called from any thread;
/// implementations marshal to the UI thread.
public interface ICaptureHost
{
    bool PresentsUi { get; }

    /// A transient toast. The coordinator has already committed any pending capture.
    void ShowToast(AppToast toast);

    /// The "Saved to …" toast of a staged capture. When it expires the host calls <see cref="CaptureCoordinator.ToastExpired"/>.
    void ShowStagedToast(AppToast toast);

    void DismissStagedToast();

    bool StagedToastVisible { get; }

    /// The user's current binding for a trigger, shown in the staged toast hint.
    string BindingFor(CaptureTrigger trigger);

    /// The session toggle binding, shown in "Captures go here until …".
    string SessionBinding { get; }

    /// The active session changed (tray text, icon).
    void StatusChanged();
}

/// Builds pending captures the way CapturePipeline.selection/region do on the Mac.
public static class PendingCaptures
{
    private static readonly char[] NewLines = ['\r', '\n', '\u0085', '\u2028', '\u2029'];

    public static PendingCapture Selection(string text, CaptureSource source, Guid? id = null, DateTimeOffset? createdAt = null) =>
        new(id ?? Guid.NewGuid(), createdAt ?? DateTimeOffset.UtcNow, CaptureTrigger.Selection, CaptureContent.Text(text), source, FirstLine(text));

    public static PendingCapture Image(byte[] png, string? ocr, CaptureSource source, string subtitle = "Image",
        Guid? id = null, DateTimeOffset? createdAt = null) =>
        new(id ?? Guid.NewGuid(), createdAt ?? DateTimeOffset.UtcNow, CaptureTrigger.Region, CaptureContent.Image(""), source, subtitle, png, ocr);

    /// First line, cut at 100 characters (99 plus an ellipsis), counted in user-perceived characters.
    public static string FirstLine(string text)
    {
        var line = text.Split(NewLines, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "";
        var info = new StringInfo(line);
        return info.LengthInTextElements > 100 ? info.SubstringByTextElements(0, 99) + "…" : line;
    }
}

public sealed record RegionRecognition(string Text, bool IsText);

/// The 1.5 s classification budget (CapturePipeline.swift:267): OCR over budget keeps the image and finishes in the background.
public static class RegionProcessing
{
    public static readonly TimeSpan Budget = TimeSpan.FromMilliseconds(1500);

    /// <param name="recognize">Runs OCR and the classifier; null when recognition failed.</param>
    /// <param name="registerDeferred">Receives the background OCR result when the budget expires.</param>
    public static async Task<PendingCapture> ProcessAsync(byte[] png, CaptureSource source, Guid id, DateTimeOffset createdAt,
        Func<byte[], RegionRecognition?> recognize, Action<Guid, Task<string?>>? registerDeferred = null,
        TimeSpan? budget = null, Action<string>? log = null)
    {
        var recognition = Task.Run(() =>
        {
            try { return recognize(png); }
            catch (Exception error)
            {
                log?.Invoke($"OCR failed; retaining image: {error.GetType().Name}");
                return null;
            }
        });
        return await ProcessWithBudgetAsync(png, source, id, createdAt, recognition, registerDeferred, budget).ConfigureAwait(false);
    }

    // Async recognition is used by the self-test so a blocked OCR simulation does not occupy a thread-pool worker.
    internal static Task<PendingCapture> ProcessAsync(byte[] png, CaptureSource source, Guid id, DateTimeOffset createdAt,
        Func<byte[], Task<RegionRecognition?>> recognize, Action<Guid, Task<string?>>? registerDeferred = null,
        TimeSpan? budget = null, Action<string>? log = null)
    {
        var recognition = Task.Run(async () =>
        {
            try { return await recognize(png).ConfigureAwait(false); }
            catch (Exception error)
            {
                log?.Invoke($"OCR failed; retaining image: {error.GetType().Name}");
                return null;
            }
        });
        return ProcessWithBudgetAsync(png, source, id, createdAt, recognition, registerDeferred, budget);
    }

    private static async Task<PendingCapture> ProcessWithBudgetAsync(byte[] png, CaptureSource source, Guid id, DateTimeOffset createdAt,
        Task<RegionRecognition?> recognition, Action<Guid, Task<string?>>? registerDeferred, TimeSpan? budget)
    {
        var winner = await Task.WhenAny(recognition, Task.Delay(budget ?? Budget)).ConfigureAwait(false);
        if (!ReferenceEquals(winner, recognition))
        {
            registerDeferred?.Invoke(id, recognition.ContinueWith(task => task.Result?.Text, TaskScheduler.Default));
            return PendingCaptures.Image(png, null, source, "Image", id, createdAt);
        }

        var recognized = await recognition.ConfigureAwait(false);
        var text = recognized?.Text ?? "";
        var preview = PendingCaptures.FirstLine(text);
        if (recognized is { IsText: true })
        {
            return new(id, createdAt, CaptureTrigger.Region, CaptureContent.Text(text), source, $"Text · {preview}");
        }

        return PendingCaptures.Image(png, recognized?.Text, source, preview.Length == 0 ? "Image" : $"Image · {preview}", id, createdAt);
    }
}
