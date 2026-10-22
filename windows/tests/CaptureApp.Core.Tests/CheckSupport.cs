using System.Globalization;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json;
using CaptureApp.Core;
using Xunit;
using Microsoft.Win32.SafeHandles;

namespace CaptureApp.Core.Tests;

internal sealed class FixedTimeProvider(DateTimeOffset now) : TimeProvider
{
    public override DateTimeOffset GetUtcNow() => now;
}

internal sealed class CheckVault : IDisposable
{
    internal static TimeZoneInfo Zone => TimeZoneInfo.FindSystemTimeZoneById("Asia/Kolkata");
    internal static DateTimeOffset Now => DateTimeOffset.Parse("2026-10-13T09:00:00Z", CultureInfo.InvariantCulture);
    internal static TimeProvider Clock => new FixedTimeProvider(Now);
    internal string Base { get; }
    internal string Home => Path.Combine(Base, "Home");
    internal string State => Path.Combine(Base, "State");
    internal string Registry => Path.Combine(State, "external-notes.json");
    internal Vault Vault { get; }
    internal NoteWriter Writer { get; }
    internal SessionStore Sessions { get; }
    internal CaptureService Service { get; }

    internal CheckVault(bool registry = false, bool windowsRules = false)
    {
        var path = Path.Combine(Path.GetTempPath(), "captureapp-core-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        Base = NoteFile.ResolveSelectedRoot(path);
        Directory.CreateDirectory(Home);
        Vault = new(Path.Combine(Base, "Vault"), registry ? Registry : null, Home, new() { WindowsRules = windowsRules });
        Writer = new(Vault, Zone, Clock);
        Sessions = new(State, Vault, Zone, Clock);
        Service = new(Vault, Sessions, Writer, Clock);
    }

    internal string Write(string relative, string text, bool home = false)
    {
        var path = Path.Combine(home ? Home : Vault.Root, relative.Replace('/', Path.DirectorySeparatorChar));
        WriteAbsolute(path, text);
        return path;
    }

    internal static void WriteAbsolute(string path, string text)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, text, NoteFile.Utf8);
    }

    internal static string Read(string path) => File.ReadAllText(path, NoteFile.Utf8);
    internal static string Marker(Guid id) => "<!-- capture:" + id.ToString("D");
    internal static Capture Capture(string text = "Hello", CaptureContentKind kind = CaptureContentKind.Text, string? source = "Safari", Guid? id = null) => new(id ?? Guid.NewGuid(), Now, new(kind, text), new(source));
    internal static Destination Destination(string path, string title = "Note") => new(path, title, NoteKind.Note);
    internal void WriteRegistry(string text) => WriteAbsolute(Registry, text);
    internal static void AtomicReplace(string path, string text)
    {
        var temporary = path + ".editor-" + Guid.NewGuid().ToString("N");
        File.WriteAllText(temporary, text, NoteFile.Utf8);
        File.Move(temporary, path, true);
    }

    internal static void SymbolicLink(string link, string target, bool directory = false)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(link)!);
        try
        {
            if (directory)
            {
                Directory.CreateSymbolicLink(link, target);
            }
            else
            {
                File.CreateSymbolicLink(link, target);
            }
        }
        catch (IOException error) when (MaySkipMissingSymbolicLinkPrivilege(error, OperatingSystem.IsWindows(),
            Environment.GetEnvironmentVariable("CAPTUREAPP_ALLOW_MISSING_SYMLINK_PRIVILEGE"),
            Environment.GetEnvironmentVariable("CI"), Environment.GetEnvironmentVariable("GITHUB_ACTIONS")))
        {
            Assert.Skip("Windows symbolic-link fixture requires privilege (error 1314); explicitly skipped locally with " +
                "CAPTUREAPP_ALLOW_MISSING_SYMLINK_PRIVILEGE=1. Enable symbolic-link creation to run this safety test.");
        }
    }

    internal static bool MaySkipMissingSymbolicLinkPrivilege(IOException error, bool windows, string? optIn, string? ci, string? githubActions) =>
        windows && error.HResult == unchecked((int)0x80070522) // HRESULT_FROM_WIN32(ERROR_PRIVILEGE_NOT_HELD = 1314)
        && optIn == "1" && string.IsNullOrEmpty(ci) && string.IsNullOrEmpty(githubActions);

    internal static void HardLink(string link, string target)
    {
        var result = OperatingSystem.IsWindows() ? CreateHardLink(link, target, 0) : Link(target, link) == 0;
        Assert.True(result, "Could not create hard-link fixture.");
    }

    internal static void Fifo(string path)
    {
        Assert.False(OperatingSystem.IsWindows());
        Assert.Equal(0, MkFifo(path, 384));
    }

    internal static string NativeRead(string path)
    {
        var fd = Open(path, 0, 0);
        Assert.True(fd >= 0);
        using var output = new MemoryStream();
        var bytes = new byte[65536];
        try
        {
            while (true)
            {
                var count = ReadNative(fd, bytes, (nuint)bytes.Length).ToInt64();
                Assert.True(count >= 0);
                if (count == 0)
                {
                    break;
                }

                output.Write(bytes, 0, (int)count);
            }
        }
        finally
        {
            Close(fd);
        }

        return NoteFile.Utf8.GetString(output.ToArray());
    }

    [DllImport("libc", EntryPoint = "read", SetLastError = true)]
    private static extern nint ReadNative(int fd, byte[] bytes, nuint count);
    internal static void NativeOverwrite(string path, string text)
    {
        // A non-cooperating Unix editor ignores FileShare.None/flock.
        var fd = Open(path, 1 | (OperatingSystem.IsMacOS() ? 0x400 : 0x200), 384);
        Assert.True(fd >= 0);
        var bytes = NoteFile.Utf8.GetBytes(text);
        try
        {
            Assert.Equal(bytes.Length, WriteNative(fd, bytes, (nuint)bytes.Length).ToInt64());
        }
        finally
        {
            Close(fd);
        }
    }

    internal static UnixFileMode GetMode(string path)
    {
        if (OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException();
        }

        return File.GetUnixFileMode(path);
    }

    internal static void SetMode(string path, int mode)
    {
        if (OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException();
        }

        File.SetUnixFileMode(path, (UnixFileMode)mode);
    }

    internal static void RestoreModified(string path, VaultFileSnapshot snapshot)
    {
        var values = new[]
        {
            new NativeTime(),
            new NativeTime
            {
                Seconds = snapshot.ModifiedSeconds,
                Nanoseconds = snapshot.ModifiedNanoseconds
            }
        };
        Assert.Equal(0, UtimensAt(OperatingSystem.IsMacOS() ? -2 : -100, path, values, 0));
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeTime
    {
        internal long Seconds, Nanoseconds;
    }

    [DllImport("libc", EntryPoint = "utimensat")]
    private static extern int UtimensAt(int fd, string path, NativeTime[] values, int flags);
    internal static string Json(object value) => JsonSerializer.Serialize(value);
    public void Dispose()
    {
        if (!OperatingSystem.IsWindows())
        {
            foreach (var path in Directory.EnumerateDirectories(Base, "*", SearchOption.AllDirectories).Prepend(Base))
            {
                if (new DirectoryInfo(path).LinkTarget is null)
                {
                    File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
                }
            }
        }

        Directory.Delete(Base, true);
    }

    [DllImport("kernel32.dll", EntryPoint = "CreateHardLinkW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateHardLink(string name, string existing, nint security);
    [DllImport("libc", EntryPoint = "link", SetLastError = true)]
    private static extern int Link(string existing, string name);
    [DllImport("libc", EntryPoint = "mkfifo", SetLastError = true)]
    private static extern int MkFifo(string path, uint mode);
    [DllImport("libc", EntryPoint = "open", SetLastError = true)]
    private static extern int Open(string path, int flags, int mode);
    [DllImport("libc", EntryPoint = "write", SetLastError = true)]
    private static extern nint WriteNative(int fd, byte[] bytes, nuint count);
    [DllImport("libc", EntryPoint = "close")]
    private static extern int Close(int fd);
}

public sealed class UnixFactAttribute : FactAttribute
{
    public UnixFactAttribute([CallerFilePath] string? sourceFilePath = null, [CallerLineNumber] int sourceLineNumber = 0) : base(sourceFilePath, sourceLineNumber)
    {
        if (OperatingSystem.IsWindows())
        {
            Skip = "Unix file modes and non-cooperating editor semantics.";
        }
    }
}

public sealed class WindowsFactAttribute : FactAttribute
{
    public WindowsFactAttribute([CallerFilePath] string? sourceFilePath = null, [CallerLineNumber] int sourceLineNumber = 0) : base(sourceFilePath, sourceLineNumber)
    {
        if (!OperatingSystem.IsWindows())
        {
            Skip = "Needs Windows";
        }
    }
}
