# focusnotes

**Take notes without breaking focus.**

focusnotes is a small macOS menu-bar app for capturing what you're reading or thinking without leaving the app you're
working in. Select text and press a shortcut. Drag over part of the screen. Jot a quick note in a floating panel. Your
window keeps focus the whole time, and everything lands in plain Markdown files you own.

> **Status:** first binary release, v0.1.0. Install the DMG from [Install](#install), or build from source using
> [Build from source](#build-from-source).

## Why

Taking a note usually means a context switch: open the notes app, find the right page, paste, tidy up, switch back.
Each switch costs a little attention, and you lose more of it the more often you do it.

focusnotes never pulls you out of what you're doing:

- **No app switching.** Captures happen in place. focusnotes never activates itself or steals focus from your window.
- **Keyboard first.** Every action has a global shortcut, and a toast confirms it was saved.
- **Sessions.** Start a session for a topic, such as a course, a paper or a design review, and every capture and
  note goes to that topic's note until you end it.
- **Plain Markdown.** Notes are ordinary `.md` files, compatible with Obsidian or any editor. There's no database
  you can't read and no lock-in.
- **On-device.** Captured text, screenshots, OCR, keyword search and optional semantic search run on your Mac. Note
  content, captures and search queries never leave your Mac. The app uses the network only to download optional
  semantic models and to check for and download updates; see [Privacy and network](#privacy-and-network).

## Features

- **Capture selection.** Saves the selected text from any app, along with where it came from.
- **Capture area.** Drag over part of the screen to save it as an image. Text in the image is recognised (OCR) and
  becomes searchable.
- **Quick note.** A floating panel for typing Markdown with a live preview. It stays on screen while you work in
  other windows, and saves with ⌘↩.
- **Search.** Keyword search across all your notes, plus optional on-device semantic search.
- **Sessions and subheadings.** Group captures by topic, and add a subheading to start a new section.

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

Inside the quick note: <kbd>⌘↩</kbd> saves, <kbd>⌘K</kbd> opens actions, <kbd>⌘P</kbd> browses notes, <kbd>esc</kbd>
closes it and keeps your draft.

## Install

focusnotes requires macOS 14 Sonoma or later on Apple silicon.

### 1. Download and verify

Download `focusnotes-0.1.0-arm64.dmg` and `SHA256SUMS.txt` from the
[GitHub Releases](https://github.com/zerodoxxx/focusnotes/releases) page. In the folder you downloaded them to, run:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

The DMG should report `OK`. If it doesn't, don't open it.

### 2. Install

Open the DMG and drag focusnotes to Applications.

### 3. First launch

focusnotes isn't notarized, and it isn't signed with an Apple Developer ID. It uses its own self-signed certificate,
because the project doesn't have a paid Apple developer account. macOS therefore blocks the first open with a dialog
like "Apple could not verify 'focusnotes' is free of malware…".

1. Click **Done**.
2. Open **System Settings → Privacy & Security** and scroll to **Security**.
3. Click **Open Anyway**. The button is available for about an hour after the blocked attempt.
4. Confirm with your password, then click **Open**.

Since macOS Sequoia, Control-click → Open no longer bypasses this check.

You don't have to trust the download on faith. The source is open, the checksum above lets you confirm the file is
the one that was published, and release builds made by CI carry a GitHub build attestation.

### 4. Grant permissions

focusnotes needs two permissions:

| Permission | Needed for |
| --- | --- |
| Accessibility | Reading the selected text in other apps and copying it |
| Screen Recording | Capturing an area of the screen |

When a permission is needed, focusnotes opens the right System Settings pane and shows a small panel with its icon.
Drag the icon into the list, then switch focusnotes on. If dragging doesn't work, click **+** and choose focusnotes in
Applications.

Screen Recording may need a relaunch. The panel has a **Relaunch** button for this. macOS may occasionally ask you to
confirm Screen Recording again. The current status of each permission is under the menu-bar icon → **Permissions**.

Your permissions survive updates. Every release is signed with the same certificate, so macOS keeps your grants.

## Updates

Choose **Check for Updates…** from the menu-bar menu. On the second launch, focusnotes asks whether to check for
updates automatically, at most once a day. Updates are downloaded from GitHub, verified with an EdDSA signature, and
installed in place.

## Semantic search

Keyword search works without any download. For meaning-based search, download the on-device models from the menu-bar
icon: **Enable Semantic Search…**. The download is about 492 MB and needs Apple silicon.

- The EmbeddingGemma model (Apache-2.0) is downloaded from huggingface.co, and ONNX Runtime (MIT) from github.com.
- Each file is checked against a pinned SHA-256 hash before it is used.
- If the download is interrupted, it resumes. You can cancel it at any time.
- To remove the models, use **Semantic Search → Remove Models…**.

See [docs/semantic-search.md](docs/semantic-search.md) for how it works.

## Privacy and network

focusnotes sends note content, captures and search queries nowhere. Everything they need is processed on your Mac.

The app connects to the network in exactly two cases:

1. **Semantic models.** When you choose **Enable Semantic Search…**.
2. **Updates.** When you choose **Check for Updates…**, or when automatic update checks are on.

## Uninstall

1. Quit focusnotes.
2. Delete focusnotes from Applications.
3. Optionally, delete the app state, which includes the models and search indexes:

   ```bash
   rm -rf "$HOME/Library/Application Support/com.zerodoxxx.focusnotes"
   ```

Your notes stay in your notes folder (`~/Documents/focusnotes` by default). Delete them only if you want to.

To clear the permissions, run:

```bash
tccutil reset Accessibility com.zerodoxxx.focusnotes
tccutil reset ScreenCapture com.zerodoxxx.focusnotes
```

## Where your notes live

Notes are saved in `~/Documents/focusnotes`:

```text
focusnotes/
├── Inbox.md              # captures made outside a session
├── Sessions/
│   └── System Design.md  # one note per session
├── <Quick note title>.md # quick notes written outside a session
└── assets/               # area captures (images)
```

Each note is readable Markdown. Timestamps and source details live in invisible HTML comments, so the text itself stays
clean:

```markdown
# System Design

### Designing Data-Intensive Applications
<!-- capture:… at=2026-10-14T13:04:58+05:30 app="Firefox" -->

Replication lag is the delay between a write on the leader and its visibility on followers.
```

To keep notes somewhere else, such as an Obsidian vault, set the folder and restart the app:

```bash
defaults write com.zerodoxxx.focusnotes vaultPath "~/Obsidian/Notes"
```

App state (drafts, the search index and pending saves) lives in
`~/Library/Application Support/com.zerodoxxx.focusnotes`.

## Build from source

### Requirements

- macOS 14 Sonoma or later
- A Swift 6.4 toolchain: a current Xcode, or the Command Line Tools
- Python 3 for the bundle build, plus the macOS command-line tools used by the
  scripts (`plutil`, `codesign`, `ditto`, `open`)
- Apple silicon, only if you want semantic search

### Build and run

```bash
git clone https://github.com/zerodoxxx/focusnotes.git
cd focusnotes
./scripts/run-app.sh
```

`run-app.sh` builds the app, quits any running copy, replaces the installed copy
at `/Applications/focusnotes.app` (or `~/Applications` if `/Applications` is not
writable) and opens it. It then deletes the build artifacts (`.build` and
the staged bundle), which can take several GB; set `KEEP_BUILD=1` to keep them for faster incremental rebuilds. A tray
icon appears in the menu bar; there is no Dock icon. Use `./scripts/run-app.sh release` for an optimised build. To
build without installing or launching, run `./scripts/build-app.sh`.

`run-app.sh` signs the app with the maintainer's release identity automatically if that identity exists on the
machine. Otherwise it signs ad hoc, and macOS asks for permissions again after each rebuild.

> **Tip:** to use your own signing identity, pass it explicitly:
> `SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/run-app.sh`.

### From source: semantic models

To fetch the semantic search models without the app's download, run:

```bash
./scripts/fetch-models.sh "$HOME/Library/Application Support/com.zerodoxxx.focusnotes/models"
```

Restart the app afterwards. The menu shows **Semantic search: On** once the models are found. See
[docs/semantic-search.md](docs/semantic-search.md) for details.

## Development

```bash
swift build                     # build every target
swift run CoreChecks            # storage, index and Markdown checks
swift run OverlayGallery --check   # UI behaviour checks for the panels
swift run OverlayGallery        # render UI snapshots to build/gallery/
scripts/check-name.sh           # make sure the app name lives only in Config/app.env
```

The app name, bundle prefix and version are set in `Config/app.env`; nothing else hard-codes them.

| Target | What it holds |
| --- | --- |
| `App` | The menu-bar app: shortcuts, capture flow, sessions, menu |
| `Core` | Headless logic: the Markdown vault, journaling, the SQLite FTS5 search index |
| `CaptureKit` | Global hotkeys, text selection and screen-area capture |
| `OverlayKit` | Panels: quick note, search, toasts, capture input |
| `EmbedKit` / `EmbedHelper` | The on-device embedding engine for semantic search |
| `OverlayGallery` | UI snapshots and behaviour checks for `OverlayKit` |

Contributions are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). The maintainer release process is in
[docs/releasing.md](docs/releasing.md).

## License and contributing

Project-owned files are licensed under the OSI-approved [MIT License](LICENSE),
which permits commercial use subject to its terms and notice requirements.
Third-party code and downloaded model/runtime artifacts keep their separate
terms; see
[third-party notices](THIRD_PARTY_NOTICES.md). Contributions are covered by the
same project terms described in [CONTRIBUTING.md](CONTRIBUTING.md).

## Further reading

- [CHANGELOG.md](CHANGELOG.md): what changed in each release
- [docs/reference.md](docs/reference.md): detailed capture, storage and editor behaviour
- [docs/quick-note-ui.md](docs/quick-note-ui.md): the quick-note panel's design
- [docs/demo.md](docs/demo.md): a full walkthrough and the self-test
- [docs/manual-tests.md](docs/manual-tests.md): manual test checklist
- [docs/semantic-search.md](docs/semantic-search.md): how semantic search works
- [docs/release-checklist.md](docs/release-checklist.md): current release review gates
- [docs/releasing.md](docs/releasing.md): how releases are built and published
- [SECURITY.md](SECURITY.md): vulnerability reporting and security scope
