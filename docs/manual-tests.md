# CaptureKit manual checks

CaptureKit currently has no app wiring. Run these checks from a signed development
host that calls the public APIs from its Carbon hotkey handlers. Capture
`FrontmostContext.capture()` synchronously in each handler, before creating a
`Task`, and pass it to `SelectionReader.read(context:)` or
`RegionCapturer.capture(context:)`. Log results without opening a window or
activating the host. Use the same signing identity across rebuilds.

1. **Permissions:** With Accessibility access disabled, confirm selected-text
   capture returns `accessibilityNotTrusted`. Invoke
   `CapturePermissions.promptForAccessibility()` explicitly, grant access in
   Settings, and repeat. Confirm `openSettings(for:)` opens the appropriate
   Accessibility or Screen Recording privacy pane. Permission prompts and Settings
   navigation are explicit setup actions, outside the capture hotkey flow.
2. **AX selection:** In Safari, Notes, and TextEdit, select a distinctive sentence
   and press Option–Shift–C. Expect the selected sentence, method `accessibility`,
   and that app's name, bundle ID, PID, and focused window title. Seed the clipboard
   first and verify AX capture leaves it unchanged. Keep the app frontmost.
3. **Clipboard fallback:** In VS Code or Slack, disable that app's AX support if
   needed to force the fallback, select text, and press Option–Shift–C. Expect
   method `clipboard`. Repeat while holding Option and Shift for at least half a
   second: the target must receive ordinary Command–C. With no selection, an
   editor may copy the current line; this is accepted behavior.
4. **Clipboard preservation:** Copy X, select Y, capture Y, then paste into a
   scratch document. Expect X. Repeat with rich text and an image on the clipboard.
   Repeat while making a newer copy during capture: a newer clipboard change after
   the capture's copy is observed must not be overwritten by restoration.
5. **Secure input:** Focus a password field that enables macOS Secure Event Input
   (verify `IsSecureEventInputEnabled()` in the host), then invoke capture. Expect
   `secureInput`, no synthetic copy, and no clipboard change. Also test while the
   capture host itself is frontmost: expect `ownApp`.
6. **Region:** With Screen Recording permission disabled, press Option–Shift–S.
   Expect `permissionNeeded` without selection UI. Explicitly call
   `requestScreenCapture()`, grant access (restart the host if macOS requires it),
   and retry. Select a rectangle: expect valid PNG data and the original frontmost
   context. Repeat and press Escape: expect `cancelled`. Verify the temporary PNG
   and its temporary directory are removed after success and cancellation.
7. **Focus and lifecycle:** For both captures, leave a text cursor active in the
   original app. After capture or Escape, type: input must still reach that app.
   The capture host must never become active or show a Dock icon. Verify all five
   default shortcuts dispatch once to the correct handler. Unregister them and
   confirm dispatch stops. Leave the host idle and inspect Activity Monitor:
   CaptureKit has no polling, timers, event taps, or global NSEvent monitors.

Permission and focus behavior require this signed host; `CaptureChecks` needs no
privacy grants and uses a private named pasteboard, never the general pasteboard.

# Folder paths and external notes

Use a temporary vault and a disposable test folder under your home directory.

1. **Vault-relative path:** In a standalone quick note, use
   `science/math/trigonometry` as the title and save. Confirm the file is created
   at `<vault>/science/math/trigonometry.md`, with missing folders created, and
   the note appears in search. Edit the file outside Focusnotes and confirm its
   indexed content updates.
2. **Case-insensitive matching and append:** Create `Science/Algebra.md`, then
   save a quick note titled `science/algebra` with distinctive text. Confirm the
   original folder and filename are reused (no `science/` duplicate and no
   `Algebra 2.md`) and the new typed note is appended to `Algebra.md` without
   removing its existing content. Repeat with only the filename's case changed.
3. **Home-relative path:** Save a quick note titled
   `/Desktop/focusnotes-path-check/Geometry`. Confirm it lands at
   `~/Desktop/focusnotes-path-check/Geometry.md`, outside the vault, and appears
   in search. Edit it in another app and confirm the change is indexed. Restart
   Focusnotes and confirm it remains available. Put a separate Markdown file
   beside it without saving through Focusnotes; confirm it is not discovered or
   indexed, and editing it does not make its content searchable. Repeat with a
   disposable note directly under HOME (`/focusnotes-path-check-root`) and an
   unregistered Markdown file beside it; confirm only the registered note's
   edits become searchable. Save a second note in the same external folder, then
   edit the first and confirm its change is still indexed. Remove the test files
   when finished.
