using System.Globalization;
using Microsoft.Data.Sqlite;

namespace CaptureApp.Embed;

public interface IVectorStore
{
    string ModelId { get; }

    int Dimensions { get; }

    void Upsert(string key, float[] vector, string? fingerprint = null);

    void Remove(IReadOnlyCollection<string> keys);

    IReadOnlyList<string> Keys();

    /// Missing fingerprints are omitted: old vectors stay searchable until reconciliation replaces them.
    IReadOnlyDictionary<string, string> Fingerprints();

    IReadOnlyList<(string Key, float Score)> Nearest(float[] query, int limit, CancellationToken cancellationToken = default);
}

/// A separate SQLite database (vectors.sqlite), scoped by model revision/quantization and dims.
/// Normalizes vectors on insert and after Float16 decoding so nearest scores are cosine similarities.
/// Serialized access and a reusable row-major cache.
public sealed class VectorStore : IVectorStore, IDisposable
{
    private static readonly object InitializeGate = new();
    private static bool initialized;

    private readonly SqliteConnection connection;
    private readonly object gate = new();
    private (string[] Keys, float[] Vectors)? cache;
    private long dataVersion = -1;

    /// Pass the text and vision ONNX graph/data files to stamp the store against their identities.
    /// Omitting them retains an existing file-size stamp while still validating model ID and dimensions.
    public VectorStore(string path, string modelId = Embedder.ModelID, int dimensions = 256, IReadOnlyList<string>? modelFiles = null)
    {
        if (!EmbedRequest.SupportedDimensions.Contains(dimensions) || modelId.Length == 0 || modelId.Contains('\0'))
        {
            throw EmbeddingException.Invalid("Invalid vector store configuration");
        }

        var requestedIdentity = modelFiles is null ? null : Identity(modelId, dimensions, modelFiles);
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        lock (InitializeGate)
        {
            if (!initialized)
            {
                SQLitePCL.Batteries_V2.Init();
                initialized = true;
            }
        }

        ModelId = modelId;
        Dimensions = dimensions;
        connection = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Mode = SqliteOpenMode.ReadWriteCreate, Pooling = false }.ToString());
        try
        {
            connection.Open();
            Exec("PRAGMA busy_timeout=5000; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;");
            Exec("""
                CREATE TABLE IF NOT EXISTS embeddings (
                    key TEXT PRIMARY KEY NOT NULL,
                    model_id TEXT NOT NULL,
                    dims INTEGER NOT NULL CHECK(dims IN (128,256,512,768)),
                    vector BLOB NOT NULL CHECK(length(vector) = dims * 2),
                    fingerprint TEXT
                ) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS meta (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                ) WITHOUT ROWID;
                """);
            var hasFingerprint = false;
            using (var columns = Command("PRAGMA table_info(embeddings)"))
            using (var reader = columns.ExecuteReader())
            {
                while (reader.Read())
                {
                    hasFingerprint |= reader.GetString(1) == "fingerprint";
                }
            }

            if (!hasFingerprint)
            {
                Exec("ALTER TABLE embeddings ADD COLUMN fingerprint TEXT");
            }

            var storedIdentity = ReadModelIdentity();
            var identity = requestedIdentity ?? IdentityKeepingFiles(modelId, dimensions, storedIdentity);
            var identityChanged = storedIdentity is not null && storedIdentity != identity;
            var missingIdentityWithVectors = storedIdentity is null && ContainsVectors();
            if (identityChanged || missingIdentityWithVectors)
            {
                Exec("BEGIN IMMEDIATE");
                try
                {
                    Exec("DELETE FROM embeddings");
                    WriteModelIdentity(identity);
                    Exec("COMMIT");
                }
                catch
                {
                    TryExec("ROLLBACK");
                    throw;
                }
            }
            else if (storedIdentity is null)
            {
                WriteModelIdentity(identity);
            }
        }
        catch (SqliteException error)
        {
            connection.Dispose();
            throw EmbeddingException.Database(error.Message);
        }
        catch
        {
            connection.Dispose();
            throw;
        }
    }

    public string ModelId { get; }

    public int Dimensions { get; }

    public void Dispose() => connection.Dispose();

    public void Upsert(string key, float[] vector, string? fingerprint = null)
    {
        if (key.Length == 0 || key.Contains('\0') || vector.Length != Dimensions || fingerprint?.Contains('\0') == true)
        {
            throw EmbeddingException.Invalid("Invalid vector key or dimensions");
        }

        var data = Float16Vectors.Encode(VectorMath.Normalized(vector));
        Locked(() =>
        {
            using var command = Command("INSERT INTO embeddings(key,model_id,dims,vector,fingerprint) VALUES($key,$model,$dims,$vector,$fingerprint) ON CONFLICT(key) DO UPDATE SET model_id=excluded.model_id,dims=excluded.dims,vector=excluded.vector,fingerprint=excluded.fingerprint");
            command.Parameters.AddWithValue("$key", key);
            command.Parameters.AddWithValue("$model", ModelId);
            command.Parameters.AddWithValue("$dims", Dimensions);
            command.Parameters.AddWithValue("$vector", data);
            command.Parameters.AddWithValue("$fingerprint", (object?)fingerprint ?? DBNull.Value);
            command.ExecuteNonQuery();
            cache = null;
        });
    }

    public void Remove(IReadOnlyCollection<string> keys)
    {
        if (keys.Any(key => key.Contains('\0')))
        {
            throw EmbeddingException.Invalid("Invalid key");
        }

        Locked(() =>
        {
            if (keys.Count == 0)
            {
                return;
            }

            Exec("BEGIN IMMEDIATE");
            try
            {
                using var command = Command("DELETE FROM embeddings WHERE key=$key");
                var parameter = command.Parameters.Add("$key", SqliteType.Text);
                foreach (var key in keys)
                {
                    parameter.Value = key;
                    command.ExecuteNonQuery();
                }

                Exec("COMMIT");
                cache = null;
            }
            catch
            {
                TryExec("ROLLBACK");
                cache = null;
                throw;
            }
        });
    }

    public IReadOnlyList<string> Keys() => Locked(() =>
    {
        LoadCache();
        return (IReadOnlyList<string>)cache!.Value.Keys;
    });

    public IReadOnlyDictionary<string, string> Fingerprints() => Locked(() =>
    {
        using var command = Command("SELECT key,fingerprint FROM embeddings WHERE model_id=$model AND dims=$dims AND fingerprint IS NOT NULL");
        command.Parameters.AddWithValue("$model", ModelId);
        command.Parameters.AddWithValue("$dims", Dimensions);
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            result[reader.GetString(0)] = reader.GetString(1);
        }

        return (IReadOnlyDictionary<string, string>)result;
    });

    public IReadOnlyList<(string Key, float Score)> Nearest(float[] query, int limit, CancellationToken cancellationToken = default)
    {
        if (query.Length != Dimensions)
        {
            throw EmbeddingException.Invalid("Query dimensions do not match store");
        }

        var unit = VectorMath.Normalized(query);
        return Locked(() =>
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (limit <= 0)
            {
                return [];
            }

            LoadCache(cancellationToken);
            var (keys, vectors) = cache!.Value;
            if (keys.Length == 0)
            {
                return [];
            }

            var scores = new float[keys.Length];
            for (var row = 0; row < keys.Length; row++)
            {
                var sum = 0f;
                var offset = row * Dimensions;
                for (var i = 0; i < Dimensions; i++)
                {
                    sum += vectors[offset + i] * unit[i];
                }

                scores[row] = sum;
            }

            // Stable key order resolves ties reproducibly.
            return (IReadOnlyList<(string, float)>)Enumerable.Range(0, keys.Length)
                .OrderByDescending(i => scores[i]).ThenBy(i => keys[i], StringComparer.Ordinal)
                .Take(limit).Select(i => (keys[i], Math.Clamp(scores[i], -1f, 1f))).ToList();
        });
    }

    private void LoadCache(CancellationToken cancellationToken = default)
    {
        long version;
        using (var command = Command("PRAGMA data_version"))
        {
            version = Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture);
        }

        if (cache is not null && version == dataVersion)
        {
            return;
        }

        using var select = Command("SELECT key,vector FROM embeddings WHERE model_id=$model AND dims=$dims ORDER BY key");
        select.Parameters.AddWithValue("$model", ModelId);
        select.Parameters.AddWithValue("$dims", Dimensions);
        var keys = new List<string>();
        var vectors = new List<float>();
        using var reader = select.ExecuteReader();
        while (reader.Read())
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (reader.GetValue(1) is not byte[] blob || blob.Length != Dimensions * 2)
            {
                throw EmbeddingException.Database("Corrupt vector row");
            }

            keys.Add(reader.GetString(0));
            vectors.AddRange(VectorMath.Normalized(Float16Vectors.Decode(blob, Dimensions)));
        }

        cache = ([.. keys], [.. vectors]);
        dataVersion = version;
    }

    private string? ReadModelIdentity()
    {
        using var command = Command("SELECT value FROM meta WHERE key='model_identity'");
        return command.ExecuteScalar() as string;
    }

    private bool ContainsVectors()
    {
        using var command = Command("SELECT EXISTS(SELECT 1 FROM embeddings LIMIT 1)");
        return Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture) != 0;
    }

    private void WriteModelIdentity(string identity)
    {
        using var command = Command("INSERT INTO meta(key,value) VALUES('model_identity',$value) ON CONFLICT(key) DO UPDATE SET value=excluded.value");
        command.Parameters.AddWithValue("$value", identity);
        command.ExecuteNonQuery();
    }

    private static string Identity(string modelId, int dimensions, IReadOnlyList<string> modelFiles)
    {
        var files = modelFiles.Select(path =>
        {
            var info = new FileInfo(path);
            if (!info.Exists)
            {
                throw EmbeddingException.Database($"Could not read model file size: {info.Name}");
            }

            return $"{info.Name}={info.Length}";
        }).OrderBy(name => name, StringComparer.Ordinal);
        return $"model={modelId};dimensions={dimensions};files={string.Join(",", files)}";
    }

    private static string IdentityKeepingFiles(string modelId, int dimensions, string? storedIdentity)
    {
        var marker = storedIdentity?.IndexOf(";files=", StringComparison.Ordinal) ?? -1;
        var files = marker >= 0 ? storedIdentity![(marker + ";files=".Length)..] : "";
        return $"model={modelId};dimensions={dimensions};files={files}";
    }

    private T Locked<T>(Func<T> body)
    {
        lock (gate)
        {
            try
            {
                return body();
            }
            catch (SqliteException error)
            {
                throw EmbeddingException.Database(error.Message);
            }
        }
    }

    private void Locked(Action body) => Locked(() =>
    {
        body();
        return 0;
    });

    private SqliteCommand Command(string sql)
    {
        var command = connection.CreateCommand();
        command.CommandText = sql;
        return command;
    }

    private void Exec(string sql)
    {
        using var command = Command(sql);
        command.ExecuteNonQuery();
    }

    private void TryExec(string sql)
    {
        try
        {
            Exec(sql);
        }
        catch (SqliteException)
        {
        }
    }
}
