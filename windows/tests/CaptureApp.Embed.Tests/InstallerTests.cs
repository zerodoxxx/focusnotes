using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using CaptureApp.ModelInstall;
using Xunit;

namespace CaptureApp.Embed.Tests;

public sealed class InstallerTests
{
    private enum Fault
    {
        None,
        TruncateHalf,
        Corrupt,
        Status500,
        Status404
    }

    /// Serves in-memory files over loopback HTTP with Range support and per-request fault injection.
    /// A minimal TcpListener server: HttpListener's http.sys handle is disposed under in-flight requests on Windows.
    private sealed class FileServer : IDisposable
    {
        private readonly TcpListener listener = new(IPAddress.Loopback, 0);
        private readonly CancellationTokenSource stop = new();
        private readonly List<TcpClient> clients = [];
        private readonly List<Task> handlers = [];
        private readonly Task loop;

        public FileServer(Dictionary<string, byte[]> files)
        {
            Files = files;
            listener.Start();
            BaseUrl = $"http://127.0.0.1:{((IPEndPoint)listener.LocalEndpoint).Port}";
            loop = Task.Run(Serve);
        }

        public string BaseUrl { get; }

        public Dictionary<string, byte[]> Files { get; }

        public List<(string Path, string? Range)> Requests { get; } = [];

        public Func<string, int, Fault> Faults { get; set; } = (_, _) => Fault.None;

        private async Task Serve()
        {
            while (!stop.IsCancellationRequested)
            {
                TcpClient client;
                try
                {
                    client = await listener.AcceptTcpClientAsync(stop.Token);
                }
                catch (Exception)
                {
                    return;
                }

                lock (clients)
                {
                    clients.Add(client);
                    handlers.Add(Task.Run(() => Handle(client)));
                }
            }
        }

        private async Task Handle(TcpClient client)
        {
            try
            {
                using var _ = client;
                var stream = client.GetStream();
                using var reader = new StreamReader(stream, System.Text.Encoding.ASCII, false, 4096, leaveOpen: true);
                var requestLine = await reader.ReadLineAsync(stop.Token);
                if (requestLine is null)
                {
                    return;
                }

                string? range = null;
                while (await reader.ReadLineAsync(stop.Token) is { Length: > 0 } header)
                {
                    if (header.StartsWith("Range:", StringComparison.OrdinalIgnoreCase))
                    {
                        range = header[6..].Trim();
                    }
                }

                var path = requestLine.Split(' ')[1].TrimStart('/');
                int attempt;
                lock (Requests)
                {
                    attempt = Requests.Count(request => request.Path == path);
                    Requests.Add((path, range));
                }

                var fault = Faults(path, attempt);
                if (fault == Fault.Status500 || fault == Fault.Status404 || !Files.TryGetValue(path, out var body))
                {
                    await Send(stream, fault == Fault.Status500 ? "500 Internal Server Error" : "404 Not Found", [], []);
                    return;
                }

                if (fault == Fault.Corrupt)
                {
                    body = [.. body];
                    body[0] ^= 0xFF;
                }

                var start = 0L;
                var status = "200 OK";
                var headers = new List<string>();
                if (range is not null && range.StartsWith("bytes=", StringComparison.Ordinal) && long.TryParse(range[6..].TrimEnd('-'), out start))
                {
                    if (start >= body.Length)
                    {
                        await Send(stream, "416 Range Not Satisfiable", [], []);
                        return;
                    }

                    status = "206 Partial Content";
                    headers.Add($"Content-Range: bytes {start}-{body.Length - 1}/{body.Length}");
                }

                var slice = body.AsSpan((int)start).ToArray();
                // Truncation: advertise the full length, send half, then drop the connection.
                await Send(stream, status, headers, fault == Fault.TruncateHalf ? slice[..(slice.Length / 2)] : slice, slice.Length);
            }
            catch (Exception)
            {
                // A client that gave up (or shutdown) is not a server failure.
            }
        }

        private static async Task Send(NetworkStream stream, string status, IEnumerable<string> headers, byte[] body, int? length = null)
        {
            var head = $"HTTP/1.1 {status}\r\nContent-Length: {length ?? body.Length}\r\nConnection: close\r\n{string.Concat(headers.Select(header => header + "\r\n"))}\r\n";
            await stream.WriteAsync(System.Text.Encoding.ASCII.GetBytes(head));
            await stream.WriteAsync(body);
            await stream.FlushAsync();
        }

        public int RequestCount(string path)
        {
            lock (Requests)
            {
                return Requests.Count(request => request.Path == path);
            }
        }

