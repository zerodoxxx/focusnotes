# Shared Core conformance scenarios

Swift Core is the reference implementation. These fixtures record its current behavior for the C# port. They contain synthetic data only. OCR inputs live separately under `ocr/` and are not loaded by this harness.

Each case is `scenarios/<area>/<id>.json`:

```json
{
  "id": "case-id",
  "area": "notetitle",
  "description": "What the case exercises",
  "input": {
    "clock": "2026-10-13T09:00:42Z",
    "timeZone": "Asia/Kolkata",
    "files": {},
    "ops": [{ "op": "cleanTitle", "text": "  Example  " }]
  },
  "expected": {
    "files": {},
    "results": ["Example"]
  }
}
```

The example illustrates the schema; the committed scenario `expected` blocks are generated exclusively by Swift. Author a case with `id`, `area`, `description`, and `input`, then run the generator. Never edit expected values manually.

`input.files` maps vault-relative `/` paths to exact UTF-8 text. The initially empty vault is seeded with these files; it is **not** implicitly prepared. `expected.files` is the complete final vault file tree, including hidden files and non-note files, with exact text bytes represented as JSON strings. Fixture files use LF. CRLF tolerance is exercised with operation text arguments. Directory entries, mtimes, disposable SQLite files, and state-directory files are not included in the tree.

`expected.results` has one JSON value per operation, in execution order. Void operations return `null`. Known Core errors return `{ "error": "kind" }`; unexpected exceptions fail the runner. Error kinds are `emptyPath`, `invalidComponent`, `tooDeep`, `tooLong`, `invalidFileName`, `ambiguousSession`, and `candidateNoLongerExists`. Objects compare by key/value; arrays compare in order; strings compare exactly, including whitespace and Unicode. Operation results explicitly project URLs to logical vault-relative paths or fake-home paths, so temporary sandbox roots never enter expected output. Text, timestamps, stable capture identifiers, and known error kinds are compared without normalization.

Every case runs in a new temporary directory with separate `vault/`, fake `home/`, `state/`, and index locations. The clock is a whole-second ISO-8601 UTC instant ending in `Z`; the Gregorian calendar uses the supplied IANA time zone. Initial and explicit `write` file mtimes use that fixed clock. A leading `/` in **operation** file paths denotes the fake home; no operation accesses the machine's real HOME. File paths reject traversal, empty components, NUL, and backslashes. User-facing **note names** passed to Core retain Core's own parsing rules. Case ids and area directory names must match their files.

## Operation vocabulary

Common to all areas:

| Operation | Arguments | Result |
| --- | --- | --- |
| `prepare` | none | `null`; runs `Vault.prepare`, creating Inbox and managed directories |
| `write` | `path`, `text` | `null`; create/replace a UTF-8 file and set fixed mtime |
| `read` | `path` | exact UTF-8 text; also observes fake-home writes |
| `remove` | `path` | `null`; delete a file |

Area-specific operations:

| Area | Operations and arguments | Results |
| --- | --- | --- |
| `notetitle` | `cleanTitle`, `matchKey`, `fileStem`: `text`; `pathName`: `text` | strings; `pathName` returns `{scope, components, relativePath, displayTitle}` |
| `vault-naming` | `pathName`: `text`; `resolve`: `text`; `unique`: `text`; `list` | parsed name; `{scope, relativePath}`; next free vault path; ordered `[{path, title, kind}]` |
| `router` | `route`: optional `title`, `sessionPath`, `sessionName` | `{path, title, kind}`; session default name is `Session` |
| `captureformat` | `block`: capture arguments below, optional `dir`, `includeSourceHeading`, `assetPathPrefix`; `sourceHeading`: optional `app`, `window`; `noteHeader`, `noteBody`, `cleanSubheading`: `text` | exact strings |
| `notewriter` | `append`, `appendIfMissing`: `path`, `title`, capture arguments; latter accepts `noteMarkerIsIdentity` | `null`; files show exact append/replay behavior |
| `sessionstore` | `start`: `name`; `current`; `end`; `reload`; `persisted`; `writeState`: `text`; `resume`: `name`, `path` | session object or `null`; `persisted` returns parsed state JSON; `writeState` seeds recovery cases; `reload` recreates the store and returns current state |
| `noteparser` | `parse`: either `text` or a seeded `path`; optional `path`, `fallback` | `{title, blocks}`; each block has `{id, kind, createdAt, sourceApp, windowTitle, body, assetPath}` |
| `searchindex` | `sync`; `query`: `text`, optional `limit`; `reindex`: `path` | sync `{added, updated, removed, unchanged}`; ordered query `[{id, title}]`; reindex `null` |

Capture arguments are optional `id` (UUID, default `00000000-0000-4000-8000-000000000001`), `at` (UTC instant, default input clock), `content` (`text`, `image`, `note`, `subheading`; default `text`), `text` (default empty), `assetPath` (required for image), `app`, and `window`. `block` defaults to root directory and includes the source heading. Image fixtures test Markdown links without writing binary assets; this format's file values are UTF-8 text.

Session objects have `{name, notePath, startedAt, resumed}`. Dates in result objects are UTC ISO-8601 strings; dates embedded in Markdown follow the injected local calendar. Session persistence can be inspected through `persisted`, and survives `reload`. `end` removes state but preserves notes.

Parser defaults are `path: "Note.md"` and `fallback: "Fallback"`. Absent block metadata is explicit JSON `null`. Query defaults to limit 40. The index starts empty and only changes through `sync` or `reindex`; queries do not sync implicitly. Search ids are Core's stable embedding keys (`<note-id>#<capture-uuid>` or `<note-id>#loose-<ordinal>`), rather than disposable SQLite row numbers. Order is the exact Core query order, including relevance and tie breaks.

## Regeneration and checks

From the package root, or a descendant directory:

```sh
swift run CoreChecks --write-conformance
swift run CoreChecks
```

The generator writes pretty-printed JSON with sorted object keys, unescaped slashes, and one final LF. It executes every operation against Swift Core before writing `expected`. A second generation must leave the fixture contents byte-identical. Normal checks never rewrite fixtures, require at least 60 total cases and at least five per known area, and print `PASS conformance <area>/<id>`.

On the C# side:

```sh
cd windows
dotnet restore --locked-mode
dotnet build -c Release --no-restore -warnaserror
dotnet test -c Release --no-build
```

`CaptureApp.Conformance.Tests` validates every scenario with System.Text.Json and executes each non-search scenario as a separate xUnit theory case. `IAreaExecutor`, keyed by `Area`, returns the complete file tree and ordered operation results for exact comparison. These executions explicitly turn `VaultNamingRules.WindowsRules` off on every operating system to compare against Mac truth. The `searchindex` executor is intentionally absent; only those theory rows are skipped with reason `step 3b`.

A scenario whose seeded file paths cannot exist on Windows may add top-level metadata:

```json
"skipOn": ["windows"],
"skipReason": "The seeded file name is illegal on Windows."
```

The C# loader accepts these optional fields, requires a non-empty reason for each exclusion, and skips only the listed operating system. The Swift runner ignores them during validation. Never change `expected` to accommodate an operating system. Cover the Windows naming outcome separately in `VaultNamingWindowsTests.cs`, using `WindowsRules` on. No current Core scenario needs a platform exclusion. The Swift writer reconstructs the known fixture schema when regenerating, so reapply any future skip metadata after regeneration (without changing expected values).
