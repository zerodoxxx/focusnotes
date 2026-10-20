using CaptureApp.Core;
using Xunit;

namespace CaptureApp.Core.Tests;

public sealed class VaultTests
{
    [Fact]
    public void PrepareAndRecursiveListingPreserveNotes()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        Assert.Equal("# Inbox\n", CheckVault.Read(e.Vault.InboxUrl));
        e.Write("Inbox.md", "# Inbox\n\nkept\n");
        e.Vault.Prepare();
        Assert.Equal("# Inbox\n\nkept\n", CheckVault.Read(e.Vault.InboxUrl));
        Assert.True(Directory.Exists(e.Vault.SessionsUrl));
        Assert.True(Directory.Exists(e.Vault.AssetsUrl));
        var inputs = new Dictionary<string, string>
        {
            ["Alpha.md"] = "# Alpha Title  \nbody\n",
            ["Beta.md"] = "no heading here\n",
            ["Bom.md"] = "\uFEFF# BOM Title\n",
            [".Hidden.md"] = "# Hidden\n",
            ["notes.txt"] = "# Not markdown\n",
            ["Sessions/2026-10-13 Design.md"] = "# 2026-10-13 Design\n",
            ["Sessions/Plain.md"] = "plain session\n",
            ["science/math/trigonometry.md"] = "# Trigonometry\n",
            ["Sessions/Archive/Review.md"] = "# Archived Session\n",
            [".support/private.md"] = "# Hidden\n",
            ["~$draft.md"] = "# Temporary\n",
            ["assets/docs/asset-note.md"] = "# Asset\n"
        };
        foreach (var (path, text) in inputs)
        {
            e.Write(path, text);
        }

