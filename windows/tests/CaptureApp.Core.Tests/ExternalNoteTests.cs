using System.Text.Json;
using CaptureApp.Core;
using Xunit;

namespace CaptureApp.Core.Tests;

public sealed class ExternalNoteTests
{
    [Fact]
    public void OnlyExplicitlyRegisteredHomeNotesAreDiscoveredAndIdsSurviveReopen()
    {
        using var e = new CheckVault(registry: true);
        e.Vault.Prepare();
        var unregistered = e.Write("Desktop/Unregistered.md", "# Unregistered\n", true);
        Assert.Equal(NotePathScope.Home, e.Vault.ResolveNoteName("/Desktop/Unregistered").Scope);
        Assert.DoesNotContain(e.Vault.ListNotes(), n => n.Url == unregistered);
        var capture = CheckVault.Capture("# /Desktop/Registered\n\nexternal body", CaptureContentKind.Note);
        var prepared = e.Service.PrepareNote(capture, CheckVault.Zone);
        Assert.Equal(Path.GetFullPath(Path.Combine(e.Home, "Desktop/Registered.md")), prepared.Destination.Url);
        e.Service.Save(prepared);
        var location = e.Vault.NoteLocation(new Uri(prepared.Destination.Url).AbsoluteUri);
        Assert.Equal(NotePathScope.Home, location.Scope);
        Assert.Equal(new Uri(location.Url).AbsoluteUri, location.Id);
        var reopened = new Vault(e.Vault.Root, e.Registry, e.Home, new() { WindowsRules = false });
        Assert.Contains(reopened.ListNotes(), n => n.Url == location.Url);
        Assert.DoesNotContain(reopened.ListNotes(), n => n.Url == unregistered);
        Assert.Equal("\nexternal body", CaptureApp.Core.Index.NoteParser.Parse(CheckVault.Read(location.Url), location.Id, "", CheckVault.Zone).Blocks.Last().Body);
        Assert.NotNull(reopened.FileSnapshotForNoteId(location.Id));
        Assert.NotNull(reopened.ExternalRegistryFingerprint());
        File.Delete(location.Url);
        Assert.DoesNotContain(reopened.ListNotes(), n => n.Url == location.Url);
        Assert.ThrowsAny<IOException>(() => reopened.NoteLocation(location.Id));
        foreach (var id in new[]
        {
            new Uri(unregistered).AbsoluteUri,
            location.Id + "?x",
            location.Id + "#fragment",
            "file://host" + new Uri(unregistered).AbsolutePath,
            new Uri(Path.Combine(e.Base, "Outside.md")).AbsoluteUri
        }

        )
        {
            Assert.ThrowsAny<Exception>(() => reopened.NoteLocation(id));
        }
    }

    [Fact]
    public void RegistrySnapshotGenerationsCacheAndConcurrentUpserts()
    {
        using var e = new CheckVault(registry: true);
        var registry = e.Vault.ExternalNoteRegistry!;
        var initial = registry.GetSnapshot();
        Assert.Empty(initial.Paths);
        Assert.Equal(0UL, initial.Generation);
        registry.Register("Desktop/A.md");
        var added = registry.GetSnapshot();
        Assert.Equal(initial.Generation + 1, added.Generation);
        registry.Register("Desktop/A.md");
        Assert.Equal(added.Generation, registry.GetSnapshot().Generation);
        e.WriteRegistry("{\"version\":1,\"paths\":[\"Desktop/B.md\"]}");
        Assert.Equal(new[] { "Desktop/A.md" }, registry.Paths());
        registry.InvalidateCache();
        Assert.Equal(new[] { "Desktop/B.md" }, registry.Paths());
        Assert.Equal(added.Generation + 1, registry.GetSnapshot().Generation);
        var other = new ExternalNoteRegistry(e.Registry);
        Parallel.For(0, 24, i => (i % 2 == 0 ? registry : other).Register($"Desktop/Note{i}.md"));
        registry.InvalidateCache();
        Assert.Equal(25, registry.Paths().Count);
        Assert.Contains("Desktop/B.md", registry.Paths());
        Assert.Equal(registry.Paths().Order(StringComparer.Ordinal), registry.Paths());
    }

    [Fact]
    public void HomeLocationInsideVaultIsListedOnceAndNeverRegisteredAsExternal()
    {
        using var e = new CheckVault(registry: true);
        var root = Path.Combine(e.Home, "Vault");
        var vault = new Vault(root, e.Registry, e.Home, new() { WindowsRules = false });
        vault.Prepare();
        var writer = new NoteWriter(vault, CheckVault.Zone);
        var sessions = new SessionStore(e.State, vault, CheckVault.Zone, CheckVault.Clock);
        var service = new CaptureService(vault, sessions, writer, CheckVault.Clock);
        var location = vault.ResolveNoteName("/Vault/Subfolder/Inside");
        Assert.Equal(NotePathScope.Vault, location.Scope);
        Assert.Equal("Subfolder/Inside.md", location.Id);
        var prepared = service.PrepareNote(CheckVault.Capture("# /Vault/Subfolder/Inside\n\ninside body", CaptureContentKind.Note), CheckVault.Zone);
        service.Save(prepared);
        Assert.Single(vault.ListNotes(), n => n.Url == location.Url);
        Assert.Empty(vault.ExternalNoteRegistry!.Paths());
        var observer = new Vault(Path.Combine(e.Base, "Observer"), e.Registry, e.Home, new() { WindowsRules = false });
        observer.Prepare();
        Assert.DoesNotContain(observer.ListNotes(), n => n.Url == location.Url);
    }

