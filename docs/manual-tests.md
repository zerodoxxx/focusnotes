# CaptureKit manual checks

Last Updated: 2026-10-26 (previous commit: `3878ada`)

The macOS app wires CaptureKit into its Carbon hotkey handlers. Run these checks
from a signed development build. The handlers capture
`FrontmostContext.capture()` synchronously, before creating a `Task`, then pass
it to `SelectionReader.read(context:)` or `RegionCapturer.capture(context:)`.
Use the same signing identity across rebuilds.

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
7. **Browser URL:** In Safari, Chrome, and Edge, load a nonsensitive HTTP(S)
   page and leave focus in the page (not the address field). Use English UI in
   Chrome and Edge; in Chrome, enable **Always show full URLs** from the
   address-bar context menu. When the browser exposes its complete address, each
   selection and area capture should have a separate `[Source](<...>)` link before
   its content. When the value is incomplete or unavailable, the capture should
   still save without the link. Capture from Firefox, Notes, or a `file:`/`about:`
   page has no Source link. Repeat with the address field focused and confirm no
   link is added while capture still succeeds.
8. **Focus and lifecycle:** For both captures, leave a text cursor active in the
   original app. After capture or Escape, type: input must still reach that app.
   The capture host must never become active or show a Dock icon. Verify all five
   default shortcuts dispatch once to the correct handler. Unregister them and
   confirm dispatch stops. Leave the host idle and inspect Activity Monitor:
   CaptureKit has no polling, timers, event taps, or global NSEvent monitors.

9. **Session changes during acquisition (macOS):** Force a clipboard fallback,
   capture distinctive text in a session, then immediately end the session. Confirm
   the captured text is saved once in that session. Repeat without a session and
   immediately start one: the earlier capture must stay in Inbox. Repeat with an
   area capture while session control is requested before acquisition completes.

Permission and focus behavior require this signed host; `CaptureChecks` needs no
privacy grants and uses a private named pasteboard, never the general pasteboard.

# Choosing the notes folder

Use disposable folders with distinguishable Markdown notes; keep a copy of the current folder setting.
Run these checks on macOS and Windows, using the menu-bar icon or tray icon respectively.

1. **Native picker:** Choose **Choose Notes Folder…**, select a writable folder with an existing note, and confirm
   the app explains that the choice applies after restarting. Before restarting, captures still use the current
   folder. After restarting, Open Notes Folder opens the selected folder, its existing note appears in search,
   and a new capture is written there. Notes in the previous folder remain intact.
2. **Cancellation:** Reopen the picker and cancel it. Restart and confirm the previously saved folder is still used.
3. **Unwritable folder:** Select a folder the app cannot write to. Confirm an error appears and the saved choice
   remains unchanged. Repeat with a folder that becomes unavailable between selection and saving.
4. **Unavailable at startup:** Save a disposable notes folder, quit the app, then make that folder inaccessible before
   relaunching. Confirm the app offers a native folder picker to select a replacement before starting captures.
   Cancel or quit once, then relaunch and choose another writable folder. Confirm the original notes and
   app state remain intact; restoring access and selecting the original folder restores its state.
5. **First launch:** With a disposable fresh app profile, confirm onboarding offers the same native folder picker.
   On macOS, keep the default once, then repeat with **Choose Notes Folder…** and confirm the custom folder is
   used immediately. On Windows, choose a custom folder from **Setup…**, restart when indicated and confirm it is
   used. Also repeat the selection through **Settings… → General → Notes folder**.
6. **State isolation:** Leave an active session, a draft and a pinned note in the original folder, then choose another
   folder and restart. Confirm the session, draft and pin do not appear in the other folder. Switch back and restart:
   the original state is restored. Repeat with a journaled pending save; it is retried only in its original folder.
   Confirm settings and installed semantic models remain available across both folders.
7. Restore the original folder setting and restart. Confirm the test did not move or delete notes from either folder.

# Folder shortcuts on macOS and Windows

Use a disposable notes folder. On macOS choose **Folder Shortcuts…** from the menu-bar icon. On Windows use
**Settings… → Folder Shortcuts** or the **Shortcuts** step in Setup. Repeat the cases on both platforms.

