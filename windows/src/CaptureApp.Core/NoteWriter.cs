using System.Security.Cryptography;
using System.Text;
using CaptureApp.Core.Index;

namespace CaptureApp.Core;

public sealed class NoteWriter(Vault vault, TimeZoneInfo timeZone, TimeProvider? timeProvider = null, Action<string>? beforeAppend = null, Action<string>? afterAppend = null)
{
    private readonly object gate = new();
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private readonly Dictionary<string, AppendState> cache = new(StringComparer.Ordinal);
    private readonly List<string> order = [];
    private int fullScans;
    private const int FileLimit = 8, MarkerLimit = 50000, SourceByteLimit = 65536;
    private sealed class AppendState(FileMetadata fingerprint)
    {
        internal FileMetadata Fingerprint = fingerprint;
        internal readonly Dictionary<string, List<long>> Markers = new(StringComparer.Ordinal);
        internal readonly NoteParser.SourceHeadingState Source = new();
        internal int Count;
        internal void Consume(byte[] data, long offset, TimeZoneInfo zone)
        {
            foreach (var prefix in new[]
            {
                "<!-- capture:",
                "<!-- note:",
                "<!-- subheading:"
            }

            )
            {
                var needle = Encoding.UTF8.GetBytes(prefix);
                var start = 0;
                while (start < data.Length)
                {
                    var found = data.AsSpan(start).IndexOf(needle);
                    if (found < 0)
                    {
                        break;
                    }

                    found += start;
                    if (found + needle.Length + 36 <= data.Length)
                    {
                        var identity = Encoding.UTF8.GetString(data, found, needle.Length + 36);
                        if (Guid.TryParseExact(identity[^36..], "D", out _))
                        {
                            if (!Markers.TryGetValue(identity, out var offsets))
                            {
                                offsets = [];
                                Markers[identity] = offsets;
                            }

                            offsets.Add(offset + found);
                            Count++;
                            if (Count > MarkerLimit)
                            {
                                break;
                            }
                        }
                    }

                    start = found + needle.Length;
                }
            }

            Source.Consume(Encoding.UTF8.GetString(data), zone);
        }
    }

    public (int FullScans, int CachedFiles) AppendCacheStatistics
    {
        get
        {
            lock (gate)
            {
                return (fullScans, cache.Count);
            }
        }
    }

    public static bool SourceGroupingMatchesFullParser(string contents, string source, TimeZoneInfo zone)
    {
        var state = new NoteParser.SourceHeadingState();
        state.Consume(contents, zone);
        return state.NeedsHeading(source, zone) == NoteParser.NeedsSourceHeading(source, contents, zone);
    }

    public void Append(Capture capture, string note, string title) => AppendCore(capture, new(note, title, NoteKind.Note), false, false);
    public void AppendIfMissing(Capture capture, Destination destination, byte[]? png = null, bool noteMarkerIsIdentity = false)
    {
        lock (gate)
        {
            if (capture.Content.Kind == CaptureContentKind.Image)
            {
                var path = CheckedAssetPath(capture.Content.Value);
                if (png is not null)
                {
                    NoteFile.EnsureAsset(png, vault.Root, path);
                }
            }

            AppendCore(capture, destination, true, noteMarkerIsIdentity);
        }
    }

