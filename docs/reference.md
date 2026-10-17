# focusnotes reference

Last Updated: 2026-10-17 (previous commit: `f3d72362bd81a0875523d78cab8ba06eed830604`)

Detailed behaviour of capture, note storage and the quick-note editor. For setup, see the [README](../README.md).

## Capture and storage

Pressing a capture shortcut again while its toast is visible chooses the destination note.

Notes are append-only, plain Markdown compatible with Obsidian: `#` contains the note title;
`##` is a user subheading, and `###` identifies a source. A source heading
appears on the first capture, when the source changes, or after an intervening
Markdown heading outside fenced code. Timestamps and apps live in invisible
markers, so repeated captures stay uncluttered:

```markdown
# Inbox

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

Browser suffixes are removed from source titles; empty titles fall back to the
app, then “Unknown source”. Legacy dated capture blocks remain readable and are
never rewritten. Session notes use `Sessions/<Title>.md`; starting the same cleaned
filename again, ignoring case, resumes that note. Existing dated session notes
can also resume in place. Images stay in `assets/`, with `../assets/` links from
session notes.

Area OCR uses preferred supported languages with accurate recognition and
language correction. Classification has a 1.5-second budget: slower OCR stages
an image and continues in the background to make it searchable. The acquisition
lock covers interactive selection only; captures still commit in acquisition
order. Captures, typed notes, and subheadings are journaled before append and replay without
duplication. No polling or recurring timers run while idle.


## Quick-note editor

Press **⌥⇧N** or choose **Write a Note…** to type Markdown with live inline
preview. At rest the panel shows only your text; hover it for the top buttons (close,
open as note, actions ⌘K, browse ⌘P, new ⌘N) and the footer. ⌘P browses pinned and recent
notes (↩ write there, ⌘↩ open, ⌥↩ reveal), ⇧⌘P pins the destination note (app state, never
written into the Markdown), and ⌘O saves like ⌘↩ then opens the note in your default
Markdown app. ⌘N saves and opens a blank note. The caret and selection lines show dimmed syntax; other lines render
without the syntax. Bullets display as •, and clickable task boxes support undo.
The stored text stays Markdown. ⌘↩ (including keypad Enter) saves and appends to
the active session; outside a session the footer says “Create note” and it creates a separate root note. Its title comes
from the first non-empty line with Markdown removed, capped at a word boundary at
60 characters (then “…”), or “Note yyyy-MM-dd HH.mm” if nothing remains. Filenames
use the existing cleaning/collision rules (`Title.md`, `Title 2.md`). An ordinary
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
New notes show “Note created” with their title; session appends show “Note added”.
The journal retains the chosen path and original draft, so recovery reuses the
same file and clears the draft after saving, including when the title line was removed.

## Search index

The app links macOS's system SQLite and checks for FTS5 when the search index opens. macOS 14 ships SQLite 3.43 or
newer. The index uses no triggers, which avoids the FTS5-in-trigger issue in SQLite versions before 3.44.
