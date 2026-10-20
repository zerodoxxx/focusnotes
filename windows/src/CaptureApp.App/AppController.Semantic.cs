using System.IO;
using System.Windows;
using CaptureApp.AppCore;
using CaptureApp.AppCore.Semantic;
using CaptureApp.AppCore.Shell;
using CaptureApp.Core.Index;
using CaptureApp.Embed;
using CaptureApp.ModelInstall;
using CaptureApp.Platform.Power;

namespace CaptureApp.App;

internal sealed partial class AppController
{
    private enum ModelPhase { Idle, Downloading, Removing }

    private ModelPhase modelPhase;
    private CancellationTokenSource? downloadCancellation;
    private ModelInstaller? installer;
    private ModelInstaller.Progress? progress;

    private string ModelsDirectory => Path.Combine(stateDirectory, "models");

    internal static string HelperPath()
    {
        var exe = Path.Combine(AppContext.BaseDirectory, "CaptureApp.EmbedHelper.exe");
        return File.Exists(exe) ? exe : Path.Combine(AppContext.BaseDirectory, "CaptureApp.EmbedHelper.dll");
    }

    internal static bool ModelsInstalled(string directory) =>
        ModelManifest.Current.RequiredFiles.All(file => File.Exists(Path.Combine(directory, file.Replace('/', Path.DirectorySeparatorChar))));

    private void InitializeSemantic()
    {
        var models = ModelsDirectory;
        var modelFiles = ModelManifest.Current.RequiredFiles.Where(file => file.StartsWith("onnx/", StringComparison.Ordinal))
            .Select(file => Path.Combine(models, file.Replace('/', Path.DirectorySeparatorChar))).ToArray();
        semantic = new SemanticIndexer(new VaultSemanticSource(pipeline.Index, pipeline.Vault),
            () => new EmbedClient(HelperPath(), models),
            () => new VectorStore(Path.Combine(stateDirectory, "vectors.sqlite"), modelFiles: modelFiles),
            ModelsInstalled(models), () => power?.IsImageEmbeddingAllowed ?? true, log: new AppLog(stateDirectory, "semantic"));
        Coordinator.Semantic = semantic;
        EnsurePowerMonitor();
    }

    /// Power events matter only while the models are installed; suspend and resume pause the indexer.
    private void EnsurePowerMonitor()
    {
        if (semantic is null || power is not null || !ModelsInstalled(ModelsDirectory)) { return; }
        power = new PowerMonitor();
        power.ImageEmbeddingAllowedChanged += (sender, allowed) => semantic?.ImageEmbeddingAllowedChanged(sender, allowed);
        power.Suspending += (_, _) => semantic?.SetEnabled(false);
        power.Resumed += (_, _) => semantic?.SetEnabled(ModelsInstalled(ModelsDirectory));
    }

