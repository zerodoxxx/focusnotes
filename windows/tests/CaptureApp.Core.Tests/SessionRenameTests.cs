using System.Security.Cryptography;
using System.Diagnostics;
using CaptureApp.Core;
using CaptureApp.Core.Index;
using Xunit;

namespace CaptureApp.Core.Tests;

public sealed class SessionRenameTests
{
    private static SessionCandidate Candidate(string path = "Sessions/archive/Standup.md", string name = "Standup") => new(name, path, CheckVault.Now);

    [Fact]
    public void RenameUpdatesHeadingAndStateInPlaceAndKeepsRelativeImages()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var original = e.Write(Candidate().NotePath, "# Standup\n\n![screen](../../assets/screen.png)\n\nuntouchedneedle\n");
        e.Write("assets/screen.png", "image bytes");
        using var index = new SearchIndex(e.Vault, Path.Combine(e.Base, "Cache", "search.sqlite"), CheckVault.Zone);
        index.Sync();
        Assert.Contains(index.Search("untouchedneedle"), hit => hit.NotePath == Candidate().NotePath);
        SessionRenamePlan? intent = null;
        var renamed = e.Service.RenameSession(Candidate(), "  Daily   sync  ", plan => intent = plan);
        Assert.Equal("Daily sync", renamed.Name);
        Assert.Equal("Sessions/archive/Daily sync.md", renamed.NotePath);
        Assert.True(renamed.Resumed);
        Assert.False(File.Exists(original));
        var target = e.Vault.UrlForRelativePath(renamed.NotePath);
        Assert.Equal("# Daily sync\n\n![screen](../../assets/screen.png)\n\nuntouchedneedle\n", CheckVault.Read(target));
        Assert.Equal(renamed, e.Sessions.Current());
        Assert.Equal(renamed, new SessionStore(e.State, e.Vault, CheckVault.Zone, CheckVault.Clock).Current());
        Assert.NotNull(intent);
        Assert.Equal(Candidate().NotePath, intent.OldPath);
        Assert.Equal(renamed, intent.Target);
        Assert.Equal(Path.Combine(e.Vault.AssetsUrl, "screen.png"),
            Path.GetFullPath(Path.Combine(Path.GetDirectoryName(target)!, "../../assets/screen.png")));
        index.Sync();
        Assert.DoesNotContain(index.Search("untouchedneedle"), hit => hit.NotePath == Candidate().NotePath);
        Assert.Contains(index.Search("untouchedneedle"), hit => hit.NotePath == renamed.NotePath);
        Assert.Empty(Directory.EnumerateFiles(Path.GetDirectoryName(target)!, ".pending-*"));
    }

    [Theory]
    [InlineData("# Old\nbody\n", "# New\nbody\n")]
    [InlineData("\uFEFF# Old\r\nbody\r\n", "\uFEFF# New\r\nbody\r\n")]
    [InlineData("# Old", "# New")]
    [InlineData("# Old\r", "# New\r")]
    [InlineData("\uFEFF# Old\r", "\uFEFF# New\r")]
    [InlineData("\n# Body heading\n", "# New\n\n\n# Body heading\n")]
    [InlineData("```\n# Example\n```\n", "# New\n\n```\n# Example\n```\n")]
    public void RewritingPreservesBomLineEndingsAndEveryBodyByte(string source, string expected)
    {
        Assert.Equal(NoteFile.Utf8.GetBytes(expected), NoteFile.RewriteHeading(NoteFile.Utf8.GetBytes(source), "New"));
    }

    [Fact]
    public void HeadingRewritePreservesInvalidUtf8AndFindsCrLfBeyondTheFirstLine()
    {
        Assert.Equal(new byte[] { 35, 32, 78, 101, 119, 10, 254 },
            NoteFile.RewriteHeading([35, 32, 255, 10, 254], "New"));
        Assert.Equal(new byte[] { 35, 32, 78, 101, 119, 10, 10, 255, 10, 254 },
            NoteFile.RewriteHeading([255, 10, 254], "New"));
        Assert.Equal(NoteFile.Utf8.GetBytes("# New\r\n\r\nfirst\nlater\r\n"),
            NoteFile.RewriteHeading(NoteFile.Utf8.GetBytes("first\nlater\r\n"), "New"));
        Assert.Equal(NoteFile.Utf8.GetBytes("# New\n\n"), NoteFile.RewriteHeading([], "New"));
        Assert.Equal(NoteFile.Utf8.GetBytes("# New\n\n#body\n"),
            NoteFile.RewriteHeading(NoteFile.Utf8.GetBytes("#body\n"), "New"));
    }

    [Fact]
    public void SamePathRewritesOnlyHeadingAndCaseOnlyRenameIsACollision()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        e.Write("Sessions/A-B.md", "# A:B\n\nbody\n");
        var renamed = e.Service.RenameSession(Candidate("Sessions/A-B.md", "A:B"), "A-B");
        Assert.Equal("Sessions/A-B.md", renamed.NotePath);
        Assert.Equal("# A-B\n\nbody\n", CheckVault.Read(e.Vault.UrlForRelativePath(renamed.NotePath)));
        Assert.Equal(SessionStoreError.CaseOnlyRename,
            Assert.Throws<SessionStoreException>(() => e.Service.RenameSession(Candidate(renamed.NotePath), "a-b")).Kind);
        Assert.Equal(renamed, e.Sessions.Current());
    }

    [Theory]
    [InlineData("Daily sync.md", false)]
    [InlineData("dAiLy SyNc.md", false)]
    [InlineData("Daily sync.md", true)]
    public void ExistingFileOrDirectoryNeverGetsOverwritten(string filename, bool directory)
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var old = e.Write(Candidate().NotePath, "# Standup\noriginal\n");
        var occupied = Path.Combine(Path.GetDirectoryName(old)!, filename);
        if (directory) { Directory.CreateDirectory(occupied); }
        else { File.WriteAllText(occupied, "keep this"); }
        var before = e.Sessions.Start("Other session");
        var failure = Assert.Throws<SessionStoreException>(() => e.Service.RenameSession(Candidate(), "Daily sync"));
        Assert.Equal(SessionStoreError.NameAlreadyExists, failure.Kind);
        Assert.Equal("# Standup\noriginal\n", CheckVault.Read(old));
        if (!directory) { Assert.Equal("keep this", File.ReadAllText(occupied)); }
        Assert.Equal(before, e.Sessions.Current());
    }

    [Theory]
    [InlineData("folder/name")]
    [InlineData("folder\\name")]
    [InlineData("../name")]
    [InlineData("\0name")]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData(".")]
    [InlineData("..")]
    [InlineData("~$draft")]
    [InlineData("CON")]
    [InlineData("nul.txt")]
    [InlineData("trailing.")]
    public void InvalidNamesNeverMoveOrRewriteTheSession(string name)
    {
        using var e = new CheckVault(windowsRules: true);
        e.Vault.Prepare();
        var old = e.Write(Candidate().NotePath, "# Standup\noriginal\n");
        Assert.Throws<NotePathNameException>(() => e.Service.RenameSession(Candidate(), name));
        Assert.Equal("# Standup\noriginal\n", CheckVault.Read(old));
        Assert.Null(e.Sessions.Current());
    }

    [Fact]
    public void LateCollisionAndHeadingReplacementFailureKeepOriginalBytes()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var old = e.Write(Candidate().NotePath, "# Standup\noriginal\n");
        var next = "Sessions/archive/Daily sync.md";
        Assert.Throws<SessionStoreException>(() => NoteFile.RenameSession(e.Vault.Root, Candidate().NotePath, next, "Daily sync",
            (_, _, _) => e.Write(next, "racing file")));
        Assert.Equal("# Standup\noriginal\n", CheckVault.Read(old));
        Assert.Equal("racing file", CheckVault.Read(e.Vault.UrlForRelativePath(next)));
        File.Delete(e.Vault.UrlForRelativePath(next));
        Assert.Throws<IOException>(() => NoteFile.RenameSession(e.Vault.Root, Candidate().NotePath, next, "Daily sync",
            beforeReplace: () => throw new IOException("Injected replace failure")));
        Assert.Equal("# Standup\noriginal\n", CheckVault.Read(old));
        Assert.False(File.Exists(e.Vault.UrlForRelativePath(next)));
        Assert.Empty(Directory.EnumerateFiles(Path.GetDirectoryName(old)!, ".pending-*"));
    }

    [Fact]
    public void FailedStatePersistenceStillRoutesNewCapturesToTheRenamedFile()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var old = e.Write(Candidate().NotePath, "# Standup\noriginal\n");
        Directory.CreateDirectory(e.Sessions.StateFileUrl); // A directory cannot be replaced by session.json.
        Assert.Throws<VaultFileException>(() => e.Service.RenameSession(Candidate(), "Daily sync"));
        var active = Assert.IsType<Session>(e.Sessions.Current());
        Assert.Equal("Sessions/archive/Daily sync.md", active.NotePath);
        Assert.False(File.Exists(old));
        var saved = e.Service.SaveText("captured after persistence failure", new());
        Assert.Equal(e.Vault.UrlForRelativePath(active.NotePath), saved.Destination.Url);
        Assert.False(File.Exists(old));
        Assert.Contains("captured after persistence failure", CheckVault.Read(saved.Destination.Url));
    }

    [Fact]
    public void AReplacedTargetIsNeverOverwrittenOrRolledBackOverAnUnrelatedFile()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        e.Write(Candidate().NotePath, "# Standup\noriginal\n");
        var next = "Sessions/archive/Daily sync.md";
        var target = e.Vault.UrlForRelativePath(next);
        var savedOriginal = target + ".saved";
        Assert.Throws<SessionRenamePendingException>(() => NoteFile.RenameSession(e.Vault.Root, Candidate().NotePath, next, "Daily sync",
            beforeReplace: () =>
            {
                File.Move(target, savedOriginal);
                File.WriteAllText(target, "unrelated target");
                e.Write(Candidate().NotePath, "unrelated old path");
            }));
        Assert.Equal("unrelated target", File.ReadAllText(target));
        Assert.Equal("unrelated old path", CheckVault.Read(e.Vault.UrlForRelativePath(Candidate().NotePath)));
        Assert.Equal("# Standup\noriginal\n", CheckVault.Read(savedOriginal));
    }

    [Fact]
    public void HardLinkedSourceAndLinkedAncestorAreRefused()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var old = e.Write(Candidate().NotePath, "# Standup\noriginal\n");
        var linked = Path.Combine(e.Base, "hardlink.md");
        CheckVault.HardLink(linked, old);
        Assert.Throws<VaultFileException>(() => NoteFile.RenameSession(e.Vault.Root, Candidate().NotePath, "Sessions/archive/New.md", "New"));
        File.Delete(linked);
        var outside = Path.Combine(e.Base, "outside");
        Directory.CreateDirectory(outside);
        File.WriteAllText(Path.Combine(outside, "Standup.md"), "# Outside\n");
        var parent = Path.GetDirectoryName(old)!;
        Directory.Move(parent, parent + ".saved");
        if (OperatingSystem.IsWindows())
        {
            using var process = Process.Start(new ProcessStartInfo("cmd.exe", $"/c mklink /J \"{parent}\" \"{outside}\"") { CreateNoWindow = true })!;
            process.WaitForExit();
            Assert.Equal(0, process.ExitCode);
        }
        else { CheckVault.SymbolicLink(parent, outside, true); }
        try
        {
            Assert.Throws<VaultFileException>(() => NoteFile.RenameSession(e.Vault.Root, Candidate().NotePath, "Sessions/archive/New.md", "New"));
            Assert.Equal("# Outside\n", File.ReadAllText(Path.Combine(outside, "Standup.md")));
            Assert.False(File.Exists(Path.Combine(outside, "New.md")));
        }
        finally { Directory.Delete(parent); }
    }

    [Fact]
    public void PendingIntentRecoversMovedOrAlreadyRewrittenFileAndRejectsUnrelatedTarget()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var old = e.Write(Candidate().NotePath, "# Standup\nbody\n");
        var original = e.Vault.FileSnapshot(Candidate().NotePath)!;
        var target = new Session("Daily sync", "Sessions/archive/Daily sync.md", CheckVault.Now, true);
        var rewritten = NoteFile.RewriteHeading(original.Contents!, target.Name);
        var plan = new SessionRenamePlan(Candidate().NotePath, target, new(original.Device, original.Inode),
            new() { Original = Convert.ToHexString(SHA256.HashData(original.Contents!)), Rewritten = Convert.ToHexString(SHA256.HashData(rewritten)) });
        File.Move(old, e.Vault.UrlForRelativePath(target.NotePath));
        Assert.Equal(target, e.Sessions.CompleteRename(plan));
        Assert.Equal("# Daily sync\nbody\n", CheckVault.Read(e.Vault.UrlForRelativePath(target.NotePath)));
        Assert.Equal(target, e.Sessions.CompleteRename(plan));
        CheckVault.AtomicReplace(e.Vault.UrlForRelativePath(target.NotePath), "# Unrelated\nkeep\n");
        Assert.Throws<VaultFileException>(() => e.Sessions.CompleteRename(plan));
        Assert.Equal("# Unrelated\nkeep\n", CheckVault.Read(e.Vault.UrlForRelativePath(target.NotePath)));
    }

    [Fact]
    public void PendingIntentInstallsRecoveredSibling()
    {
        var (e, plan, staged, target) = Staged(true);
        using var _ = e;
        Assert.Equal(target, e.Sessions.CompleteRename(plan));
        Assert.Equal("# Daily sync\nbody\n", CheckVault.Read(e.Vault.UrlForRelativePath(target.NotePath)));
        Assert.Empty(Directory.EnumerateFiles(Path.GetDirectoryName(staged)!, ".*-*"));
        e.Sessions.CleanupRename(plan);
    }

    [Fact]
    public void PendingIntentNeverInstallsABarePendingFile()
    {
        var (e, plan, staged, target) = Staged(false);
        using var _ = e;
        Assert.Throws<FileNotFoundException>(() => e.Sessions.CompleteRename(plan));
        Assert.False(File.Exists(e.Vault.UrlForRelativePath(target.NotePath)));
        Assert.True(File.Exists(staged));
    }

    [Fact]
    public void RecoveredFileWithOtherIdentityIsNotInstalled()
    {
        var (e, plan, staged, target) = Staged(true);
        using var _ = e;
        var wrong = plan.Installation! with { Identity = new(plan.Installation.Identity.Device, plan.Installation.Identity.Inode + 1) };
        NoteFile.InstallSessionTemporary(e.Vault.Root, wrong, target.NotePath);
        Assert.False(File.Exists(e.Vault.UrlForRelativePath(target.NotePath)));
        Assert.True(File.Exists(Path.Combine(Path.GetDirectoryName(staged)!, NoteFile.RecoveredName(Path.GetFileName(staged), Path.GetFileName(target.NotePath)))));
    }

    [Fact]
    public void ExistingTargetIsNeverOverwrittenByRecovery()
    {
        var (e, plan, staged, target) = Staged(true);
        using var _ = e;
        var path = e.Write(target.NotePath, "# user\n");
        NoteFile.InstallSessionTemporary(e.Vault.Root, plan.Installation!, target.NotePath);
        Assert.Equal("# user\n", CheckVault.Read(path));
        Assert.True(File.Exists(Path.Combine(Path.GetDirectoryName(staged)!, NoteFile.RecoveredName(Path.GetFileName(staged), Path.GetFileName(target.NotePath)))));
    }

    [Fact]
    public void PendingIntentWhoseSessionFolderIsGoneIsAbandonedNotFatal()
    {
        var (e, plan, staged, _) = Staged(true);
        using var _ = e;
        Directory.Delete(Path.GetDirectoryName(staged)!, true);
        Assert.Throws<FileNotFoundException>(() => e.Sessions.CompleteRename(plan));
    }

    [Fact]
    public void CleanupKeepsTheStagedCopyRestorableWhenBothSessionNamesAreGone()
    {
        var (e, plan, staged, target) = Staged(false);
        using var _ = e;
        e.Sessions.CleanupRename(plan);
        Assert.False(File.Exists(staged));
        NoteFile.SweepStaleTemporaries(e.Vault.Root, TimeSpan.Zero);
        Assert.Equal("# Daily sync\nbody\n", CheckVault.Read(e.Vault.UrlForRelativePath(target.NotePath)));
    }

    [Fact]
    public void CleanupDeletesTheStagedCopyOnceASessionNameExists()
    {
        var (e, plan, staged, target) = Staged(false);
        using var _ = e;
        e.Write(target.NotePath, "# Daily sync\nbody\n");
        e.Sessions.CleanupRename(plan);
        Assert.Empty(Directory.EnumerateFiles(Path.GetDirectoryName(staged)!, ".*-*"));
    }

    // Old note removed and a staged rewrite at ".pending-" (or already renamed to ".recovered-").
    private static (CheckVault E, SessionRenamePlan Plan, string Staged, Session Target) Staged(bool recovered)
    {
        var e = new CheckVault();
        e.Vault.Prepare();
        var old = e.Write(Candidate().NotePath, "# Standup\nbody\n");
        var original = e.Vault.FileSnapshot(Candidate().NotePath)!;
        var target = new Session("Daily sync", "Sessions/archive/Daily sync.md", CheckVault.Now, true);
        var rewritten = NoteFile.RewriteHeading(original.Contents!, target.Name);
        var stagedPath = "Sessions/archive/.pending-" + Guid.NewGuid().ToString("N");
        var staged = e.Write(stagedPath, System.Text.Encoding.UTF8.GetString(rewritten));
        var identity = e.Vault.FileSnapshot(stagedPath)!;
        var plan = new SessionRenamePlan(Candidate().NotePath, target, new(original.Device, original.Inode),
            new() { Original = Convert.ToHexString(SHA256.HashData(original.Contents!)), Rewritten = Convert.ToHexString(SHA256.HashData(rewritten)) },
            new(new(identity.Device, identity.Inode), stagedPath));
        File.Delete(old);
        if (recovered)
        {
            var kept = Path.Combine(Path.GetDirectoryName(staged)!, NoteFile.RecoveredName(Path.GetFileName(staged), Path.GetFileName(target.NotePath)));
            File.Move(staged, kept);
        }
        return (e, plan, staged, target);
    }
}
