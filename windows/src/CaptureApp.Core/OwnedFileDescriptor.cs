using Microsoft.Win32.SafeHandles;

namespace CaptureApp.Core;
/// Transfers ownership of a native file handle and closes it at most once.
public sealed class OwnedFileDescriptor : IDisposable
{
    private SafeFileHandle? handle;
    public OwnedFileDescriptor(SafeFileHandle handle)
    {
        ArgumentNullException.ThrowIfNull(handle);
        if (handle.IsInvalid || handle.IsClosed)
        {
            throw new ArgumentException("A valid owned handle is required.", nameof(handle));
        }

        this.handle = handle;
    }

    public SafeFileHandle? Handle => Volatile.Read(ref handle);

    public void Close() => Interlocked.Exchange(ref handle, null)?.Dispose();
    public void Dispose() => Close();
}
