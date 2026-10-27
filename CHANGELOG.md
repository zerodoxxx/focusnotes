# Changelog

Last Updated: 2026-10-28 (previous commit: `433fea5`)

All notable changes to focusnotes are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Implemented Windows edition: a tray app for Windows 10 22H2 and Windows 11 (x64 and arm64) with the same capture, quick note, session and search features, Windows default shortcuts with rebinding, a first-launch Setup, bundled offline OCR, optional semantic search, and Velopack installs with signed-index updates. Windows x64 and arm64 installers and portable ZIPs first shipped in v0.1.5; the Mac app is unchanged.
- Selection and area captures can include a separate Markdown `Source` link to the current HTTP(S) address from supported browsers: Safari, Chrome, and Edge on macOS; Chrome and Edge on Windows when their address bar exposes a complete URL.
- Shared conformance fixtures (`conformance/`) that both the Swift reference and the Windows port must pass; regenerate with `swift run CoreChecks --write-conformance`.

### Fixed

- macOS: starting, resuming or ending a session no longer shows an error when only the search-index update afterwards fails; the session change and its toast stand.
- macOS: a quick note, subheading or session name submitted while the app was busy is no longer dropped when the app quits; it is saved or applied during the five-second quit drain if it starts before that deadline. An ambiguous session name submitted then is logged rather than started.
- macOS: one note changing while the search index syncs no longer aborts the whole sync; that note keeps its existing results and is picked up by the next sync, and deleted notes are still removed.
- macOS: a capture no longer fails with "Operation not permitted" when its note is replaced by an editor's save while the capture waits; it retries against the current file. If a session rename moves the note away instead, the capture fails and stays in the recovery journal rather than recreating the old note.
- macOS and Windows: after a quick note or subheading failed to save, the quick-note editor would not open again and showed "Couldn't save pending capture" each time. It now opens with the kept draft.
- macOS: a capture kept after a failed chosen-note save is no longer saved to the default destination by a later toast, search or session change; it stays pending until retried. A newer capture first saves a retry-pending one to its default destination with a notice, and the capture shortcut reopens the chooser only while the retry warning is visible. A failed append now reports the original write error even when rollback fails.
- Windows: when a note replace removes the note and cannot put the new copy back, the kept `.recovered-` copy is restored (never over an existing file) by the startup sweep (vault roots only), the next note append, or session rename recovery, and the event is written to the app log. Copies of state files (`session.json`, the external-note registry) are kept for manual recovery only. Very long note names and case-only mismatches are not auto-restored.

## [0.1.0] - Unreleased

First binary release. Apple silicon, macOS 14 Sonoma or later.

### Added

- Drag-to-install DMG with a SHA-256 checksum file (`SHA256SUMS.txt`) for verification.
- In-app download of the optional semantic search models, with pinned SHA-256 checks, resume and cancel.
- A permission guide panel that opens the right System Settings pane and helps add focusnotes to the Accessibility and Screen Recording lists.
- Automatic updates through Sparkle, with EdDSA-signed update archives and an opt-in daily check.
- Stable signing for release builds, so Accessibility and Screen Recording grants survive updates.
