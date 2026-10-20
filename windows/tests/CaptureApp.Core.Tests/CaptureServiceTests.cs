using System.Text.Json;
using CaptureApp.Core;
using CaptureApp.Core.Index;
using Xunit;

namespace CaptureApp.Core.Tests;

public sealed class CaptureServiceTests
{
    [Fact]
    public void DirectSaveRoutingTextImagesAndFixedDestinationReplay()
    {
        using var e = new CheckVault();
        var id = Guid.Parse("00000000-0000-4000-8000-0000000000AA");
        var service = new CaptureService(e.Vault, e.Sessions, e.Writer, CheckVault.Clock, () => id);
        byte[] png = [0x89, 0x50, 0x4e, 0x47];
        var inbox = service.SaveText("Hello inbox", new("Safari"));
        Assert.Equal(id, inbox.CaptureId);
        Assert.Equal(NoteKind.Inbox, inbox.Destination.Kind);
        Assert.Equal(e.Vault.InboxUrl, inbox.Destination.Url);
        Assert.Contains(CheckVault.Marker(id), CheckVault.Read(e.Vault.InboxUrl), StringComparison.Ordinal);
        e.Sessions.Start("Design");
        var session = service.SaveText("Into session", new("Xcode"));
        Assert.Equal(NoteKind.Session, session.Destination.Kind);
        Assert.Contains("### Xcode\n", CheckVault.Read(session.Destination.Url), StringComparison.Ordinal);
        Assert.DoesNotContain("Into session", CheckVault.Read(e.Vault.InboxUrl), StringComparison.Ordinal);
        Assert.Equal(NoteKind.Inbox, service.SaveText("Heading wins", new(), "Inbox").Destination.Kind);
        Assert.Contains("Heading wins", CheckVault.Read(e.Vault.InboxUrl), StringComparison.Ordinal);
        var existing = e.Write("Science/Math/Trigonometry.md", "# Existing nested note\n\n");
        var capture = CheckVault.Capture("Nested heading capture");
        var prepared = service.Prepare(capture, "science/math/trigonometry");
        Assert.Equal(existing, prepared.Destination.Url);
        Assert.Equal("trigonometry", prepared.Destination.Title);
        service.Save(prepared);
        Assert.StartsWith("# Existing nested note\n\n", CheckVault.Read(existing), StringComparison.Ordinal);
        var nested = service.Prepare(CheckVault.Capture("Create nested destination"), "Science/New Folder/New Note");
        service.Save(nested);
        service.Save(nested);
        Assert.Equal(1, Count(CheckVault.Read(nested.Destination.Url), CheckVault.Marker(nested.Capture.Id)));
        Assert.Throws<NotePathNameException>(() => service.Prepare(CheckVault.Capture("unsafe"), "Science/../escape"));
        var nestedImage = service.SaveImage(png, new(), "science/new folder/new note");
        Assert.Contains("![](../../assets/", CheckVault.Read(nestedImage.Destination.Url), StringComparison.Ordinal);
        var image = service.SaveImage(png, new("Preview"));
        Assert.Equal(NoteKind.Session, image.Destination.Kind);
        var parsed = NoteParser.Parse(CheckVault.Read(image.Destination.Url), e.Vault.NoteId(image.Destination.Url), "", CheckVault.Zone);
        var asset = parsed.Blocks.Last(b => b.Kind == BlockKind.Image).AssetPath!;
        Assert.Equal(png, File.ReadAllBytes(e.Vault.UrlForRelativePath(asset)));
        var inboxImage = service.SaveImage(png, new(), "Inbox");
        Assert.Contains("![](assets/", CheckVault.Read(inboxImage.Destination.Url), StringComparison.Ordinal);
        Assert.DoesNotContain("![](../", CheckVault.Read(inboxImage.Destination.Url), StringComparison.Ordinal);
        var retry = service.Prepare(CheckVault.Capture("retry identity"), "Retry Destination");
        Directory.CreateDirectory(retry.Destination.Url);
        Assert.ThrowsAny<IOException>(() => service.Save(retry));
        Directory.Delete(retry.Destination.Url);
        e.Sessions.Start("Changed Session");
        var saved = service.Save(retry);
        Assert.Equal(saved, service.Save(retry));
        Assert.Equal(retry.Destination, saved.Destination);
        Assert.Equal(1, Count(CheckVault.Read(saved.Destination.Url), CheckVault.Marker(saved.CaptureId)));
        Assert.Equal(retry.Capture.CreatedAt, Assert.Single(NoteParser.Parse(CheckVault.Read(saved.Destination.Url), "Retry.md", "", CheckVault.Zone).Blocks).CreatedAt);
    }