    private void OnVaultRefresh(VaultRefreshRequest request)
    {
        if (request.Notes) { semantic?.Schedule(); }
        if (!request.Assets || !Ocr.Value.IsAvailable) { return; }
        try
        {
            foreach (var path in pipeline.Index.AssetsMissingText(request.RecheckingAssetPaths))
            {
                if (lifetime.IsCancellationRequested) { return; }
                try
                {
                    var data = pipeline.AssetData(path);
                    pipeline.Index.SetImageText(path, Ocr.Value.Recognize(data, lifetime.Token).Text, SearchIndex.ImageFingerprint(data));
                }
                catch (Exception error) when (error is not OperationCanceledException)
                {
                    log.Error($"OCR backfill failed for an asset ({error.GetType().Name}): {error.Message}");
                }
            }

            semantic?.Schedule();
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { log.Error($"OCR backfill list failed ({error.GetType().Name})"); }
    }

    // The tray's Semantic Search entry (SemanticModelsMenu.swift).
    private SemanticMenuState CurrentSemanticMenu()
    {
        var installed = ModelsInstalled(ModelsDirectory);
        return modelPhase switch
        {
            ModelPhase.Downloading => new(SemanticMenuPhase.Downloading, Percent: progress is { } p ? (int)Math.Floor(p.Fraction * 100) : null),
            ModelPhase.Removing => new(SemanticMenuPhase.Removing),
            _ => installed ? new(SemanticMenuPhase.Installed) : new(SemanticMenuPhase.NotInstalled, Installer().HasPartialDownload)
        };
    }

    private ModelInstaller Installer()
    {
        if (installer is not null) { return installer; }
        var created = new ModelInstaller(ModelsDirectory, ModelInstaller.DefaultBundledResources);
        created.RecoverInterruptedCommit();
        return installer = created;
    }

    internal bool ModelsAreInstalled => ModelsInstalled(ModelsDirectory);

    private void ActivateSemanticMenu()
    {
        switch (modelPhase)
        {
            case ModelPhase.Downloading: ConfirmCancelDownload(); break;
            case ModelPhase.Idle when !ModelsInstalled(ModelsDirectory): ConfirmDownload(); break;
        }
    }

    internal void ConfirmDownload()
    {
        if (modelPhase != ModelPhase.Idle) { return; }
        ModelInstaller current;
        try { current = Installer(); }
        catch (Exception error) { Coordinator.Report(error, Strings.CouldNotDownloadModels); return; }
        var resuming = current.HasPartialDownload;
        var answer = MessageBox.Show(Strings.DownloadModelsBody(ModelInstallException.FormatBytes(ModelManifest.Current.TotalDownloadBytes)),
            Strings.DownloadModelsTitle(resuming), MessageBoxButton.OKCancel, MessageBoxImage.Question);
        if (answer != MessageBoxResult.OK) { return; }
        _ = DownloadAsync(current);
    }

    private async Task DownloadAsync(ModelInstaller current)
    {
        progress = null;
        downloadCancellation = new CancellationTokenSource();
        var cancellation = downloadCancellation;
        modelPhase = ModelPhase.Downloading;
        RefreshMenu();
        Exception? failure = null;
        try
        {
            await current.InstallAsync(update => dispatcher.BeginInvoke(() =>
            {
                if (modelPhase != ModelPhase.Downloading) { return; }
                progress = update;
                RefreshMenu();
            }), cancellation.Token);
        }
        catch (Exception error) { failure = error; }

        modelPhase = ModelPhase.Idle;
        progress = null;
        downloadCancellation = null;
        cancellation.Dispose();
        semantic?.SetEnabled(ModelsInstalled(ModelsDirectory));
        EnsurePowerMonitor();
        RefreshMenu();
        if (failure is null) { Coordinator.ShowToast(new(AppToastStyle.Success, Strings.SemanticReady)); return; }
        // A user cancel is silent, whichever error the installer surfaced on the way out.
        if (quitting || failure is OperationCanceledException || failure is ModelInstallException { Kind: ModelInstallErrorKind.Cancelled }) { return; }
        Coordinator.Report(failure, Strings.CouldNotDownloadModels);
    }

    private void ConfirmCancelDownload()
    {
        var keep = MessageBox.Show(Strings.CancelDownloadBody + $"\n\nChoose Yes to {Strings.CancelDownload.ToLowerInvariant()}, No to {Strings.KeepDownloading.ToLowerInvariant()}.",
            Strings.CancelDownloadTitle, MessageBoxButton.YesNo, MessageBoxImage.Question);
        if (keep == MessageBoxResult.Yes) { downloadCancellation?.Cancel(); }
    }

    /// Stops an in-flight download so it cannot outlive the app. Partial files are kept for resume.
    private void CancelModelDownload() => downloadCancellation?.Cancel();

    internal void ConfirmRemoveModels()
    {
        if (modelPhase != ModelPhase.Idle || !ModelsInstalled(ModelsDirectory)) { return; }
        var answer = MessageBox.Show(Strings.RemoveModelsBody(ModelInstallException.FormatBytes(ModelManifest.Current.TotalDownloadBytes)),
            Strings.RemoveModelsTitle, MessageBoxButton.OKCancel, MessageBoxImage.Warning);
        if (answer == MessageBoxResult.OK) { _ = RemoveModelsAsync(); }
    }

    private async Task RemoveModelsAsync()
    {
        modelPhase = ModelPhase.Removing;
        RefreshMenu();
        // Stops new embedding work and keeps the indexer usable for a later re-download.
        semantic?.SetEnabled(false);
        try { await Task.Run(() => Installer().Remove()); }
        catch (Exception error) { Coordinator.Report(error, Strings.CouldNotRemoveModels); }
        modelPhase = ModelPhase.Idle;
        RefreshMenu();
    }
}
