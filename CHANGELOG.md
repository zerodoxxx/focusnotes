# Changelog

All notable changes to focusnotes are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Implemented Windows edition: a tray app for Windows 10 22H2 and Windows 11 (x64 and arm64) with the same capture, quick note, session and search features, Windows default shortcuts with rebinding, a first-launch Setup, bundled offline OCR, optional semantic search, and Velopack installs with signed-index updates. Windows installers are not part of the currently published releases; the Mac app is unchanged.
- Shared conformance fixtures (`conformance/`) that both the Swift reference and the Windows port must pass; regenerate with `swift run CoreChecks --write-conformance`.

## [0.1.0] - Unreleased

First binary release. Apple silicon, macOS 14 Sonoma or later.

### Added

- Drag-to-install DMG with a SHA-256 checksum file (`SHA256SUMS.txt`) for verification.
- In-app download of the optional semantic search models, with pinned SHA-256 checks, resume and cancel.
- A permission guide panel that opens the right System Settings pane and helps add focusnotes to the Accessibility and Screen Recording lists.
- Automatic updates through Sparkle, with EdDSA-signed update archives and an opt-in daily check.
- Stable signing for release builds, so Accessibility and Screen Recording grants survive updates.