    [Fact]
    public void OfflinePreparationDoesNotCreateRootAndRegistryErrorsFailClosed()
    {
        using var e = new CheckVault();
        var capture = CheckVault.Capture("queue while vault is detached");
        var queued = e.Service.Prepare(capture, "Queued Note");
        Assert.Equal(e.Vault.UrlForRelativePath("Queued Note.md"), queued.Destination.Url);
        Assert.False(Directory.Exists(e.Vault.Root));
        using var external = new CheckVault(registry: true);
        external.WriteRegistry("{\"version\":1,\"paths\":[\"Desktop/Registered.md\"]}x");
        var scanned = false;
        var error = Assert.Throws<ExternalNoteRegistryException>(() => CaptureService.LoadNotesForRouting(external.Vault.ExternalRegistrySnapshot, _ =>
        {
            scanned = true;
            throw new VaultFileException(VaultFileError.Unavailable);
        }));
        Assert.Equal(ExternalNoteRegistryError.MalformedRegistry, error.Kind);
        Assert.False(scanned);
        Assert.Throws<VaultFileException>(() => CaptureService.LoadNotesForRouting(() => new(0, ["Desktop/Registered.md"]), _ => throw new VaultFileException(VaultFileError.Unavailable)));
        Assert.Empty(CaptureService.LoadNotesForRouting(() => null, _ => throw new VaultFileException(VaultFileError.Unavailable)));
        Assert.Empty(CaptureService.LoadNotesForRouting(() => new(0, []), _ => throw new VaultFileException(VaultFileError.Unavailable)));
    }

    [Fact]
    public void DirectCaptureMethodsRejectLinkedInboxAndAssetsBeforeWriting()
    {
        using var e = new CheckVault();
        Directory.CreateDirectory(e.Vault.Root);
        var outside = Path.Combine(e.Base, "outside.md");
        CheckVault.WriteAbsolute(outside, "outside text\n");
        CheckVault.SymbolicLink(e.Vault.InboxUrl, outside);
        Assert.ThrowsAny<IOException>(() => e.Service.SaveText("must not escape", new()));
        Assert.Equal("outside text\n", CheckVault.Read(outside));
        File.Delete(e.Vault.InboxUrl);
        var assets = Path.Combine(e.Base, "outside-assets");
        Directory.CreateDirectory(assets);
        Directory.Delete(e.Vault.AssetsUrl);
        CheckVault.SymbolicLink(e.Vault.AssetsUrl, assets, true);
        Assert.ThrowsAny<IOException>(() => e.Service.SaveImage([1, 2, 3], new()));
        Assert.ThrowsAny<IOException>(() => e.Writer.SaveImage([1, 2, 3], CheckVault.Now));
        Assert.Empty(Directory.EnumerateFiles(assets));
    }

    [Fact]
    public void CaptureRecoveryJsonMatchesSwiftCodableShapes()
    {
        using var e = new CheckVault();
        var id = Guid.Parse("a1b2c3d4-0000-4000-8000-00000000000f");
        foreach (var content in new[]
        {
            CaptureContent.Text("body"),
            CaptureContent.Note("body"),
            CaptureContent.Subheading("body"),
            CaptureContent.Image("assets/shot.png")
        }

        )
        {
            var capture = new Capture(id, CheckVault.Now, content, new());
            var prepared = new PreparedCapture(capture, new(e.Vault.InboxUrl, "Inbox", NoteKind.Inbox));
            var text = JsonSerializer.Serialize(prepared);
            using var json = JsonDocument.Parse(text);
            var root = json.RootElement;
            Assert.Equal(id.ToString("D").ToUpperInvariant(), root.GetProperty("capture").GetProperty("id").GetString());
            Assert.Equal((CheckVault.Now - new DateTimeOffset(2001, 1, 1, 0, 0, 0, TimeSpan.Zero)).TotalSeconds, root.GetProperty("capture").GetProperty("createdAt").GetDouble());
            Assert.Equal(JsonValueKind.Object, root.GetProperty("destination").GetProperty("kind").GetProperty("inbox").ValueKind);
            Assert.Equal(new Uri(e.Vault.InboxUrl).AbsoluteUri, root.GetProperty("destination").GetProperty("url").GetString());
            Assert.Empty(root.GetProperty("capture").GetProperty("source").EnumerateObject());
            Assert.False(root.TryGetProperty("createsNote", out _));
            Assert.False(root.TryGetProperty("noteMarkerIsIdentity", out _));
            Assert.Equal(prepared, JsonSerializer.Deserialize<PreparedCapture>(text));
        }
    }

    private static int Count(string text, string part) => text.Split(part, StringSplitOptions.None).Length - 1;
}
