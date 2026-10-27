# focusnotes reference

Last Updated: 2026-10-28 (previous commit: `69e5fba`)

Detailed behaviour of capture, note storage and the quick-note editor. For setup, see the [README](../README.md).

## Capture and storage

Pressing a capture shortcut again while its toast is visible chooses the destination note.
To choose before saving, use **⌃⇧C** for selection or **⌃⇧S** for an area. These outside-session
shortcuts open **Add to note…** immediately, with note suggestions. A chosen title routes to an
existing note, then a matching session title, then Inbox, or a new root note; folder and `/` home
paths use the same routing as the re-press picker. Escape saves the capture to Inbox. The shortcuts
also work without a session. A current session stays active and the toast names it alongside the
destination; the next normal capture still goes to the session.

Captures append to plain Markdown compatible with Obsidian: `#` contains the note title;
`##` is a user subheading, and `###` identifies a source. A source heading
appears on the first capture, when the source changes, or after an intervening
Markdown heading outside fenced code. Timestamps and app metadata live in
invisible markers; browser captures add a separate `Source` link when available:

```markdown
# Inbox

### System Design
<!-- capture:a1b2c3d4-0000-4000-8000-000000000001 at=2026-10-14T13:04:58+05:30 app="Safari" -->

[Source](<https://example.com/design>)

First paragraph.

<!-- capture:a1b2c3d4-0000-4000-8000-000000000002 at=2026-10-14T13:05:10+05:30 app="Safari" -->

Second paragraph.

## Tradeoffs
<!-- subheading:a1b2c3d4-0000-4000-8000-000000000003 -->

### System Design
<!-- capture:a1b2c3d4-0000-4000-8000-000000000004 at=2026-10-14T13:05:25+05:30 app="Safari" -->

Third paragraph.
```