1. **Recorder and cancellation:** Add a Quick Note shortcut for `Projects/Research`, record an unused combination
   with Command, Option, or Control on macOS, or Ctrl or Alt on Windows, and save. Confirm its displayed combination and action. Start editing the
   combination, press a different one, then cancel (or **Revert Changes** on Windows); the original combination must still work and the cancelled
   one must not dispatch. Cancel a new shortcut too and confirm it does not appear after relaunch.
2. **Validation and cap:** Try an existing folder shortcut combination, a built-in combination, a plain letter,
   Shift alone with a letter, Escape, and a modifier key. Confirm useful validation and no saved change. Try
   empty, absolute, home, traversal, hidden, and malformed folder paths. Add 20 valid mappings and confirm a
   twenty-first cannot be saved. Remove one, add another, and confirm the removed combination no longer acts.
3. **Other-app conflicts:** Reserve a test combination in another app, then attempt to save it here. Confirm the
   conflict is visible and does not replace a working binding. Release the combination in the other app and retry;
   it should register once. Relaunch with the other app holding a previously saved combination and confirm the
   unavailable shortcut is reported; remove the conflict and retry registration.
4. **Folder quick note and active session:** Start an ordinary session, invoke the folder Quick Note shortcut,
   type a fresh title and body, and save. Confirm the note lands in `Projects/Research/`, the active session note
   is untouched, and the session remains active. Repeat with Browse selecting a note elsewhere; that explicit
   destination must win. A subsequent normal capture should still use the active session.
5. **Durable draft:** Invoke the folder shortcut, type text, toggle pin-on-save, and close with Escape. Relaunch
   and restore the draft; its folder and pin intent must survive and save to the configured folder. Repeat after
   rapid typing and immediate dismissal. Save or discard the draft, open an ordinary quick note, and confirm it
   does not inherit the earlier folder context.
6. **Session action:** Add a Start Session shortcut for `Meetings`. Invoke it while another session is active
   and confirm a name prompt appears without changing that session. Escape and blank/whitespace submissions
   must create no note and leave the active session unchanged. Enter `Standup` and confirm creation of
   `Sessions/Meetings/Standup.md`, with later captures routed there. Invoke again and enter the same name;
   confirm it resumes the existing note and preserves its content. Create a `Standup` in a different folder
   and confirm it is neither suggested nor resumed by this shortcut. Try a path such as `../Standup` and
   confirm rejection without changing the active session. Repeat blank/cancel checks through the ordinary
   Start Session command with no active session; no default or timestamp-named session may be created.
7. **Missing and renamed folders:** Remove an empty configured destination and invoke its shortcut; saving must
   recreate it. Rename a configured folder outside the app and invoke its shortcut again; it should use the saved
   path, recreating it, while the renamed folder and its notes remain intact. Try an unwritable destination and
   confirm the error retains the draft for retry.
8. **Per-folder settings and persistence:** Relaunch and confirm mappings and actions persist. Switch to a
   different selected notes folder, restart, and confirm the first folder's mappings do not dispatch there. Switch
   back and confirm they return. Remove a mapping, relaunch, and confirm its combination remains unregistered.

9. **Windows built-in customization:** Disable a built-in shortcut, assign its combination to a folder shortcut,
   then try enabling the built-in again or resetting defaults. Confirm the duplicate is rejected without losing
   either saved setting. Verify AltGr-sensitive combinations are rejected on an affected keyboard layout.
10. **Menu fallback:** While a saved combination is unavailable, invoke the folder action from the menu and confirm
    it still uses its configured destination. Remove the external conflict and retry registration.

# Folder paths and external notes

Use a temporary vault and a disposable test folder under your home directory.

