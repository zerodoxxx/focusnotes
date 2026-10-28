using CaptureApp.AppCore.Shell;
using CaptureApp.Core;
using CaptureApp.Core.Index;
using Xunit;

namespace CaptureApp.AppCore.Tests;

public sealed class TitlePickerPathTests
{
    [Fact]
    public void NestedHomeSessionAndSameTitledNotesCarryAPathThatRoutesToThem()
    {
        using var temp = new TempDirectory();
        var home = Path.Combine(temp.Path, "home");
        Directory.CreateDirectory(home);
        using var pipeline = CapturePipeline.Open(Path.Combine(temp.Path, "vault"), Path.Combine(temp.Path, "state"), TimeZoneInfo.Utc, homeDirectory: home);
        var vault = pipeline.Vault;
        foreach (var (path, text) in new Dictionary<string, string>
        {
            ["Unique.md"] = "# Unique\n",
            ["Ideas.md"] = "# Ideas\n",
            ["Ideas 2.md"] = "# Ideas\n",
            ["Foo.md"] = "# A/B\n",
            ["Archive/Nested.md"] = "# Nested\n",
            ["Archive/Ideas.md"] = "# Ideas\n",
            ["Team standup.md"] = "# Standup\n",
            ["Sessions/2026-10-13 Standup.md"] = "# Standup\n",
            ["Sessions/2026-10-13 Retro.md"] = "# Retro\n"
        })
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.Combine(vault.Root, path))!);
            File.WriteAllText(Path.Combine(vault.Root, path), text);
        }

        Directory.CreateDirectory(Path.Combine(home, "Desktop"));
        File.WriteAllText(Path.Combine(home, "Desktop", "Journal.md"), "# Journal\n");
        (vault.ExternalNoteRegistry ?? throw new InvalidOperationException("No registry.")).Register("Desktop/Journal.md");

        var notes = vault.ListNotes();
        var suggestions = notes.Where(n => n.Kind != NoteKind.Inbox).Select(n => new NoteSuggestion(n.Title, n.Kind, vault.NoteId(n.Url), DateTimeOffset.UnixEpoch)).ToArray();
        var homeId = suggestions.Single(s => s.Title == "Journal").Path;
        var picks = new CaptureCoordinator(pipeline, new HeadlessCaptureHost()).PickerChoices(suggestions);
        string? ValueOf(string id) => picks.ValueOf(suggestions.Single(s => s.Path == id));

        // Unique root notes and unique sessions keep their bare title.
        Assert.Null(ValueOf("Unique.md"));
        Assert.Null(ValueOf("Team standup.md"));
        Assert.Null(ValueOf("Sessions/2026-10-13 Retro.md"));
        var expected = new Dictionary<string, string>
        {
            ["Archive/Nested.md"] = "Archive/Nested",
            ["Archive/Ideas.md"] = "Archive/Ideas",
            ["Sessions/2026-10-13 Standup.md"] = "Sessions/2026-10-13 Standup",
            [homeId] = "/Desktop/Journal",
            // Root notes with a shared or path-like heading are picked by their file name.
            ["Ideas.md"] = "Ideas.md",
            ["Ideas 2.md"] = "Ideas 2.md",
            ["Foo.md"] = "Foo.md"
        };
        foreach (var (id, value) in expected)
        {
            Assert.Equal(value, ValueOf(id));
            Assert.Equal(Path.GetFullPath(vault.NoteLocation(id).Url), Path.GetFullPath(picks.DestinationOf(value)!.Url));
        }

        Assert.Null(picks.DestinationOf("Ideas"));
        // Extensionless values also route to the same note by title.
        foreach (var (id, value) in expected.Where(p => !p.Value.EndsWith(".md", StringComparison.Ordinal)))
        {
            Assert.Equal(Path.GetFullPath(vault.NoteLocation(id).Url), Path.GetFullPath(Router.Destination(value, null, notes, vault).Url));
        }
    }

    [Fact]
    public async Task EachOfTwoRootNotesWithTheSameHeadingCanBePicked()
    {
        using var temp = new TempDirectory();
        using var pipeline = CapturePipeline.Open(Path.Combine(temp.Path, "vault"), Path.Combine(temp.Path, "state"), TimeZoneInfo.Utc);
        var coordinator = new CaptureCoordinator(pipeline, new HeadlessCaptureHost());
        var vault = pipeline.Vault;
        File.WriteAllText(Path.Combine(vault.Root, "Biology.md"), "# Biology\n");
        File.WriteAllText(Path.Combine(vault.Root, "Biology 2.md"), "# Biology\n");
        var suggestions = vault.ListNotes().Where(n => n.Kind == NoteKind.Note)
            .Select(n => new NoteSuggestion(n.Title, n.Kind, vault.NoteId(n.Url), DateTimeOffset.UnixEpoch)).ToArray();
        var picks = coordinator.PickerChoices(suggestions);
        Assert.Equal(["Biology 2.md", "Biology.md"], suggestions.Select(s => picks.ValueOf(s)!).Order(StringComparer.Ordinal));

        foreach (var (name, needle) in new[] { ("Biology.md", "first pick needle"), ("Biology 2.md", "second pick needle") })
        {
            await coordinator.StageAsync(PendingCaptures.Selection(needle, new()));
            var saved = await coordinator.CommitPending(destination: picks.DestinationOf(picks.ValueOf(suggestions.Single(s => s.Path == name))!), announce: true)!;
            Assert.Equal(Path.Combine(vault.Root, name), saved.Destination.Url);
            var text = File.ReadAllText(saved.Destination.Url);
            Assert.Equal(1, text.Split(needle).Length - 1);
        }

        Assert.DoesNotContain("second pick needle", File.ReadAllText(Path.Combine(vault.Root, "Biology.md")), StringComparison.Ordinal);
        Assert.DoesNotContain("first pick needle", File.ReadAllText(Path.Combine(vault.Root, "Biology 2.md")), StringComparison.Ordinal);
        Assert.DoesNotContain("pick needle", File.ReadAllText(vault.InboxUrl), StringComparison.Ordinal);
    }

    [Fact]
    public async Task PickedNoteRemovedBeforeTheCommitKeepsTheCapture()
    {
        using var temp = new TempDirectory();
        using var pipeline = CapturePipeline.Open(Path.Combine(temp.Path, "vault"), Path.Combine(temp.Path, "state"), TimeZoneInfo.Utc);
        var host = new HeadlessCaptureHost();
        var coordinator = new CaptureCoordinator(pipeline, host);
        var gone = Path.Combine(pipeline.Vault.Root, "Gone.md");
        File.WriteAllText(gone, "# Gone\n");
        var destination = new Destination(gone, "Gone", NoteKind.Note);
        File.Delete(gone);
        var capture = PendingCaptures.Selection("kept pick needle", new());
        await coordinator.StageAsync(capture);
        await Assert.ThrowsAnyAsync<Exception>(() => coordinator.CommitPending(destination: destination, announce: true)!);
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (coordinator.PendingWithRetryWarning is null && DateTime.UtcNow < deadline) { await Task.Delay(10, TestContext.Current.CancellationToken); }
        Assert.Equal(capture.Id, coordinator.PendingWithRetryWarning?.Id);
        Assert.False(File.Exists(gone));
        Assert.DoesNotContain("kept pick needle", File.ReadAllText(pipeline.Vault.InboxUrl), StringComparison.Ordinal);
    }
}
