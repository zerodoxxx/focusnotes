# focusnotes

**Take notes without breaking focus.**

focusnotes is a small macOS menu-bar app for capturing what you're reading or thinking without leaving the app you're
in. Select text and press a shortcut, drag over part of the screen, or jot a quick note in a floating panel. Your
window keeps focus the whole time, and everything lands in plain Markdown files you own.

## Features

- **Capture selection.** Saves the selected text from any app, along with where it came from.
- **Capture area.** Drag over part of the screen to save it as an image. Text in the image is recognised (OCR) and
  becomes searchable.
- **Quick note.** A floating Markdown panel with a live preview. It stays on screen while you work and saves with ⌘↩.
  Include folder segments in the title to save a note in a subfolder.
- **Sessions.** Start a session for a topic (a course, a paper, a design review) and every capture goes to that
  topic's note until you end it. A unique existing name resumes its note; duplicate matches open a chooser,
  while a slash-qualified name picks a path under `Sessions/`. Add subheadings to start new sections.
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
| <kbd>⌥⇧N</kbd> | Write a quick note |
| <kbd>⌥⇧F</kbd> | Search notes |
| <kbd>⌥⇧A</kbd> | Start or end a session |
| <kbd>⌥⇧H</kbd> | Add a subheading |
| <kbd>⌥⇧L</kbd> | Open the notes folder |

In the quick note: <kbd>⌘↩</kbd> saves, <kbd>⌘K</kbd> opens actions, <kbd>⌘P</kbd> browses notes, and <kbd>esc</kbd>
closes it and keeps your draft.

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

Timestamps and source details are stored in HTML comments, so the visible text stays clean:

```markdown
# System Design

### Designing Data-Intensive Applications
<!-- capture:… at=2026-10-14T13:04:58+05:30 app="Firefox" -->

Replication lag is the delay between a write on the leader and its visibility on followers.
```

To use another folder, such as an Obsidian vault, set it and restart the app:

```bash
defaults write com.zerodoxxx.focusnotes vaultPath "~/Obsidian/Notes"
```

App state (drafts, search index, pending saves, models) lives in
`~/Library/Application Support/com.zerodoxxx.focusnotes`.

## Semantic search

Keyword search works out of the box. For meaning-based search, choose **Enable Semantic Search…** from the menu to
download the on-device models (about 492 MB, Apple silicon only): EmbeddingGemma (Apache-2.0) from huggingface.co and
ONNX Runtime (MIT) from github.com. Each file is checked against a pinned SHA-256 hash, downloads resume if
interrupted, and **Semantic Search → Remove Models…** deletes them. See [docs/semantic-search.md](docs/semantic-search.md).

## Privacy

Note content, captures and search queries are processed on your Mac and sent nowhere. The app uses the network only
to download the optional semantic models and to check for and download updates.

## Uninstall

Quit focusnotes and delete it from Applications. Optionally remove its app state and permissions:

```bash
rm -rf "$HOME/Library/Application Support/com.zerodoxxx.focusnotes"
tccutil reset Accessibility com.zerodoxxx.focusnotes
tccutil reset ScreenCapture com.zerodoxxx.focusnotes
```

Your notes stay in your notes folder.

## Build from source

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
scripts/check-name.sh              # the app name must live only in Config/app.env
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
