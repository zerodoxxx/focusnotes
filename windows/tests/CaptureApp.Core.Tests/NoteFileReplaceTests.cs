using CaptureApp.Core;
using Xunit;

namespace CaptureApp.Core.Tests;

public sealed class NoteFileReplaceTests
{
    private static string Recovered(string dir, string name = "note.md", char id = 'a') =>
        Path.Combine(dir, NoteFile.RecoveredName(".pending-" + new string(id, 32), name));

    private static string Plain(string dir, char id = 'a') =>
        Path.Combine(dir, NoteFile.RecoveredName(".pending-" + new string(id, 32), null));

    // Puts a different file at path; writing it before the old one goes away keeps the inode from being reused.
    private static void Swap(string path, string contents)
    {
        File.WriteAllText(path + ".swap", contents);
        File.Move(path + ".swap", path, true);
    }

    private static IOException Lost() => new("1176") { HResult = unchecked((int)0x80070498) };

    private static (string Dir, string Target, string Temporary) ReplaceSetup(CheckVault e)
    {
        var dir = Directory.CreateDirectory(Path.Combine(e.Base, "replace")).FullName;
        var target = Path.Combine(dir, "note.md");
        var temporary = Path.Combine(dir, ".pending-" + new string('a', 32));
        File.WriteAllText(target, "old");
        File.WriteAllText(temporary, "new");
        return (dir, target, temporary);
    }

    private static void Replace(string temporary, string target, Action<string, string>? replace = null, Action<string, string>? move = null)
    {
        var lost = false;
        NoteFile.ReplaceFile(temporary, target, FileMetadata.At(target)!, ref lost, replace, move);
    }

    [Fact]
    public void ReplaceFallbackMovesTemporaryIntoPlaceWhenTargetWasRemoved()
    {
        using var e = new CheckVault();
        var (_, target, temporary) = ReplaceSetup(e);
        Replace(temporary, target, (_, d) => { File.Delete(d); throw Lost(); });
        Assert.Equal("new", File.ReadAllText(target));
        Assert.False(File.Exists(temporary));
    }

    [Fact]
    public void OtherReplaceErrorsWithTargetMissingAreRethrownWithoutMoving()
    {
        using var e = new CheckVault();
        var (_, target, temporary) = ReplaceSetup(e);
        var moves = 0;
        Assert.Throws<IOException>(() => Replace(temporary, target,
            (_, d) => { File.Delete(d); throw new IOException("other"); }, (_, _) => moves++));
        Assert.Equal(0, moves);
        Assert.True(File.Exists(temporary));
    }

    [Fact]
    public void FinalMoveFailureSurfacesTheOriginalReplaceException()
    {
        using var e = new CheckVault();
        var (_, target, temporary) = ReplaceSetup(e);
        var original = Lost();
        var thrown = Assert.Throws<IOException>(() => Replace(temporary, target,
            (_, d) => { File.Delete(d); throw original; }, (_, _) => throw new IOException("locked")));
        Assert.Same(original, thrown);
    }

    [Fact]
    public void UnauthorizedMoveFailuresRetryAndStillSurfaceTheOriginalException()
    {
        using var e = new CheckVault();
        var (_, target, temporary) = ReplaceSetup(e);
        var original = Lost();
        var moves = 0;
        var thrown = Assert.Throws<IOException>(() => Replace(temporary, target,
            (_, d) => { File.Delete(d); throw original; }, (_, _) => { moves++; throw new UnauthorizedAccessException(); }));
        Assert.Same(original, thrown);
        Assert.Equal(3, moves);
        Assert.True(File.Exists(temporary));
    }

    [Theory]
    [InlineData(true, false, false, true)]
    [InlineData(true, true, false, false)]
    [InlineData(false, false, false, false)]
    [InlineData(true, true, true, true)]
    public void CleanupTemporaryKeepsOnlyTheLastCopy(bool replaced, bool targetPresent, bool targetLost, bool kept)
    {
        using var e = new CheckVault();
        var (dir, target, temporary) = ReplaceSetup(e);
        var before = FileMetadata.At(target)!;
        if (!targetPresent) { File.Delete(target); }
        NoteFile.CleanupTemporary(temporary, target, replaced ? before : null, targetLost);
        var recovered = targetLost ? Recovered(dir) : Plain(dir);
        Assert.False(File.Exists(temporary));
        Assert.Equal(kept, File.Exists(recovered));
        if (kept) { Assert.Equal("new", File.ReadAllText(recovered)); }
    }

