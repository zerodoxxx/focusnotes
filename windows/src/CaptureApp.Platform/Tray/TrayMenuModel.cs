namespace CaptureApp.Platform.Tray;

/// <summary>Platform-neutral description of a tray menu item.</summary>
public sealed record TrayMenuItem(
    string Id,
    string Title,
    string ShortcutText = "",
    bool Enabled = true,
    bool Checked = false,
    IReadOnlyList<TrayMenuItem>? Children = null,
    bool IsSeparator = false)
{
    public static TrayMenuItem Separator() => new(string.Empty, string.Empty, IsSeparator: true);
}

/// <summary>Menu content is supplied by the App layer; the tray host only renders and dispatches item ids.</summary>
public sealed class TrayMenuModel
{
    public TrayMenuModel(IEnumerable<TrayMenuItem> items)
    {
        ArgumentNullException.ThrowIfNull(items);
        Items = items.ToArray();
        ValidateItems(Items, new HashSet<string>(StringComparer.Ordinal));
    }

    public IReadOnlyList<TrayMenuItem> Items { get; }

    private static void ValidateItems(IReadOnlyList<TrayMenuItem> items, HashSet<string> ids)
    {
        foreach (var item in items)
        {
            ArgumentNullException.ThrowIfNull(item);
            if (item.IsSeparator)
            {
                continue;
            }

            ArgumentException.ThrowIfNullOrWhiteSpace(item.Id);
            ArgumentNullException.ThrowIfNull(item.Title);
            if (!ids.Add(item.Id))
            {
                throw new ArgumentException($"Tray menu item ids must be unique: '{item.Id}'.", nameof(items));
            }

            if (item.Children is { Count: > 0 })
            {
                ValidateItems(item.Children, ids);
            }
        }
    }
}

public sealed record TrayIconAssets(string Light, string Dark, string AttentionLight, string AttentionDark)
{
    public static TrayIconAssets FromDirectory(string directory) => new(
        Path.Combine(directory, "tray-light.ico"),
        Path.Combine(directory, "tray-dark.ico"),
        Path.Combine(directory, "tray-attention-light.ico"),
        Path.Combine(directory, "tray-attention-dark.ico"));

    public static TrayIconAssets FindDefault()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
        {
            foreach (var assetDirectory in new[]
                     {
                         Path.Combine(directory.FullName, "Assets"),
                         Path.Combine(directory.FullName, "windows", "src", "CaptureApp.Platform", "Assets"),
                         Path.Combine(directory.FullName, "src", "CaptureApp.Platform", "Assets")
                     })
            {
                var candidate = FromDirectory(assetDirectory);
                if (File.Exists(candidate.Light))
                {
                    return candidate;
                }
            }
        }

        throw new FileNotFoundException("Tray icon files were not found. Pass TrayIconAssets.FromDirectory(...) when creating the tray host.");
    }
}
