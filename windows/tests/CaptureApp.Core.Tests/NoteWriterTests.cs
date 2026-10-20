using CaptureApp.Core;
using CaptureApp.Core.Index;
using Xunit;

namespace CaptureApp.Core.Tests;

public sealed class NoteWriterTests
{
    [Fact]
    public void ExactCreationSeparatorsAndExistingBytes()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var capture = CheckVault.Capture();
        var block = CaptureFormat.Block(capture, "", CheckVault.Zone);
        var path = e.Vault.UrlForRelativePath("New.md");
        e.Writer.Append(capture, path, "New");
        Assert.Equal("# New\n\n" + block, CheckVault.Read(path));
        foreach (var (name, before) in new[]
        {
            ("no trailing newline", "# N\n\nold"),
            ("one trailing newline", "# N\n\nold\n"),
            ("two trailing newlines", "# N\n\nold\n\n"),
            ("empty file", "")
        }

        )
        {
            var file = e.Write(name + ".md", before);
            e.Writer.Append(capture, file, "N");
            Assert.Equal(before.Length == 0 ? "# N\n\n" + block : "# N\n\nold\n\n" + block, CheckVault.Read(file));
        }

        var keep = e.Write("Keep.md", "# Keep\n\nexisting é text\n");
        var beforeBytes = File.ReadAllBytes(keep);
        e.Writer.Append(capture, keep, "Keep");
        Assert.True(File.ReadAllBytes(keep).AsSpan().StartsWith(beforeBytes));
    }

    [Fact]
    public async Task IndependentWritersRaceCreationAndAppendOffsets()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var file = e.Vault.UrlForRelativePath("Concurrent.md");
        var captures = Enumerable.Range(0, 50).Select(i => CheckVault.Capture("Line " + i)).ToArray();
        await Task.WhenAll(captures.Select(c => Task.Run(() => new NoteWriter(e.Vault, CheckVault.Zone).Append(c, file, "Concurrent"))));
        var text = CheckVault.Read(file);
        Assert.StartsWith("# Concurrent\n\n", text, StringComparison.Ordinal);
        Assert.Equal(1, Count(text, "# Concurrent\n"));
        Assert.Equal(50, Count(text, "<!-- capture:"));
        foreach (var c in captures)
        {
            Assert.Equal(1, Count(text, CheckVault.Marker(c.Id)));
        }
    }

    [Fact]
    public void ImagesUseSafeAssetsAndRelativeLinksInEveryScope()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        byte[] png = [0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10];
        var asset = e.Writer.SaveImage(png, CheckVault.Now);
        Assert.Matches(@"^assets/2026-10-13-143000-[0-9a-f]{4}\.png$", asset);
        Assert.Equal(png, File.ReadAllBytes(e.Vault.UrlForRelativePath(asset)));
        foreach (var (file, expectedPrefix) in new[]
        {
            (e.Vault.UrlForRelativePath("Root image.md"), "assets/"),
            (e.Vault.UrlForRelativePath("Projects/Research/Deep/Nested.md"), "../../../assets/"),
            (Path.Combine(e.Home, "Deep/Visual Notes.md"), "../../Vault/assets/")
        }

        )
        {
            CheckVault.WriteAbsolute(file, "# Visual Notes\n\nExisting text\n");
            var before = File.ReadAllBytes(file);
            var c = CheckVault.Capture(asset, CaptureContentKind.Image);
            var d = CheckVault.Destination(file, "Visual Notes");
            e.Writer.AppendIfMissing(c, d);
            var written = File.ReadAllBytes(file);
            Assert.True(written.AsSpan().StartsWith(before));
            e.Writer.AppendIfMissing(c, d);
            Assert.Equal(written, File.ReadAllBytes(file));
            var text = CheckVault.Read(file);
            Assert.Contains("![](" + expectedPrefix, text, StringComparison.Ordinal);
            var parsed = NoteParser.Parse(text, new Uri(file).AbsoluteUri, "Visual Notes", CheckVault.Zone, e.Vault.AssetsUrl);
            Assert.Contains(parsed.Blocks, b => b.Kind == BlockKind.Image && b.AssetPath == asset);
        }

        var replay = CheckVault.Capture("assets/Replay.png", CaptureContentKind.Image);
        var target = CheckVault.Destination(e.Vault.UrlForRelativePath("Replay image.md"));
        e.Write("assets/Replay.png", "short");
        e.Writer.AppendIfMissing(replay, target, png);
        Assert.Equal(png, File.ReadAllBytes(e.Vault.UrlForRelativePath("assets/Replay.png")));
        e.Writer.AppendIfMissing(replay, target, png);
        Assert.Equal(1, Count(CheckVault.Read(target.Url), CheckVault.Marker(replay.Id)));
    }

    [Fact]
    public void NoteAndAssetSymlinksHardlinksAndLinkedParentsNeverChangeOutsideFiles()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var outside = Path.Combine(e.Base, "outside.md");
        CheckVault.WriteAbsolute(outside, "outside bytes\n");
        foreach (var symbolic in new[]
        {
            true,
            false
        }

        )
        {
            var link = e.Vault.UrlForRelativePath(symbolic ? "Linked.md" : "Hardlinked.md");
            if (symbolic)
            {
                CheckVault.SymbolicLink(link, outside);
            }
            else
            {
                CheckVault.HardLink(link, outside);
            }

            Assert.ThrowsAny<IOException>(() => e.Writer.Append(CheckVault.Capture(), link, "Linked"));
            Assert.Equal("outside bytes\n", CheckVault.Read(outside));
            var asset = e.Vault.UrlForRelativePath(symbolic ? "assets/Linked.png" : "assets/Hardlinked.png");
            if (symbolic)
            {
                CheckVault.SymbolicLink(asset, outside);
            }
            else
            {
                CheckVault.HardLink(asset, outside);
            }

            var c = CheckVault.Capture(e.Vault.RelativePath(asset)!, CaptureContentKind.Image);
            Assert.ThrowsAny<IOException>(() => e.Writer.AppendIfMissing(c, CheckVault.Destination(e.Vault.UrlForRelativePath("Image.md")), [1, 2, 3]));
            Assert.Equal("outside bytes\n", CheckVault.Read(outside));
        }

        Assert.False(NoteFile.CreateAsset([1, 2, 3], e.Vault.Root, "assets/Linked.png"));
        Assert.Equal("outside bytes\n", CheckVault.Read(outside));
        var directory = Path.Combine(e.Base, "outside-folder");
        Directory.CreateDirectory(directory);
        CheckVault.SymbolicLink(e.Vault.UrlForRelativePath("Linked parent"), directory, true);
        Assert.ThrowsAny<IOException>(() => e.Writer.Append(CheckVault.Capture(), e.Vault.UrlForRelativePath("Linked parent/Note.md"), "Note"));
        Assert.Empty(Directory.EnumerateFileSystemEntries(directory));
        CheckVault.SymbolicLink(Path.Combine(e.Home, "Linked.md"), outside);
        Assert.ThrowsAny<IOException>(() => e.Writer.AppendIfMissing(CheckVault.Capture(), CheckVault.Destination(Path.Combine(e.Home, "Linked.md"))));
        foreach (var asset in new[]
        {
            "../outside.png",
            "assets/.hidden.png",
            "assets/a/b.png",
            "assets/file.txt",
            "assets/x\0.png"
        }

        )
        {
            Assert.ThrowsAny<Exception>(() => e.Writer.AppendIfMissing(CheckVault.Capture(asset, CaptureContentKind.Image), CheckVault.Destination(e.Vault.UrlForRelativePath("Bad.md")), [1]));
        }
    }

    [Fact]
    public void GroupSourcesHeadingsFencesLegacyMarkersAndSubheadingReplay()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var file = e.Vault.UrlForRelativePath("Grouped.md");
        var destination = CheckVault.Destination(file, "Grouped");
        var first = CheckVault.Capture();
        e.Writer.AppendIfMissing(first, destination);
        var second = first with
        {
            Id = Guid.NewGuid()
        };
        e.Writer.AppendIfMissing(second, destination);
        var repeated = CheckVault.Read(file);
        Assert.Equal(1, Count(repeated, "### Safari\n"));
        Assert.Contains("Hello\n\n" + CheckVault.Marker(second.Id), repeated, StringComparison.Ordinal);
        e.Writer.AppendIfMissing(second, destination);
        Assert.Equal(repeated, CheckVault.Read(file));
        e.Writer.AppendIfMissing(CheckVault.Capture("```markdown\n## fenced\n```"), destination);
        e.Writer.AppendIfMissing(CheckVault.Capture(), destination);
        Assert.Equal(1, Count(CheckVault.Read(file), "### Safari\n"));
        var subheading = CheckVault.Capture("### Details\nnext", CaptureContentKind.Subheading);
        e.Writer.AppendIfMissing(subheading, destination);
        var saved = CheckVault.Read(file);
        e.Writer.AppendIfMissing(subheading, destination);
        Assert.Equal(saved, CheckVault.Read(file));
        Assert.Contains("## Details next\n<!-- subheading:", saved, StringComparison.Ordinal);
        e.Writer.AppendIfMissing(CheckVault.Capture(), destination);
        Assert.Equal(2, Count(CheckVault.Read(file), "### Safari\n"));
        var changed = CheckVault.Capture() with
        {
            Source = new("Safari", "Other page")
        };
        e.Writer.AppendIfMissing(changed, destination);
        Assert.Contains("### Other page\n" + CheckVault.Marker(changed.Id), CheckVault.Read(file), StringComparison.Ordinal);
        var legacy = $"# Legacy\n\n### 2026-10-13 14:30 · Safari\n<!-- capture:{first.Id:D} -->\n\nHello\n";
        var old = e.Write("Legacy.md", legacy);
        e.Writer.AppendIfMissing(first, CheckVault.Destination(old));
        Assert.Equal(legacy, CheckVault.Read(old));
        var damaged = $"# Damaged\n\n### Safari\n<!-- capture:{first.Id:D} at=2026-10";
        var damagedPath = e.Write("Damaged.md", damaged);
        e.Writer.AppendIfMissing(first, CheckVault.Destination(damagedPath));
        Assert.StartsWith(damaged, CheckVault.Read(damagedPath), StringComparison.Ordinal);
        Assert.Single(NoteParser.Parse(CheckVault.Read(damagedPath), "Damaged.md", "", CheckVault.Zone).Blocks, b => b.CaptureId == first.Id && b.Body == "Hello");
    }

    [Fact]
    public void PartialAppendsReplayOnceAndParserPrefersCompleteOccurrence()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var capture = CheckVault.Capture();
        var block = CaptureFormat.Block(capture, "", CheckVault.Zone);
        foreach (var fragment in new[]
        {
            block[..(block.IndexOf(" -->", StringComparison.Ordinal) + 4)],
            block[..^3]
        }

        )
        {
            var file = e.Write(Guid.NewGuid() + ".md", "# Partial\n\n" + fragment);
            var before = File.ReadAllBytes(file);
            var destination = CheckVault.Destination(file);
            e.Writer.AppendIfMissing(capture, destination);
            var saved = File.ReadAllBytes(file);
            Assert.True(saved.AsSpan().StartsWith(before));
            Assert.Equal(2, Count(CheckVault.Read(file), CheckVault.Marker(capture.Id)));
            var parsed = NoteParser.Parse(CheckVault.Read(file), Path.GetFileName(file), "", CheckVault.Zone);
            var body = Assert.Single(parsed.Blocks, b => b.CaptureId == capture.Id);
            Assert.Equal("Hello", body.Body);
            e.Writer.AppendIfMissing(capture, destination);
            Assert.Equal(saved, File.ReadAllBytes(file));
        }
    }

    [UnixFact]
    public void CacheFingerprintUsesCtimeAndInodeAndEvictsAfterEightDestinations()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var capture = CheckVault.Capture();
        var file = e.Write("Cached.md", "# Cached\n\n" + string.Concat(Enumerable.Repeat("old content\n", 100000)));
        var d = CheckVault.Destination(file, "Cached");
        e.Writer.AppendIfMissing(capture, d);
        var second = capture with
        {
            Id = Guid.NewGuid(),
            Content = CaptureContent.Text("Second cached body")
        };
        e.Writer.AppendIfMissing(second, d);
        var saved = CheckVault.Read(file);
        e.Writer.AppendIfMissing(capture, d);
        Assert.Equal(saved, CheckVault.Read(file));
        Assert.Equal(1, e.Writer.AppendCacheStatistics.FullScans);
        var before = e.Vault.FileSnapshot("Cached.md", false)!;
        CheckVault.NativeOverwrite(file, saved.Replace("### Safari\n", "### Chrome\n", StringComparison.Ordinal));
        CheckVault.RestoreModified(file, before);
        var edited = e.Vault.FileSnapshot("Cached.md", false)!;
        Assert.Equal(before.Inode, edited.Inode);
        Assert.Equal(before.Size, edited.Size);
        Assert.Equal(before.ModifiedSeconds, edited.ModifiedSeconds);
        Assert.Equal(before.ModifiedNanoseconds, edited.ModifiedNanoseconds);
        Assert.NotEqual((before.ChangedSeconds, before.ChangedNanoseconds), (edited.ChangedSeconds, edited.ChangedNanoseconds));
        second = second with
        {
            Id = Guid.NewGuid(),
            Content = CaptureContent.Text("After same-size edit")
        };
        e.Writer.AppendIfMissing(second, d);
        Assert.Equal(2, e.Writer.AppendCacheStatistics.FullScans);
        Assert.Contains("### Safari\n" + CheckVault.Marker(second.Id), CheckVault.Read(file), StringComparison.Ordinal);
        var after = CheckVault.Read(file);
        CheckVault.AtomicReplace(file, after);
        e.Writer.AppendIfMissing(second, d);
        Assert.Equal(3, e.Writer.AppendCacheStatistics.FullScans);
        Assert.Equal(after, CheckVault.Read(file));
        for (var i = 0; i < 12; i++)
        {
            e.Writer.AppendIfMissing(capture with { Id = Guid.NewGuid() }, CheckVault.Destination(e.Vault.UrlForRelativePath($"Cache limit {i}.md")));
        }

        Assert.InRange(e.Writer.AppendCacheStatistics.CachedFiles, 0, 8);
        var scans = e.Writer.AppendCacheStatistics.FullScans;
        e.Writer.AppendIfMissing(capture, d);
        Assert.Equal(scans + 1, e.Writer.AppendCacheStatistics.FullScans);
    }

    [Fact]
    public void CachedSourceParserMatchesFreshWritersAcrossFenceAndPendingLineCases()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var legacy = $"# Source\n\n### 2026-10-13 14:30 · Safari\n<!-- capture:{Guid.NewGuid():D} -->\n\nlegacy\n";
        var cached = e.Write("Source cached.md", legacy);
        var fresh = e.Write("Source fresh.md", legacy);
        var bodies = new[]
        {
            CaptureContent.Text("ordinary"),
            CaptureContent.Text("```markdown\n## fenced heading\n```"),
            CaptureContent.Text("~~~\n# still fenced"),
            CaptureContent.Text("### hidden source\n~~~"),
            CaptureContent.Note("## Note section\nbody"),
            CaptureContent.Text("after a note heading"),
            CaptureContent.Subheading("Details"),
            CaptureContent.Text("after a subheading"),
            CaptureContent.Text("````\n```\n## fenced\n````"),
            CaptureContent.Text("final")
        };
        foreach (var content in bodies)
        {
            var c = CheckVault.Capture() with
            {
                Content = content
            };
            e.Writer.AppendIfMissing(c, CheckVault.Destination(cached, "Source"));
            new NoteWriter(e.Vault, CheckVault.Zone).AppendIfMissing(c, CheckVault.Destination(fresh, "Source"));
            Assert.Equal(File.ReadAllBytes(fresh), File.ReadAllBytes(cached));
            foreach (var source in new[]
            {
                "Safari",
                "Chrome",
                "Unknown source"
            }

            )
            {
                Assert.True(NoteWriter.SourceGroupingMatchesFullParser(CheckVault.Read(cached), source, CheckVault.Zone));
            }
        }

        foreach (var suffix in new[]
        {
            "\r\n### Safari\r\n",
            "\n### Chrome",
            "\n~~~\n## fenced",
            $"\n### Safari\n<!-- capture:{Guid.NewGuid():D} -->",
            "\n    ```\n# indented"
        }

        )
        {
            Assert.True(NoteWriter.SourceGroupingMatchesFullParser(legacy + suffix, "Safari", CheckVault.Zone));
        }
    }

    [UnixFact]
    public void NonCooperatingPrewriteEditorForcesRescanBeforeDecisions()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var file = e.Vault.UrlForRelativePath("Prewrite.md");
        var armed = false;
        var writer = new NoteWriter(e.Vault, CheckVault.Zone, beforeAppend: path =>
        {
            if (armed)
            {
                armed = false;
                CheckVault.NativeOverwrite(path, CheckVault.NativeRead(path).Replace("### Safari\n", "### Chrome\n", StringComparison.Ordinal));
            }
        });
        var first = CheckVault.Capture();
        writer.AppendIfMissing(first, CheckVault.Destination(file));
        armed = true;
        var second = CheckVault.Capture();
        writer.AppendIfMissing(second, CheckVault.Destination(file));
        Assert.Equal(2, writer.AppendCacheStatistics.FullScans);
        Assert.Contains("### Chrome\n" + CheckVault.Marker(first.Id), CheckVault.Read(file), StringComparison.Ordinal);
        Assert.Contains("### Safari\n" + CheckVault.Marker(second.Id), CheckVault.Read(file), StringComparison.Ordinal);
        Assert.Equal(1, Count(CheckVault.Read(file), CheckVault.Marker(second.Id)));
    }

    [UnixFact]
    public void AtomicEditorReplacementRetriesWithAndWithoutCopiedAppendAndBoundsAttempts()
    {
        using var e = new CheckVault();
        e.Vault.Prepare();
        var capture = CheckVault.Capture();
        foreach (var copy in new[]
        {
            false,
            true
        }

        )
        {
            var remaining = 1;
            var file = e.Vault.UrlForRelativePath("Replacement " + copy + ".md");
            var writer = new NoteWriter(e.Vault, CheckVault.Zone, afterAppend: path =>
            {
                if (remaining-- > 0)
                {
                    CheckVault.AtomicReplace(path, copy ? CheckVault.NativeRead(path) : "# Replacement\n\neditor kept this\n");
                }
            });
            writer.AppendIfMissing(capture, CheckVault.Destination(file, "Replacement"));
            var text = CheckVault.Read(file);
            Assert.Equal(1, Count(text, CheckVault.Marker(capture.Id)));
            Assert.Contains("Hello\n", text, StringComparison.Ordinal);
            if (!copy)
            {
                Assert.Contains("editor kept this", text, StringComparison.Ordinal);
            }
        }

        var unstable = new NoteWriter(e.Vault, CheckVault.Zone, afterAppend: path => CheckVault.AtomicReplace(path, "# Replacement\n\neditor kept this\n"));
        Assert.Equal(VaultFileError.Changed, Assert.Throws<VaultFileException>(() => unstable.AppendIfMissing(capture, CheckVault.Destination(e.Vault.UrlForRelativePath("Unstable.md")))).Kind);
    }

    private static int Count(string text, string part) => text.Split(part, StringSplitOptions.None).Length - 1;
}
