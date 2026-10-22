using CaptureApp.AppCore.Shell;
using Xunit;

namespace CaptureApp.AppCore.Tests.Shell;

public sealed class NotesFolderChoiceTests
{
    [Fact]
    public void ProbeKeepsExistingFilesAndRemovesItsTemporaryFile()
    {
        using var directory = new TempDirectory();
        var note = Path.Combine(directory.Path, "My note.md");
        File.WriteAllText(note, "# Existing note\nKeep this text.");

        var folder = NotesFolderChoice.Probe(" " + directory.Path + Path.DirectorySeparatorChar + " ");

        Assert.Equal(Path.GetFullPath(directory.Path), folder);
        Assert.Equal("# Existing note\nKeep this text.", File.ReadAllText(note));
        Assert.Equal([note], Directory.GetFiles(directory.Path));
        Assert.True(NotesFolderChoice.SameFolder(folder, folder + Path.DirectorySeparatorChar));
    }

    [Theory]
    [InlineData("")]
    [InlineData(" ")]
    [InlineData("relative-notes")]
    [InlineData("../notes")]
    public void EmptyAndRelativePathsAreRejected(string path) =>
        Assert.Throws<ArgumentException>(() => NotesFolderChoice.Probe(path));

    [Fact]
    public void AFileCannotBecomeTheNotesFolder()
    {
        using var directory = new TempDirectory();
        var file = Path.Combine(directory.Path, "existing.md");
        File.WriteAllText(file, "existing");
        Assert.ThrowsAny<IOException>(() => NotesFolderChoice.Probe(file));
        Assert.Equal("existing", File.ReadAllText(file));
    }
}
