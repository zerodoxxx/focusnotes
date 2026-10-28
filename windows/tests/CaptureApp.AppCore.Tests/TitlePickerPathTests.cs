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
        var paths = new CaptureCoordinator(pipeline, new HeadlessCaptureHost()).ExplicitTitlePaths(suggestions);

        // Unique root notes and unique sessions keep their bare title.
        Assert.DoesNotContain("Unique.md", paths.Keys);
        Assert.DoesNotContain("Team standup.md", paths.Keys);
        Assert.DoesNotContain("Sessions/2026-10-13 Retro.md", paths.Keys);
        var expected = new Dictionary<string, string>
        {
            ["Archive/Nested.md"] = "Archive/Nested",
            ["Archive/Ideas.md"] = "Archive/Ideas",
            ["Ideas 2.md"] = "Ideas 2",
            ["Foo.md"] = "Foo",
            ["Sessions/2026-10-13 Standup.md"] = "Sessions/2026-10-13 Standup",
            [homeId] = "/Desktop/Journal"
        };
        Assert.Equal(expected.OrderBy(p => p.Key, StringComparer.Ordinal), paths.OrderBy(p => p.Key, StringComparer.Ordinal));
        foreach (var (id, value) in paths)
        {
            Assert.Equal(Path.GetFullPath(vault.NoteLocation(id).Url), Path.GetFullPath(Router.Destination(value, null, notes, vault).Url));
        }
    }
}
