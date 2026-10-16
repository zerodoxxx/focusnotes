# Release review checklist

Audit date: 2026-10-15. This records current review evidence and the checks that
still need a final result. Do not describe the repository as fully verified
until the open items below are closed.

## License and attribution

- [x] The root project license is MIT. The independent review approved the
  license text and confirmed it permits commercial use under its terms.
- [x] `THIRD_PARTY_NOTICES.md` preserves separate ONNX Runtime MIT and
  EmbeddingGemma Apache-2.0 terms. The independent review approved the scopes,
  model attribution, sidecar hashes, and downloader destinations.
- [x] The maintainer confirms that the icon artwork was created for focusnotes
  using Codex (GPT-6.1-sol). The notice records this as maintainer-reported
  provenance without claiming independent copyright or a separate third-party
  asset license.

## Security changes

- [x] Build scripts no longer read a local keychain password or unlock a
  personal keychain. Signing uses an explicit `SIGN_IDENTITY` or ad-hoc
  signing.
- [x] `APPNAME` and bundle/install paths are validated before destructive
  operations. `bash scripts/test-app-path-safety.sh`, `bash -n` on the scripts,
  and `scripts/check-name.sh` passed. These checks do not protect against a
  compromised account or a same-user process changing paths between checks.
- [x] Vault paths, session names, OCR asset paths, and error descriptions are
  private in unified-log fields; the source review approved the logging changes.
- [x] Core vault I/O uses root-anchored descriptors and no-follow checks to
  contain managed note and asset reads/writes. The final CoreChecks run passed
  these regressions. These safeguards do not imply equivalent hardening for the
  separate Application Support session, draft, recovery-journal, or SQLite
  cache files.

## Current verification

Latest post-hardening results (last verified before the 0.1.0 release work; re-run the checks before tagging):

| Check | Current status |
| --- | --- |
| `swift build` | Passed for all targets. No Swift source warnings; only host CLT framework/library search-path linker warnings. |
| `swift run CoreChecks` | Passed all groups, including vault safety, OCR, ranking, shared-asset, performance, and watcher checks. For 2,000 notes × 10 captures: cold sync 1.603 s, warm sync 182.2 ms, search median 11.93 ms. |
| `swift run CaptureChecks` | Passed all groups without Accessibility or Screen Recording permissions. |
| `swift run OverlayGallery --check` | Passed all groups. |
| `swift run EmbedChecks --models <installed-models-directory>` | Passed 81 checks, 0 failures, 0 skips, using already-installed models; no downloads were run. |
| `swift run App --self-test <fresh-temp-directory>` | Passed, exit 0. With fresh temporary vault/state, verified 7 captures, OCR search, external watcher edits, shutdown/recovery, drafts, and pins. The semantic portion intentionally skipped because the isolated state had no models; `EmbedChecks` separately passed all 81 model-backed checks. No real vault or macOS permissions were touched. |
| `scripts/check-name.sh` | Passed after fixture naming changes. |
| `bash scripts/test-app-path-safety.sh` and `bash -n` | Passed; the path harness does not perform a real build or install. |

One earlier helper-stdout-close failure did not recur after the settled build;
no source fix is attributed to that non-reproducible result.

CI workflows (`.github/workflows/checks.yml` and `release.yml`) are part of the
release process. The release identity is imported from GitHub secrets only in
CI, so hosted-runner results must be read from the workflow runs. The local
results above do not replace them. See [releasing.md](releasing.md).

## Manual distribution and disclosure checks

- [x] Authenticate the downloaded ONNX runtime at load time. The helper now
  checks the dylib against a pinned SHA-256 (matching `DYLIB_HASH` in
  `scripts/fetch-models.sh`) immediately before `dlopen` and refuses to load it
  on mismatch; EmbedChecks covers the rejection path.
- [x] Signing policy: binaries are distributed without Apple Developer ID
  signing or notarization. Releases use the stable self-signed "focusnotes
  Release Signing" identity, and `release.sh` fails if the designated
  requirement differs from `Config/signing-requirement.txt`. Never replace this
  identity, since a different certificate resets users' Accessibility and
  Screen Recording permissions. Users approve the first launch via System
  Settings → Privacy & Security → Open Anyway. Revisit library validation only
  if Apple signing is adopted later.
- [ ] Validate Accessibility and Screen Recording grant, denial, and
  reauthorization flows on a clean macOS account, via the permission guide
  panel. Automated CaptureChecks do not exercise macOS privacy prompts.
- [ ] Update in place from the previous release on a clean account: Accessibility
  and Screen Recording stay granted after the update.
- [ ] Sparkle "Check for Updates…" finds the new version from the published
  `appcast.xml`.
- [ ] The in-app semantic model download completes on a clean account.
- [ ] CI runs `checks.yml` on pushes and pull requests. Confirm that
  `release.yml` can be manually started, prepare a version branch and pull
  request, and build, attest, and draft the release after that PR is merged.
  Confirm the required PR checks and review, draft assets, and appcast before
  publishing. If the expected Actions permission block prevents automatic PR
  creation, confirm the run succeeds with a warning and a compare link, then
  open the PR manually. Unexpected PR-creation errors must remain failed runs.
- [ ] After making the repository public, enable GitHub private vulnerability
  reporting (Settings → Security and quality → Advanced Security → Private
  vulnerability reporting, or
  `gh api -X PUT repos/zerodoxxx/focusnotes/private-vulnerability-reporting`)
  and confirm with the matching `gh api` GET. GitHub offers it only on public
  repositories. `SECURITY.md` covers both cases.
- [x] Pin the optional Python dependencies used by
  `EmbedChecks/generate-reference.py`: see
  `Sources/EmbedChecks/requirements-reference.txt` (fixture-recorded versions;
  numpy bounded).

## Review limits

A path-only heuristic scan found no common credential markers in the working
tree or the 17 commits reachable from `main` and `origin/main`. `gitleaks` was
unavailable; unreachable history and arbitrary credential formats were not
covered. The dependency review found no published ONNX Runtime advisory
matching version 1.31.0 as of the audit date and reported that the pinned
artifacts matched their upstream digests ([release](https://github.com/microsoft/onnxruntime/releases/tag/v1.31.0),
[advisories](https://github.com/microsoft/onnxruntime/security/advisories),
[model revision](https://huggingface.co/onnx-community/embeddinggemma-2-ONNX/tree/daa72c51243991dfcaf9f9137d2c573d8f7790c0)).
This was a targeted advisory and provenance check, not a full dependency source
audit. No penetration test, fuzzing campaign, or remote adversarial assessment
was performed. Notes, images, Application Support state, and caches are local
files without app-provided encryption at rest.