When a selection or area capture comes from a supported browser whose native
accessibility interface exposes its complete address-bar value, the capture
block includes a separate `[Source](<...>)` Markdown link immediately before
the content. Only HTTP(S) addresses are accepted. The app reads the exposed
address bar, not page contents or selected text; if the browser or address bar
is unsupported, inaccessible, or does not expose a complete URL, the capture
still saves without the link. A focused address field is skipped because it may
contain an unsubmitted edit rather than the current page address. On macOS, the supported browsers are Safari,
Chrome, and Edge. On Windows, Chrome and Edge are supported when UI Automation
exposes the English **Address and search bar** control and a complete HTTP(S)
value. Firefox is not supported on either platform.
Chrome may hide part of its address by default; right-click the address bar and
choose **Always show full URLs** to expose the complete URL when needed. ([Chromium's explanation](https://blog.chromium.org/2020/08/helping-people-spot-spoofs-url.html))
([Sources/CaptureKit/FrontmostContext.swift](../Sources/CaptureKit/FrontmostContext.swift), [windows/src/CaptureApp.Platform/Context/FrontmostContext.cs](../windows/src/CaptureApp.Platform/Context/FrontmostContext.cs), [Sources/Core/CaptureFormat.swift](../Sources/Core/CaptureFormat.swift), [windows/src/CaptureApp.Core/CaptureFormat.cs](../windows/src/CaptureApp.Core/CaptureFormat.cs))

Browser suffixes are removed from source titles; empty titles fall back to the
app, then “Unknown source”. Legacy dated capture blocks remain readable and are
never rewritten. Session notes can live at any depth under `Sessions/`. A unique
bare-name match resumes at its full path; several matches open a newest-first
picker with title, path, and modified date. Return resumes the highlighted session;
⌘↩ (Ctrl+Enter on Windows) opens a rename field with its current title selected.
Return confirms the rename and resumes the session; Escape returns to the picker.
Renaming changes the filename and title heading in the same folder, preserving the
remaining Markdown and relative image links. Names use session filename cleanup,
cannot contain folder separators, and cannot replace another file, including a
case-insensitive match. Pins, pending captures, and search follow the new path.
The heading rewrite uses an atomic replacement rather than truncating the note.
A slash-qualified name such as
`archive/Standup` resolves directly under `Sessions/`; a missing qualified name
creates that nested path. Escape cancels without changing session state. Existing
dated session notes can also resume in place. Images stay in `assets/`, with
relative `../assets/` links from session notes.

### Quick-note paths

A standalone quick note's derived title can include slash-separated folders.
Relative paths are under the vault, so `science/math/trigonometry` saves to
`<vault>/science/math/trigonometry.md`. A leading `/` resolves from the user's
home folder: `/Desktop/science/math/trigonometry` saves to
`~/Desktop/science/math/trigonometry.md`. Missing folders are created. Folder
and existing filename matching is case-insensitive, and saving to an existing
note appends the typed note to that file. Every valid unprefixed slash-separated
name is folder syntax, including ambiguous prose or dates such as
`pros/cons of X` and `10/18 standup`. For relative names, URLs, trailing/repeated
separators, and whitespace adjacent to a slash use the legacy flat filename cleanup;
malformed leading-slash HOME paths retain strict validation.

Sessions keep their `Sessions/` namespace: a quick note saved while a session is
active appends to that session note unless **Write outside session** is selected.
That action uses the same standalone paths described above without ending the session. Paths containing traversal
components such as `..`, paths that cross a symbolic link, and leaves beginning
with `~$` are rejected. The vault's `assets/` destination is reserved, matched
case-insensitively; a home-relative path that resolves inside that directory is
also rejected. Paths are limited to 32 components and 900 UTF-8 bytes.
Vault notes are discovered recursively below the vault, with hidden files and
the root-level directory named `assets` excluded case-insensitively; nested
directories named `assets` remain ordinary note folders. Before writing to an
external destination, Focusnotes records its exact HOME-relative Markdown path
in a durable registry so journal replay can reuse the destination. The registry
caches a validated path snapshot and generation, invalidated when its file or
parent changes. At startup, safely readable notes at registered paths join the
vault's discovered notes; missing or unreadable paths are skipped.
Search indexes those paths, and the watcher monitors existing parent directories
of registered external notes using bounded vnode sources; recursive FSEvents is
limited to the vault. Missing parents are observed from their nearest existing
ancestor, and only the registered paths are rechecked on an event. If the registry
is malformed, unsupported, or unsafe, its bytes are preserved, external notes are
hidden from search and new external saves are refused with a warning. Vault notes
remain usable; a valid registry recovery restores external indexing and watching.
Focusnotes does not scan HOME to discover external notes.

Area OCR uses preferred supported languages with accurate recognition and
language correction. Classification has a 1.5-second budget: slower OCR stages
an image and continues in the background to make it searchable. The acquisition
lock covers interactive selection only; captures still commit in acquisition
order. Captures, typed notes, and subheadings are journaled before append and replay without
duplication. No polling or recurring timers run while idle.


## Quick-note editor

Press **⌥⇧N** or choose **Quick-note** to type Markdown with live inline
preview. At rest the panel shows only your text; hover it for the top buttons (close,
open as note, actions ⌘K, browse ⌘P, new ⌘N) and the footer. ⌘P browses pinned and recent
notes (↩ write there, ⌘↩ open, ⌥↩ reveal), ⇧⌘P pins the destination note (app state, never
written into the Markdown), and ⌘O saves like ⌘↩ then opens the note in your default
Markdown app. ⌘N saves and opens a blank note. During a session, **Write outside session** in Actions
(⇧⌘N) toggles standalone routing for this note. The title shows its resolved destination, Browse can
still choose an existing note, and Save as New Note and pin-on-save work as usual. Choose the action
again, or press ⌘N on a blank editor, to restore the session destination. **⌃⇧N** (or **Quick-note Outside
Session**) opens the panel with Write outside session already on; ⇧⌘N switches it back to the session, and ⌘N on a
blank editor keeps it outside. Without a session it behaves like ⌥⇧N. Saving or closing clears the
choice; closing keeps the draft text, and the next quick note or normal capture uses the session.
The caret and selection lines show dimmed syntax; other lines render
without the syntax. Bullets display as •, and clickable task boxes support undo.
The stored text stays Markdown. ⌘↩ (including keypad Enter) saves and appends to
the active session by default. With no session routing or Browse destination, the footer says “Add to note”
for an existing path or Inbox and “Create note” otherwise. Its name comes
from the first non-empty line with Markdown removed, or “Note yyyy-MM-dd HH.mm”
if nothing remains. An unqualified name keeps the 60-character display-title cap
(then “…”). A path is parsed before display truncation: each component is cleaned
and bounded to 120 characters and 220 UTF-8 bytes, while the displayed title is
its sanitized final component, capped at 60 characters. Slashes in the name
select the note's folder path as described above. An ordinary
first line equal to the untruncated title is omitted from the body; lists, tasks,
quotes and code stay intact. Captures and subheadings still use Inbox without a
session. Return inserts a new line and continues lists (removing an empty marker);
Shift+Return inserts a plain newline, and Tab/Shift+Tab indent/outdent list items.
Return during IME composition goes to the input method. Escape or
clicking outside keeps an atomic `draft-note.md` in the app state directory,
restored next time. Paste is plain text; ⌘Z/⇧⌘Z undo/redo. A pending capture saves
first. Typed notes have invisible timestamped `<!-- note:… at=… -->` markers,
appear with their note title and time in keyword and semantic search, and do not change the capture
source. A heading typed in a note makes the next capture repeat its source heading.
Successful saves clear the draft; empty input clears it without appending.
New notes show “Note created” with their title; session appends show “Saved to <session>” with the note's first line.
An outside-session save names the target and the still-active session, for example
“Saved to Biology · Thermo still active”.
The journal retains the chosen path and original draft, so recovery reuses the
same file and clears the draft after saving, including when the title line was removed.

## Search index

The app links macOS's system SQLite and checks for FTS5 when the search index opens. macOS 14 ships SQLite 3.43 or
newer. The index uses no triggers, which avoids the FTS5-in-trigger issue in SQLite versions before 3.44.

## Windows differences

The implemented Windows edition writes the same files as the Mac app: the same Markdown, hidden markers, `Inbox.md`, `Sessions/`, `assets/` and state-file schemas, so a vault can move between the two. Current GitHub releases include Windows installers for x64 and arm64. This section lists where behaviour differs. Everything above applies unless stated here.

- **Keys.** Ctrl replaces ⌘ in the quick note (Ctrl+Enter saves, Ctrl+K Actions, Ctrl+P Browse, Ctrl+N new, Ctrl+Shift+N Write outside session while a session is active, Ctrl+O open as note, Ctrl+Shift+P pin, Ctrl+Shift+C copy Markdown, Ctrl+Shift+Backspace discard) and Alt+Enter replaces ⌥↩ ("Show in File Explorer"). The global shortcuts use Alt+Shift, matching the Mac's Option+Shift modifier pair, plus Q, G, F, A, W, H and E (selection, area, search, session, write, subheading, notes folder). Outside-session captures use Ctrl+Shift+Q for selection and Ctrl+Shift+G for an area; Ctrl+Shift+W opens the quick note outside the session. All global shortcuts can be rebound in Settings.
- **Paths.** The vault defaults to `Documents\focusnotes` and app state to `%LocalAppData%\com.zerodoxxx.focusnotes`. In a note name, `/` and `\` both separate folders, and a leading `/` resolves from `%USERPROFILE%` instead of the home folder. External-note registry entries are stored `/`-separated and home-relative, as on the Mac. A path that crosses a symbolic link, junction or other reparse point is rejected where the Mac rejects symlinks. Paths longer than 260 characters work.
- **Reserved names (DV7).** Windows file-name rules are applied on top of the Mac's. File names replace `<`, `>`, `"`, `|`, `?` and `*` with `-`, as both editions do for `:`, so a note titled `Why?` is saved as `Why-.md` with the heading `# Why?`, and `TODO: call Bob` as `TODO- call Bob.md` on both. After that cleanup, a component is rejected if it is a device name (`CON`, `PRN`, `AUX`, `NUL`, `COM1`-`COM9`, `LPT1`-`LPT9`), also with an extension such as `con.txt`, or ends with a period. A drive path such as `C:\Notes\a` is rejected rather than saved as a `C-` folder in the vault. Rejection uses the same message as the Mac's reserved-name errors. The Mac accepts these names and keeps `<>"|?*` in file names.
- **Selection capture (DV2, DV6, DV8).** Capture reads the selection through UI Automation. Only if that fails, and only when the clipboard fallback is turned on, it briefly sends Ctrl+C to the app and restores the clipboard. It waits up to two seconds for you to release the shortcut keys naturally, proceeding as soon as they are up. Switching to another app during that wait cancels capture. The fallback aborts without injecting if modifier keys remain held at the deadline ("Release the shortcut keys and try again"), or if the clipboard holds more than 64 MB or a format that cannot be copied safely ("Couldn't capture selection" with "Your clipboard is too large to restore safely"). The clipboard is restored only if nothing newer was copied in the meantime. The target app's own copy can still appear in Windows clipboard history. Apps running as administrator cannot be read: the toast "Can't capture from apps running as administrator" points to Capture Area.
- **OCR.** Windows area OCR uses RapidOcrNet's bundled PP-OCRv5 Latin models and starts English-first. The Mac's preferred-language model selection is not part of this POC; reading order, paragraph joining and the 1.5-second classification budget remain shared behavior.
- **Search index.** The index uses a bundled SQLite with FTS5 through `Microsoft.Data.Sqlite` rather than the system library, with the same schema and ranking. The watcher uses `ReadDirectoryChangesW`; on an overflow or error it rescans by enumerating the folder.
- **Semantic search.** The opt-in downloads only the model files (about 455 MB), because ONNX Runtime is bundled. Image embedding waits for AC power and battery saver off; Windows has no thermal state, so the helper runs with EcoQoS, below-normal priority and background I/O instead.
- **Additions.** Setup, Settings, start at login (on by default), single instance, and log files in the state directory's `logs` folder. See [DESIGN.md](../DESIGN.md#windows-edition).
