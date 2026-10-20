using System.Text;

namespace CaptureApp.Core;

public sealed record VaultFileSnapshot(byte[]? Contents, long Size, ulong Device, ulong Inode, long ModifiedSeconds, long ModifiedNanoseconds, long ChangedSeconds, long ChangedNanoseconds)
{
    public DateTimeOffset ModifiedAt => DateTimeOffset.FromUnixTimeSeconds(ModifiedSeconds).AddTicks(ModifiedNanoseconds / 100);
    public DateTimeOffset ChangedAt => DateTimeOffset.FromUnixTimeSeconds(ChangedSeconds).AddTicks(ChangedNanoseconds / 100);

    internal static VaultFileSnapshot From(FileMetadata value, byte[]? contents) => new(contents, value.Size, value.Device, value.Inode, value.ModifiedSeconds, value.ModifiedNanoseconds, value.ChangedSeconds, value.ChangedNanoseconds);
}

public sealed record VaultNoteFile(string Id, string Url, NoteKind Kind, VaultFileSnapshot? Snapshot);
public sealed record VaultNoteLocation(NotePathScope Scope, string RelativePath, string Url)
{
    public string Id => Scope == NotePathScope.Vault ? RelativePath : new Uri(Path.GetFullPath(Url)).AbsoluteUri;
}

public sealed record VaultManagedLocation(VaultNoteLocation Note, string Root)
{
    public NotePathScope Scope => Note.Scope;
    public string RelativePath => Note.RelativePath;
    public string Url => Note.Url;
}

public sealed class Vault
{
    public const string InboxFileName = "Inbox.md";
    public const string InboxTitle = "Inbox";
    public const string SessionsDirectoryName = "Sessions";
    public const string AssetsDirectoryName = "assets";
    public string Root { get; }
    public string HomeRoot { get; }
    public string InboxUrl => Path.Combine(Root, InboxFileName);
    public string SessionsUrl => Path.Combine(Root, SessionsDirectoryName);
    public string AssetsUrl => Path.Combine(Root, AssetsDirectoryName);
    public VaultNamingRules NamingRules { get; }
    public ExternalNoteRegistry? ExternalNoteRegistry { get; }

