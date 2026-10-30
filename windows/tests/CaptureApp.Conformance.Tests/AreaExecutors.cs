using System.Globalization;
using System.Text.Json;
using CaptureApp.Core;
using CaptureApp.Core.Index;

namespace CaptureApp.Conformance.Tests;

public sealed class NoteTitleExecutor() : CoreAreaExecutor("notetitle");
public sealed class RouterExecutor() : CoreAreaExecutor("router");
public sealed class CaptureFormatExecutor() : CoreAreaExecutor("captureformat");
public sealed class NoteWriterExecutor() : CoreAreaExecutor("notewriter");
public sealed class VaultNamingExecutor() : CoreAreaExecutor("vault-naming");
public sealed class SessionStoreExecutor() : CoreAreaExecutor("sessionstore");
public sealed class NoteParserExecutor() : CoreAreaExecutor("noteparser");
public sealed class CaptureDestinationExecutor() : CoreAreaExecutor("capturedestination");
public sealed class SearchIndexExecutor() : IAreaExecutor
{
    public string Area => "searchindex";

    public Task<ScenarioExpected> ExecuteAsync(ScenarioInput input, CancellationToken cancellationToken = default)
    {
        using var execution = new SearchIndexExecution(input);
        var results = new List<JsonElement>();
        foreach (var op in input.Ops)
        {
            cancellationToken.ThrowIfCancellationRequested();
            object? value = execution.Perform(op);
            results.Add(JsonSerializer.SerializeToElement(value));
        }

        return Task.FromResult(new ScenarioExpected { Files = execution.Files(), Results = results });
    }

    private sealed class SearchIndexExecution : IDisposable
    {
        private readonly string temporary = Path.Combine(Path.GetTempPath(), "captureapp-searchindex-conformance-" + Guid.NewGuid().ToString("N"));
        private readonly string root;
        private readonly ScenarioInput input;
        private readonly Vault vault;
        private readonly SearchIndex index;

        internal SearchIndexExecution(ScenarioInput input)
        {
            this.input = input;
            root = Path.Combine(temporary, "vault");
            Directory.CreateDirectory(root);
            Directory.CreateDirectory(Path.Combine(temporary, "cache"));
            root = NoteFile.ResolveSelectedRoot(root);
            vault = new(root, homeDirectoryUrl: Path.Combine(temporary, "home"), namingRules: new() { WindowsRules = false });
            foreach (var file in input.Files.OrderBy(x => x.Key, StringComparer.Ordinal))
            {
                Write(file.Key, file.Value);
            }

            index = new(vault, Path.Combine(temporary, "cache", "index.sqlite"), TimeZoneInfo.FindSystemTimeZoneById(input.TimeZone));
        }

        private string Url(string path)
        {
            _ = NoteFile.PathComponents(path);
            return Path.Combine(root, path.Replace('/', Path.DirectorySeparatorChar));
        }

        private void Write(string path, string text)
        {
            var target = Url(path);
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.WriteAllText(target, text, NoteFile.Utf8);
            File.SetLastWriteTimeUtc(target, input.Clock.UtcDateTime);
        }

        private static string S(Dictionary<string, JsonElement> op, string key) => op.TryGetValue(key, out var value) && value.ValueKind != JsonValueKind.Null ? value.GetString()! : throw new JsonException("Missing " + key);

        internal object? Perform(Dictionary<string, JsonElement> op)
        {
            switch (S(op, "op"))
            {
                case "sync":
                    var stats = index.Sync();
                    return new { added = stats.Added, updated = stats.Updated, removed = stats.Removed, unchanged = stats.Unchanged };
                case "query":
                    var limit = op.TryGetValue("limit", out var limitValue) ? limitValue.GetInt32() : 40;
                    return index.Search(S(op, "text"), limit).Select(hit => new { id = hit.EmbeddingKey, title = hit.NoteTitle }).ToArray();
                case "write":
                    Write(S(op, "path"), S(op, "text"));
                    return null;
                case "remove":
                    File.Delete(Url(S(op, "path")));
                    return null;
                case "reindex":
                    index.Reindex(Url(S(op, "path")));
                    return null;
                default:
                    throw new InvalidOperationException("Missing searchindex operation: " + S(op, "op"));
            }
        }

