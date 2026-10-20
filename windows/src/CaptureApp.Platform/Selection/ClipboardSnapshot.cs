using System.Diagnostics;
using System.Runtime.InteropServices;

namespace CaptureApp.Platform.Selection;

internal enum SnapshotFailure { None, Unavailable, TooLarge, Changed, TimedOut }
internal sealed record SnapshotResult(ClipboardSnapshot? Snapshot, SnapshotFailure Failure) : IDisposable
{
    public void Dispose() => Snapshot?.Dispose();
}

/// <summary>Owns detached copies. No clipboard-owned handle escapes the open-clipboard scope.</summary>
internal sealed class ClipboardSnapshot(uint sequence, IReadOnlyList<ClipboardValue> values) : IDisposable
{
    private int references = 1;
    internal ClipboardSnapshot Retain() { Interlocked.Increment(ref references); return this; }
    internal const long MaximumBytes = 64L * 1024 * 1024;
    internal static readonly TimeSpan MaximumTime = TimeSpan.FromMilliseconds(250);
    internal uint Sequence { get; } = sequence;
    internal IReadOnlyList<ClipboardValue> Values { get; } = values;
    public void Dispose() { if (Interlocked.Decrement(ref references) == 0) foreach (var value in Values) value.Dispose(); }

    internal static SnapshotResult Take(nint owner)
    {
        var clock = Stopwatch.StartNew();
        if (!ClipboardGuard.TryOpen(owner, clock, MaximumTime)) return new(null, SnapshotFailure.Unavailable);
        var copies = new List<ClipboardValue>();
        var success = false;
        try
        {
            var sequence = NativeMethods.GetClipboardSequenceNumber();
            if (sequence == 0) return new(null, SnapshotFailure.Unavailable);
            var formats = new List<uint>();
            uint format = 0;
            while (true)
            {
                Marshal.SetLastPInvokeError(0);
                format = NativeMethods.EnumClipboardFormats(format);
                if (format == 0)
                {
                    if (Marshal.GetLastPInvokeError() != 0) return new(null, SnapshotFailure.Unavailable);
                    break;
                }
                formats.Add(format);
                if (formats.Count > 65536 || clock.Elapsed >= MaximumTime) return new(null, SnapshotFailure.TimedOut);
            }
            long bytes = 0;
            var seen = new HashSet<uint>();
            foreach (var id in formats)
            {
                if (IsSynthesized(id, seen)) continue;
                seen.Add(id);
                if (clock.Elapsed >= MaximumTime) return new(null, SnapshotFailure.TimedOut);
                var handle = NativeMethods.GetClipboardData(id); // May synchronously ask a delayed owner to render.
                if (clock.Elapsed >= MaximumTime) return new(null, SnapshotFailure.TimedOut);
                if (handle == 0) return new(null, SnapshotFailure.Unavailable);
                var copy = ClipboardValue.Copy(id, handle, MaximumBytes - bytes, out var tooLarge);
                if (copy is null) return new(null, tooLarge ? SnapshotFailure.TooLarge : SnapshotFailure.Unavailable);
                copies.Add(copy);
                bytes += copy.ByteCount;
                if (clock.Elapsed >= MaximumTime) return new(null, SnapshotFailure.TimedOut);
                if (NativeMethods.GetClipboardSequenceNumber() != sequence) return new(null, SnapshotFailure.Changed);
            }
            if (NativeMethods.GetClipboardSequenceNumber() != sequence) return new(null, SnapshotFailure.Changed);
            success = true;
            return new(new(sequence, copies), SnapshotFailure.None);
        }
        finally
        {
            _ = NativeMethods.CloseClipboard();
            if (!success) foreach (var copy in copies) copy.Dispose();
        }
    }

    // EnumClipboardFormats enumerates a source before its synthesized conversions (Win32 clipboard-formats).
    // GDI handles are skipped only when they are a conversion; native handles use the corresponding copy API.
    internal static bool IsSynthesized(uint format, IReadOnlySet<uint> earlier) => format switch
    {
        1 or 7 or 13 => earlier.Contains(1) || earlier.Contains(7) || earlier.Contains(13),
        2 or 8 or 17 => earlier.Contains(2) || earlier.Contains(8) || earlier.Contains(17),
        9 => earlier.Contains(8) || earlier.Contains(17),
        3 or 14 => earlier.Contains(3) || earlier.Contains(14),
        _ => false
    };
}

internal sealed class ClipboardValue(uint format, byte[]? bytes, nint handle, long byteCount) : IDisposable
{
    internal uint Format { get; } = format;
    internal byte[]? Bytes { get; } = bytes;
    internal nint Handle { get; private set; } = handle;
    internal long ByteCount { get; } = byteCount;

