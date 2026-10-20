using CaptureApp.Core;
using CaptureApp.Core.Index;

namespace CaptureApp.AppCore.Semantic;

/// What the semantic indexer reads from the keyword index and the vault.
public interface ISemanticSource
{
    IReadOnlyList<EmbeddableBlock> EmbeddableBlocks();

    IReadOnlyDictionary<string, SearchHit> Hits(IEnumerable<string> keys);

    /// Size and modification time of a vault-relative asset, with its bytes when requested; null if missing.
    VaultFileSnapshot? FileSnapshot(string relativePath, bool includingContents);

    string UrlForRelativePath(string relativePath);
}

public sealed class VaultSemanticSource(SearchIndex index, Vault vault) : ISemanticSource
{
    public IReadOnlyList<EmbeddableBlock> EmbeddableBlocks() => index.EmbeddableBlocks();

    public IReadOnlyDictionary<string, SearchHit> Hits(IEnumerable<string> keys) => index.Hits(keys);

    public VaultFileSnapshot? FileSnapshot(string relativePath, bool includingContents) => vault.FileSnapshot(relativePath, includingContents);

    public string UrlForRelativePath(string relativePath) => vault.UrlForRelativePath(relativePath);
}

public sealed record SemanticHits(IReadOnlyList<SearchHit> Text, IReadOnlyList<SearchHit> Images)
{
    public static SemanticHits Empty { get; } = new([], []);
}
