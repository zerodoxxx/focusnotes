using CaptureApp.Core;
using CaptureApp.Core.Index;

namespace CaptureApp.AppCore.Tests;

internal static class TestPipeline
{
    public static CapturePipeline Open(TempDirectory temp) => CapturePipeline.Open(
        Path.Combine(temp.Path, "vault"), Path.Combine(temp.Path, "state"), TimeZoneInfo.Utc);

    public static (string Root, string State, Vault Vault, SearchIndex Index) OpenIndexedVault(TempDirectory temp)
    {
        var root = Path.Combine(temp.Path, "vault");
        var state = Path.Combine(temp.Path, "state");
        var vault = new Vault(root, Path.Combine(state, "external-notes.json"));
        vault.Prepare();
        return (root, state, vault, new SearchIndex(vault, Path.Combine(state, "index.sqlite"), TimeZoneInfo.Local));
    }
}
