using System.Security.Cryptography;

namespace CaptureApp.ModelInstall;

/// Downloads the opt-in semantic-search models into the models directory.
///
/// Every file is checked against its pinned SHA-256 from the manifest. Partial downloads live in a sibling
/// staging directory and resume on the next call. The models directory is replaced only after everything verifies.
public sealed class ModelInstaller
{
    /// Bytes completed out of the total download size.
    public readonly record struct Progress(long CompletedBytes, long TotalBytes)
    {
        public double Fraction => TotalBytes > 0 ? Math.Min(1, (double)CompletedBytes / TotalBytes) : 1;
    }

    private const long SpaceHeadroom = 300_000_000;
    private const int MaxNetworkRetries = 3;

    private readonly string modelsDirectory;
    private readonly string bundledResources;
    private readonly ModelManifest manifest;
    private readonly IModelTransport transport;
    private readonly Func<string, long> freeSpace;
    private readonly Func<int, TimeSpan> retryDelay;
    private int installing;

    public ModelInstaller(string modelsDirectory, string bundledResources, ModelManifest? manifest = null, IModelTransport? transport = null,
        Func<string, long>? freeSpace = null, Func<int, TimeSpan>? retryDelay = null)
    {
        this.modelsDirectory = Path.GetFullPath(modelsDirectory);
        this.bundledResources = bundledResources;
        this.manifest = manifest ?? ModelManifest.Current;
        this.transport = transport ?? new HttpModelTransport();
        this.freeSpace = freeSpace ?? VolumeFreeSpace;
        this.retryDelay = retryDelay ?? (attempt => TimeSpan.FromSeconds(attempt));
    }

    /// The license files ship next to the app, under ModelLicenses.
    public static string DefaultBundledResources => Path.Combine(AppContext.BaseDirectory, "ModelLicenses");

    /// Sibling of the models directory where downloads accumulate until they verify.
    public string StagingDirectory => Path.Combine(Path.GetDirectoryName(modelsDirectory)!, "models.download");

    /// True when an earlier download left files behind that the next install call can resume.
    public bool HasPartialDownload => Directory.Exists(StagingDirectory) && Directory.EnumerateFileSystemEntries(StagingDirectory).Any();

