# Menu bar demo

Run `scripts/run-app.sh` from the project root. The app stays in the menu bar with
no Dock icon. Click its menu-bar icon → **Permissions → Accessibility** and grant the
app access in System Settings. Press **⌥⇧S** once to request Screen Recording,
then grant the app access under **Permissions → Screen Recording**. Relaunch with
`scripts/run-app.sh` after granting both permissions. The permission checkmarks
refresh whenever the menu opens.

1. In Safari, select a paragraph and press **⌥⇧C**. A “Saved to Inbox” toast
   appears; leave it alone for two seconds to append the text to Inbox.
2. Select another paragraph and press **⌥⇧C**, then press **⌥⇧C** again while its
   toast is visible. Type **Safari Research** in “Add to note…” and press Enter.
   Suggestions support arrow keys and Tab. Escape saves to the default destination.
3. Press **⌥⇧S** and drag around a diagram. Sparse diagrams stay images with
   searchable OCR; dense prose regions become text when OCR finishes within 1.5 s.
   Slower OCR stages an image and adds searchable text later. Other capture
   shortcuts work while OCR runs. Press Escape to cancel an area.
4. Press **⌥⇧A**, enter **Demo Session**, and press Enter. The menu-bar icon fills.
   Capture two selections with **⌥⇧C**, letting each toast expire. Press **⌥⇧A**
   again: “Session ended · Demo Session” shows “2 captures”. Starting **Demo Session**
   again resumes `Sessions/Demo Session.md` and shows “Session resumed · Demo Session”.
   Names match ignoring case after filename cleaning; existing dated notes resume
   in place too.
   Press **⌥⇧H** (or **Add Subheading…** in the menu), type **Tradeoffs**,
   and press Enter. The panel says “Add subheading” and “In Demo Session” (or “In
   Inbox” with no session). A pending capture saves first, then `## Tradeoffs` is
   appended. Escape cancels, and empty input does nothing.
5. Press **⌥⇧N** (or **Quick-note**, right before **Quick-note Outside Session** and **Add Subheading…**).
   The floating editor shows only your text; hover it to reveal the buttons and a footer
   reading **Add to note** (the faded title above names **Demo Session**), or
   **Create note** without an active session. Try **⌘P** to open the Browse card and pick a note, **⇧⌘P** to add/remove it from Browse’s Pinned section, **⌘O** to open as a note, **⌘N** for a
   fresh note. Type
   Markdown: headings, bold, italic, strike, code, lists/tasks, quotes, and links
   render in place. The caret and selection lines reveal dimmed Markdown syntax;
   other lines hide it. Bullets always display as •, ordered numbers stay visible,
   and task checkboxes toggle with a click (undoable). Quote lines show a bar. The
   stored text remains unchanged except for edits, including task toggles. Return adds
   a line and continues the current list (an empty item removes its marker); inside
   fenced code it adds a plain newline. **Shift+Return** always adds a plain newline.
   **⌘+Return** (including **⌘+keypad Enter**) saves. Return during IME composition goes to
   the input method. **Tab/Shift+Tab** indent/outdent lists by two spaces; **⌘Z/⇧⌘Z**
   undo/redo. Paste inserts plain text. The editor grows from a two-line minimum to 60% of the
   screen or 680pt, then scrolls; trailing empty caret lines count once. Lists, tasks, quotes,
   bold and inline code keep the body line height. It shrinks when lines are deleted; width
   only grows. The right capsule is **Browse, New, Actions** (trailing ellipsis).
   Opening Actions or Browse by click or shortcut keeps its button's circular pressed fill on, even on
   hover. Swapping cards transfers the on state; closing the card clears it.
   Quick notes are sticky: clicking outside or switching Spaces leaves the note visible.
   Losing key closes any open card. Its caret stops while another window has key. The first text click
   places the caret; buttons and band drags work on the first click without activating focusnotes.
   **⌥⇧N** on a visible non-key note restores focus without rebuilding it or changing draft, caret
   or scroll; while key it closes, draft kept. Escape/✕ also keep a draft; reopening a closed
   note restores its caret at the end and shows **Draft kept**. A pinned title has a small pin
   glyph before it. **Add to Pinned/Remove from Pinned** controls Browse membership, not the
   window. An unsaved draft’s pin intent survives closing/reopening, pins its created note on
   save, and clears on discard or New Note; an existing/session destination’s real pin state wins.
   Pinning runs after a successful note write and before draft cleanup, including shutdown retry and startup
   replay. Interactive saves use the call's intent; recovery uses the latest matching persisted draft intent.
   Removing that intent before recovery leaves the note unpinned. Intent stays in the draft store, so discarded
   or replaced drafts do not pin older recovered jobs. A pin-storage error produces one warning toast,
   **Note saved, but not pinned**, with the destination title below it, while the note save succeeds and clears
   its draft. A success toast must not replace that warning.
   A pending capture commits before a new editor opens. Inside a session, saves append Markdown and show **Saved to <session>**.
   Outside a session, the first line names the note, optionally with folders (`science/Biology`) or a `/` home path.
   A name with no note at that path creates one and shows **Note created** with its title; an existing note at that
   path (or **Inbox**) is appended to and shows **Note added** with the note's first line. With **Write outside session**
   on during a session, the toast reads **Saved to <title> · <session> still active**.
   The title is the first non-empty line stripped of heading/list/task/quote syntax,
   emphasis, code delimiters, links (keeping their labels), and HTML comments, with
   whitespace collapsed. Long titles stop at a word boundary within 60 characters
   and add “…”; empty stripped titles use **Note yyyy-MM-dd HH.mm** and always create a new
   note. Filenames follow the usual cleaning rules (**Title.md**); **Save as New Note** (⌥⌘↩) creates a numbered
   **Title 2.md** beside an existing note instead of appending. If the
   physical first line equals the untruncated title after stripping, it is omitted
   from the body unless it is a list, task, quote or code line. A title-only note is
   valid. Other body text stays intact, with trailing whitespace trimmed. Saving
   clears the original draft; empty input clears it without saving. Typed notes
   are searchable under their note title and time, including semantic search with
   installed models. Captures and subheadings continue using Inbox outside sessions.