        internal Dictionary<string, string> Files() => Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories).ToDictionary(path => Path.GetRelativePath(root, path).Replace(Path.DirectorySeparatorChar, '/'), path => File.ReadAllText(path, NoteFile.Utf8), StringComparer.Ordinal);

        public void Dispose()
        {
            index.Dispose();
            Directory.Delete(temporary, true);
        }
    }
}

public abstract class CoreAreaExecutor(string area) : IAreaExecutor
{
    public string Area { get; } = area;

    public Task<ScenarioExpected> ExecuteAsync(ScenarioInput input, CancellationToken cancellationToken = default)
    {
        using var execution = new Execution(input, Area);
        var results = new List<JsonElement>();
        foreach (var op in input.Ops)
        {
            cancellationToken.ThrowIfCancellationRequested();
            object? value;
            try
            {
                value = execution.Perform(op);
            }
            catch (NotePathNameException error)
            {
                value = new
                {
                    error = Lower(error.Kind.ToString())
                };
            }
            catch (VaultFileException error) when (error.Kind == VaultFileError.InvalidFileName)
            {
                value = new
                {
                    error = "invalidFileName"
                };
            }
            catch (SessionStoreException error)
            {
                value = new
                {
                    error = error.Kind == SessionStoreError.Ambiguous ? "ambiguousSession" : "candidateNoLongerExists"
                };
            }

            results.Add(JsonSerializer.SerializeToElement(value));
        }

        return Task.FromResult(new ScenarioExpected { Files = execution.Files(), Results = results });
    }