    private void AppendCore(Capture capture, Destination destination, bool replay, bool noteIdentity)
    {
        lock (gate)
        {
            var location = vault.ManagedLocation(destination.Url);
            var target = NoteFile.SafePath(location.Root, location.RelativePath, true);
            var directory = string.Join('/', location.RelativePath.Split('/').SkipLast(1));
            var prefix = CaptureFormat.RelativePath(Path.GetDirectoryName(target)!, vault.Root);
            if (prefix == ".")
            {
                prefix = "";
            }

            var block = CaptureFormat.Block(capture, directory, timeZone, false, prefix);
            var header = CaptureFormat.NoteHeader(destination.Title) + "\n";
            var kind = capture.Content.Kind;
            var identity = "<!-- " + (kind == CaptureContentKind.Note ? "note:" : kind == CaptureContentKind.Subheading ? "subheading:" : "capture:") + capture.Id.ToString("D");
            var savedMarker = replay && noteIdentity && kind == CaptureContentKind.Note ? block.Split('\n')[0] : null;
            var heading = kind is CaptureContentKind.Note or CaptureContentKind.Subheading ? null : CaptureFormat.SourceHeading(capture.Source);
            var equivalents = kind is CaptureContentKind.Note or CaptureContentKind.Subheading ? Array.Empty<string>() : new[]
            {
                $"<!-- capture:{capture.Id:D} -->" + block[block.IndexOf('\n')..]
            };
            lock (NoteFile.Gate(target))
            {
                // A replace that lost the note leaves a hidden copy; put it back so the append extends the old note.
                NoteFile.RestoreRecovered(location.Root, target);
                if (savedMarker is not null)
                {
                    NoteFile.Create(NoteFile.Utf8.GetBytes(header + block), location.Root, location.RelativePath);
                }

                for (var attempt = 0; attempt < 4; attempt++)
                {
                    target = NoteFile.SafePath(location.Root, location.RelativePath, true);
                    using var stream = NoteFile.OpenExclusive(target, FileMode.OpenOrCreate, FileAccess.ReadWrite);
                    var initial = FileMetadata.Of(stream);
                    var state = Take(target, initial);
                    var emitted = block;
                    if (replay || heading is not null || attempt > 0)
                    {
                        byte[]? contents = null;
                        if (state is null)
                        {
                            stream.Position = 0;
                            using var buffer = new MemoryStream();
                            stream.CopyTo(buffer);
                            contents = buffer.ToArray();
                            fullScans++;
                            var scanned = new AppendState(initial);
                            scanned.Consume(contents, 0, timeZone);
                            if (scanned.Count <= MarkerLimit && scanned.Source.RetainedByteCount <= SourceByteLimit)
                            {
                                state = scanned;
                            }
                        }

                        var requested = new[]
                        {
                            block
                        }.Concat(equivalents).Select(NoteFile.Utf8.GetBytes).ToArray();
                        var alreadySaved = state is not null ? Matches(stream, state, identity, savedMarker, requested) : savedMarker is not null && contents!.AsSpan().IndexOf(NoteFile.Utf8.GetBytes(savedMarker)) >= 0 || requested.Any(bytes => contents!.AsSpan().IndexOf(bytes) >= 0);
                        if (alreadySaved)
                        {
                            if (!Current(stream, initial, location))
                            {
                                continue;
                            }

                            if (state is not null)
                            {
                                Store(target, state);
                            }

                            return;
                        }

                        if (heading is not null && (state?.Source.NeedsHeading(heading, timeZone) ?? NoteParser.NeedsSourceHeading(heading, Encoding.UTF8.GetString(contents!), timeZone)))
                        {
                            emitted = "### " + heading + "\n" + block;
                        }
                    }

                    var separator = header;
                    if (initial.Size > 0)
                    {
                        stream.Position = Math.Max(0, initial.Size - 2);
                        var tail = new byte[(int)Math.Min(2, initial.Size)];
                        stream.ReadExactly(tail);
                        separator = tail.Length >= 2 && tail[^2] == 10 && tail[^1] == 10 ? "" : tail[^1] == 10 ? "\n" : "\n\n";
                    }

                    beforeAppend?.Invoke(target);
                    if (!Current(stream, initial, location))
                    {
                        continue;
                    }

                    var data = NoteFile.Utf8.GetBytes(separator + emitted);
                    // Written through the handle, not the stream's buffer: a stuck buffered flush would otherwise
                    // be retried (and could leave partial bytes again) when the stream is disposed after rollback.
                    var handle = stream.SafeFileHandle;
                    try
                    {
                        if (NoteFile.AppendWriteHook.Value is { } hook)
                        {
                            hook(handle, initial.Size, data);
                        }
                        else
                        {
                            RandomAccess.Write(handle, data, initial.Size);
                            RandomAccess.FlushToDisk(handle);
                        }
                    }
                    catch
                    {
                        // A failed append can leave a valid note marker followed by only part of its body, and replay
                        // accepts the marker alone, so drop this attempt's bytes before the error triggers a retry.
                        // If rollback fails, still surface the original write error.
                        try
                        {
                            RandomAccess.SetLength(handle, initial.Size);
                        }
                        catch (Exception rollback)
                        {
                            NoteFile.Report($"Append rollback failed for {target}; partial bytes may remain: {rollback}");
                        }

                        throw;
                    }

                    var written = FileMetadata.Of(stream);
                    afterAppend?.Invoke(target);
                    if (!Current(stream, written, location))
                    {
                        continue;
                    }

                    if (state is not null && written.Size == initial.Size + data.Length)
                    {
                        state.Consume(data, initial.Size, timeZone);
                        state.Fingerprint = written;
                        Store(target, state);
                    }

                    return;
                }

                throw new VaultFileException(VaultFileError.Changed, "The note changed during four append attempts.");
            }
        }
    }