4. **Path safety:** Try a title with a `..` component, such as
   `science/../outside`, a leaf beginning `~$` (for example `folder/~$draft`),
   and vault destinations `assets/example` and `ASSETS/example`. Also try the
   leading-slash home-relative spelling of a path inside the vault's `assets/`
   directory. Try destinations crossing a symbolic-link directory or file.
   Confirm each save is rejected, no file outside the allowed destination is
   changed, and the draft remains available for correction. On a case-sensitive
   test volume, create a root-level `ASSETS/ignored.md` in the temporary vault;
   confirm it stays out of Browse and Search like the `assets/` tree. When
   checking watcher events, confirm changes there are classified as assets, not
   notes.
5. **Session namespace:** Start a session and save a typed note. Confirm it
   appends under `Sessions/<session title>.md`; it does not create a note at a
   title-derived folder or home-relative path. End the session and confirm a
   standalone quick note uses the path from its title.

# Quick note panel (⌥⇧N)

Run from the built app. Layout and behaviour are specified in `quick-note-ui.md`. For an isolated two-line
fixture without launching the real app, run this from the repo root:

```sh
GALLERY_SHORT_NOTE=1 .build-ui/out/Products/Debug/OverlayGallery --live editor
```

Close with esc after testing; the live fixture includes sample Browse rows.