    private static string Lower(string value) => char.ToLowerInvariant(value[0]) + value[1..];
    private sealed class FixedClock(DateTimeOffset now) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => now;
    }

    private sealed class Execution : IDisposable
    {
        private readonly string temporary = Path.Combine(Path.GetTempPath(), "captureapp-conformance-" + Guid.NewGuid().ToString("N"));
        private readonly string root, home, state;
        private readonly TimeZoneInfo zone;
        private readonly ScenarioInput input;
        private readonly Vault vault;
        private readonly NoteWriter writer;
        private readonly FixedClock clock;
        private readonly string area;
        private SessionStore sessions;
        private CaptureService? service;
        internal Execution(ScenarioInput input, string area)
        {
            this.input = input;
            this.area = area;
            root = Path.Combine(temporary, "vault");
            home = Path.Combine(temporary, "home");
            state = Path.Combine(temporary, "state");
            Directory.CreateDirectory(root);
            Directory.CreateDirectory(home);
            root = NoteFile.ResolveSelectedRoot(root);
            home = NoteFile.ResolveSelectedRoot(home);
            zone = TimeZoneInfo.FindSystemTimeZoneById(input.TimeZone);
            clock = new(input.Clock);
            vault = new(root, homeDirectoryUrl: home, namingRules: new() { WindowsRules = false });
            writer = new(vault, zone, clock);
            sessions = new(state, vault, zone, clock);
            foreach (var file in input.Files.OrderBy(x => x.Key, StringComparer.Ordinal))
            {
                Write(file.Key, file.Value);
            }
        }

        private string Url(string path)
        {
            var relative = path.StartsWith('/') ? path[1..] : path;
            _ = NoteFile.PathComponents(relative);
            return Path.Combine(path.StartsWith('/') ? home : root, relative.Replace('/', Path.DirectorySeparatorChar));
        }

        private string LogicalPath(string path) => Vault.RelativeUnder(path, root) ?? "/" + (Vault.RelativeUnder(path, home) ?? throw new InvalidOperationException("Path outside fixture sandbox."));
        private void Write(string path, string text)
        {
            var target = Url(path);
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.WriteAllText(target, text, NoteFile.Utf8);
            File.SetLastWriteTimeUtc(target, input.Clock.UtcDateTime);
        }

        private static string S(Dictionary<string, JsonElement> op, string key, string? fallback = null) => op.TryGetValue(key, out var value) && value.ValueKind != JsonValueKind.Null ? value.GetString()! : fallback ?? throw new JsonException("Missing " + key);
        private static string? Optional(Dictionary<string, JsonElement> op, string key) => op.TryGetValue(key, out var value) && value.ValueKind != JsonValueKind.Null ? value.GetString() : null;
        private static bool B(Dictionary<string, JsonElement> op, string key, bool fallback = false) => op.TryGetValue(key, out var value) ? value.GetBoolean() : fallback;
        private static object? SessionResult(Session? session) => session is null ? null : new
        {
            name = session.Name,
            notePath = session.NotePath,
            startedAt = Stamp(session.StartedAt),
            resumed = session.Resumed
        };
        private static string? Stamp(DateTimeOffset? date) => date?.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
        private Capture Capture(Dictionary<string, JsonElement> op)
        {
            var content = S(op, "content", "text");
            var text = S(op, "text", "");
            return new(Guid.Parse(S(op, "id", "00000000-0000-4000-8000-000000000001")), Optional(op, "at") is { } at ? DateTimeOffset.Parse(at, CultureInfo.InvariantCulture) : input.Clock, content switch
            {
                "text" => CaptureContent.Text(text),
                "note" => CaptureContent.Note(text),
                "subheading" => CaptureContent.Subheading(text),
                "image" => CaptureContent.Image(S(op, "assetPath")),
                _ => throw new JsonException("Unknown content.")
            }, new(Optional(op, "app"), Optional(op, "window")));
        }

        // One CaptureService per case, so note reservations persist between ops.
        private CaptureService Service => service ??= new(vault, sessions, writer, clock);

        private static CaptureIntent Intent(Dictionary<string, JsonElement> op)
        {
            var (pick, title) = (Optional(op, "pick"), Optional(op, "title"));
            if (pick is not null && title is not null)
            {
                throw new JsonException("title and pick are mutually exclusive.");
            }

            CaptureTarget? target = pick is not null
                ? new CaptureTarget.Pick(new(pick, Path.GetFileNameWithoutExtension(pick), S(op, "pickKind", "note") switch
                {
                    "note" => NoteKind.Note,
                    "session" => NoteKind.Session,
                    "inbox" => NoteKind.Inbox,
                    var kind => throw new JsonException("Unknown pickKind: " + kind)
                }))
                : title is not null ? new CaptureTarget.Title(title) : null;
            return new(target, B(op, "outsideSession"), Optional(op, "folder") is { } raw ? new NoteFolder(raw) : null, B(op, "newNote"));
        }

        private object? PerformCaptureDestination(Dictionary<string, JsonElement> op)
        {
            switch (S(op, "op"))
            {
                case "startSession":
                    sessions.Start(S(op, "name"));
                    return null;
                case "resolve":
                    var intent = Intent(op);
                    PreparedCapture prepared;
                    try
                    {
                        prepared = Service.Resolve(Capture(op), intent, zone);
                    }
                    catch (FileNotFoundException) when (intent.Target is CaptureTarget.Pick)
                    {
                        return new { error = "noteNotFound" };
                    }

                    return new
                    {
                        path = LogicalPath(prepared.Destination.Url),
                        title = prepared.Destination.Title,
                        kind = Lower(prepared.Destination.Kind.ToString()),
                        createsNote = prepared.CreatesNote == true
                    };
                case "existingTitle":
                    return Service.ExistingTitle(S(op, "text"), Intent(op), zone);
                default:
                    throw new InvalidOperationException("Missing capturedestination operation: " + S(op, "op"));
            }
        }

        internal object? Perform(Dictionary<string, JsonElement> op)
        {
            // Other ops in this area use the common ops below, as in the Swift runner.
            if (area == "capturedestination" && S(op, "op") is "startSession" or "resolve" or "existingTitle")
            {
                return PerformCaptureDestination(op);
            }

            switch (S(op, "op"))
            {
                case "prepare":
                    vault.Prepare();
                    return null;
                case "write":
                    Write(S(op, "path"), S(op, "text"));
                    return null;
                case "read":
                    return File.ReadAllText(Url(S(op, "path")), NoteFile.Utf8);
                case "remove":
                    File.Delete(Url(S(op, "path")));
                    return null;
                case "cleanTitle":
                    return NoteTitle.CleanTitle(S(op, "text"));
                case "matchKey":
                    return NoteTitle.MatchKey(S(op, "text"));
                case "fileStem":
                    return NoteTitle.FileStem(S(op, "text"));
                case "pathName":
                    var name = NoteTitle.PathName(S(op, "text"), vault.NamingRules);
                    return new
                    {
                        scope = Lower(name.Scope.ToString()),
                        components = name.Components,
                        relativePath = name.RelativePath,
                        displayTitle = name.DisplayTitle
                    };
                case "resolve":
                    var location = vault.ResolveNoteName(S(op, "text"));
                    return new
                    {
                        scope = Lower(location.Scope.ToString()),
                        relativePath = location.RelativePath
                    };
                case "unique":
                    return LogicalPath(vault.UniqueNoteUrl(S(op, "text")));
                case "list":
                    return vault.ListNotes().Select(n => new { path = LogicalPath(n.Url), title = n.Title, kind = Lower(n.Kind.ToString()) }).ToArray();
                case "route":
                    var active = Optional(op, "sessionPath") is { } path ? new Session(S(op, "sessionName", "Session"), path, input.Clock) : null;
                    var destination = Router.Destination(Optional(op, "title"), active, vault.ListNotes(), vault);
                    return new
                    {
                        path = LogicalPath(destination.Url),
                        title = destination.Title,
                        kind = Lower(destination.Kind.ToString())
                    };
                case "noteHeader":
                    return CaptureFormat.NoteHeader(S(op, "text"));
                case "noteBody":
                    return CaptureFormat.NoteBody(S(op, "text"));
                case "cleanSubheading":
                    return CaptureFormat.CleanSubheading(S(op, "text"));
                case "sourceHeading":
                    return CaptureFormat.SourceHeading(Capture(op).Source);
                case "block":
                    return CaptureFormat.Block(Capture(op), S(op, "dir", ""), zone, B(op, "includeSourceHeading", true), Optional(op, "assetPathPrefix"));
                case "append":
                    writer.Append(Capture(op), Url(S(op, "path")), S(op, "title"));
                    return null;
                case "appendIfMissing":
                    writer.AppendIfMissing(Capture(op), new(Url(S(op, "path")), S(op, "title"), NoteKind.Note), noteMarkerIsIdentity: B(op, "noteMarkerIsIdentity"));
                    return null;
                case "start":
                    return SessionResult(sessions.Start(S(op, "name")));
                case "current":
                    return SessionResult(sessions.Current());
                case "end":
                    sessions.End();
                    return null;
                case "reload":
                    sessions = new(state, vault, zone, clock);
                    return SessionResult(sessions.Current());
                case "persisted":
                    return JsonDocument.Parse(File.ReadAllBytes(Path.Combine(state, "session.json"))).RootElement.Clone();
                case "writeState":
                    Directory.CreateDirectory(state);
                    File.WriteAllText(Path.Combine(state, "session.json"), S(op, "text"), NoteFile.Utf8);
                    return null;
                case "resume":
                    return SessionResult(sessions.Resume(new(S(op, "name"), S(op, "path"), input.Clock)));
                case "parse":
                    var notePath = S(op, "path", "Note.md");
                    var parsed = NoteParser.Parse(Optional(op, "text") ?? File.ReadAllText(Url(notePath), NoteFile.Utf8), notePath, S(op, "fallback", "Fallback"), zone);
                    return new
                    {
                        title = parsed.Title,
                        blocks = parsed.Blocks.Select(b => new { id = b.CaptureId?.ToString("D"), kind = Lower(b.Kind.ToString()), createdAt = Stamp(b.CreatedAt), sourceApp = b.SourceApp, windowTitle = b.WindowTitle, body = b.Body, assetPath = b.AssetPath }).ToArray()
                    };
                default:
                    throw new InvalidOperationException("Missing executor operation: " + S(op, "op"));
            }
        }

        internal Dictionary<string, string> Files() => Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories).ToDictionary(LogicalPath, p => File.ReadAllText(p, NoteFile.Utf8), StringComparer.Ordinal);
        public void Dispose() => Directory.Delete(temporary, true);
    }
}