    internal static ClipboardValue? Copy(uint format, nint source, long remaining, out bool tooLarge)
    {
        tooLarge = false;
        long size;
        if (format == 2)
        {
            if (NativeMethods.GetObject(source, Marshal.SizeOf<NativeMethods.Bitmap>(), out var bitmap) == 0) return null;
            size = Math.Abs((long)bitmap.Height) * Math.Abs((long)bitmap.WidthBytes) * Math.Max(1, (int)bitmap.Planes);
        }
        else if (format == 14) size = NativeMethods.GetEnhMetaFileBits(source, 0, 0);
        else if (format == 9) size = NativeMethods.GetPaletteEntries(source, 0, 0, null) * 4L + 4;
        else size = (long)NativeMethods.GlobalSize(source);
        if (size > remaining) { tooLarge = true; return null; }
        if (size <= 0) return null;
        if (format is 2 or 9 or 14)
        {
            var duplicate = DuplicateHandle(format, source);
            return duplicate == 0 ? null : new(format, null, duplicate, size);
        }
        // CF_OWNERDISPLAY and display-only representations cannot safely be recreated by a different owner.
        if (format is 0x80 or 0x81 or 0x82 or 0x83 or 0x8e || format is >= 0x200 and <= 0x2ff) return null;
        var pointer = NativeMethods.GlobalLock(source);
        if (pointer == 0) return null;
        try
        {
            if (format == 3)
            {
                if (size < Marshal.SizeOf<NativeMethods.MetafilePicture>()) return null;
                var picture = Marshal.PtrToStructure<NativeMethods.MetafilePicture>(pointer);
                var metaSize = NativeMethods.GetMetaFileBitsEx(picture.Metafile, 0, 0);
                if (size + metaSize > remaining) { tooLarge = true; return null; }
                picture.Metafile = NativeMethods.CopyMetaFile(picture.Metafile, 0);
                if (picture.Metafile == 0) return null;
                var copy = NativeMethods.GlobalAlloc(0x42, (nuint)size);
                var destination = copy == 0 ? 0 : NativeMethods.GlobalLock(copy);
                if (destination == 0)
                {
                    _ = NativeMethods.DeleteMetaFile(picture.Metafile);
                    if (copy != 0) _ = NativeMethods.GlobalFree(copy);
                    return null;
                }
                Marshal.StructureToPtr(picture, destination, false);
                _ = NativeMethods.GlobalUnlock(copy);
                return new(format, null, copy, size + metaSize);
            }
            var data = new byte[(int)size];
            Marshal.Copy(pointer, data, 0, data.Length);
            return new(format, data, 0, size);
        }
        finally { _ = NativeMethods.GlobalUnlock(source); }
    }

    internal ClipboardValue? Prepare()
    {
        if (Bytes is not null)
        {
            var handle = NativeMethods.GlobalAlloc(0x42, (nuint)Bytes.Length);
            var pointer = handle == 0 ? 0 : NativeMethods.GlobalLock(handle);
            if (pointer == 0) { if (handle != 0) _ = NativeMethods.GlobalFree(handle); return null; }
            Marshal.Copy(Bytes, 0, pointer, Bytes.Length);
            _ = NativeMethods.GlobalUnlock(handle);
            return new(Format, null, handle, Bytes.Length);
        }
        return Copy(Format, Handle, ClipboardSnapshot.MaximumBytes, out _);
    }

    private static nint DuplicateHandle(uint format, nint source)
    {
        if (format == 2) return NativeMethods.CopyImage(source, 0, 0, 0, 0x2000);
        if (format == 14) return NativeMethods.CopyEnhMetaFile(source, 0);
        var count = NativeMethods.GetPaletteEntries(source, 0, 0, null);
        if (count == 0 || count > ushort.MaxValue) return 0;
        var entries = new byte[count * 4];
        if (NativeMethods.GetPaletteEntries(source, 0, count, entries) != count) return 0;
        var palette = new byte[entries.Length + 4];
        palette[0] = 0; palette[1] = 3;
        palette[2] = (byte)count; palette[3] = (byte)(count >> 8);
        entries.CopyTo(palette, 4);
        return NativeMethods.CreatePalette(palette);
    }

    internal void Transfer() => Handle = 0;
    public void Dispose()
    {
        if (Handle == 0) return;
        if (Format is 2 or 9) _ = NativeMethods.DeleteObject(Handle);
        else if (Format == 14) _ = NativeMethods.DeleteEnhMetaFile(Handle);
        else
        {
            if (Format == 3)
            {
                var pointer = NativeMethods.GlobalLock(Handle);
                if (pointer != 0)
                {
                    _ = NativeMethods.DeleteMetaFile(Marshal.PtrToStructure<NativeMethods.MetafilePicture>(pointer).Metafile);
                    _ = NativeMethods.GlobalUnlock(Handle);
                }
            }
            _ = NativeMethods.GlobalFree(Handle);
        }
        Handle = 0;
    }
}