1. **Rest and hover:** At rest the panel shows your text and a faded title line
   centred in the top band (the note's name, or "New note" when empty); no buttons
   or footer. Moving the pointer inside brightens the title and fades in the top band
   (close and open as note on the left; browse, new and trailing ellipsis Actions in one capsule on the
   right) and the footer. Typing alone never reveals them. Text does not move when
   they appear.
2. **Footer wording:** Outside a session it reads "Create note"; in a session, or
   after choosing a note in Browse, "Add to note". The footer never repeats the
   note's name; the title line shows it.
3. **Size:** Width grows with the longest line (400 to 600pt) and never shrinks
   while open. Height grows with the text up to 60% of the screen or 680pt, then
   scrolls. Type Tasks, Enter, - , a, Enter, - b: height must follow 1, 2, 2, 2, 3, 3
   body lines with the two-line minimum, never shrink when the marker becomes a bullet, and never
   leave an extra blank band below a trailing caret line. Repeat with - [ ] , 1. , quotes, bold,
   inline code and Tasks followed by two newlines. Delete back to Tasks: height returns to the
   two-line minimum. Body styles keep the same line height; headings may be taller.
   **Moving:** Drag the panel by its top band (the title counts) or by the footer, at rest
   or hovered; dragging the text selects text instead, and the buttons still click.
   Release, press esc, reopen with ⌥⇧N: it opens where you left it. Drag it to a second
   screen: it stays open. Reopen with the mouse on the other screen: it opens at the same relative spot there.
   Open a card, then drag by the band: the card closes and the panel moves. Grow the text
   near the bottom of the screen: the panel shifts up to stay fully visible.
4. **Actions (⌘K):** A card appears at the top right, under the buttons, with the
   note text still visible behind it. It lists New Note, Add to Pinned/Remove from Pinned | Open as Note, Copy as Markdown and Discard Draft (two groups), with one
   keycap box per shortcut key. Inapplicable rows are dimmed and skipped by the
   arrow keys. ⌘K or esc closes the card only; clicking outside it closes it too. Browse is only in the
   top-right capsule; ⌘P from the Actions filter still swaps to Browse.
   **Open-card button:** The Actions ellipsis keeps the circular pressed fill while Actions is open; Browse
   does the same while Browse is open. Try click and ⌘K/⌘P, swap both ways, and hover the on button: its fill
   must stay pressed. Check esc, click-away, resign-key, running a row and dismissing the note all clear the
   state. Accessibility reports only the open card's button as on/selected.
   **Overlay geometry:** Repeat with an empty/two-line note and a long scrolling note. Opening, closing,
   filtering and swapping cards must leave the note surface, corners, border, title, text and footer at exactly
   the same size and position. Short notes let the card hang below them over transparent space; only the
   window grows downward, instantly, and shrinks back on close. The shadow follows the two visible shapes.
   Drag the note near the screen bottom, then open each card: its bottom ends at least 8pt above the
   visibleFrame bottom and its list scrolls. Opening a card never shifts the note up. Transparent overflow
   and the card cannot drag the note; a transparent click passes through or closes the card. Add text
   while a card is open: note growth still works normally, with the card anchored under its band.
   Open, swap or close cards during a text resize: the note animation continues without jumping.
   **Pointer and mouse:** With another app still active, type in the note and each card filter, then move
   the mouse. The pointer must reappear on the first movement: arrow over bands/chrome/card rows, I-beam
   over note text/filter fields. A rendered task checkbox shows the pointing hand. Hover must select enabled rows just like ↑/↓; click runs Actions or Write
   here in Browse, including clicks on labels/icons. Disabled Actions do nothing and do not highlight.
   While another app is frontmost, click the filter once and type: that first click focuses it, it keeps
   focus and shows a coral caret. Check the first click on a row and in the scroll list as well. Any system input-source/Caps Lock
   badge must follow the drawn insertion point rather than the text view origin.
5. **Browse (⌘P):** A card opens at the top right (the editor is not replaced) with
   Pinned then Recent, filtered as you type; it scrolls past seven rows. Its 28pt bottom strip shows
   ↩ Write here, ⌘↩ Open and ⌥↩ Reveal with a separator above it. These hints stay visible even when
   the card covers the note footer or is capped near the screen bottom; the list scrolls above the strip.
   The note footer keeps its normal save, Actions and Close hints. ↩ writes there (card closes, the
   title line shows the note, next save appends to it), ⌘↩ opens the note in the
   default app, ⌥↩ reveals it in Finder, esc closes the card. Opening Actions closes
   Browse and the other way round. With a card open, a screen-change callback must preserve the
   note frame and card anchor when the note already fits, and recompute the card height cap for the
   new visible frame. `OverlayGallery --check` exercises this with two simulated visible frames on
   a single-monitor host; also check on multiple displays when available.
6. **Pinned notes (⇧⌘P):** Add to Pinned/Remove from Pinned changes Browse membership, not window
   stickiness. A pinned note shows a small pin before its title, centred with the text, sharing its
   rest/hover alpha. For an unsaved draft, type text, add it to Pinned, close with esc/✕/toggle, and
   reopen: the pin indicator remains. Save: the created note appears in Pinned and the draft intent
   is consumed. Discard or New Note resets the intent. An existing/session destination’s real pin
   state wins. Relaunch: saved note pins stay. The Markdown file is unchanged.
   **Save failures:** With pin intent set, fail a note write, reopen the kept draft, choose Remove from Pinned,
   repair the write failure and retry. The original filename is used once and the created note is unpinned.
   Repeat with a pinned failed save, repair the write failure and quit: shutdown retry pins the note before
   clearing its intent. Repeat through startup journal replay. Clearing the intent before either recovery path
   must leave the note unpinned; discarding or replacing a draft must not pin an older recovered job.
   A pin-storage failure after a successful note write ends with exactly one warning toast, **Note saved, but
   not pinned**, with the destination title below it; **Note created** must not replace it. The draft clears and
   the panel closes; recovery or a cleared-draft re-save must not create a second file. A pin failure during the
   retry at quit is only logged, since no toast can show while the app terminates.
   The isolated quick SelfTest exercises these filesystem failures, both recovery paths and the final toast
   dispatched by the production toast path, using temporary state.
7. **Open as note (⌘O):** With text, saves like ⌘↩ (session note when a session is
   active, otherwise a new note) and opens it in the default app. With no text it
   opens the session or chosen note; with neither, a "Nothing to open yet" toast.
8. **New (⌘N):** With text, saves then opens a blank note. With no text, the panel
   stays open and the chosen destination resets.

9. **Sticky focus:** Click another app after pinning and with each card open. The note stays visible
   at the same frame; the card closes and the caret stops. Hover still reveals the bands. The first
   text click places the caret and typing reaches the note, the first band-button click runs it, and
   the first band drag moves it, without activating focusnotes. While another app has focus, press
   ⌥⇧N: the same note regains key with draft, caret and scroll unchanged. Press it again while key:
   it closes, draft kept. Switch Spaces/full-screen apps: the note follows and stays at its current
   level/position. Change screen parameters: it re-clamps on-screen. Input/Search still dismiss on
   click-away and Space changes. Opening another focusnotes panel, save, esc/✕, Open as Note and
   app quit still close the note.

Last Updated: `ab5df2f`
