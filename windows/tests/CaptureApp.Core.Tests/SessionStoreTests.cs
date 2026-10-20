using System.Text.Json;
using CaptureApp.Core;
using Xunit;

namespace CaptureApp.Core.Tests;

public sealed class SessionStoreTests
{
    [Fact]
    public void StartPersistReloadResumeAndEnd()
    {
        using var e = new CheckVault();
        Assert.Null(e.Sessions.Current());
        var started = e.Sessions.Start("Design Review");
        Assert.Equal("Design Review", started.Name);
        Assert.Equal("Sessions/Design Review.md", started.NotePath);
        Assert.Equal(CheckVault.Now, started.StartedAt);
        Assert.Equal("# Design Review\n", CheckVault.Read(e.Vault.UrlForRelativePath(started.NotePath)));
        var reopened = new SessionStore(e.State, e.Vault, CheckVault.Zone, CheckVault.Clock);
        Assert.Equal(started, reopened.Current());
        e.Write(started.NotePath, "# Design Review\nextra line\n");
        e.Sessions.Start("Design Review");
        Assert.Equal("# Design Review\nextra line\n", CheckVault.Read(e.Vault.UrlForRelativePath(started.NotePath)));
        var later = new SessionStore(e.State, e.Vault, CheckVault.Zone, new FixedTimeProvider(CheckVault.Now.AddDays(1)));
        var resumed = later.Start("design review");
        Assert.True(resumed.Resumed);
        Assert.Equal(started.NotePath, resumed.NotePath);
        Assert.Equal("Design Review", resumed.Name);
        var slash = e.Sessions.Start("A/B");
        Assert.Equal("Sessions/A/B.md", slash.NotePath);
        Assert.False(slash.Resumed);
        var colon = e.Sessions.Start("a:b");
        Assert.Equal("Sessions/a-b.md", colon.NotePath);
        Assert.False(colon.Resumed);
        Assert.True(e.Sessions.Start("A/B").Resumed);
        foreach (var name in new[]
        {
            "TODO/",
            "Read https://x.com",
            "a//b",
            "pros / cons"
        }

        )
        {
            Assert.Equal("Sessions/" + NoteTitle.FileStem(NoteTitle.CleanTitle(name)) + ".md", e.Sessions.Start(name).NotePath);
        }

        var before = e.Sessions.Current();
        foreach (var name in new[]
        {
            "/outside",
            " /outside",
            "science/../escape",
            "science/\0name",
            "science/~$draft"
        }

        )
        {
            Assert.Equal(NotePathNameError.InvalidComponent, Assert.Throws<NotePathNameException>(() => e.Sessions.Start(name)).Kind);
            Assert.Equal(before, e.Sessions.Current());
        }

        e.Write("Sessions/2026-10-12 Legacy.md", "# Legacy\n\nold bytes\n");
        var legacy = e.Sessions.Start("legacy");
        Assert.Equal("Sessions/2026-10-12 Legacy.md", legacy.NotePath);
        Assert.True(legacy.Resumed);
        e.Write("Sessions/archive/Standup.md", "# Standup\n\narchived notes\n");
        var nested = e.Sessions.Start("Standup");
        Assert.Equal("Sessions/archive/Standup.md", nested.NotePath);
        Assert.True(nested.Resumed);
        Assert.False(File.Exists(e.Vault.UrlForRelativePath("Sessions/Standup.md")));
        var blank = e.Sessions.Start("   ");
        Assert.Equal("Session", blank.Name);
        Assert.Equal("Sessions/Session.md", blank.NotePath);
        e.Sessions.End();
        Assert.Null(e.Sessions.Current());
        Assert.False(File.Exists(e.Sessions.StateFileUrl));
        e.Sessions.End();
        Assert.Null(new SessionStore(e.State, e.Vault, CheckVault.Zone).Current());
        CheckVault.WriteAbsolute(e.Sessions.StateFileUrl, "{not json");
        Assert.Null(new SessionStore(e.State, e.Vault, CheckVault.Zone).Current());
        CheckVault.WriteAbsolute(e.Sessions.StateFileUrl, "{\"name\":\"Legacy\",\"notePath\":\"Sessions/2026-10-12 Legacy.md\",\"startedAt\":\"2026-10-13T09:00:00Z\"}");
        Assert.Equal("Sessions/2026-10-12 Legacy.md", new SessionStore(e.State, e.Vault, CheckVault.Zone).Current()!.NotePath);
    }

