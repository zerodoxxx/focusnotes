using CaptureApp.Core;
using Microsoft.Win32;

namespace CaptureApp.Platform.Shell;

/// <summary>Manages the per-user Run value used by Start at login.</summary>
public sealed class LoginItem
{
    public const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";

    private readonly string _valueName;
    private readonly string _executablePath;

    public LoginItem() : this(AppInfo.Name, Environment.ProcessPath ?? throw new InvalidOperationException("The current process has no executable path."))
    {
    }

    public LoginItem(string valueName, string executablePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(valueName);
        ArgumentException.ThrowIfNullOrWhiteSpace(executablePath);
        _valueName = valueName;
        _executablePath = Path.GetFullPath(executablePath);
    }

    public string? RegisteredCommand
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: false);
            return key?.GetValue(_valueName, null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
        }
    }

    public bool IsEnabled => RegisteredCommand is not null;

    public void SetEnabled(bool enabled)
    {
        using var key = enabled
            ? Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true)
            : Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true);

        if (!enabled)
        {
            key?.DeleteValue(_valueName, throwOnMissingValue: false);
            return;
        }

        if (key is null)
        {
            throw new InvalidOperationException("Could not open the per-user Run registry key.");
        }

        var quotedPath = QuoteExecutablePath(_executablePath);
        key.SetValue(_valueName, quotedPath, RegistryValueKind.String);
    }

    public static string QuoteExecutablePath(string executablePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(executablePath);
        if (executablePath.Contains('"'))
        {
            throw new ArgumentException("Executable paths cannot contain a quote character.", nameof(executablePath));
        }

        var fullPath = Path.GetFullPath(executablePath);
        var quotedPath = $"\"{fullPath}\"";
        if (quotedPath.Length > 260)
        {
            throw new ArgumentException("The quoted executable path must be no longer than 260 characters.", nameof(executablePath));
        }

        return quotedPath;
    }
}