1. **Vault-relative path:** In a standalone quick note, use
   `science/math/trigonometry` as the title and save. Confirm the file is created
   at `<vault>/science/math/trigonometry.md`, with missing folders created, and
   the note appears in search. Edit the file outside Focusnotes and confirm its
   indexed content updates.
   Also confirm a valid unprefixed prose/date name such as `pros/cons of X` or
   `10/18 standup` is interpreted as a folder path. Relative URL-shaped names,
   `TODO/`, `a//b`, and a relative slash with whitespace beside it should instead
   save as flat filenames using the legacy cleanup. Verify malformed leading-slash
   HOME paths still show a path validation error.
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
   Create `Sessions/Standup.md` and `Sessions/archive/Standup.md`, start `Standup`,
   and confirm the chooser lists both titles, paths, and modification dates in
   newest-first order. Up/Down plus Return resumes the selected full path;
   Escape leaves the session state and both notes untouched. A unique nested
   bare-name match resumes its exact path, while `archive/Standup` resolves
   directly without a chooser. A missing qualified name creates a nested session.
   **Rename from the chooser:** Highlight the archived session and press ⌘↩
   (Ctrl+Enter on Windows). Confirm its current title is selected for editing.
   Escape returns to the chooser without changing either file. Open rename again,
   enter `Daily sync`, and confirm: only the archived file becomes
   `Sessions/archive/Daily sync.md`, its `# ` heading changes, and the session
   resumes there. Subsequent captures append to the renamed note. Check that
   existing image links still resolve, a pin follows the renamed note, pending
   journaled captures recover there, and Search drops the old path and finds the
   new title. Try a separator-containing name and an existing filename with
   different casing: both must show an error and leave the original intact.
   Try renaming `Standup` to `standup`: expect “Choose a name that changes more
   than letter casing.” On Windows, an occupied name should say “A session with
   that name already exists. Choose a different name.” Invalid names should say
   “Enter a valid session name without folder separators.” Confirm the retry
   field retains and selects the attempted name and neither note changes.
   **Windows rename recovery (disposable state/vault only):** Pin the session,
   back up `pinned-notes.json`, replace it with a directory of the same name,
   then rename the session to `Daily sync`. Confirm the file moves and the warning
   reads “Session rename pending · Daily sync” / “State updates will retry before
   the next save.” Restore
   the pin file, capture again, and confirm the capture and pin follow the new
   path and `session-rename.json` is cleared. Repeat with a restart before the
   capture and confirm recovery completes once. For an interrupted rename that
   leaves `session-rename.json` and the source at its old path, edit that source
   before restarting: the intent must be abandoned, the edited bytes preserved,
   and startup and later captures must work. If the interrupted move already
   reached the new path, edit that same file before restarting: recovery must
   adopt it, preserve the edits, and complete state migration. A missing or
   unrelated target must also abandon the stale intent without overwriting a
   note. The reproducible interruption fixtures are in
   `windows/tests/CaptureApp.AppCore.Tests/SessionRenameTests.cs`; ordinary
   pre-move failures now clear their intent immediately.
6. **Registry preservation and recovery:** With a disposable state directory,
   register two external notes, then replace `external-notes.json` with malformed
   bytes, version 2, or a symlink. Confirm Focusnotes warns that the registry was
   preserved, external notes disappear from search, vault notes remain searchable,
   and an attempted external save is refused with a specific warning. Compare the
   malformed/versioned file bytes before/after; for the symlink case, confirm the
   symlink identity and target are unchanged. Restore a valid registry (or remove
   the unsafe registry to restore a valid empty state), then confirm the warning
   clears, external indexing and watching recover, and an external save succeeds.
   Atomically replace a registered note in its parent folder, create an unregistered
   Markdown sibling there, and churn an unrelated HOME subtree. Confirm the
   registered replacement is reindexed, while neither the sibling nor unrelated
   HOME files are indexed or reported as note changes.

# Capture destination recovery (macOS)

Use a disposable vault and distinctive text for each capture.

1. Create `Standup.md` and `Archive/Old.md` with the same `# Standup` heading.
   Capture to `Standup` and confirm only the root note changes. Register a HOME
   note with that heading and repeat; it must not intercept the bare title.
2. Give two root notes the same heading. Capture to that title and confirm a
   chooser lists both exact paths. Select the second row and confirm only that
   file changes, once. Repeat with duplicate session headings and no matching
   root heading. Escape from either chooser must keep the capture pending;
   press its capture shortcut again and choose a valid destination.
3. Choose `../escape` as a capture destination. Confirm the warning offers
   another choice and neither Inbox nor the active session receives the capture.
   Let the warning expire, then press the same capture shortcut, choose a valid
   note, and confirm the original capture is saved exactly once.
4. Try `pros / cons`, `TODO/`, and `a//b` through the capture title picker, typed
   notes outside a session, and session start. Confirm the same flat filename
   cleanup applies, with session files kept under `Sessions/`. A true nested
   name such as `science/math` still uses folders. Traversal remains rejected.