        Assert.Equal(new[] { "Note|Alpha Title", "Note|Beta", "Note|BOM Title", "Inbox|Inbox", "Session|2026-10-13 Design", "Session|Archived Session", "Session|Plain", "Note|Trigonometry" }, e.Vault.ListNotes().Select(n => $"{n.Kind}|{n.Title}"));
        Assert.Equal("Foo.md", Path.GetFileName(e.Vault.UniqueNoteUrl("Foo")));
        e.Write("Foo.md", "# Foo\n");
        Assert.Equal("Foo 2.md", Path.GetFileName(e.Vault.UniqueNoteUrl("Foo")));
        e.Write("Foo 2.md", "# Foo 2\n");
        Assert.Equal("Foo 3.md", Path.GetFileName(e.Vault.UniqueNoteUrl("Foo")));
        Assert.All(e.Vault.ListNoteFiles(), n => Assert.NotNull(n.Snapshot));
    }

    [UnixFact]
    public void InboxPrivacyMigrationPreservesOwnerReadOnlyMode()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        Assert.Equal(384, (int)CheckVault.GetMode(e.Vault.InboxUrl));
        e.Write("Inbox.md", "# Inbox\n\nkept\n");
        CheckVault.SetMode(e.Vault.InboxUrl, 420);
        e.Vault.Prepare();
        Assert.Equal(384, (int)CheckVault.GetMode(e.Vault.InboxUrl));
        CheckVault.SetMode(e.Vault.InboxUrl, 292);
        e.Vault.Prepare();
        Assert.Equal(256, (int)CheckVault.GetMode(e.Vault.InboxUrl));
        Assert.Equal("# Inbox\n\nkept\n", CheckVault.Read(e.Vault.InboxUrl));
        CheckVault.SetMode(e.Vault.InboxUrl, 384);
    }

    [Fact]
    public void InboxSymlinksAndHardlinksAreRefused()
    {
        using var e = new CheckVault();
        Directory.CreateDirectory(e.Vault.Root);
        var outside = Path.Combine(e.Base, "outside.md");
        CheckVault.WriteAbsolute(outside, "outside bytes\n");
        foreach (var symbolic in new[]
        {
            true,
            false
        }

        )
        {
            if (symbolic)
            {
                CheckVault.SymbolicLink(e.Vault.InboxUrl, outside);
            }
            else
            {
                CheckVault.HardLink(e.Vault.InboxUrl, outside);
            }

            Assert.ThrowsAny<IOException>(e.Vault.Prepare);
            Assert.Equal("outside bytes\n", CheckVault.Read(outside));
            File.Delete(e.Vault.InboxUrl);
        }
    }

    [Fact]
    public void UnsafeFilesAndDirectoriesAreNotListed()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var outside = Path.Combine(e.Base, "outside.md");
        CheckVault.WriteAbsolute(outside, "# Outside\nprivate body\n");
        var directory = Path.Combine(e.Base, "outside-folder");
        CheckVault.WriteAbsolute(Path.Combine(directory, "Nested.md"), "# Nested\n");
        CheckVault.SymbolicLink(e.Vault.UrlForRelativePath("Symlink.md"), outside);
        CheckVault.HardLink(e.Vault.UrlForRelativePath("Hardlink.md"), outside);
        CheckVault.SymbolicLink(e.Vault.UrlForRelativePath("Linked folder"), directory, true);
        if (!OperatingSystem.IsWindows())
        {
            CheckVault.Fifo(e.Vault.UrlForRelativePath("Waiting.md"));
        }

        Assert.Equal(new[] { "Inbox.md" }, e.Vault.ListNotes().Select(n => e.Vault.NoteId(n.Url)));
        Assert.Equal(new[] { "Inbox.md" }, e.Vault.ListNotes().Select(n => e.Vault.NoteId(n.Url)));
        Assert.Equal(new[] { "Inbox.md" }, e.Vault.ListNoteFiles().Select(n => n.Id));
        Assert.ThrowsAny<IOException>(() => e.Vault.FileSnapshot("Hardlink.md"));
    }

    [Fact]
    public void SelectedRootSymlinkIsResolvedOnce()
    {
        using var e = new CheckVault();
        var target = Path.Combine(e.Base, "target");
        Directory.CreateDirectory(target);
        var alias = Path.Combine(e.Base, "alias");
        CheckVault.SymbolicLink(alias, target, true);
        var vault = new Vault(alias, namingRules: new() { WindowsRules = false });
        vault.Prepare();
        Assert.Equal(target, vault.Root);
        Assert.True(File.Exists(Path.Combine(target, "Inbox.md")));
        Directory.Delete(alias);
        var other = Path.Combine(e.Base, "other");
        Directory.CreateDirectory(other);
        CheckVault.SymbolicLink(alias, other, true);
        vault.Prepare();
        Assert.False(File.Exists(Path.Combine(other, "Inbox.md")));
    }

    [Fact]
    public void MissingRootAdoptsExternalCreationWithoutPreparing()
    {
        using var e = new CheckVault();
        Assert.Empty(e.Vault.ListNotes());
        Assert.False(Directory.Exists(e.Vault.Root));
        Directory.CreateDirectory(e.Vault.Root);
        Assert.Empty(e.Vault.ListNotes());
        e.Write("Sessions/External.md", "# External\nbody\n");
        Assert.Equal("# External\nbody\n", NoteFile.Utf8.GetString(e.Vault.FileSnapshot("Sessions/External.md")!.Contents!));
        Assert.Contains(e.Vault.ListNotes(), n => n.Title == "External" && n.Kind == NoteKind.Session);
    }

    [Fact]
    public void NoteNameResolutionCanonicalCaseAndDeferredPaths()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var existing = e.Write("Science/Math/Trigonometry.md", "# Trigonometry\n\nkeep these bytes\n");
        var resolved = e.Vault.ResolveNoteName("science/math/trigonometry");
        Assert.Equal(NotePathScope.Vault, resolved.Scope);
        Assert.Equal("Science/Math/Trigonometry.md", resolved.RelativePath);
        Assert.Equal(resolved.RelativePath, resolved.Id);
        Assert.Equal(existing, resolved.Url);
        Assert.Equal("Science/physics/quantum.md", e.Vault.ResolveNoteName("science/physics/quantum").RelativePath);
        Assert.False(Directory.Exists(e.Vault.UrlForRelativePath("Science/physics")));
        Assert.Throws<NotePathNameException>(() => e.Vault.ResolveNoteName("Assets/hidden-note"));
        var outside = Path.Combine(e.Base, "outside");
        Directory.CreateDirectory(outside);
        CheckVault.SymbolicLink(e.Vault.UrlForRelativePath("Linked"), outside, true);
        Assert.ThrowsAny<IOException>(() => e.Vault.ResolveNoteName("linked/note"));
        var home = e.Vault.ResolveNoteName("/Desktop/Nested/Theory");
        Assert.Equal(NotePathScope.Home, home.Scope);
        Assert.Equal("Desktop/Nested/Theory.md", home.RelativePath);
        Assert.Equal(new Uri(home.Url).AbsoluteUri, home.Id);
        Assert.False(Directory.Exists(Path.GetDirectoryName(home.Url)));
        var missing = new Vault(Path.Combine(e.Base, "NotMounted"), namingRules: new() { WindowsRules = false });
        Assert.Equal(missing.UrlForRelativePath("notes/math/queued.md"), missing.ResolveNoteName("notes/math/queued").Url);
        Assert.False(Directory.Exists(missing.Root));
    }

    [Fact]
    public void CaseVariantAssetsAndUnsafeIdentities()
    {
        using var e = new CheckVault();
        e.Write("ASSETS/docs/Note.md", "# Secret\n");
        e.Vault.Prepare();
        Assert.DoesNotContain(e.Vault.ListNotes(), n => n.Title == "Secret");
        foreach (var path in new[]
        {
            "folder\\name.md",
            "folder/name\a.md",
            "../outside.md",
            "/absolute.md",
            "folder//name.md"
        }

        )
        {
            Assert.ThrowsAny<Exception>(() => e.Vault.FileSnapshot(path));
        }

        foreach (var id in new[]
        {
            "../outside.md",
            "Inbox.md?x",
            "file://server/Inbox.md",
            "NotMarkdown.txt"
        }

        )
        {
            Assert.ThrowsAny<Exception>(() => e.Vault.NoteLocation(id));
        }
    }
}
