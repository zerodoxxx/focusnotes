using CaptureApp.Core;
using Xunit;

namespace CaptureApp.Core.Tests;

public sealed class NoteFileReplaceTests
{
    private static string Recovered(string dir, string name = "note.md") =>
        Path.Combine(dir, NoteFile.RecoveredName(".pending-" + new string('a', 32), name));

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
        NoteFile.ReplaceFile(temporary, target, ref lost, replace, move);
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
        if (!targetPresent) { File.Delete(target); }
        NoteFile.CleanupTemporary(temporary, target, replaced, targetLost);
        var recovered = Recovered(dir);
        Assert.False(File.Exists(temporary));
        Assert.Equal(kept, File.Exists(recovered));
        if (kept) { Assert.Equal("new", File.ReadAllText(recovered)); }
    }

    [Fact]
    public void TargetRecreatedDuringFallbackStillKeepsTheTemporary()
    {
        using var e = new CheckVault();
        var (dir, target, temporary) = ReplaceSetup(e);
        var lost = false;
        Assert.Throws<IOException>(() => NoteFile.ReplaceFile(temporary, target, ref lost,
            (_, d) => { File.Delete(d); throw Lost(); },
            (_, d) => { File.WriteAllText(d, "other"); throw new IOException("exists"); }));
        Assert.True(lost);
        NoteFile.CleanupTemporary(temporary, target, true, lost);
        Assert.Equal("new", File.ReadAllText(Recovered(dir)));
        Assert.Equal("other", File.ReadAllText(target));
    }

    [Fact]
    public void SweepLeavesOldRecoveredFilesAlone()
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
    public void AtomicWriteRestoresTheRecoveredCopyBeforeTheNextWrite()
    {
        using var e = new CheckVault();
        var path = LoseTarget(e);
        // A create-only write must find the restored note rather than make a new one.
        Assert.Throws<IOException>(() => NoteFile.AtomicWrite("other"u8.ToArray(), e.Vault.Root, "note.md", overwrite: false));
        Assert.Equal("new", File.ReadAllText(path));
        Assert.Empty(Directory.EnumerateFiles(e.Vault.Root, ".recovered-*"));
    }

    [Fact]
    public void SweepRestoresRecoveredCopyOnlyWhenTargetIsMissing()
    {
        using var e = new CheckVault();
        var path = LoseTarget(e);
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