5. Run `CoreChecks --skip-performance` to exercise a forced partial typed-note
   append: the original file must survive the failed write, then retry must
   save the complete body once. Existing checks also verify that replay preserves
   an externally edited body after a successful save.

# One-off notes and captures outside a session

Use a disposable vault. On Windows, use Ctrl in place of ⌘ for editor actions and
Ctrl+Shift+Q / Ctrl+Shift+G for the outside-session selection / area captures and
Ctrl+Shift+W for the outside-session quick note.

1. Start `Thermo`, open a quick note, and choose **Write outside session** in Actions
   or press ⇧⌘N. Enter `Biology` and distinctive body text, then save. Confirm
   `Biology.md` is created, the Thermo note is unchanged, the toast names Biology
   and says Thermo is still active, and the next normal capture and quick note
   append to Thermo. Repeat with existing `Biology.md`, `science/Biology`, `Inbox`,
   and a disposable `/Desktop/focusnotes-path-check/Biology` home path; existing
   targets append and missing folders are created.
2. With the detached editor open, toggle ⇧⌘N again: the title and destination
   return to Thermo without clearing the text. Repeat using ⌘N on a blank editor.
   Close a detached draft and reopen: text remains, but the destination is Thermo.
   End the session: the outside-session action is hidden or disabled.
   With Thermo active, press ⌃⇧N (or choose **Quick-note Outside Session**): the panel opens with
   Write outside session on. Save `Biology` text and confirm Thermo is unchanged. Reopen with ⌃⇧N,
   press ⇧⌘N, save, and confirm it appends to Thermo with a “Saved to Thermo” toast. ⌘N on a blank
   ⌃⇧N editor stays outside. Without a session, ⌃⇧N behaves like ⌥⇧N.
3. In a detached note, choose an existing target using Browse and confirm the
   save appends there. Try Save as New Note with an existing typed path: a
   numbered sibling is created. Set pin-on-save on an unsaved detached draft and
   confirm the saved target, rather than Thermo, appears in Pinned.
4. With Thermo active, select text in another app and press ⌃⇧C. Confirm the
   note picker opens immediately. Choose `Biology`; confirm only that note changes.
   Repeat with ⌃⇧S and a screen region; confirm the image, OCR text, and relative
   asset link work in the chosen note. Repeat both captures and press Escape in
   the note picker: each saves to Inbox, leaves Thermo unchanged, and keeps the
   session active. Repeat without a session. A normal capture's toast re-press
   must still open its existing destination picker.
   Repeat with a session named `Inbox` and with a separate `science/Inbox.md` note:
   Escape must always save to the vault's root `Inbox.md`, leaving those notes unchanged.
5. Occupy either new capture chord with another app or a test host before
   registration. Confirm the existing unavailable-shortcuts warning appears,
   then use **Capture Selection Outside Session…** and **Capture Area Outside Session…**
   from the menu bar or Windows tray menu. Both must still open the destination picker.
   Release the chord and use Retry Shortcuts. Both new shortcuts should work.
   On Windows, rebind both under Settings → Shortcuts and confirm the displayed
   combinations and menu labels follow the saved bindings. Turn the shortcuts off
   and repeat both tray commands; selection must still capture the original application's text.
6. **Windows upgrade:** In a disposable profile from the previous version, bind Search to
   Ctrl+Shift+Q and Session to Ctrl+Shift+G. Upgrade and confirm both actions keep those
   bindings; the new captures get distinct alternatives shown in Settings and the tray menu.
   Repeat with Quick Note bound to Ctrl+Shift+N and another customized shortcut. Confirm
   only the now-reserved combination gets a replacement, Settings explains it, and changing
   either shortcut works without resetting the others. Restart after saving and confirm
   the chosen bindings and unrelated settings remain intact.

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
2. **Footer wording:** Outside a session it reads "Create note" unless the typed
   name resolves to an existing or reserved note; then it reads "Add to note".
   In a session, or after choosing a note in Browse, it reads "Add to note". The footer never repeats the
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
   note text still visible behind it. It lists New Note, Save as New Note,
   Add to Pinned/Remove from Pinned | Open as Note, Copy as Markdown and Discard Draft (two groups), with one
   keycap box per shortcut key. Inapplicable rows are dimmed and skipped by the
   arrow keys. ⌘K or esc closes the card only; clicking outside it closes it too. Browse is only in the
   top-right capsule; ⌘P from the Actions filter still swaps to Browse.
   **Save as New Note:** With no session or Browse destination, type an existing
   exact note path and confirm the row is enabled. ⌥⌘↩ (Ctrl+Alt+Enter on Windows)
   creates a numbered sibling in that folder and leaves the original intact.
   Repeat with Windows backslashes and a HOME-relative external note. For a new
   name or an explicit destination the row is disabled; the shortcut uses the default save.
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