        public void Dispose()
        {
            // Stop accepting first, then unblock and drain in-flight handlers before releasing anything.
            stop.Cancel();
            listener.Stop();
            lock (clients)
            {
                foreach (var client in clients)
                {
                    try { client.Dispose(); } catch (Exception) { }
                }
            }

            try { loop.Wait(TimeSpan.FromSeconds(2)); } catch (Exception) { }
            Task[] pending;
            lock (clients)
            {
                pending = [.. handlers];
            }

            try { Task.WaitAll(pending, TimeSpan.FromSeconds(2)); } catch (Exception) { }
            stop.Dispose();
        }
    }

    private sealed class Fixture : IDisposable
    {
        public const string Big = "onnx/model.onnx_data";

        private readonly TempDirectory temp = new();

        public Fixture()
        {
            var payloads = new Dictionary<string, byte[]>
            {
                ["onnx/model.onnx"] = RandomNumberGenerator.GetBytes(3_000),
                [Big] = RandomNumberGenerator.GetBytes(400_000),
                ["tokenizer.json"] = RandomNumberGenerator.GetBytes(50_000)
            };
            Server = new FileServer(payloads);
            Directory.CreateDirectory(Licenses);
            File.WriteAllText(Path.Combine(Licenses, "L1.txt"), "license one");
            File.WriteAllText(Path.Combine(Licenses, "L2.txt"), "license two");
            Manifest = new ModelManifest
            {
                ModelFiles = [.. payloads.Select(pair => new ModelArtifact(pair.Key, $"{Server.BaseUrl}/{pair.Key}", Hash(pair.Value), pair.Value.Length))],
                Licenses =
                [
                    new BundledLicense("L1.txt", Hash("license one"u8.ToArray()), "INSTALLED-L1.txt"),
                    new BundledLicense("L2.txt", Hash("license two"u8.ToArray()), "INSTALLED-L2.txt")
                ]
            };
        }

        public FileServer Server { get; }

        public ModelManifest Manifest { get; }

        public string Root => temp.Path;

        public string Models => Path.Combine(Root, "data", "models");

        public string Licenses => Path.Combine(Root, "licenses");

        public ModelInstaller Installer(Func<string, long>? freeSpace = null) => new(Models, Licenses, Manifest,
            new HttpModelTransport(requireHttps: false), freeSpace ?? (_ => long.MaxValue), _ => TimeSpan.Zero);

        public static string Hash(byte[] data) => Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();

        public void Dispose()
        {
            Server.Dispose();
            temp.Dispose();
        }
    }

    [Fact]
    public async Task FreshInstallDownloadsVerifiesAndCommits()
    {
        using var fixture = new Fixture();
        var progress = new List<ModelInstaller.Progress>();
        await fixture.Installer().InstallAsync(progress.Add);

        foreach (var file in fixture.Manifest.ModelFiles)
        {
            Assert.Equal(fixture.Server.Files[file.Path], await File.ReadAllBytesAsync(Path.Combine(fixture.Models, file.Path)));
        }

        Assert.Equal("license one", await File.ReadAllTextAsync(Path.Combine(fixture.Models, "INSTALLED-L1.txt")));
        Assert.False(Directory.Exists(Path.Combine(fixture.Root, "data", "models.download")));
        Assert.Equal(1.0, progress[^1].Fraction);
        Assert.Equal(fixture.Manifest.TotalDownloadBytes, progress[^1].TotalBytes);
    }

    [Fact]
    public async Task ResumesWithARangeRequestAfterATruncatedResponse()
    {
        using var fixture = new Fixture();
        fixture.Server.Faults = (path, attempt) => path == Fixture.Big && attempt == 0 ? Fault.TruncateHalf : Fault.None;
        await fixture.Installer().InstallAsync(_ => { });

        Assert.Equal(2, fixture.Server.RequestCount(Fixture.Big));
        var resumed = fixture.Server.Requests.Last(request => request.Path == Fixture.Big).Range;
        Assert.NotNull(resumed);
        Assert.StartsWith("bytes=", resumed);
        Assert.NotEqual("bytes=0-", resumed);
        Assert.Equal(fixture.Server.Files[Fixture.Big], await File.ReadAllBytesAsync(Path.Combine(fixture.Models, Fixture.Big)));
    }

