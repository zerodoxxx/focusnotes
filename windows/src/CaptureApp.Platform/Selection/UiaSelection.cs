using System.Runtime.InteropServices;
using System.Windows.Automation;

namespace CaptureApp.Platform.Selection;

internal enum FieldSafety { Safe, Password, Unknown, WrongProcess }
internal sealed record UiaRead(FieldSafety Safety, string? Text = null);

internal static class UiaSelection
{
    private static readonly Lazy<BoundedWorker> Worker = new(() => new("Selection UI Automation (MTA)"));

    internal static async Task<UiaRead> ReadAsync(uint targetPid, bool includeSelection, CancellationToken cancellationToken)
    {
        var result = await Worker.Value.RunAsync(() => Read(targetPid, includeSelection),
            TimeSpan.FromMilliseconds(200), cancellationToken).ConfigureAwait(false);
        // A timeout supplies no selection. Unknown password state fails closed at the caller's safety checkpoints.
        return result ?? new(FieldSafety.Unknown);
    }

    private static UiaRead Read(uint targetPid, bool includeSelection)
    {
        try
        {
            var element = AutomationElement.FocusedElement;
            if (element is null) return new(FieldSafety.Unknown);
            if ((uint)element.Current.ProcessId != targetPid) return new(FieldSafety.WrongProcess);
            if (element.Current.IsPassword) return new(FieldSafety.Password);
            if (!includeSelection || !element.TryGetCurrentPattern(TextPattern.Pattern, out var value)) return new(FieldSafety.Safe);
            var ranges = ((TextPattern)value).GetSelection();
            return new(FieldSafety.Safe, string.Concat(ranges.Select(range => range.GetText(-1))));
        }
        catch (Exception ex) when (ex is ElementNotAvailableException or InvalidOperationException or COMException or UnauthorizedAccessException)
        { return new(FieldSafety.Unknown); }
    }
}