6. Press **⌥⇧F**. The empty query shows Recent; type a word from a capture to
   search. Enter copies its full text (or image); **⌘Enter** opens the Markdown
   note in the default editor, and **⌥Enter** reveals it in Finder. Escape closes
   the panel. Try pasting a copied capture back into your current app.
7. With models installed, capture “Token buckets allow bursts”, wait for background
   indexing, then search for **throttling API traffic** with **⌥⇧F**. The capture
   appears despite having no query words. A cold helper can take several seconds
   to warm; type the query again once indexing has finished. Semantic-only rows
   have no word highlights. When all required model files are present, the menu shows a
   checked **Semantic Search** item with **Remove Models…** beneath it; otherwise it offers
   **Enable Semantic Search…**.
8. Choose **Open Notes Folder** from the menu (also **⌥⇧L**). Inspect
   `Inbox.md`, `Safari Research.md`, any notes created with **⌥⇧N** outside a session,
   `Sessions/Demo Session.md`, and PNGs in
   `assets/`. Capture menu actions work after the menu closes.
9. Edit a note in Obsidian or another editor, save a new paragraph, then search
   for it. The vault watcher updates the index in the background without reopening
   search; external image edits also retry missing/outdated OCR.

During captures and toasts, keep typing in the original app: it remains active.
Destination, session, note editor, subheading, and search panels temporarily accept keyboard input without
activating the app. Input/Search dismiss on click-away; quick notes retain their window, close any
card, and return keyboard input to the clicked app. Explicitly closing a panel returns input to the
previous window. Opening
notes, Finder, or System Settings intentionally switches to those apps.

Notes default to `~/Documents/<app display name>/`. Choose **Choose Notes Folder…**
from the menu-bar icon to select another writable folder, such as an existing Obsidian vault,
then restart the app. First launch offers the default folder or **Choose Notes Folder…**,
and uses a folder selected there immediately. Existing notes stay where they are; the app
does not move them. The choice is saved as `vaultPath` in UserDefaults.
Session state and the disposable search cache live at
`~/Library/Application Support/<bundle identifier>/`. Read the display
name and bundle identifier from the built app's `Contents/Info.plist` (the source
configuration is `Config/app.env`). Each notes folder retains its own sessions, drafts,
pending saves, pins and search index when switching folders; settings and downloaded
models remain shared. To reset, quit the app, delete its notes folder
and state directory, then run `scripts/run-app.sh` again; this deletes your notes
and assets. System Settings permission grants remain in place.

For a permission-free pipeline smoke test, run the built app's executable with
`--self-test <empty temporary directory>`. It uses that directory for both notes
and state, prints a JSON verification summary, and exits. Add
`--models <models directory>` to include the no-keyword-overlap semantic assertion;
without model files the semantic part is reported as skipped and the test passes.
For isolated quick-note pin-intent persistence, legacy migration, unpinned retry, shutdown/startup recovery and final pin-failure warning checks that do not require OCR, run
`QUICK_NOTE_SELF_TEST=1 .build-ui/out/Products/Debug/App --self-test <empty temporary directory>`.
This uses the CLI self-test executable and temporary state, with no real app launch.