    [Fact]
    public async Task ContinuesAPartialDownloadLeftByAnEarlierRun()
    {
        using var fixture = new Fixture();
        var installer = fixture.Installer();
        var partial = Path.Combine(installer.StagingDirectory, Fixture.Big + ".part");
        Directory.CreateDirectory(Path.GetDirectoryName(partial)!);
        await File.WriteAllBytesAsync(partial, fixture.Server.Files[Fixture.Big].AsSpan(0, 1000).ToArray());
        Assert.True(installer.HasPartialDownload);

        await installer.InstallAsync(_ => { });

        Assert.Equal("bytes=1000-", fixture.Server.Requests.Single(request => request.Path == Fixture.Big).Range);
        Assert.Equal(fixture.Server.Files[Fixture.Big], await File.ReadAllBytesAsync(Path.Combine(fixture.Models, Fixture.Big)));
        Assert.False(installer.HasPartialDownload);
    }

    [Fact]
    public async Task ABadHashIsRetriedOnceThenFailsWithoutTouchingInstalledModels()
    {
        using var fixture = new Fixture();
        Directory.CreateDirectory(fixture.Models);
        await File.WriteAllTextAsync(Path.Combine(fixture.Models, "previous.txt"), "keep");
        fixture.Server.Faults = (path, _) => path == "tokenizer.json" ? Fault.Corrupt : Fault.None;

        var error = await Assert.ThrowsAsync<ModelInstallException>(() => fixture.Installer().InstallAsync(_ => { }));

        Assert.Equal(ModelInstallErrorKind.ChecksumMismatch, error.Kind);
        Assert.Equal(2, fixture.Server.RequestCount("tokenizer.json"));
        Assert.Equal("keep", await File.ReadAllTextAsync(Path.Combine(fixture.Models, "previous.txt")));
        Assert.False(File.Exists(Path.Combine(fixture.Models, "tokenizer.json")));
    }

    [Fact]
    public async Task AGoodDownloadAfterOneBadHashSucceeds()
    {
        using var fixture = new Fixture();
        fixture.Server.Faults = (path, attempt) => path == "tokenizer.json" && attempt == 0 ? Fault.Corrupt : Fault.None;
        await fixture.Installer().InstallAsync(_ => { });
        Assert.Equal(2, fixture.Server.RequestCount("tokenizer.json"));
        Assert.True(File.Exists(Path.Combine(fixture.Models, "tokenizer.json")));
    }

    [Fact]
    public async Task ServerErrorsAreRetriedThreeTimesButNotFoundIsNot()
    {
        using var fixture = new Fixture();
        fixture.Server.Faults = (path, _) => path == "onnx/model.onnx" ? Fault.Status500 : Fault.None;
        var error = await Assert.ThrowsAsync<ModelInstallException>(() => fixture.Installer().InstallAsync(_ => { }));
        Assert.Equal((ModelInstallErrorKind.HttpStatus, 500), (error.Kind, error.StatusCode));
        Assert.Equal(4, fixture.Server.RequestCount("onnx/model.onnx"));

        fixture.Server.Faults = (path, _) => path == "onnx/model.onnx" ? Fault.Status404 : Fault.None;
        var missing = await Assert.ThrowsAsync<ModelInstallException>(() => fixture.Installer().InstallAsync(_ => { }));
        Assert.Equal(404, missing.StatusCode);
        Assert.Equal(5, fixture.Server.RequestCount("onnx/model.onnx"));
    }

    [Fact]
    public async Task InsufficientDiskSpaceFailsBeforeAnyDownloadAndKeepsPartials()
    {
        using var fixture = new Fixture();
        var installer = fixture.Installer(_ => 1_000);
        var partial = Path.Combine(installer.StagingDirectory, Fixture.Big + ".part");
        Directory.CreateDirectory(Path.GetDirectoryName(partial)!);
        await File.WriteAllBytesAsync(partial, new byte[10]);

        var error = await Assert.ThrowsAsync<ModelInstallException>(() => installer.InstallAsync(_ => { }));

        Assert.Equal(ModelInstallErrorKind.InsufficientDiskSpace, error.Kind);
        Assert.Equal(1_000, error.Available);
        Assert.Empty(fixture.Server.Requests);
        Assert.True(File.Exists(partial));
        Assert.Contains("Not enough free disk space", error.Message);
    }

    [Fact]
    public async Task ValidInstalledFilesAreReusedWithoutDownloading()
    {
        using var fixture = new Fixture();
        await fixture.Installer().InstallAsync(_ => { });
        fixture.Server.Requests.Clear();

        await fixture.Installer().InstallAsync(_ => { });

        Assert.Empty(fixture.Server.Requests);
    }

