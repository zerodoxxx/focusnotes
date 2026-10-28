# Release review checklist

Last Updated: 2026-10-28 (previous commit: `ed1551e`)

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

## Windows distribution status

The published [v0.1.5 release](https://github.com/zerodoxxx/focusnotes/releases/tag/v0.1.5) includes Windows x64 and
arm64 installers and portable packages. The release workflow attaches these assets to the draft automatically; use
this checklist to review the packages and record the remaining Windows release-readiness checks. macOS items above
are unaffected. See [releasing.md](releasing.md#windows-release-prerequisites) for the release setup.

- [ ] Release signing mode is understood: the workflow supports unsigned Authenticode installers with all three
  optional signer settings unset. If signing is configured, `SIGNPATH_API_TOKEN`, `WINDOWS_SIGN_TEMPLATE` and
  `WINDOWS_SIGNER_THUMBPRINTS` must all be set and the enforced inventory must pass; partial configuration fails.
- [ ] Update keys: `scripts/make-windows-update-key.sh` was run for K1 and K2, `WINDOWS_UPDATE_ED_KEYS` is committed,
  K1 is the `WINDOWS_UPDATE_ED_KEY_1` secret, and K2 is backed up offline and kept out of CI.
- [ ] The signing inventory is reviewed for x64 and arm64. In unsigned mode, record the unsigned FocusNotes files;
  with Authenticode configured, confirm every file is ours-and-signed, vendor-signed or on the upstream allow-list.
- [ ] On Windows 11 x64 and arm64, record Smart App Control behavior in enforcement and evaluation modes. It may
  block unsigned files, and there is no per-app bypass; do not disable it to make the test pass. If Windows allows
  installation, test every feature (including OCR and semantic search), update and uninstall. Confirm the README
  describes the observed limitation and review CodeIntegrity events 3076/3077.
- [ ] Install and update on native Windows 11 x64, Windows 11 arm64 and Windows 10 22H2 x64; the arm64 installer is
  refused on x64.
- [ ] The device checks in the Windows section of [manual-tests.md](manual-tests.md) pass on all three targets.
- [ ] Deviations DV1-DV12, OCR languages not covered by the bundled models, and any exception to the measured focus,
  OCR and resource gates are signed off by the maintainer.
- [ ] `THIRD_PARTY_NOTICES.md` lists every shipped Windows component at its shipped version.
- [ ] README, ARCHITECTURE.md, DESIGN.md and the reference match the release candidate, including the unsigned
  installer and Smart App Control limitations.

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