    [Fact]
    public void TargetRecreatedDuringFallbackStillKeepsTheTemporary()
    {
        using var e = new CheckVault();
        var (dir, target, temporary) = ReplaceSetup(e);
        var before = FileMetadata.At(target)!;
        var lost = false;
        Assert.Throws<IOException>(() => NoteFile.ReplaceFile(temporary, target, before, ref lost,
            (_, d) => { File.Delete(d); throw Lost(); },
            (_, d) => { File.WriteAllText(d, "other"); throw new IOException("exists"); }));
        Assert.True(lost);
        NoteFile.CleanupTemporary(temporary, target, before, lost);
        Assert.Equal("new", File.ReadAllText(Recovered(dir)));
        Assert.Equal("other", File.ReadAllText(target));
    }

    [Fact]
    public void ReplaceTreatsAVisibleTargetThatIsNotTheReplacedFileAsLost()
    {
        // Stands in for a delete-pending name, which File.Exists still reports as present on Windows.
        using var e = new CheckVault();
        var (dir, target, temporary) = ReplaceSetup(e);
        var before = FileMetadata.At(target)!;
        var lost = false;
        Assert.Throws<IOException>(() => NoteFile.ReplaceFile(temporary, target, before, ref lost,
            (_, d) => { Swap(d, "other"); throw Lost(); }));
        Assert.True(lost);
        NoteFile.CleanupTemporary(temporary, target, before, lost);
        Assert.Equal("new", File.ReadAllText(Recovered(dir)));
    }

    [Fact]
    public void CleanupKeepsTheTemporaryWhenTheReplacedFileIsNoLongerAtTheTarget()
    {
        using var e = new CheckVault();
        var (dir, target, temporary) = ReplaceSetup(e);
        var before = FileMetadata.At(target)!;
        Swap(target, "other");
        NoteFile.CleanupTemporary(temporary, target, before, false);
        Assert.Equal("new", File.ReadAllText(Plain(dir)));
        Assert.Equal("other", File.ReadAllText(target));
    }

    [Fact]
    public void CleanupCopiesTheTemporaryWhenRenamingItFails()
    {
        using var e = new CheckVault();
        var (dir, target, temporary) = ReplaceSetup(e);
        var before = FileMetadata.At(target)!;
        File.Delete(target);
        NoteFile.CleanupTemporary(temporary, target, before, true, (_, _) => throw new IOException("locked"));
        Assert.Equal("new", File.ReadAllText(Recovered(dir)));
        NoteFile.SweepStaleTemporaries(e.Base, TimeSpan.Zero);
        Assert.Equal("new", File.ReadAllText(target));
    }

    [Fact]
    public void SweepLeavesRecoveredFileAloneWhenItsTargetExists()
    {
        using var e = new CheckVault();
        var (dir, _, temporary) = ReplaceSetup(e);
        var recovered = Recovered(dir);
        File.Move(temporary, recovered);
        File.SetLastWriteTimeUtc(recovered, DateTime.UtcNow.AddDays(-2));
        NoteFile.SweepStaleTemporaries(e.Base, TimeSpan.FromHours(1));
        Assert.True(File.Exists(recovered));
    }

    [Fact]
    public void ReplaceFailureWithTargetPresentRethrowsAndLeavesTargetUntouched()
    {
        using var e = new CheckVault();
        var (_, target, temporary) = ReplaceSetup(e);
        Assert.Throws<IOException>(() => Replace(temporary, target, (_, _) => throw Lost()));
        Assert.Equal("old", File.ReadAllText(target));
        Assert.True(File.Exists(temporary));
    }

    [Fact]
    public void ReplaceFallbackRetriesThenKeepsTemporaryWhenMoveKeepsFailing()
    {
        using var e = new CheckVault();
        var (_, target, temporary) = ReplaceSetup(e);
        var moves = 0;
        Assert.Throws<IOException>(() => Replace(temporary, target,
            (_, d) => { File.Delete(d); throw Lost(); }, (_, _) => { moves++; throw new IOException("locked"); }));
        Assert.Equal(3, moves);
        Assert.False(File.Exists(target));
        Assert.Equal("new", File.ReadAllText(temporary));
    }

    private sealed class Hooks : IDisposable
    {
        public Hooks()
        {
            NoteFile.ReplaceHook.Value = (_, d) => { File.Delete(d); throw Lost(); };
            NoteFile.MoveHook.Value = (_, _) => throw new IOException("locked");
        }

        public void Dispose() { NoteFile.ReplaceHook.Value = null; NoteFile.MoveHook.Value = null; }
    }