    [Fact]
    public async Task ARepairDownloadsOnlyTheFileThatNoLongerVerifies()
    {
        using var fixture = new Fixture();
        await fixture.Installer().InstallAsync(_ => { });
        File.WriteAllText(Path.Combine(fixture.Models, "tokenizer.json"), "damaged");
        fixture.Server.Requests.Clear();

        await fixture.Installer().InstallAsync(_ => { });

        Assert.Equal(new[] { "tokenizer.json" }, fixture.Server.Requests.Select(request => request.Path));
    }

    [Fact]
    public async Task MissingLicenseResourceFailsBeforeDownloading()
    {
        using var fixture = new Fixture();
        File.Delete(Path.Combine(fixture.Licenses, "L2.txt"));
        var error = await Assert.ThrowsAsync<ModelInstallException>(() => fixture.Installer().InstallAsync(_ => { }));
        Assert.Equal(ModelInstallErrorKind.MissingBundledResource, error.Kind);
        Assert.Empty(fixture.Server.Requests);
    }

    [Fact]
    public async Task TamperedLicenseResourceIsRejected()
    {
        using var fixture = new Fixture();
        File.WriteAllText(Path.Combine(fixture.Licenses, "L1.txt"), "tampered");
        var error = await Assert.ThrowsAsync<ModelInstallException>(() => fixture.Installer().InstallAsync(_ => { }));
        Assert.Equal(ModelInstallErrorKind.ChecksumMismatch, error.Kind);
        Assert.False(Directory.Exists(fixture.Models));
    }

    [Fact]
    public async Task RemoveDeletesModelsAndPartialDownloads()
    {
        using var fixture = new Fixture();
        var installer = fixture.Installer();
        await installer.InstallAsync(_ => { });
        Directory.CreateDirectory(installer.StagingDirectory);
        File.WriteAllText(Path.Combine(installer.StagingDirectory, "x.part"), "x");

        installer.Remove();

        Assert.False(Directory.Exists(fixture.Models));
        Assert.False(Directory.Exists(installer.StagingDirectory));
        installer.Remove();
    }

    [Fact]
    public async Task CancellationBeforeStartReportsCancelledAndSecondInstallIsRejectedWhileRunning()
    {
        using var fixture = new Fixture();
        using var cancelled = new CancellationTokenSource();
        await cancelled.CancelAsync();
        var error = await Assert.ThrowsAsync<ModelInstallException>(() => fixture.Installer().InstallAsync(_ => { }, cancelled.Token));
        Assert.Equal(ModelInstallErrorKind.Cancelled, error.Kind);

        var gate = new TaskCompletionSource();
        var entered = new TaskCompletionSource();
        var installer = new ModelInstaller(fixture.Models, fixture.Licenses, fixture.Manifest, new BlockingTransport(entered, gate), _ => long.MaxValue);
        var running = installer.InstallAsync(_ => { });
        await entered.Task;
        var busy = await Assert.ThrowsAsync<ModelInstallException>(() => installer.InstallAsync(_ => { }));
        Assert.Equal(ModelInstallErrorKind.Unavailable, busy.Kind);
        Assert.Throws<ModelInstallException>(installer.Remove);
        gate.SetException(new OperationCanceledException());
        Assert.Equal(ModelInstallErrorKind.Cancelled, (await Assert.ThrowsAsync<ModelInstallException>(() => running)).Kind);
    }

    [Fact]
    public async Task InsecureUrlsAreRefusedByTheProductionTransport()
    {
        using var transport = new HttpModelTransport();
        using var temp = new TempDirectory();
        var error = await Assert.ThrowsAsync<ModelInstallException>(() =>
            transport.DownloadAsync(new Uri("http://example.invalid/file"), Path.Combine(temp.Path, "f"), 0, _ => { }, CancellationToken.None));
        Assert.Equal(ModelInstallErrorKind.InsecureRedirect, error.Kind);
    }

    [Fact]
    public void AnInterruptedCommitRestoresTheNewestBackup()
    {
        using var fixture = new Fixture();
        var backup = Path.Combine(fixture.Root, "data", "models.old-abc");
        Directory.CreateDirectory(backup);
        File.WriteAllText(Path.Combine(backup, "kept.txt"), "x");

        fixture.Installer().RecoverInterruptedCommit();

        Assert.True(File.Exists(Path.Combine(fixture.Models, "kept.txt")));
        Assert.False(Directory.Exists(backup));
    }

    private sealed class BlockingTransport(TaskCompletionSource entered, TaskCompletionSource gate) : IModelTransport
    {
        public async Task DownloadAsync(Uri url, string file, long offset, Action<long> progress, CancellationToken cancellationToken)
        {
            entered.TrySetResult();
            await gate.Task;
        }
    }
}