# Windows release device checks

The published Windows edition includes x64 and arm64 installers. These device checks provide release-grade validation
that automated Windows runners cannot cover. Run them for Windows 11 arm64, Windows 11 x64, and Windows 10 22H2 x64.
Automated tests tagged
`Needs=InteractiveDesktop` (set `CAPTUREAPP_RUN_INTERACTIVE_TESTS=1`, then `dotnet test --filter "Needs=InteractiveDesktop"`) are part of 11a and 11b. Record the
target, build and result for each item.

## 11a Interactive desktop (Windows 11 arm64 VM)

1. **Focus (click-away, return, no lost keys):** In each of Notepad, Word, Chrome, Edge, Firefox, VS Code, Windows
   Terminal, Teams and File Explorer, put the caret in a text field and press the Quick-note shortcut. Type 20
   characters at once: all 20 reach the note. Press Esc, then Ctrl+Enter, then ✕ in turn: after each, the original
   window is foreground with its caret where it was. Reopen, click another window: focus stays there, the note stays
   visible, and an open Actions/Browse card closes. Do the same with Search and Input: they dismiss on click-away and on a
   virtual-desktop switch. Minimize or close the original window before an explicit close: focusnotes must not
   change the foreground window. Click a panel button while the panel is inactive: it runs on the first click and the
   foreground window does not change. Toasts never take focus, ignore clicks, and never appear in the taskbar or Alt+Tab.
2. **Selection capture per app:** Select a distinctive sentence in each app above, plus Word, Excel (a cell range) and a
   PDF viewer, and press Capture Selection with the clipboard fallback both off and on. Expect the sentence and the
   app name as the source (UI Automation first, the fallback only where the app does not share its selection). With
   the fallback off in an app that needs it, expect "No text selected" with the hint to turn it on. Seed the clipboard
   with text, an image and rich text first: each must be intact afterwards. In an app that needs clipboard fallback,
   hold the capture shortcut's modifiers for half a second, then release: capture must complete from that single
   press, with no copy before release. Hold them for more than two seconds: expect "Release the shortcut keys and
   try again" and no injected copy. Switch to another app during the wait: capture must cancel without copying
   from either app. Focus a password field: expect
   "Can't capture from secure fields". Put an image over 64 MB on the clipboard in an app that needs the fallback:
   expect "Couldn't capture selection" and an untouched clipboard.
3. **Administrator apps:** Run Notepad as administrator, select text, press Capture Selection: expect "Can't capture
   from apps running as administrator" with the Capture Area hint. Capture Area over that window still saves an image
   and its OCR text.
4. **Area capture and DPI:** With two monitors at 100%, 150% and 200% scale (mixed), drag an area on each and across
   both. The PNG matches the dragged region, OCR finds the text, and Esc cancels without a file. Change a monitor's
   scale while a panel is open: it re-lays out on the correct monitor.
5. **Tray:** Restart Explorer (`taskkill /f /im explorer.exe`, then start it): the icon returns. On Windows 11, confirm
   where a new icon first appears and that Setup explains how to show it. Check light and dark taskbar themes and the
   attention variant.
6. **Hotkey conflicts:** With PowerToys, Teams, VS Code, Chrome, Firefox, Zoom and Discord installed and running,
   press each Alt+Shift default shortcut with each app focused. The app's action runs and the other app does not also react.
   Repeat with multiple Windows input languages enabled. Record any app that shadows a default; rebinding must fix it.
7. **AltGr layouts:** Add the Polish (Programmers) and German keyboard layouts. In Settings → Shortcuts, try a
   Ctrl+Alt+Shift+letter combination that types a character on that layout: it is refused with a suggested free letter.
