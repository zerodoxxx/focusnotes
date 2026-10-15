# Changelog

All notable changes to focusnotes are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - Unreleased

First binary release. Apple silicon, macOS 14 Sonoma or later.

### Added

- Drag-to-install DMG with a SHA-256 checksum file (`SHA256SUMS.txt`) for verification.
- In-app download of the optional semantic search models, with pinned SHA-256 checks, resume and cancel.
- A permission guide panel that opens the right System Settings pane and helps add focusnotes to the Accessibility and Screen Recording lists.
- Automatic updates through Sparkle, with EdDSA-signed update archives and an opt-in daily check.
- Stable signing for release builds, so Accessibility and Screen Recording grants survive updates.
