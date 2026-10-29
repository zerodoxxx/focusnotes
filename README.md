# focusnotes

**Take notes without breaking focus.**

focusnotes is a small native app for capturing what you're reading or thinking without leaving the app you're in.
The macOS edition runs from the menu bar; select text and press a shortcut, drag over part of the screen, or jot a
quick note in a floating panel. Everything lands in plain Markdown files you own.

> **Platforms.** FocusNotes supports macOS and Windows. Windows x64 and arm64 installers and portable archives are
> available from [Releases](https://github.com/zerodoxxx/focusnotes/releases); see [Windows support](#windows-support)
> for installation steps and platform details. The feature overview and shortcut table use macOS defaults; Windows
> behavior, shortcuts, and installation are covered in Windows support.

## Features

- **Capture selection.** Saves the selected text from any app, along with where it came from.
- **Capture area.** Drag over part of the screen. Text in the area is recognised (OCR): a region of dense text is
  saved as plain text, and anything else is saved as an image whose recognised text becomes searchable.
- **Browser links.** Selection and area captures from supported browsers include a separate Markdown `Source` link
  to the current page when its complete HTTP(S) address is exposed by the browser's native accessibility interface.
  FocusNotes reads the address bar only; it does not inspect page contents or selected text to find a URL. If the
  field is being edited or does not expose a complete address, the capture still saves without a link. Supported
  browsers are Safari, Chrome, and Edge on
  macOS, and Chrome and Edge on Windows. Chrome and Edge must expose their English “Address and search bar” control;
  Firefox is not supported. In Chrome, right-click the address bar and choose **Always show full URLs** to expose the
  complete URL when needed ([Chromium's explanation](https://blog.chromium.org/2020/08/helping-people-spot-spoofs-url.html)).
- **Quick note.** A floating Markdown panel with a live preview. It stays on screen while you work and saves with ⌘↩.
  Include folder segments in the title to save a note in a subfolder.
- **Sessions.** Start a session for a topic (a course, a paper, a design review) and every capture goes to that
  topic's note until you end it. A unique existing name resumes its note; duplicate matches open a chooser,
  where ⌘↩ (Ctrl+Enter on Windows) renames and resumes the selected session. A slash-qualified name picks a
  path under `Sessions/`. Add subheadings to start new sections. Use **Write outside session** in a quick note,
  or an outside-session capture shortcut, to save a one-off note elsewhere while the session stays active.
- **Search.** Keyword search across all notes, plus optional on-device semantic search.
- **No focus stealing.** focusnotes never activates itself; every action has a global shortcut and a toast confirms
  the save.
- **Plain Markdown, on-device.** Notes are ordinary `.md` files that work with Obsidian or any editor. Note content,
  captures and search queries never leave your Mac.

## Shortcuts

| Shortcut | Action |
| --- | --- |
| <kbd>⌥⇧C</kbd> | Capture selected text |
| <kbd>⌥⇧S</kbd> | Capture an area of the screen |
| <kbd>⌃⇧C</kbd> | Capture selected text outside the session; choose a note |
| <kbd>⌃⇧S</kbd> | Capture an area outside the session; choose a note |
| <kbd>⌥⇧N</kbd> | Write a quick note (appends to the active session) |
| <kbd>⌃⇧N</kbd> | Write a quick note outside the session |
| <kbd>⌥⇧F</kbd> | Search notes |
| <kbd>⌥⇧A</kbd> | Start or end a session |
| <kbd>⌥⇧H</kbd> | Add a subheading |
| <kbd>⌥⇧L</kbd> | Open the notes folder |

In the quick note: <kbd>⌘↩</kbd> saves, <kbd>⌘K</kbd> opens actions, <kbd>⌘P</kbd> browses notes, and <kbd>esc</kbd>
closes it and keeps your draft. While a session is active, <kbd>⇧⌘N</kbd> toggles **Write outside session**:
the first nonblank line names a new or existing note, including folder and `/` home paths. Browse and
Save as New Note still work. Press it again, or <kbd>⌘N</kbd> on a blank editor, to return to the session.
<kbd>⌃⇧N</kbd> (**Quick-note Outside Session** in the menu) opens the quick note with **Write outside session**
already on; <kbd>⇧⌘N</kbd> still switches it back to the session, and <kbd>⌘N</kbd> on a blank editor keeps it outside.
Saving or closing resets that destination; the next quick note or normal capture uses the session again.

Outside-session capture shortcuts open **Add to note…** immediately, even without a session; <kbd>esc</kbd>
saves to Inbox. For a normal capture, pressing the same shortcut again while its save toast is visible
also opens the note picker. The active session stays running in both cases.

Add up to 20 global shortcuts for specific folders. On macOS, choose **Folder Shortcuts…** from the menu-bar icon.
On Windows, use **Settings… → Folder Shortcuts**, the **Shortcuts** step in Setup, or **Folder Shortcuts → Configure Folder Shortcuts…** in the tray menu.
Record a combination and choose **Quick Note** or **Start Session**. Built-in and duplicate combinations
are rejected; combinations already registered by another app show a conflict. Saved bindings can also be run
from the menu (**Use Folder Shortcut** on macOS, the **Folder Shortcuts** submenu on Windows) when their
combination is unavailable. Quick Note folders are
relative to the selected notes folder. Start Session folders are relative to `Sessions/`; each invocation
asks for a session name, then creates or resumes that session in the configured folder. Suggestions only
include sessions in that folder. A name is required; cancelling or submitting a blank name leaves the
current session unchanged.

A folder quick note saves in its configured folder even while another session is active. An explicit
Browse destination takes precedence over the folder, and the folder takes precedence over the active
session. The blank editor is titled with its folder; the typed name then picks a note inside that folder,
so the footer shows **Add to note** for an existing note there and **Save as New Note** makes a numbered
copy in the folder. Closing the editor keeps its folder with the draft, including across relaunches.
Missing folders are recreated when saving. Shortcuts bind to paths: renaming a folder outside the app
does not update its shortcut. Folder shortcut settings belong to each selected notes folder.

## Install

Requires macOS 14 Sonoma or later on Apple silicon.

1. **Download.** Get the DMG and `SHA256SUMS.txt` from [Releases](https://github.com/zerodoxxx/focusnotes/releases),
   then verify the download. It should report `OK`; if not, don't open it.

   ```bash
   shasum -a 256 -c SHA256SUMS.txt
   ```

2. **Install.** Open the DMG and drag focusnotes to Applications.

3. **First launch.** focusnotes is self-signed and not notarized (the project has no paid Apple developer account),
   so macOS blocks the first open. Click **Done**, then go to **System Settings → Privacy & Security**, click
   **Open Anyway** next to the focusnotes message, and confirm. On macOS 15 and later, Control-click → Open no longer
   bypasses this. Release builds made by CI also carry a GitHub build attestation.

4. **Permissions.** focusnotes walks you through granting these. Every release is signed with the same certificate,
   so grants survive updates.

   | Permission | Needed for |
   | --- | --- |
   | Accessibility | Reading the selected text in other apps |
   | Screen Recording | Capturing an area of the screen (may need a relaunch) |

   The current status of each is under the menu-bar icon → **Permissions**.

**Updates:** choose **Check for Updates…** from the menu, or turn on automatic checks (at most once a day). Updates
come from GitHub and are verified with an EdDSA signature before installing.

## Where your notes live

Notes are saved in `~/Documents/focusnotes`:

```text
focusnotes/
├── Inbox.md              # captures made outside a session
├── Sessions/
│   └── System Design.md  # one note per session
├── <Quick note name>.md  # quick notes, optionally in nested folders
└── assets/               # area captures (images)
```

Quick-note titles can include folder paths. `science/math/trigonometry` saves as
`science/math/trigonometry.md` under the notes folder, creating missing folders.
Prefix the path with `/` to resolve it from your home folder: `/Desktop/science/math/trigonometry`
saves to `~/Desktop/science/math/trigonometry.md`. If the target note already exists,
Focusnotes appends to it. Folder and filename matching ignores case. External note paths
used this way are tracked for search and file updates; Focusnotes does not scan your home folder.
Names resolve to their exact path: `foo` means the vault-root `foo.md`, even when
`archive/foo.md` exists. To create a separate numbered note in the same folder, choose
**Save as New Note** in Actions (⌥⌘↩ on macOS, Ctrl+Alt+Enter on Windows). The editor
shows **Add to note** when the default save will append. Browse destinations take precedence over
the typed name; the active session does too unless **Write outside session** is selected.
Paths into the reserved `assets/` folder and note names whose final component starts with `~$` are
rejected.

An unprefixed valid slash-separated name always means a folder path, so names such as
`10/18 standup` resolve as paths too. For relative names, URL-shaped input and malformed
slash forms with a trailing/repeated separator or whitespace next to a slash fall back to a
flat filename. Leading-slash HOME paths keep strict validation.
If the external-note registry is damaged, unsupported, or unsafe, it is preserved and external
notes are paused with a warning. Registry-dependent note listing, indexing, and capture routing
pause until recovery; local Markdown files remain intact.

Session names use the same slash convention inside `Sessions/`: a valid name such as
`archive/Standup` creates or resumes a nested session note. Relative malformed slash forms, such
as `pros / cons` or `TODO/`, use the cleaned flat session-name matching flow instead.

Timestamps and source app/window details are stored in HTML comments. Browser captures also add a separate `Source` link:

```markdown
# System Design

### Designing Data-Intensive Applications
<!-- capture:… at=2026-10-14T13:04:58+05:30 app="Safari" -->

[Source](<https://example.com/design>)

Replication lag is the delay between a write on the leader and its visibility on followers.
```

To use another folder, such as an Obsidian vault, choose **Choose Notes Folder…** from the
menu-bar icon and select it in the system folder picker. The folder must be writable.
Restart the app to use a change made from the menu. First launch offers the default notes
folder or **Choose Notes Folder…**; a folder selected there is used immediately. Existing
notes stay in their original folder and are not moved.

App state (drafts, search index, pending saves, models) lives in
`~/Library/Application Support/com.zerodoxxx.focusnotes`.
Each notes folder keeps its own sessions, drafts, pending saves, pins, folder shortcuts and search index;
returning to a previous folder restores that folder's state. Settings and downloaded models
are shared across folders.

## Semantic search on macOS

Keyword search works out of the box. For meaning-based search, choose **Enable Semantic Search…** from the menu to
download the on-device models (about 492 MB, Apple silicon only): EmbeddingGemma (Apache-2.0) from huggingface.co and
ONNX Runtime (MIT) from github.com. Each file is checked against a pinned SHA-256 hash, downloads resume if
interrupted, and **Semantic Search → Remove Models…** deletes them. See [docs/semantic-search.md](docs/semantic-search.md).

## Privacy

Note content, captures and search queries are processed on your device and sent nowhere. The app uses the network only
to download the optional semantic models and to check for and download updates.

## Uninstall

Quit focusnotes and delete it from Applications. Optionally remove its app state and permissions:

```bash
rm -rf "$HOME/Library/Application Support/com.zerodoxxx.focusnotes"
tccutil reset Accessibility com.zerodoxxx.focusnotes
tccutil reset ScreenCapture com.zerodoxxx.focusnotes
```

Your notes stay in your notes folder.

## Windows support

A native Windows edition (C# on .NET 10 with WPF) lives in [`windows/`](windows/). It implements the FocusNotes
features on Windows 10 22H2 and Windows 11, for x64 and arm64. Current
[releases](https://github.com/zerodoxxx/focusnotes/releases) include a `Setup.exe` installer and a portable ZIP for
each architecture. Authenticode signing is optional; unsigned installers may trigger Windows security warnings or
be blocked by Smart App Control. Use the [Windows build instructions](CONTRIBUTING.md#windows) to build from source.

### Install on Windows

From [Releases](https://github.com/zerodoxxx/focusnotes/releases), download `focusnotes-win-x64-Setup.exe` for x64
(Intel/AMD) or `focusnotes-win-arm64-Setup.exe` for Windows on ARM, plus the same release's `SHA256SUMS.txt`. The
corresponding portable ZIP is also available for each architecture. In PowerShell, check the installer's SHA-256
against its entry in `SHA256SUMS.txt` (use the ARM64 filename if that is the installer you downloaded):

```powershell
Get-FileHash .\focusnotes-win-x64-Setup.exe -Algorithm SHA256
```

Run the matching `Setup.exe`. It installs for your user under `%LocalAppData%` and does not require administrator
rights. On first launch, complete Setup to choose the notes folder and configure the app. Read [Windows install notes](#windows-install-notes) for SmartScreen and Smart App Control guidance.

- **Targets.** Windows 10 22H2 and Windows 11, on x64 and arm64. Each architecture gets its own installer and
  update channel.
- **Same behaviour, Windows mechanics.** The same capture and note actions, sessions, search, toasts and plain-Markdown vault.
  The vault layer is checked against the same shared fixtures as the Mac app (see [CONTRIBUTING.md](CONTRIBUTING.md)).
  Selection capture uses UI Automation, with an opt-in clipboard fallback. Area OCR runs locally with RapidOcrNet's
  bundled PP-OCRv5 Latin models; this Windows POC is English-first, with multilingual coverage deferred. OCR models
  ship with the app and are not downloaded at runtime; captured images stay on your PC.
- **Tray, not menu bar.** The app lives in the notification area and has no taskbar button or main window. On
  Windows 11 a new tray icon may start in the overflow flyout; drag it out (Settings → Personalization → Taskbar →
  Other system tray icons).
- **Setup on first launch.** A Setup window runs once: it explains what the app uses, asks two questions (the
  clipboard fallback and automatic update checks), then offers a folder picker and checks the notes folder,
  registers and tests the shortcuts, lets you add folder shortcuts,
  and offers a selection and an area capture test, the tray icon, start at login and the semantic search pointer.
  Nothing is registered or captured until the first page is answered. Reopen it from the tray icon → **Setup…**.
  Windows has no permission prompts for these features, so Setup is where a problem shows up early.

### Shortcuts on Windows

Windows uses Alt+Shift for the normal global shortcuts, matching Option+Shift on macOS.
Outside-session captures use Ctrl+Shift on both platforms.

| Action | Windows | Mac |
| --- | --- | --- |
| Capture selected text | <kbd>Alt+Shift+Q</kbd> | <kbd>⌥⇧C</kbd> |
| Capture an area of the screen | <kbd>Alt+Shift+G</kbd> | <kbd>⌥⇧S</kbd> |
| Capture selected text outside the session | <kbd>Ctrl+Shift+Q</kbd> | <kbd>⌃⇧C</kbd> |
| Capture an area outside the session | <kbd>Ctrl+Shift+G</kbd> | <kbd>⌃⇧S</kbd> |
| Write a quick note | <kbd>Alt+Shift+W</kbd> | <kbd>⌥⇧N</kbd> |
| Write a quick note outside the session | <kbd>Ctrl+Shift+W</kbd> | <kbd>⌃⇧N</kbd> |
| Search notes | <kbd>Alt+Shift+F</kbd> | <kbd>⌥⇧F</kbd> |
| Start or end a session | <kbd>Alt+Shift+A</kbd> | <kbd>⌥⇧A</kbd> |
| Add a subheading | <kbd>Alt+Shift+H</kbd> | <kbd>⌥⇧H</kbd> |
| Open the notes folder | <kbd>Alt+Shift+E</kbd> | <kbd>⌥⇧L</kbd> |

These defaults are provisional until they are tested against common apps on real devices. Rebind any of them in
**Settings… → Shortcuts**. In the quick note, <kbd>Ctrl+Enter</kbd> saves, <kbd>Ctrl+K</kbd> opens actions,
<kbd>Ctrl+P</kbd> browses notes, <kbd>Ctrl+Shift+N</kbd> toggles **Write outside session** while a session
is active, and <kbd>Esc</kbd> closes it and keeps your draft. <kbd>Ctrl+N</kbd> on a blank editor returns
to the session. <kbd>Ctrl+Shift+W</kbd> (**Quick-note Outside Session** in the tray) opens the quick note with
**Write outside session** already on. Outside-session captures open the same note picker; <kbd>Esc</kbd> saves to Inbox.
Both outside-session capture commands and Quick-note Outside Session are also available from the tray menu, including when their shortcuts are turned off or unavailable.
After an upgrade, existing custom shortcuts take priority over new defaults. Settings shows any replacement needed for a conflict or a combination newly reserved by the editor; use **Change…** to choose another shortcut.
Windows Setup and Settings customize the built-in shortcuts and provide folder-bound Quick Note and Start Session shortcuts.

### Where things live on Windows

| What | Location |
| --- | --- |
| Notes | `Documents\focusnotes` (change from **Choose Notes Folder…** in the tray menu, **Setup…**, or **Settings… → General → Notes folder**; applies after a restart) |
| App state (settings, drafts, search index, pending saves, models, logs) | `%LocalAppData%\com.zerodoxxx.focusnotes` |
| The installed app | `%LocalAppData%\focusnotes-win-<arch>` (per user, no administrator rights needed) |

The folder picker uses the native Windows dialog and checks that the selected folder is writable before saving.
Changing folders leaves existing notes in their original location. Sessions, drafts, pending saves, pins, folder shortcuts and
search indexes belong to each notes folder and are retained when you switch back. Settings and downloaded
models are shared across folders.

The notes are the same plain Markdown files as on the Mac, so a vault can be shared between the two. Uninstalling
removes only the installed app; your notes and app state stay.

### Windows install notes

- **Smart App Control and SmartScreen.** Unsigned installers may trigger a SmartScreen warning. Smart App Control may
  block an unsigned app when it cannot confirm the app is safe, and it has no per-app bypass. Do not turn off these
  protections to run focusnotes; use only installers from the official [GitHub releases](https://github.com/zerodoxxx/focusnotes/releases),
  and do not run the app on a device that blocks it. See Microsoft's [Smart App Control FAQ](https://support.microsoft.com/en-us/windows/security/threat-malware-protection/smart-app-control-frequently-asked-questions)
  and [SmartScreen reputation guidance](https://learn.microsoft.com/windows/apps/package-and-deploy/smartscreen-reputation).
- **Administrator windows.** Windows does not let a normal app read another app that runs as administrator. Capture
  Selection shows "Can't capture from apps running as administrator"; use Capture Area instead.
- **Updates** come from GitHub and are verified with an EdDSA signature on the update index before anything is
  downloaded, then checked against package hashes. Semantic search downloads only the model files (about 455 MB),
  because the ONNX Runtime ships with the app.

## Build from source

This section covers the macOS app; Windows build commands are in [CONTRIBUTING.md](CONTRIBUTING.md#windows).

Requirements: macOS 14+, a Swift 6.4 toolchain (current Xcode or Command Line Tools), and Python 3. Semantic search
needs Apple silicon.

```bash
git clone https://github.com/zerodoxxx/focusnotes.git
cd focusnotes
./scripts/run-app.sh            # debug build, install to /Applications and launch
./scripts/run-app.sh release    # optimised build
./scripts/build-app.sh          # build only
```

`run-app.sh` deletes its build artifacts afterwards; set `KEEP_BUILD=1` to keep them for faster rebuilds. It signs
with the maintainer's identity if present, otherwise ad hoc (macOS then asks for permissions again after each
rebuild). To use your own identity:
`SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/run-app.sh`.

To fetch the semantic models without the in-app download, run
`./scripts/fetch-models.sh "$HOME/Library/Application Support/com.zerodoxxx.focusnotes/models"` and restart the app.

## Development

```bash
swift build                        # build every target
swift run CoreChecks               # storage, index and Markdown checks
swift run OverlayGallery --check   # UI behaviour checks for the panels
swift run OverlayGallery           # render UI snapshots to build/gallery/
```

| Target | What it holds |
| --- | --- |
| `App` | The menu-bar app: shortcuts, capture flow, sessions, menu |
| `Core` | Headless logic: the Markdown vault, journaling, the SQLite FTS5 search index |
| `CaptureKit` | Global hotkeys, text selection and screen-area capture |
| `OverlayKit` | Panels: quick note, search, toasts, capture input |
| `EmbedKit` / `EmbedHelper` | The on-device embedding engine for semantic search |
| `OverlayGallery` | UI snapshots and behaviour checks for `OverlayKit` |

More detail: [reference](docs/reference.md), [quick-note UI](docs/quick-note-ui.md), [demo](docs/demo.md),
[manual tests](docs/manual-tests.md), [releasing](docs/releasing.md), [release checklist](docs/release-checklist.md),
[changelog](CHANGELOG.md).

## Contributing, security and license

Contributions are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Report vulnerabilities as described in
[SECURITY.md](SECURITY.md).

Project-owned files are licensed under the [MIT License](LICENSE). Third-party code and downloaded models keep their
own terms; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