    // Replace fails after removing the target and the fallback move fails: only the ".recovered-" copy remains.
    private static string LoseTarget(CheckVault e, string relative = "note.md")
    {
        e.Vault.Prepare();
        var path = e.Write(relative, "old");
        using (new Hooks())
        {
            Assert.Throws<IOException>(() => NoteFile.AtomicWrite("new"u8.ToArray(), e.Vault.Root, relative));
        }
        Assert.False(File.Exists(path));
        Assert.Equal("new", File.ReadAllText(Assert.Single(Directory.EnumerateFiles(Path.GetDirectoryName(path)!, ".recovered-*"))));
        return path;
    }

    [Fact]
    public void AtomicWriteNeverConsumesTheRecoveredCopyOfARegistry()
    {
        using var e = new CheckVault(registry: true);
        var registry = e.Vault.ExternalNoteRegistry!;
        registry.Register("Desktop/A.md");
        using (new Hooks())
        {
            Assert.Throws<IOException>(() => NoteFile.AtomicWrite("{\"version\":1,\"paths\":[\"Desktop/A.md\"]}"u8.ToArray(), Path.GetDirectoryName(e.Registry)!, "external-notes.json"));
        }
        var kept = Assert.Single(Directory.EnumerateFiles(Path.GetDirectoryName(e.Registry)!, ".recovered-*"));
        var content = File.ReadAllText(kept);
        Assert.False(File.Exists(e.Registry));
        registry.Register("Desktop/B.md");
        // The fresh registry is installed; the old copy is retired under a plain name, content intact.
        Assert.True(File.Exists(e.Registry));
        Assert.NotEqual(content, File.ReadAllText(e.Registry));
        Assert.Equal(content, File.ReadAllText(Assert.Single(Directory.EnumerateFiles(Path.GetDirectoryName(e.Registry)!, ".recovered-*"))));
    }