Both modes verify the 1.5-second OCR budget with delayed recognition, subsequent
OCR searchability, a second acquisition during OCR, source-heading omission,
session resume, and the controller method used by **⌥⇧H**, including journal replay. They also verify **⌥⇧N** controller saving, pending-first
ordering, keyword search, atomic draft text/pin-intent persistence, legacy migration, restoration and cleanup, and
typed-note replay without duplicate bytes. Controller saves without a session create
a titled root file, are searchable, clear the original draft after title removal,
append when saved again under the same title, use a collision suffix only for Save as
New Note, and replay into their fixed path without another file. Write outside session
routing, its toggle and its reset are checked against a live session.
The real format example is written to `FeedbackCases/Vault/Sessions/Feedback.md`
inside the self-test directory. Both modes also append an external capture block using FileManager and require
it to become searchable through the watcher within five seconds, with no explicit
sync. The test checks that termination stops the watcher.

Models live in `~/Library/Application Support/<bundle identifier>/models/`.
Read `CFBundleIdentifier` from the built bundle's `Contents/Info.plist`, then run
`scripts/fetch-models.sh "$HOME/Library/Application Support/<bundle identifier>/models"`
with that identifier substituted. The download is about 492 MB and every file is
verified against its pinned SHA-256; rerunning reuses verified files. Opening the menu notices newly installed
models without relaunching. Images are indexed only on AC power with nominal or
fair thermal state; deferred images retry on the next capture or index sync.

Captures use a cleaned window title as their `###` source heading (without trailing
browser branding), falling back to app name or “Unknown source”. Date and app
metadata are invisible and keep their local time-zone offset:

```markdown
### System Design
<!-- capture:a1b2c3d4-0000-4000-8000-000000000001 at=2026-10-14T13:04:58+05:30 app="Firefox" -->

First paragraph.

<!-- capture:a1b2c3d4-0000-4000-8000-000000000002 at=2026-10-14T13:05:10+05:30 app="Firefox" -->

Second paragraph.

## Tradeoffs
<!-- subheading:a1b2c3d4-0000-4000-8000-000000000003 -->

### System Design
<!-- capture:a1b2c3d4-0000-4000-8000-000000000004 at=2026-10-14T13:05:25+05:30 app="Firefox" -->

Third paragraph.
```

The source heading repeats only when its cleaned text changes or any Markdown
ATX heading (`#` through `######`) appears after the previous capture marker,
including a user subheading. Headings inside fenced code do not count. Old
`### date · app · window` capture blocks keep parsing forever; no old bytes are
rewritten. Marker app names escape quotes and comment delimiters.

`swift build --scratch-path .build-ui` followed by `.build-ui/out/Products/Debug/OverlayGallery` from the repo root renders the subheading
panel as `build/gallery/input-subheading-light.png` and
`build/gallery/input-subheading-dark.png`. The gallery uses the production panel
views without ordering windows. Add `--live subheading` to preview it interactively.

The same gallery renders `build/gallery/editor-empty-{light,dark}.png`,
`editor-draft-{light,dark}.png`, and `editor-styles-{light,dark}.png`, with the
production editor views. `editor-styles` keeps the caret on its H2 line;
`editor-caret-on-list-{light,dark}.png` keeps it on the long bullet item. The gallery
adds `editor-new-note-{light,dark}.png` for the **New note** destination.
Bullets use the body font at semibold weight; task boxes align with the text's cap
height center, and inline code has a rounded fill with three points of horizontal padding.
The gallery
also checks bullet glyphs/indices, hidden syntax and caret-line invalidation,
checkbox toggle/undo, and MarkdownStyler ranges and measures full
20k-character restyles; larger notes restyle edited paragraphs. Add `--live editor`
for an interactive preview, or `--check` for keyboard, focus, IME, and draft-error
behavior assertions. Atomic editor draft text and pin intent live together in `draft-note.json` alongside the
capture journal's `unsaved/` directory. Existing `draft-note.md` files migrate on the next draft write;
saving/discarding removes the whole draft record. There are no recurring draft timers.

A typed note begins with `<!-- note:<uuid> at=<local ISO-8601 timestamp> -->`,
then a blank line and its body. It emits no source heading. Capture source grouping
uses the last capture marker, skipping note/subheading markers; a heading typed
inside a note still forces the next source heading (except inside fenced code).