    [Fact]
    public void ExternalSymlinksAndHardlinksFailWithoutChangingTargets()
    {
        using var e = new CheckVault(registry: true);
        e.Vault.Prepare();
        var outside = Path.Combine(e.Base, "outside.md");
        CheckVault.WriteAbsolute(outside, "outside target\n");
        foreach (var symbolic in new[]
        {
            true,
            false
        }

        )
        {
            var name = symbolic ? "Symbolic" : "Hard";
            var path = Path.Combine(e.Home, name + ".md");
            if (symbolic)
            {
                CheckVault.SymbolicLink(path, outside);
            }
            else
            {
                CheckVault.HardLink(path, outside);
            }

            var prepared = e.Service.PrepareNote(CheckVault.Capture("# /" + name + "\nbody", CaptureContentKind.Note), CheckVault.Zone);
            Assert.Equal(path, prepared.Destination.Url);
            Assert.ThrowsAny<IOException>(() => e.Service.Save(prepared));
            Assert.Equal("outside target\n", CheckVault.Read(outside));
            Assert.DoesNotContain(e.Vault.ListNotes(), n => n.Url == path);
        }
    }

    [Fact]
    public void RegistrySymlinkMalformedAndNewerVersionsFailClosedAndPreserveBytes()
    {
        foreach (var (text, kind, link) in new[]
        {
            ("{\"version\":1,\"paths\":[\"Desktop/a.md\",\"Desktop/b.md\"]}x", ExternalNoteRegistryError.MalformedRegistry, false),
            ("{\"version\":2,\"paths\":[\"Desktop/a.md\",\"Desktop/b.md\"]}", ExternalNoteRegistryError.UnsupportedVersion, false),
            ("{\"version\":1,\"paths\":[\"Desktop/a.md\"]}", ExternalNoteRegistryError.UnreadableRegistry, true)
        }

        )
        {
            using var e = new CheckVault(registry: true);
            e.Write("Desktop/a.md", "# A\n", true);
            e.Write("Desktop/b.md", "# B\n", true);
            Directory.CreateDirectory(e.State);
            if (link)
            {
                var target = Path.Combine(e.Base, "registry-target.json");
                CheckVault.WriteAbsolute(target, text);
                CheckVault.SymbolicLink(e.Registry, target);
            }
            else
            {
                e.WriteRegistry(text);
            }

            e.Vault.Prepare();
            Assert.Equal(kind, Assert.Throws<ExternalNoteRegistryException>(() => e.Vault.ListNotes()).Kind);
            Assert.Equal(kind, Assert.Throws<ExternalNoteRegistryException>(() => e.Service.Prepare(CheckVault.Capture("must not be misrouted"), "A")).Kind);
            Assert.False(File.Exists(e.Vault.UrlForRelativePath("A.md")));
            var prepared = e.Service.PrepareNote(CheckVault.Capture("# /Desktop/c\nmust not overwrite registry", CaptureContentKind.Note), CheckVault.Zone);
            Assert.Equal(kind, Assert.Throws<ExternalNoteRegistryException>(() => e.Service.Save(prepared)).Kind);
            Assert.Equal(text, CheckVault.Read(e.Registry));
            Assert.False(File.Exists(prepared.Destination.Url));
        }
    }

    [Fact]
    public void RegistryFiltersTamperedPathsAndExternalDirectoryLinks()
    {
        using var e = new CheckVault(registry: true);
        e.Vault.Prepare();
        var safe = e.Write("Desktop/Allowed.md", "# Allowed\n", true);
        var outside = Path.Combine(e.Base, "Outside");
        Directory.CreateDirectory(outside);
        CheckVault.WriteAbsolute(Path.Combine(outside, "Outside.md"), "# Outside\n");
        CheckVault.SymbolicLink(Path.Combine(e.Home, "Escaped"), outside, true);
        var bad = new[]
        {
            "../TraversalEscape.md",
            Path.Combine(e.Base, "AbsoluteEscape.md"),
            "Desktop/Back\\slash.md",
            "Desktop/Bad\a.md",
            "Desktop/NotMarkdown.txt",
            "Desktop//Double.md",
            "Escaped/Outside.md"
        };
        e.WriteRegistry(JsonSerializer.Serialize(new { version = 1, paths = bad.Append("Desktop/Allowed.md").Append("Desktop/Allowed.md") }));
        e.Vault.InvalidateExternalRegistryCache();
        var notes = e.Vault.ListNotes();
        Assert.Contains(notes, n => n.Url == safe);
        Assert.DoesNotContain(notes, n => n.Title == "Outside");
        Assert.Equal(2, notes.Count);
        foreach (var path in bad.Where(p => p != "Escaped/Outside.md"))
        {
            Assert.False(ExternalNoteRegistry.IsSafeRelativeMarkdownPath(path));
        }

        Assert.Equal(new[] { "Desktop/Allowed.md", "Escaped/Outside.md" }, e.Vault.ExternalNoteRegistry!.Paths());
    }

    [Fact]
    public void OwnedHandleIsClosedOnlyOnceEvenWhenDisposeRaces()
    {
        using var e = new CheckVault();
        var file = e.Write("Owned.md", "owned");
        var handle = File.OpenHandle(file);
        var owned = new OwnedFileDescriptor(handle);
        Parallel.For(0, 20, _ => owned.Close());
        Assert.Null(owned.Handle);
        Assert.True(handle.IsClosed);
        using var replacement = File.OpenHandle(file);
        owned.Close();
        owned.Dispose();
        Assert.False(replacement.IsClosed);
        Assert.False(replacement.IsInvalid);
    }
}