8. **IME:** With a Japanese IME, compose text in the quick note and press Return during composition: it confirms the
   composition and does not save or insert a newline.
9. **Panels and accessibility:** Turn Windows animations off: panels and toasts appear without motion. With Narrator on,
   the editor ("Note text"), chrome buttons and Actions/Browse rows are announced with labels.
10. **Emulation:** Run the x64 build on Windows 11 arm64: Setup offers the native build.
11. **Browser URL:** In Chrome and Edge with English browser UI, load a nonsensitive
    HTTP(S) page and leave focus in the page. Enable Chrome's **Always show full URLs**
    option from the address-bar context menu. When UI Automation exposes the
    complete address, selection and area captures should each include a separate
    `[Source](<...>)` link before content. If the value is incomplete or unavailable,
    capture should still save without the link. In an unsupported app (including
    Firefox), with a localized control name, while the address field is focused,
    or on a `file:`/`about:` page, capture should also save without the Source link.

## 11b Native x64 (Windows 11 and Windows 10 22H2)

1. Repeat 11a items 1 to 3, 6, and 11 on both systems.
2. Install the x64 `Setup.exe` without administrator rights, then update from vN to vN+1. The app relaunches, the tray
   icon returns, shortcuts re-register, Setup does not reappear, and `Get-Process`/PE inspection shows the x64 build
   stays AMD64.
3. Run the arm64 installer on x64: it is refused.

## 11c Release package signing and Smart App Control

1. Run the signing inventory on the released artifacts and confirm every file is classified. Unsigned releases should
   record the FocusNotes binaries as unsigned; when Authenticode is configured, the enforced inventory must pass.
2. On Windows 11 x64 and arm64 with Smart App Control in enforcement mode, then in evaluation mode, record whether
   Windows allows or blocks the unsigned installer and app. A block is an expected limitation when Windows cannot
   confirm an unsigned file is safe; do not disable Smart App Control or try to bypass it. If installation is allowed,
   exercise every feature including OCR and semantic search, apply an update, relaunch and uninstall. Review Event
   Viewer → Microsoft → Windows → CodeIntegrity → Operational for events 3076 and 3077 and record the result.
3. Check SmartScreen behavior for the unsigned installer. It may warn that the publisher is unknown; verify the file
   came from the official release before deciding whether to run it. When Authenticode is configured, confirm the
   publisher shown matches the configured signer.

## 11d Hardware-only

1. **Unplug test:** On a Windows laptop with image-bearing notes and the semantic models installed, start a re-index on
   AC power, then unplug it and enable battery saver: image and OCR embedding stop and resume only after AC power returns
   and battery saver is off. Keyword search keeps working throughout.
2. **Hard reset during update (VM):** Reset the VM while an update applies. The next launch runs a working version,
   `--self-test` passes, the vault and state directory are intact, and re-running `Setup.exe` repairs the install if
   it does not launch.

## 11e Fresh-profile Setup walkthrough

On a new Windows user profile on each target:

1. First launch opens Setup. Before the first page is answered, no shortcut works and the tray menu shows only
   **Finish Setup…** and **Quit**.
2. Answer both questions, then pass the notes folder with a Controlled Folder Access block (Windows Security → Virus
   & threat protection → Ransomware protection) and with an online-only OneDrive folder; the explanations name the cause
   and the fix, and captures journal in the meantime.
3. Close Setup midway, relaunch: it reopens at the first incomplete required step, once per launch.
4. Skip each recommended step: it shows "Not tested" and no badge. Fail each required step (occupy a hotkey, make the
   folder read-only, delete the start-at-login entry): the badge, **Finish Setup… (n left)** and the "Setup needs
   attention" toast appear on the next launch.

## 11f Release candidate

Build the candidate from one tagged commit and run every section above plus the Mac-equivalent sections of this file
(the capture, folder-path, external-note and quick-note sections apply on Windows with Ctrl for ⌘ and `\` or `/`
separators). Any code change needs a new candidate and a full rerun. Compare vault bytes with the Mac for the same
captures.

## 11g Sign-offs

The maintainer reviews and signs off deviations DV1-DV11 (see [DESIGN.md](../DESIGN.md#deviations-from-the-mac)), any OCR
language not covered, any exception to the focus, OCR and resource gates, and the candidate itself.
