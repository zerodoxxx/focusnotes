# Security

focusnotes is an early macOS app built and run locally. It is not a hosted
service, and this project does not publish a supported-release or
security-response schedule.

## Reporting a vulnerability

Please do not post exploit details, sensitive reproduction steps, private notes,
screenshots, or captures in a public issue, pull request, or discussion.

If GitHub offers a **Report a vulnerability** option on this repository's
Security page, use it to send a private report. Whether that feature is enabled
is controlled by the repository settings. If it is unavailable, use a private
maintainer contact listed on the repository page, if one is provided. If no
private contact is available, open only a minimal public issue asking for a
private reporting channel; do not include vulnerability details.

A useful private report includes the affected commit or version, macOS version,
a concise impact description, steps to reproduce with synthetic data, and any
known workaround. Do not attach real notes, vault paths, screenshots, or model
files unless they are essential and you have removed personal data.

There is no published response-time commitment.

## Security scope

The app stores notes as ordinary Markdown and images in the selected local
vault. Drafts, journals, and search caches are stored in the user's Application
Support directory. The app does not encrypt these files at rest; anyone or any
process that can read the user's account or vault can read them. Captures can
include selected text, screenshots, OCR text, source application names, and
window titles.

Core vault I/O now uses root-anchored directory descriptors and no-follow
checks for managed note and asset reads and writes. The final CoreChecks run
passed the vault-safety regressions on 2026-10-15. These checks do not imply
equivalent protections for ordinary Application Support session state, drafts,
recovery journals, or SQLite caches, and they do not protect files from another
process running as the same user.

Capturing selected text requires macOS Accessibility access. The selection flow
may use the pasteboard after the user invokes the capture shortcut. Capturing a
screen area requires Screen Recording access. Review these permissions before
use and choose a vault appropriate for the data being captured.

Capture and search processing run locally, and note content never leaves the
Mac. The app contacts the network in only two cases: when the user chooses
**Download Semantic Search Models (492 MB)…** and accepts the consent dialog
(which names the download size, the hosts huggingface.co and github.com, the
licenses, and the SHA-256 verification; see
[docs/semantic-search.md](docs/semantic-search.md)), and for
update checks and downloads, which run only after the user allows automatic
checks or chooses **Check for Updates…**.

The model download uses HTTPS only, follows redirects only to HTTPS, and uses
an ephemeral session with no cookies and no cache. Files are staged beside the
models folder, resumed with HTTP Range requests when a download is interrupted,
and checked against a pinned SHA-256 before the staged set is moved into place
atomically. The optional ONNX Runtime library is extracted from its pinned
archive and loaded by the helper process, which checks it against the pinned
SHA-256 before every load and refuses a mismatched file.

Updates are delivered through Sparkle 2.10.0 from the project's GitHub release
appcast. They are signed with an EdDSA key held by the maintainer, and Sparkle
also requires the update to be signed with the same code-signing identity. No
system profile is sent. Releases are signed with one stable self-signed
certificate, not an Apple Developer ID, and are not notarized. The certificate's
designated requirement is recorded in the repository, and the release script
refuses to ship if it changes, so Accessibility and Screen Recording grants
survive updates. Releases are built without the hardened runtime, so library
validation is off; the SHA-256 pin is the integrity control for the downloaded
library. See [semantic-search.md](docs/semantic-search.md).

This scope does not cover a compromised macOS account, malicious software
running as the same user, tampering with locally downloaded files, or the
behavior of third-party code under its own license. The project license and
third-party terms are listed in [LICENSE](LICENSE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Vault contents remain editable by other applications. Treat them as user data,
not as an access-control boundary.