    private FileMetadata? rootIdentity;
    public Vault(string root, string? externalNoteRegistryUrl = null, string? homeDirectoryUrl = null, VaultNamingRules? namingRules = null)
    {
        Root = NoteFile.ResolveSelectedRoot(root);
        HomeRoot = NoteFile.ResolveSelectedRoot(homeDirectoryUrl ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
        NamingRules = namingRules ?? new();
        ExternalNoteRegistry = externalNoteRegistryUrl is null ? null : new(externalNoteRegistryUrl);
        try { rootIdentity = FileMetadata.At(Root); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private void ValidateRoot()
    {
        var current = FileMetadata.At(Root);
        if (rootIdentity is not null && current is not null && !rootIdentity.SameFile(current))
        {
            throw new VaultFileException(VaultFileError.Changed, "The selected root was replaced.");
        }

        current?.Validate(directory: true);
        rootIdentity ??= current;
    }

    public void Prepare()
    {
        ValidateRoot();
        NoteFile.PrepareRoot(Root);
        rootIdentity ??= FileMetadata.At(Root);
        NoteFile.PrepareManagedDirectory(Root, SessionsDirectoryName);
        NoteFile.PrepareManagedDirectory(Root, AssetsDirectoryName);
        NoteFile.PrepareInbox(Root);
    }

    public void ValidateExternalNoteRegistry()
    {
        ExternalNoteRegistry?.InvalidateCache();
        _ = ExternalRegistrySnapshot();
    }

    public ExternalNoteRegistry.Snapshot? ExternalRegistrySnapshot() => ExternalNoteRegistry?.GetSnapshot();
    public void InvalidateExternalRegistryCache() => ExternalNoteRegistry?.InvalidateCache();
    public VaultFileSnapshot? ExternalRegistryFingerprint() => ExternalNoteRegistry?.CurrentFingerprint();
    public IReadOnlyList<VaultNoteLocation> ExternalNoteLocations(ExternalNoteRegistry.Snapshot? snapshot = null)
    {
        if (ExternalNoteRegistry is null)
        {
            return [];
        }

        var result = new List<VaultNoteLocation>();
        foreach (var path in (snapshot ?? ExternalNoteRegistry.GetSnapshot()).Paths)
        {
            try
            {
                var managed = ManagedLocation(Path.Combine(HomeRoot, path.Replace('/', Path.DirectorySeparatorChar)));
                if (managed.Scope == NotePathScope.Home)
                {
                    result.Add(managed.Note);
                }
            }
            catch (ArgumentException)
            {
            }
            catch (VaultFileException)
            {
            }
        }

        return result.OrderBy(x => x.Id, StringComparer.Ordinal).ToArray();
    }

    public IReadOnlyList<NoteRef> ListNotes() => ListNotes(ExternalRegistrySnapshot());
    public IReadOnlyList<NoteRef> ListNotes(ExternalNoteRegistry.Snapshot? externalRegistrySnapshot)
    {
        var result = new List<NoteRef>();
        foreach (var file in MarkdownFiles(false))
        {
            try
            {
                var prefix = NoteFile.ReadManagedPrefix(4096, Root, file.Id);
                if (prefix is not null)
                {
                    result.Add(new(file.Url, Title(file.Url, prefix), file.Kind));
                }
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }

        foreach (var location in ExternalNoteLocations(externalRegistrySnapshot))
        {
            try
            {
                var prefix = NoteFile.ReadManagedPrefix(4096, HomeRoot, location.RelativePath);
                if (prefix is not null)
                {
                    result.Add(new(location.Url, Title(location.Url, prefix), NoteKind.Note));
                }
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }

        return result;
    }

    public IReadOnlyList<VaultNoteFile> ListNoteFiles()
    {
        var result = MarkdownFiles(true).Where(x => x.Snapshot is not null).ToList();
        foreach (var location in ExternalNoteLocations())
        {
            try
            {
                var snapshot = FileSnapshotForNoteId(location.Id, false);
                if (snapshot is not null)
                {
                    result.Add(new(location.Id, location.Url, NoteKind.Note, snapshot));
                }
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }

        return result;
    }

    private IReadOnlyList<VaultNoteFile> MarkdownFiles(bool metadata)
    {
        ValidateRoot();
        var result = new List<VaultNoteFile>();
        if (!Directory.Exists(Root))
        {
            return result;
        }

        void Visit(string relative)
        {
            var directory = relative.Length == 0 ? Root : Path.GetDirectoryName(NoteFile.SafePath(Root, relative + "/.read-check"))!;
            foreach (var entry in Directory.EnumerateFileSystemEntries(directory).Order(StringComparer.Ordinal))
            {
                var name = Path.GetFileName(entry);
                if (name.StartsWith('.') || relative.Length == 0 && name.Equals(AssetsDirectoryName, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                var path = relative.Length == 0 ? name : relative + "/" + name;
                try
                {
                    var value = FileMetadata.At(entry);
                    if (value?.IsDirectory == true)
                    {
                        _ = NoteFile.SafePath(Root, path + "/.read-check");
                        Visit(path);
                    }
                    else if (!name.StartsWith("~$", StringComparison.Ordinal) && Path.GetExtension(name).Equals(".md", StringComparison.OrdinalIgnoreCase))
                    {
                        value?.Validate();
                        if (value is not null && !value.IsLink)
                        {
                            result.Add(new(path, entry, Kind(path), metadata ? VaultFileSnapshot.From(value, null) : null));
                        }
                    }
                }
                catch (IOException)
                {
                }
                catch (UnauthorizedAccessException)
                {
                }
            }
        }

        Visit("");
        return result.OrderBy(x => x.Id, StringComparer.Ordinal).ToArray();
    }

    public string UniqueNoteUrl(string title, ISet<string>? excluding = null)
    {
        var stem = NoteTitle.FileStem(title);
        NamingRules.ValidateComponent(stem);
        var candidate = Path.Combine(Root, stem + ".md");
        var suffix = 2;
        while (File.Exists(candidate) || Directory.Exists(candidate) || excluding?.Contains(candidate) == true)
        {
            candidate = Path.Combine(Root, $"{stem} {suffix++}.md");
        }

        return candidate;
    }

    public VaultNoteLocation ResolveNoteName(string rawName) => ResolveNoteName(NoteTitle.PathName(rawName, NamingRules));
    public VaultNoteLocation ResolveNoteName(NotePathName name)
    {
        ValidateName(name);
        var root = name.Scope == NotePathScope.Vault ? Root : HomeRoot;
        var parents = new List<string>();
        for (var i = 0; i < name.Components.Count - 1; i++)
        {
            var directory = Path.Combine(root, string.Join(Path.DirectorySeparatorChar, parents));
            var matched = MatchingName(name.Components[i], directory);
            if (matched is null)
            {
                parents.AddRange(name.Components.Skip(i).Take(name.Components.Count - 1 - i));
                break;
            }

            var candidate = Path.Combine(directory, matched);
            if (FileMetadata.At(candidate) is not { IsDirectory: true, IsLink: false })
            {
                throw new VaultFileException(VaultFileError.InvalidFileName);
            }

            _ = NoteFile.SafePath(root, string.Join('/', parents.Append(matched)) + "/.resolve-check");
            parents.Add(matched);
        }

        var leaf = name.LeafName + ".md";
        var existing = MatchingName(leaf, Path.Combine(root, string.Join(Path.DirectorySeparatorChar, parents)));
        var relative = string.Join('/', parents.Append(existing ?? leaf));
        return Location(name.Scope, relative);
    }

    public VaultNoteLocation DeferredNoteLocation(NotePathName name)
    {
        ValidateName(name);
        return Location(name.Scope, name.RelativePath + ".md");
    }

    private VaultNoteLocation Location(NotePathScope scope, string relative)
    {
        var root = scope == NotePathScope.Vault ? Root : HomeRoot;
        var url = Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar));
        if (scope == NotePathScope.Home && RelativeUnder(url, Root) is { } vaultRelative)
        {
            scope = NotePathScope.Vault;
            relative = vaultRelative;
        }

        ValidateNoteLocation(scope, relative);
        return new(scope, relative, url);
    }

    private void ValidateName(NotePathName name)
    {
        _ = NotePathName.Validated(name.Scope, name.Components, NamingRules);
    }

    private static string? MatchingName(string requested, string directory)
    {
        if (!Directory.Exists(directory))
        {
            return null;
        }

        var names = Directory.EnumerateFileSystemEntries(directory).Select(Path.GetFileName).OfType<string>().Where(n => string.Equals(n.Normalize(), requested.Normalize(), StringComparison.OrdinalIgnoreCase)).Order(StringComparer.Ordinal).ToArray();
        return names.FirstOrDefault(n => n == requested) ?? names.FirstOrDefault();
    }

    private void ValidateNoteLocation(NotePathScope scope, string relative)
    {
        var components = NoteFile.PathComponents(relative);
        if (components[^1].StartsWith("~$", StringComparison.Ordinal) || scope == NotePathScope.Vault && components[0].Equals(AssetsDirectoryName, StringComparison.OrdinalIgnoreCase))
        {
            throw new NotePathNameException(NotePathNameError.InvalidComponent);
        }

        foreach (var value in components)
        {
            NamingRules.ValidateComponent(value);
        }
    }

    public VaultManagedLocation ManagedLocation(string url)
    {
        var path = DecodeFilePath(url);
        if (!Path.IsPathFullyQualified(path) || path.Contains('\0') || path.Split(Path.DirectorySeparatorChar).Any(p => p is "." or ".."))
        {
            throw new VaultFileException(VaultFileError.InvalidFileName);
        }

        var unrooted = path[Path.GetPathRoot(path)!.Length..];
        if (unrooted.Split(Path.DirectorySeparatorChar).Any(p => p.Length == 0))
        {
            throw new VaultFileException(VaultFileError.InvalidFileName);
        }

        var relative = RelativeUnder(path, Root);
        var scope = NotePathScope.Vault;
        var root = Root;
        if (relative is null)
        {
            relative = RelativeUnder(path, HomeRoot);
            scope = NotePathScope.Home;
            root = HomeRoot;
        }

        if (relative is null)
        {
            throw new VaultFileException(VaultFileError.InvalidFileName);
        }

        ValidateNoteLocation(scope, relative);
        if (scope == NotePathScope.Vault)
        {
            ValidateRoot();
        }

        return new(new(scope, relative, Path.GetFullPath(path)), root);
    }

    public string NoteId(string url) => ManagedLocation(url).Note.Id;
    public string UrlForRelativePath(string path) => Path.Combine(Root, path.Replace('/', Path.DirectorySeparatorChar));
    public string ManagedUrl(string relativePath)
    {
        _ = NoteFile.PathComponents(relativePath);
        var managed = ManagedLocation(UrlForRelativePath(relativePath));
        if (managed.Scope != NotePathScope.Vault || managed.RelativePath != relativePath)
        {
            throw new VaultFileException(VaultFileError.InvalidFileName);
        }

        return managed.Url;
    }

    public string? RelativePath(string url) => RelativeUnder(DecodeFilePath(url), Root);
    public static string? RelativeUnder(string path, string root)
    {
        var prefix = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root)) + Path.DirectorySeparatorChar;
        var full = Path.GetFullPath(path);
        return full.StartsWith(prefix, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal) ? full[prefix.Length..].Replace(Path.DirectorySeparatorChar, '/') : null;
    }

    public static string DecodeFilePath(string path)
    {
        if (!path.StartsWith("file:", StringComparison.OrdinalIgnoreCase))
        {
            return path;
        }

        if (!Uri.TryCreate(path, UriKind.Absolute, out var uri) || !uri.IsFile || uri.Host.Length != 0 || uri.UserInfo.Length != 0 || uri.Query.Length != 0 || uri.Fragment.Length != 0 || uri.AbsoluteUri != path)
        {
            throw new VaultFileException(VaultFileError.PermissionDenied);
        }

        return uri.LocalPath;
    }

    public VaultFileSnapshot? FileSnapshot(string relativePath, bool includingContents = true)
    {
        ValidateRoot();
        return NoteFile.ReadManagedSnapshot(Root, relativePath, includingContents);
    }

    public VaultFileSnapshot? FileSnapshotForNoteId(string noteId, bool includingContents = true)
    {
        var location = ManagedLocationForNoteId(noteId);
        return NoteFile.ReadManagedSnapshot(location.Root, location.RelativePath, includingContents);
    }

    private VaultManagedLocation ManagedLocationForNoteId(string id)
    {
        var external = id.StartsWith("file://", StringComparison.Ordinal);
        if (!external && (Path.IsPathRooted(id) || id.Length == 0))
        {
            throw new VaultFileException(VaultFileError.PermissionDenied);
        }

        var managed = ManagedLocation(external ? DecodeFilePath(id) : ManagedUrl(id));
        if (managed.Note.Id != id || !Path.GetExtension(managed.Url).Equals(".md", StringComparison.OrdinalIgnoreCase) || external && (managed.Scope != NotePathScope.Home || ExternalNoteRegistry?.Paths().Contains(managed.RelativePath, StringComparer.Ordinal) != true))
        {
            throw new VaultFileException(VaultFileError.PermissionDenied);
        }

        return managed;
    }

    public VaultNoteLocation NoteLocation(string id)
    {
        var location = ManagedLocationForNoteId(id);
        if (NoteFile.ReadManagedSnapshot(location.Root, location.RelativePath, false) is null)
        {
            throw new VaultFileException(VaultFileError.PermissionDenied);
        }

        return location.Note;
    }

    public void RegisterExternalNote(VaultNoteLocation location)
    {
        if (location.Scope != NotePathScope.Home)
        {
            return;
        }

        var managed = ManagedLocation(location.Url);
        if (ExternalNoteRegistry is null || managed.Scope != NotePathScope.Home || managed.Note != location)
        {
            throw new VaultFileException(VaultFileError.PermissionDenied);
        }

        ExternalNoteRegistry.Register(location.RelativePath);
    }

    private static NoteKind Kind(string relative) => relative == InboxFileName ? NoteKind.Inbox : relative.StartsWith(SessionsDirectoryName + "/", StringComparison.Ordinal) ? NoteKind.Session : NoteKind.Note;
    private static string Title(string path, byte[] data)
    {
        var line = Encoding.UTF8.GetString(data).Split('\n')[0].TrimStart('\uFEFF');
        var title = line.StartsWith("# ", StringComparison.Ordinal) ? NoteTitle.CleanTitle(line[2..]) : "";
        return title.Length == 0 ? Path.GetFileNameWithoutExtension(path) : title;
    }
}
