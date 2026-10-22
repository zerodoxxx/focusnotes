using System.Text;
using CaptureApp.Core;
using Xunit;

namespace CaptureApp.Core.Tests;

public sealed class LongNoteCollisionTests
{
    public static IEnumerable<object[]> BoundedLeaves =>
    [
        [new string('a', 120), new string('a', 118)],
        [new string('計', 72) + "abcd", new string('計', 72) + "ab"],
        [string.Concat(Enumerable.Repeat("😀", 55)), string.Concat(Enumerable.Repeat("😀", 54))]
    ];

    [Theory]
    [MemberData(nameof(BoundedLeaves))]
    public async Task SaveAsNewRetainsSuffixForLongAsciiAndMultibyteLeaves(string leaf, string numberedBase)
    {
        using var e = new CheckVault(windowsRules: true);
        var original = CheckVault.Capture("# " + leaf + "\nbody", CaptureContentKind.Note);
        var first = e.Service.PrepareNote(original, CheckVault.Zone);
        var second = await Task.Run(() => e.Service.PrepareNote(original with { Id = Guid.NewGuid() }, CheckVault.Zone, newNote: true), TestContext.Current.CancellationToken)
            .WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
        var third = await Task.Run(() => e.Service.PrepareNote(original with { Id = Guid.NewGuid() }, CheckVault.Zone, newNote: true), TestContext.Current.CancellationToken)
            .WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);

        Assert.Equal(leaf + ".md", Path.GetFileName(first.Destination.Url));
        Assert.Equal(numberedBase + " 2.md", Path.GetFileName(second.Destination.Url));
        Assert.Equal(numberedBase + " 3.md", Path.GetFileName(third.Destination.Url));
        Assert.True(second.CreatesNote);
        Assert.True(third.CreatesNote);
        foreach (var prepared in new[] { first, second, third })
        {
            var stem = Path.GetFileNameWithoutExtension(prepared.Destination.Url);
            Assert.True(NoteTitle.Graphemes(stem).Count <= 120);
            Assert.True(Encoding.UTF8.GetByteCount(stem) <= 220);
        }
    }

    [Fact]
    public async Task SaveAsNewKeepsTheWholeRelativePathWithinTheByteLimit()
    {
        using var e = new CheckVault(windowsRules: true);
        var folders = string.Join('/', Enumerable.Repeat(new string('d', 120), 7));
        var leaf = new string('n', 53);
        var name = folders + "/" + leaf;
        Assert.Equal(NotePathName.MaximumRelativePathBytes, Encoding.UTF8.GetByteCount(name));
        var original = CheckVault.Capture("# " + name + "\nbody", CaptureContentKind.Note);
        var first = e.Service.PrepareNote(original, CheckVault.Zone);
        var second = await Task.Run(() => e.Service.PrepareNote(original with { Id = Guid.NewGuid() }, CheckVault.Zone, newNote: true), TestContext.Current.CancellationToken)
            .WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);

        Assert.Equal(Path.GetDirectoryName(first.Destination.Url), Path.GetDirectoryName(second.Destination.Url));
        Assert.Equal(new string('n', 51) + " 2.md", Path.GetFileName(second.Destination.Url));
        Assert.Equal(NotePathName.MaximumRelativePathBytes, Encoding.UTF8.GetByteCount(e.Vault.NoteId(second.Destination.Url)[..^3]));
    }
}
