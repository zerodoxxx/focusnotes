using System.Windows.Automation;
using CaptureApp.Platform.Selection;

namespace CaptureApp.Platform.Context;

/// <summary>Best-effort browser address snapshot; never changes focus or reads page content.</summary>
internal static class BrowserAddress
{
    private const int MaxNodes = 192;
    private const int MaxDepth = 10;
    private static readonly Lazy<BoundedWorker> Worker = new(() => new("Browser address UI Automation (MTA)"));

    internal static string? Read(nint window, uint processId, string? executablePath)
    {
        if (window == 0 || processId == 0 || !IsSupportedBrowser(executablePath)) return null;
        try
        {
            // UIA providers can block inside a single COM call. The dedicated worker keeps
            // the hotkey delay bounded and refuses another lookup while one is still running.
            return Worker.Value.RunAsync(() => new AddressResult(ReadOnWorker(window, processId)),
                TimeSpan.FromMilliseconds(150), CancellationToken.None).GetAwaiter().GetResult()?.Url;
        }
        catch (Exception) { return null; }
    }

    internal static bool IsSupportedBrowser(string? executablePath)
    {
        if (string.IsNullOrWhiteSpace(executablePath)) return false;
        var filename = executablePath.Replace('\\', '/').Split('/')[^1];
        return filename.Equals("chrome.exe", StringComparison.OrdinalIgnoreCase)
            || filename.Equals("msedge.exe", StringComparison.OrdinalIgnoreCase);
    }

    private static string? ReadOnWorker(nint window, uint processId)
    {
        try
        {
            var root = AutomationElement.FromHandle(window);
            return root is null ? null : FindAddress(new UiaAddressElement(root), processId);
        }
        catch (Exception) { return null; }
    }

    internal static string? FindAddress(IAddressElement root, uint processId)
    {
        try
        {
            var queue = new Queue<(IAddressElement Element, int Depth, bool InToolbar)>();
            queue.Enqueue((root, 0, false));
            var visited = 0;
            while (queue.Count > 0 && visited < MaxNodes)
            {
                var (element, depth, inToolbar) = queue.Dequeue();
                visited++;
                if (element.ProcessId <= 0 || (uint)element.ProcessId != processId) continue;

                var type = element.ControlType;
                // A web page can contain arbitrary edit fields and labels, including one
                // impersonating the omnibox. Do not enter its accessibility subtree.
                if (type == ControlType.Document) continue;
                if (type == ControlType.Edit && inToolbar &&
                    string.Equals(element.Name, "Address and search bar", StringComparison.Ordinal))
                {
                    // While focused, the omnibox can contain an unsubmitted address or
                    // search query instead of the active page. Never label it as the source.
                    if (element.HasKeyboardFocus) return null;
                    return Validate(element.Value);
                }

                if (depth >= MaxDepth) continue;
                var childInToolbar = inToolbar || type == ControlType.ToolBar;
                foreach (var child in element.Children)
                {
                    if (visited + queue.Count >= MaxNodes) break;
                    queue.Enqueue((child, depth + 1, childInToolbar));
                }
            }
        }
        catch (Exception) { /* Inaccessible, stale, or failed UIA provider: keep the capture. */ }
        return null;
    }

    internal static string? Validate(string? candidate)
    {
        if (string.IsNullOrEmpty(candidate) || candidate.Length > 8192 ||
            candidate.Any(char.IsWhiteSpace) || candidate.Any(char.IsControl)) return null;
        if (!candidate.StartsWith("https://", StringComparison.OrdinalIgnoreCase) &&
            !candidate.StartsWith("http://", StringComparison.OrdinalIgnoreCase)) return null;
        if (!Uri.TryCreate(candidate, UriKind.Absolute, out var uri) ||
            !uri.IsWellFormedOriginalString() || string.IsNullOrEmpty(uri.Host) ||
            !string.IsNullOrEmpty(uri.UserInfo) ||
            (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps)) return null;
        return uri.AbsoluteUri;
    }

    private sealed record AddressResult(string? Url);
}

internal interface IAddressElement
{
    int ProcessId { get; }
    ControlType ControlType { get; }
    string Name { get; }
    bool HasKeyboardFocus { get; }
    string? Value { get; }
    IEnumerable<IAddressElement> Children { get; }
}

internal sealed class UiaAddressElement(AutomationElement element) : IAddressElement
{
    public int ProcessId => element.Current.ProcessId;
    public ControlType ControlType => element.Current.ControlType;
    public string Name => element.Current.Name;
    public bool HasKeyboardFocus => element.Current.HasKeyboardFocus;
    public string? Value => element.TryGetCurrentPattern(ValuePattern.Pattern, out var pattern)
        ? ((ValuePattern)pattern).Current.Value : null;

    public IEnumerable<IAddressElement> Children
    {
        get
        {
            var walker = TreeWalker.ControlViewWalker;
            for (var child = walker.GetFirstChild(element); child is not null; child = walker.GetNextSibling(child))
                yield return new UiaAddressElement(child);
        }
    }
}