    private static bool Current(FileStream stream, FileMetadata expected, VaultManagedLocation location)
    {
        var path = NoteFile.SafePath(location.Root, location.RelativePath);
        var named = FileMetadata.At(path);
        named?.Validate();
        return named is not null && expected.SameFile(named) && FileMetadata.Of(stream) == expected;
    }

    private AppendState? Take(string path, FileMetadata fingerprint)
    {
        order.Remove(path);
        if (!cache.Remove(path, out var state) || state.Fingerprint != fingerprint)
        {
            return null;
        }

        return state;
    }

    private void Store(string path, AppendState state)
    {
        if (state.Count > MarkerLimit || state.Source.RetainedByteCount > SourceByteLimit)
        {
            return;
        }

        while (order.Count >= FileLimit || order.Count > 0 && cache.Values.Sum(s => s.Count) + state.Count > MarkerLimit)
        {
            cache.Remove(order[0]);
            order.RemoveAt(0);
        }

        cache[path] = state;
        order.Add(path);
    }

    private static bool Matches(FileStream stream, AppendState state, string identity, string? savedMarker, byte[][] blocks)
    {
        if (!state.Markers.TryGetValue(identity, out var offsets))
        {
            return false;
        }

        var needle = NoteFile.Utf8.GetBytes(identity);
        bool EqualsAt(byte[] expected, long offset)
        {
            if (offset < 0 || offset + expected.Length > stream.Length)
            {
                return false;
            }

            var actual = new byte[expected.Length];
            stream.Position = offset;
            stream.ReadExactly(actual);
            return actual.AsSpan().SequenceEqual(expected);
        }

        foreach (var offset in offsets)
        {
            if (savedMarker is not null && EqualsAt(NoteFile.Utf8.GetBytes(savedMarker), offset))
            {
                return true;
            }

            foreach (var block in blocks)
            {
                var marker = block.AsSpan().IndexOf(needle);
                if (marker >= 0 && EqualsAt(block, offset - marker))
                {
                    return true;
                }
            }
        }

        return false;
    }

    public string SaveImage(byte[] png, DateTimeOffset? createdAt = null)
    {
        lock (gate)
        {
            var stamp = CaptureFormat.LocalStamp(createdAt ?? clock.GetUtcNow(), "yyyy-MM-dd-HHmmss", timeZone);
            while (true)
            {
                var path = $"{Vault.AssetsDirectoryName}/{stamp}-{RandomNumberGenerator.GetInt32(65536):x4}.png";
                if (NoteFile.CreateAsset(png, vault.Root, path))
                {
                    return path;
                }
            }
        }
    }

    private static string CheckedAssetPath(string path)
    {
        var parts = path.Split('/');
        if (parts.Length != 2 || parts[0] != Vault.AssetsDirectoryName || !parts[1].EndsWith(".png", StringComparison.Ordinal) || parts[1].StartsWith('.') || path.Contains('\0'))
        {
            throw new VaultFileException(VaultFileError.InvalidFileName);
        }

        return path;
    }
}