    [Fact]
    public void AppendRestoresTheRecoveredNoteBeforeWriting()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        e.Write("Note.md", "# Note\n\nbefore\n");
        using (new Hooks())
        {
            Assert.Throws<IOException>(() => NoteFile.AtomicWrite("# Note\n\nkept\n"u8.ToArray(), e.Vault.Root, "Note.md"));
        }
        var path = e.Vault.UrlForRelativePath("Note.md");
        Assert.False(File.Exists(path));
        var capture = CheckVault.Capture("appended");
        e.Writer.Append(capture, path, "Note");
        var text = CheckVault.Read(path);
        Assert.StartsWith("# Note\n\nkept\n", text, StringComparison.Ordinal);
        Assert.EndsWith(CaptureFormat.Block(capture, "", CheckVault.Zone), text, StringComparison.Ordinal);
        Assert.Empty(Directory.EnumerateFiles(e.Vault.Root, ".recovered-*"));
    }

    private static string Hex(string value) => Convert.ToHexStringLower(System.Text.Encoding.UTF8.GetBytes(value));

    [Theory]
    [InlineData("../evil.md")]
    [InlineData("..\\evil.md")]
    [InlineData("/tmp/evil.md")]
    [InlineData("C:\\evil.md")]
    [InlineData("sub/evil.md")]
    [InlineData(".hidden.md")]
    [InlineData(".pending-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")]
    [InlineData("..")]
    [InlineData("a:b.md")]
    [InlineData("nul\0.md")]
    public void SweepIgnoresRecoveredNamesThatEncodeUnsafeTargets(string decoded) => SweepLeaves(Hex(decoded));

    [Theory]
    [InlineData("abc")]
    [InlineData("zz")]
    [InlineData("")]
    [InlineData("ff")]
    public void SweepIgnoresMalformedRecoveredNames(string suffix) => SweepLeaves(suffix);

    [Fact]
    public void SweepIgnoresOverlongRecoveredNames() => SweepLeaves(new string('6', 202));

    private static void SweepLeaves(string suffix)
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var dir = Directory.CreateDirectory(Path.Combine(e.Vault.Root, "sub")).FullName;
        var kept = Path.Combine(dir, ".recovered-" + new string('a', 32) + "-" + suffix);
        File.WriteAllText(kept, "data");
        var before = Directory.EnumerateFileSystemEntries(e.Base, "*", SearchOption.AllDirectories).Order().ToArray();
        NoteFile.SweepStaleTemporaries(e.Vault.Root, TimeSpan.FromHours(1));
        Assert.Equal("data", File.ReadAllText(kept));
        Assert.Equal(before, Directory.EnumerateFileSystemEntries(e.Base, "*", SearchOption.AllDirectories).Order().ToArray());
    }

    [Fact]
    public void FailedRestoreOfTheNewestCopyKeepsEverythingAndSkipsOlderOnes()
    {
        using var e = new CheckVault();
        // Not the vault root, so the vault's background startup sweep cannot race this test.
        var root = Directory.CreateDirectory(Path.Combine(e.Base, "isolated")).FullName;
        var older = Recovered(root, "note.md", 'a');
        var newer = Recovered(root, "note.md", 'b');
        File.WriteAllText(older, "older");
        File.WriteAllText(newer, "newer");
        File.SetLastWriteTimeUtc(older, DateTime.UtcNow.AddMinutes(-5));
        NoteFile.MoveHook.Value = (_, _) => throw new IOException("locked");
        try { NoteFile.RestoreRecovered(root, Path.Combine(root, "note.md")); }
        finally { NoteFile.MoveHook.Value = null; }
        Assert.False(File.Exists(Path.Combine(root, "note.md")));
        Assert.Equal("older", File.ReadAllText(older));
        Assert.Equal("newer", File.ReadAllText(newer));
    }

    [Fact]
    public void RestoreSkipsRecoveredSymbolicLinks()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var real = Path.Combine(e.Base, "real.txt");
        File.WriteAllText(real, "linked");
        var link = Recovered(e.Vault.Root);
        try { File.CreateSymbolicLink(link, real); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or PlatformNotSupportedException) { return; }
        NoteFile.RestoreRecovered(e.Vault.Root, Path.Combine(e.Vault.Root, "note.md"));
        Assert.False(File.Exists(Path.Combine(e.Vault.Root, "note.md")));
        Assert.NotNull(new FileInfo(link).LinkTarget);
        Assert.Equal("linked", File.ReadAllText(real));
    }

    [Fact]
    public void InstallingAFreshTargetRetiresRestorableCopies()
    {
        using var e = new CheckVault();
        var path = LoseTarget(e);
        var kept = Assert.Single(Directory.EnumerateFiles(e.Vault.Root, ".recovered-*"));
        var id = Path.GetFileName(kept)[".recovered-".Length..][..32];
        NoteFile.Create("fresh"u8.ToArray(), e.Vault.Root, "note.md");
        Assert.Equal("fresh", File.ReadAllText(path));
        File.Delete(path);
        NoteFile.SweepStaleTemporaries(e.Vault.Root, TimeSpan.FromHours(1));
        Assert.False(File.Exists(path));
        Assert.Equal("new", File.ReadAllText(Path.Combine(e.Vault.Root, ".recovered-" + id)));
    }

    [Fact]
    public void RestoreTakesTheNewestCopyAndKeepsOlderOnesUnderPlainNames()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var older = Recovered(e.Vault.Root, "note.md", 'a');
        var newer = Recovered(e.Vault.Root, "note.md", 'b');
        File.WriteAllText(older, "older");
        File.WriteAllText(newer, "newer");
        File.SetLastWriteTimeUtc(older, DateTime.UtcNow.AddMinutes(-5));
        NoteFile.SweepStaleTemporaries(e.Vault.Root, TimeSpan.FromHours(1));
        Assert.Equal("newer", File.ReadAllText(Path.Combine(e.Vault.Root, "note.md")));
        Assert.False(File.Exists(newer));
        Assert.False(File.Exists(older));
        Assert.Equal("older", File.ReadAllText(Plain(e.Vault.Root, 'a')));
    }

    [Fact]
    public void SweepRestoresRecoveredCopyOnlyWhenTargetIsMissing()
    {
        using var e = new CheckVault();
        var path = LoseTarget(e);
        Assert.False(File.Exists(path));
        var other = e.Write("keep.md", "user");
        File.WriteAllText(Recovered(e.Vault.Root, "keep.md"), "stale");
        NoteFile.SweepStaleTemporaries(e.Vault.Root, TimeSpan.FromHours(1));
        Assert.Equal("new", File.ReadAllText(path));
        Assert.Equal("user", File.ReadAllText(other));
        Assert.True(File.Exists(Recovered(e.Vault.Root, "keep.md")));
    }

    [Fact]
    public void SessionRenameHoldingTheIntentIsRecoveredFromTheKeptCopy()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        e.Write(Candidate.NotePath, "# Standup\nbody\n");
        SessionRenamePlan? intent = null;
        using (new Hooks())
        {
            Assert.IsType<SessionRenamePendingException>(Record.Exception(() =>
                e.Service.RenameSession(Candidate, "Daily sync", plan => intent = plan)));
        }
        Assert.NotNull(intent);
        var target = e.Vault.UrlForRelativePath(intent!.Target.NotePath);
        Assert.False(File.Exists(target));
        Assert.Equal(intent.Target, e.Sessions.CompleteRename(intent));
        Assert.Equal("# Daily sync\nbody\n", CheckVault.Read(target));
    }

    private static SessionCandidate Candidate { get; } = new("Standup", "Sessions/archive/Standup.md", CheckVault.Now);
}