    [Fact]
    public void AmbiguitySortsNewestFirstThenPathAndExactCandidates()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var older = e.Write("Sessions/Standup.md", "# Root Standup\n");
        var newer = e.Write("Sessions/archive/Standup.md", "# Archived Standup\n");
        var tied = e.Write("Sessions/z-archive/Standup.md", "# Z Standup\n");
        File.SetLastWriteTimeUtc(older, CheckVault.Now.AddDays(-1).UtcDateTime);
        File.SetLastWriteTimeUtc(newer, CheckVault.Now.AddHours(-1).UtcDateTime);
        File.SetLastWriteTimeUtc(tied, CheckVault.Now.AddHours(-1).UtcDateTime);
        var failure = Assert.Throws<SessionStoreException>(() => e.Sessions.Start("Standup"));
        Assert.Equal(SessionStoreError.Ambiguous, failure.Kind);
        Assert.Equal(new[] { "Sessions/archive/Standup.md", "Sessions/z-archive/Standup.md", "Sessions/Standup.md" }, failure.Candidates.Select(n => n.NotePath));
        Assert.Equal(new[] { "Archived Standup", "Z Standup", "Root Standup" }, failure.Candidates.Select(n => n.Name));
        Assert.Null(e.Sessions.Current());
        Assert.False(File.Exists(e.Sessions.StateFileUrl));
        Assert.Equal("# Root Standup\n", CheckVault.Read(older));
        Assert.Equal("# Archived Standup\n", CheckVault.Read(newer));
        Assert.Equal("# Z Standup\n", CheckVault.Read(tied));
        var exact = e.Sessions.Start("archive/Standup");
        Assert.True(exact.Resumed);
        Assert.Equal("Sessions/archive/Standup.md", exact.NotePath);
        var created = e.Sessions.Start("new-group/Planning");
        Assert.False(created.Resumed);
        Assert.Equal("# Planning\n", CheckVault.Read(e.Vault.UrlForRelativePath(created.NotePath)));
        Assert.Equal("Sessions/z-archive/Standup.md", e.Sessions.Resume(failure.Candidates[1]).NotePath);
        File.Delete(tied);
        Assert.Equal(SessionStoreError.CandidateNoLongerExists, Assert.Throws<SessionStoreException>(() => e.Sessions.Resume(failure.Candidates[1])).Kind);
    }

    [Fact]
    public void InvalidTypedStateLoadsAsNoSession()
    {
        using var e = new CheckVault();
        CheckVault.WriteAbsolute(e.Sessions.StateFileUrl, "{\"name\":\"S\",\"notePath\":\"Sessions/S.md\",\"startedAt\":\"2026-10-13T09:00:00Z\",\"resumed\":\"false\"}");
        Assert.Null(new SessionStore(e.State, e.Vault, CheckVault.Zone, CheckVault.Clock).Current());
    }

    [UnixFact]
    public void FailedStateDeletionRetainsActiveSession()
    {
        using var e = new CheckVault();
        var kept = e.Sessions.Start("Keep on failure");
        CheckVault.SetMode(e.State, 320);
        try
        {
            Assert.ThrowsAny<Exception>(e.Sessions.End);
            Assert.Equal(kept, e.Sessions.Current());
            Assert.True(File.Exists(e.Sessions.StateFileUrl));
        }
        finally
        {
            CheckVault.SetMode(e.State, 448);
        }

        e.Sessions.End();
    }

    [Fact]
    public void SessionStartRefusesLinkedSessionDirectoryAndLateReplacement()
    {
        using var e = new CheckVault();
        Directory.CreateDirectory(e.Vault.Root);
        var outside = Path.Combine(e.Base, "outside-sessions");
        Directory.CreateDirectory(outside);
        CheckVault.SymbolicLink(e.Vault.SessionsUrl, outside, true);
        Assert.ThrowsAny<IOException>(() => e.Sessions.Start("Escaped"));
        Assert.Null(e.Sessions.Current());
        Assert.Empty(Directory.EnumerateFiles(outside));
        Assert.False(File.Exists(e.Sessions.StateFileUrl));
        Directory.Delete(e.Vault.SessionsUrl);
        e.Vault.Prepare();
        var store = new SessionStore(e.State, e.Vault, CheckVault.Zone, CheckVault.Clock, beforeNoteWrite: _ =>
        {
            Directory.Move(e.Vault.SessionsUrl, e.Vault.SessionsUrl + ".old");
            CheckVault.SymbolicLink(e.Vault.SessionsUrl, outside, true);
        });
        Assert.ThrowsAny<IOException>(() => store.Start("Escaped"));
        Assert.Null(store.Current());
        Assert.Empty(Directory.EnumerateFiles(outside));
    }
}