    /// Installs the models, resuming any earlier partial download. Nothing is downloaded unless this is called.
    public async Task InstallAsync(Action<Progress> progress, CancellationToken cancellationToken = default)
    {
        if (Interlocked.CompareExchange(ref installing, 1, 0) != 0)
        {
            throw ModelInstallException.Unavailable("An install is already running.");
        }

        try
        {
            await PerformInstallAsync(progress, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            throw ModelInstallException.Cancelled();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw ModelInstallException.Io(error.Message);
        }
        finally
        {
            Volatile.Write(ref installing, 0);
        }
    }

    /// Deletes the installed models and any partial download.
    public void Remove()
    {
        if (Volatile.Read(ref installing) != 0)
        {
            throw ModelInstallException.Unavailable("A download is in progress.");
        }

        try
        {
            foreach (var directory in new[] { modelsDirectory, StagingDirectory })
            {
                if (Directory.Exists(directory))
                {
                    Directory.Delete(directory, recursive: true);
                }
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw ModelInstallException.Io(error.Message);
        }
    }

    /// Free bytes available to the current user on the volume that holds the path.
    public static long VolumeFreeSpace(string path)
    {
        try
        {
            return new DriveInfo(Path.GetPathRoot(Path.GetFullPath(path))!).AvailableFreeSpace;
        }
        catch (Exception error) when (error is IOException or ArgumentException or UnauthorizedAccessException)
        {
            throw ModelInstallException.Unavailable("The free space on this volume is unknown.");
        }
    }

    /// Heals an interrupted commit. Safe to call on every launch, before anything reads the models directory.
    public void RecoverInterruptedCommit() => RemoveStaleBackups(Path.GetDirectoryName(modelsDirectory)!);

    private async Task PerformInstallAsync(Action<Progress> progress, CancellationToken cancellationToken)
    {
        var staging = StagingDirectory;
        var parent = Path.GetDirectoryName(modelsDirectory)!;
        var total = manifest.TotalDownloadBytes;

        // Step 1: staging directory (also creates the parent) and cleanup of backups left by a crash.
        Directory.CreateDirectory(staging);
        RemoveStaleBackups(parent);

        // Fail before any download when a bundled license is missing from the app.
        foreach (var license in manifest.Licenses)
        {
            if (!File.Exists(Path.Combine(bundledResources, license.ResourceName)))
            {
                throw ModelInstallException.MissingBundledResource(license.ResourceName);
            }
        }

        // Step 2: work list. Files that already verify are reused and count as completed.
        var downloads = new List<ModelArtifact>();
        var completed = 0L;
        // .part files of files that no longer need downloading. Removed only after the space check passes.
        var stalePartNames = new List<string>();
        foreach (var artifact in manifest.ModelFiles)
        {
            var staged = Path.Combine(staging, artifact.Path);
            if (HashMatches(staged, artifact.Sha256))
            {
                stalePartNames.Add(artifact.Path);
                completed += artifact.Size;
                continue;
            }

            var installed = Path.Combine(modelsDirectory, artifact.Path);
            if (HashMatches(installed, artifact.Sha256))
            {
                stalePartNames.Add(artifact.Path);
                ReplaceByCopy(staged, installed);
                completed += artifact.Size;
                continue;
            }

            downloads.Add(artifact);
        }

        // Step 3: disk pre-flight, counting bytes already present in .part files as downloaded.
        // Read-only: nothing is deleted until the space check has passed.
        var remainingBytes = downloads.Sum(item => item.Size - PartialBytes(PartPath(item.Path), item.Size));
        var required = remainingBytes + SpaceHeadroom;
        var available = freeSpace(parent);
        if (available < required)
        {
            throw ModelInstallException.InsufficientDiskSpace(required, available);
        }

        foreach (var name in stalePartNames)
        {
            TryDelete(PartPath(name));
        }

        var throttle = new ProgressThrottle(total, progress);
        throttle.Report(completed, force: true);

        // Step 4: downloads in manifest order.
        foreach (var item in downloads)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var baseline = completed;
            var size = item.Size;
            await FetchAsync(item, onDisk => throttle.Report(baseline + Math.Min(onDisk, size)), cancellationToken).ConfigureAwait(false);
            // Keep a completed transfer resumable if cancellation arrives as it finishes,
            // but do not start finalization after the user has cancelled.
            cancellationToken.ThrowIfCancellationRequested();
            completed += item.Size;
        }

        // Step 5: bundled license files, verified before they are copied in.
        foreach (var license in manifest.Licenses)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var source = Path.Combine(bundledResources, license.ResourceName);
            if (!HashMatches(source, license.Sha256))
            {
                throw ModelInstallException.ChecksumMismatch(license.ResourceName);
            }

            ReplaceByCopy(Path.Combine(staging, license.InstalledName), source);
        }

        // Step 6: everything the app needs is present, and nothing is half-written.
        foreach (var name in manifest.RequiredFiles.Concat(manifest.Licenses.Select(license => license.InstalledName)))
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!File.Exists(Path.Combine(staging, name)))
            {
                throw ModelInstallException.Io($"{name} is missing after the download");
            }
        }

        cancellationToken.ThrowIfCancellationRequested();
        if (Directory.EnumerateFiles(staging, "*.part", SearchOption.AllDirectories).Any())
        {
            throw ModelInstallException.Io("an incomplete download is still present");
        }

        // Step 7: atomic commit. The old directory is kept until the new one is in place. This is the final
        // cancellation point before the swap: verified downloads stay in staging and the installed set stays untouched.
        if (!Directory.Exists(staging))
        {
            throw ModelInstallException.Io("the staging folder was removed during the install");
        }

        cancellationToken.ThrowIfCancellationRequested();
        Commit(staging, cancellationToken);

        // Step 8: final progress.
        throttle.Report(total, force: true);
    }

    /// Downloads one file, resuming from its .part file, with retries on network errors.
    private async Task FetchAsync(ModelArtifact item, Action<long> progress, CancellationToken cancellationToken)
    {
        var part = PartPath(item.Path);
        var destination = Path.Combine(StagingDirectory, item.Path);
        if (!Uri.TryCreate(item.Url, UriKind.Absolute, out var source))
        {
            throw ModelInstallException.Io($"the download address for {item.Path} is invalid");
        }

        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        var networkRetries = 0;
        var checksumRetried = false;
        while (true)
        {
            // Read before every attempt, so a retry after a stale range resumes from the file's real size.
            var offset = PartialBytes(part, item.Size);
            if (offset == 0)
            {
                TryDelete(part);
            }

            try
            {
                await transport.DownloadAsync(source, part, offset, progress, cancellationToken).ConfigureAwait(false);
            }
            catch (ModelInstallException error) when (IsRetryable(error))
            {
                if (networkRetries >= MaxNetworkRetries)
                {
                    throw;
                }

                networkRetries++;
                await Task.Delay(retryDelay(networkRetries), cancellationToken).ConfigureAwait(false);
                continue;
            }

            if (HashMatches(part, item.Sha256))
            {
                ReplaceByMove(destination, part);
                return;
            }

            TryDelete(part);
            if (checksumRetried)
            {
                throw ModelInstallException.ChecksumMismatch(item.Path);
            }

            // Corrupt bytes: download the file again from the start, once.
            checksumRetried = true;
        }
    }

    /// Swaps the staged directory in for the models directory. On failure the old directory is restored.
    private void Commit(string staging, CancellationToken cancellationToken)
    {
        var parent = Path.GetDirectoryName(modelsDirectory)!;
        string? backup = null;
        if (Directory.Exists(modelsDirectory))
        {
            cancellationToken.ThrowIfCancellationRequested();
            backup = Path.Combine(parent, "models.old-" + Guid.NewGuid());
            Directory.Move(modelsDirectory, backup);
        }

        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            Directory.Move(staging, modelsDirectory);
        }
        catch
        {
            if (backup is not null)
            {
                try
                {
                    Directory.Move(backup, modelsDirectory);
                }
                catch (IOException)
                {
                }
            }

            throw;
        }

        if (backup is not null)
        {
            TryDeleteDirectory(backup);
        }
    }

    /// Removes models.old-* directories left behind by an interrupted commit. Only this installer creates them.
    /// If the models directory is missing (the crash fell between moving it aside and moving the new one in),
    /// the newest backup is restored first so the previous models survive.
    private void RemoveStaleBackups(string parent)
    {
        if (!Directory.Exists(parent))
        {
            return;
        }

        var backups = Directory.EnumerateDirectories(parent, "models.old-*")
            .OrderByDescending(Directory.GetCreationTimeUtc).ToList();
        if (backups.Count == 0)
        {
            return;
        }

        if (!Directory.Exists(modelsDirectory))
        {
            try
            {
                Directory.Move(backups[0], modelsDirectory);
            }
            catch (IOException)
            {
                // Keep every backup if the restore fails, so no models are lost.
                return;
            }

            backups.RemoveAt(0);
        }

        foreach (var backup in backups)
        {
            TryDeleteDirectory(backup);
        }
    }

    private static bool HashMatches(string file, string expected)
    {
        if (!File.Exists(file))
        {
            return false;
        }

        using var stream = File.OpenRead(file);
        return Convert.ToHexString(SHA256.HashData(stream)).Equals(expected, StringComparison.OrdinalIgnoreCase);
    }

    /// Bytes already in the partial file. Read-only: 0 when the file is missing or larger than expected.
    private static long PartialBytes(string part, long expectedSize)
    {
        var info = new FileInfo(part);
        return info.Exists && info.Length <= expectedSize ? info.Length : 0;
    }

    /// Network drops and server-side failures (429 and 5xx) are retried; other statuses fail at once.
    private static bool IsRetryable(ModelInstallException error) => error.Kind switch
    {
        ModelInstallErrorKind.Network => true,
        ModelInstallErrorKind.HttpStatus => error.StatusCode is 429 or (>= 500 and <= 599),
        _ => false
    };

    private string PartPath(string name) => Path.Combine(StagingDirectory, name + ".part");

    private static void ReplaceByCopy(string destination, string source)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        File.Copy(source, destination, overwrite: true);
    }

    private static void ReplaceByMove(string destination, string source)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        File.Move(source, destination, overwrite: true);
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
        }
    }

    private static void TryDeleteDirectory(string path)
    {
        try
        {
            Directory.Delete(path, recursive: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
        }
    }

    /// Shares one progress callback between the transport and the installer, and limits it to about
    /// ten calls per second unless forced.
    private sealed class ProgressThrottle(long total, Action<Progress> callback)
    {
        private readonly object gate = new();
        private long lastEmit = long.MinValue;

        public void Report(long completed, bool force = false)
        {
            var now = Environment.TickCount64;
            lock (gate)
            {
                if (!force && lastEmit != long.MinValue && now - lastEmit < 100)
                {
                    return;
                }

                lastEmit = now;
            }

            callback(new Progress(Math.Min(Math.Max(completed, 0), total), total));
        }
    }
}
