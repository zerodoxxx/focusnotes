# Changelog

Last Updated: 2026-10-28 (previous commit: `265176e`)

All notable changes to focusnotes are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Implemented Windows edition: a tray app for Windows 10 22H2 and Windows 11 (x64 and arm64) with the same capture, quick note, session and search features, Windows default shortcuts with rebinding, a first-launch Setup, bundled offline OCR, optional semantic search, and Velopack installs with signed-index updates. Windows x64 and arm64 installers and portable ZIPs first shipped in v0.1.5; the Mac app is unchanged.
- Selection and area captures can include a separate Markdown `Source` link to the current HTTP(S) address from supported browsers: Safari, Chrome, and Edge on macOS; Chrome and Edge on Windows when their address bar exposes a complete URL.
- Shared conformance fixtures (`conformance/`) that both the Swift reference and the Windows port must pass; regenerate with `swift run CoreChecks --write-conformance`.

### Fixed

- macOS: a failed write while creating a session note or `Inbox.md` (for example, on a full disk) no longer leaves a cut-off heading such as `# Fo` that then became the note's title. The new file is removed, so a retry writes the whole heading.
- macOS: a note that an editor saves while focusnotes lists notes no longer drops out of capture routing and session matching, which could create a duplicate note. It is read again; one that keeps changing stays listed under its file name, so session matching by file name still finds it. Hard links, symlinks and unreadable files are still not listed.
- macOS: a failed capture save no longer also fails the next quick-note save or keeps the quick-note editor from opening; the capture's own failure is still reported.
- macOS: reopening the note picker for a capture kept for retry while the quick-note editor can't close (its draft failed to save) no longer drops the retry warning. The warning comes back with the draft error, so the capture shortcut can reopen the picker once the editor closes. A note picked in the several-notes chooser is saved even if the editor can't close.
- macOS: a search, note picker or quick-note panel requested during a selection capture now appears only after the selection is read, so the clipboard fallback's ⌘C can't land in that panel and report "No text selected".
- macOS: quitting while the app is still launching no longer starts the initial index scan during shutdown.
- Windows: after a second failed update apply, the next launch now deletes the downloaded package for that version, and any damaged package, so Retry downloads it again instead of reusing the failing package. Readable packages of other versions are kept, and a package that can't be deleted is logged without hiding the "Update failed" state.
- Windows: an exception in a vault-change observer is now written to the app log instead of being ignored.
- Windows: a failed note append (for example, a full disk or a dropped network vault) no longer leaves a typed note's marker without its body. The append is truncated back to the note's original length, so the retry writes the whole note.
- Windows: when a recovered copy of a note can't be moved back in place, an append now fails and the capture is kept for retry instead of starting a new note holding only the new capture that hid the old one.
- macOS: starting, resuming or ending a session no longer shows an error when only the search-index update afterwards fails; the session change and its toast stand.
- macOS: a quick note, subheading or session name submitted while the app was busy is no longer dropped when the app quits; it is saved or applied during the five-second quit drain if it starts before that deadline. An ambiguous session name submitted then is logged rather than started.
- macOS: one note changing while the search index syncs no longer aborts the whole sync; that note keeps its existing results and is picked up by the next sync, and deleted notes are still removed.
- macOS: a capture no longer fails with "Operation not permitted" when its note is replaced by an editor's save while the capture waits; it retries against the current file. If a session rename moves the note away instead, the capture fails and stays in the recovery journal rather than recreating the old note.
- macOS and Windows: after a quick note or subheading failed to save, the quick-note editor would not open again and showed "Couldn't save pending capture" each time. It now opens with the kept draft.
- macOS: a capture kept after a failed chosen-note save is no longer saved to the default destination by a later toast, search or session change; it stays pending until retried. A newer capture first saves a retry-pending one to its default destination with a notice, and the capture shortcut reopens the chooser only while the retry warning is visible. A failed append now reports the original write error even when rollback fails.
- Windows: note titles, chosen-note names and session names containing `:` (for example `TODO: call Bob`, `Re: budget` or `Standup: Q3`) no longer fail with a reserved-name error. They are saved with `-`, as on the Mac, and match an existing note's heading. `?`, `*`, `"`, `<`, `>` and `|`, which Windows can't store in a file name, are also saved as `-`; the title keeps the typed characters. Device names, trailing periods and drive paths such as `C:\Notes\a` are still rejected.
- Windows: an antivirus scanner or indexer briefly holding a just-staged capture's journal record no longer fails the save with "Couldn't save capture"; state-file replaces and journal-record deletes retry for up to 10 seconds.
- Windows: when a note replace removes the note and cannot put the new copy back, the kept `.recovered-` copy is restored (never over an existing file) by the startup sweep (vault roots only), the next note append, or session rename recovery, and the event is written to the app log. Copies of state files (`session.json`, the external-note registry) are kept for manual recovery only. Very long note names and case-only mismatches are not auto-restored.
- Windows: a capture whose chosen note title could not be prepared (for example `TODO/`, `a//b`, a URL, `..` or `CON`) was saved to Inbox or the session anyway while the toast said “Couldn't save capture” and “this note was not saved”, and retrying duplicated it. It now stays pending and the toast says “Couldn't save to that note” with “Capture kept”. No toast, search or session change saves it to the default destination. The capture shortcut or Escape on the picker brings the choice back, a newer capture first saves it to its default with a notice, and quitting saves it there.
- Windows: a capture title now matches notes directly under the vault root, then sessions, as on the Mac, instead of the first match at any depth. **Behaviour change:** a bare title that matches only a nested or HOME note no longer reaches it and creates a root note; use the note's path (`archive/ideas`, `/Desktop/ideas`) or pick it from the title picker. Several matches in a tier no longer silently take the first: the capture is kept and a toast asks for a path. `pros / cons`, `TODO/` and URLs keep a flat file name instead of failing or nesting.
- Windows: the title picker saves a picked suggestion to that exact note and shows the path for nested, HOME and same-titled notes, so notes sharing a heading (such as `Biology.md` and `Biology 2.md`) can each be chosen.
- Windows: starting, ending, resuming or renaming a session, a folder session shortcut and a subheading now wait for a capture still being acquired, so it can't be saved to Inbox or the next session after the session changes.
- Windows: retyping a subheading that failed to save no longer writes it twice when the app quits.

## [0.1.0] - Unreleased

First binary release. Apple silicon, macOS 14 Sonoma or later.

### Added

- Drag-to-install DMG with a SHA-256 checksum file (`SHA256SUMS.txt`) for verification.
- In-app download of the optional semantic search models, with pinned SHA-256 checks, resume and cancel.
- A permission guide panel that opens the right System Settings pane and helps add focusnotes to the Accessibility and Screen Recording lists.
- Automatic updates through Sparkle, with EdDSA-signed update archives and an opt-in daily check.
- Stable signing for release builds, so Accessibility and Screen Recording grants survive updates.
