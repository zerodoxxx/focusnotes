# Releasing focusnotes

Last Updated: 2026-10-22 (previous commit: `77592ee`)

This is the maintainer runbook for building, signing, checking, and publishing a
release. The app is distributed without Apple Developer ID signing or
notarization, so users approve the first launch once in System Settings. What
keeps existing installs working is a stable self-signed identity and a stable
Sparkle update key. Both are created once and must never be replaced.

For the open review items, see [release-checklist.md](release-checklist.md).

## One-time setup

Do these once, on the maintainer's Mac. Never repeat them. Replacing either
key breaks existing users.

### 1. Signing identity

```sh
brew install openssl@3
scripts/make-signing-identity.sh
```

This creates the self-signed "focusnotes Release Signing" identity in its own
keychain, `~/Library/Keychains/focusnotes-signing.keychain-db` (not the login
keychain). It also writes:

- a backup, `~/focusnotes-signing-identity.p12`
- `Config/signing-requirement.txt`

Then:

1. Store the `.p12` file and both passwords in a password manager.
2. Delete the `.p12` file from disk.
3. Commit `Config/signing-requirement.txt`.

Never replace this identity. A different certificate changes the code
signing requirement, which resets every user's Accessibility and Screen
Recording permissions. `release.sh` fails if the built app's requirement does
not match the committed file.

To restore the identity on a new Mac:

```sh
scripts/import-signing-identity.sh <path/to/identity.p12>
```

### 2. Sparkle update key

```sh
scripts/make-update-key.sh
```

This creates the Sparkle EdDSA update-signing key in the login keychain. It
writes the public key into `Config/app.env` as `SPARKLE_PUBLIC_ED_KEY` and
exports a private-key backup file.

Back up the exported file the same way as the `.p12` (password manager), delete
the file, and commit `Config/app.env`.

Never lose this key. Without it, existing installs cannot verify future updates.

### 3. Models for the release checks

```sh
scripts/fetch-models.sh "$HOME/Library/Application Support/com.zerodoxxx.focusnotes/models"
```

`release.sh` runs `EmbedChecks` with these models. A release fails if that
output contains `SKIP`.

## Per release

### 1. Merge the code you want to release

Merge ordinary code changes to `main` as usual. Pushing code does not start a
release.

### 2. Start a release from GitHub Actions

Open **Actions → Release → Run workflow** on the default branch and enter the
version without the leading `v` (for example, `0.1.2`). For a new release, use
a stable `major.minor.patch` version greater than the current `VERSION` in
`Config/app.env`. To retry a failed version after its tag and release have been
cleared, enter that same version; `BUILD` still increments.

The workflow first checks that the selected default-branch commit is current
and that neither a tag nor a GitHub release already uses `v<version>`. It then
increments `BUILD`, updates `VERSION` and `BUILD` in `Config/app.env`, and pushes
a version commit to a release branch, then tries to open a pull request for it.
Review and merge the PR using the normal checks and approval rules. This keeps
the version commit on `main` without bypassing branch protection.

If GitHub blocks `GITHUB_TOKEN` from creating the PR with the expected
permission error, the workflow succeeds with a warning, leaves the commit on
its release branch, and puts a compare link in the run summary. Open that link
and create the PR manually; the release does not start until the PR is merged.
Unexpected PR-creation errors still fail the run and include the same recovery
link. A repository admin can review the setting under **Settings → Actions →
General → Allow GitHub Actions to create and approve pull requests**. GitHub may
require a maintainer to approve the CI runs created by a bot PR before they can
satisfy required checks.

Merging the version PR to `main` starts the release build for the resulting
merge commit. Ordinary code merges do not start a release. The workflow:

- runs `scripts/release.sh` in tag mode: all checks, the build, signing, the
  bundle checks and the DMG verification described in `release.sh` below;
- attests the DMG, pushes tag `v<version>`, and creates a **draft** release with the DMG,
  `SHA256SUMS.txt`, `appcast.xml` and generated notes.

Review and test the draft, then publish it in GitHub. A regular merge can happen
at any time; the release includes the code on `main` when its version commit is
merged. If a build fails and leaves no tag or release, run **Release → Run
workflow** again with the same version to create a PR that increments `BUILD`;
merge it to retry. The workflow removes its own tag only when GitHub confirms
that no release exists for it. If a release exists or GitHub cannot confirm its
state, the workflow leaves the release and tag untouched; inspect and resolve
that state before retrying. `BUILD` always goes up.

The published [v0.1.1 release](https://github.com/zerodoxxx/focusnotes/releases/tag/v0.1.1)
already uses that version, so it cannot be reused. Choose an unused version
such as `0.1.2` for the next release.

The workflow writes only to a release branch and opens a PR; the version commit
reaches the default branch through the usual review and merge process. Its
release job runs only for a push to `main` that changes `Config/app.env`.

You can also build on your Mac with `scripts/release.sh`. Run it on a clean tree
at the bump commit, with no local or remote tag `v<version>`. The script creates
the tag, and you then push it with `git push origin v<version>` and create the
draft as in step 4 below.

The release script:

- refuses a dirty working tree, a local tag `v<version>`, or a tag already on `origin`
  (in tag mode it requires the local tag to point at `HEAD` instead);
- unlocks the signing keychain;
- runs all checks (`CoreChecks`, `CaptureChecks`, `OverlayGallery --check`,
  `ModelInstallChecks`, `EmbedChecks`). `EmbedChecks` must not SKIP;
- builds and signs the app;
- checks the bundle: `codesign --verify --strict`, the signing Authority,
  arm64 binaries, no local build paths, version and build numbers, bundled
  licenses, and that the designated requirement equals `Config/signing-requirement.txt`;
- writes to `dist/`:
  - `focusnotes-<version>-arm64.dmg`
  - `SHA256SUMS.txt`
  - `appcast.xml` (the Sparkle feed, EdDSA-signed);
- verifies the mounted DMG (signed app, `Applications` link).

If any step fails, fix the cause and run again. Do not hand-edit `dist/`.

### 3. Smoke-test the draft on a fresh macOS user account

Download the DMG from the draft release. Use a clean macOS account, not your
everyday one.

1. Install from the DMG and get past Gatekeeper with **System Settings → Privacy &
   Security → Open Anyway**.
2. In the permission guide panel, grant Accessibility and Screen Recording.
3. Download the semantic model from inside the app and wait for it to complete.
4. Update in place from the previous version (install the previous DMG first,
   then open the new one). Check that permissions are kept and
   **Check for Updates…** finds the new version.

If any step fails, do not publish. Fix it, bump `BUILD` in a new change, merge
it, and start again.

### 4. Create the draft by hand (local builds only)

Skip this step when the workflow created the draft. After a local
`scripts/release.sh` build and `git push origin v<version>`:

```sh
gh release create v<version> --draft --verify-tag --title "focusnotes <version>" \
  --notes-file <notes.md> \
  dist/focusnotes-<version>-arm64.dmg dist/SHA256SUMS.txt dist/appcast.xml
```

`<notes.md>` is the release notes for this version, for example taken from
`CHANGELOG.md`. Keep it outside the repository.

### 5. Publish the draft

Publish the draft in the GitHub UI or with `gh release edit v<version> --draft=false`.
Only then does `releases/latest/download/appcast.xml` point to this release, so
existing users are offered the update.

## Windows release prerequisites

The Windows edition is implemented, but the currently published [v0.1.1](https://github.com/zerodoxxx/focusnotes/releases/tag/v0.1.1)
and [v0.1.0](https://github.com/zerodoxxx/focusnotes/releases/tag/v0.1.0) releases contain macOS DMGs and checksums,
with no Windows assets. The release workflow now builds both Windows architectures on every release push, whether or
not Authenticode signing is configured. Without it, Windows installers are unsigned; SmartScreen may warn and Smart
App Control may block the app when it cannot confirm the app is safe. Do not disable Windows protections to install
focusnotes. See the [README](../README.md#windows-install-notes) for the user-facing limitation.

Windows update signing is still required independently of Authenticode. The gate fails if the committed public key
set or the `WINDOWS_UPDATE_ED_KEY_1` private secret is missing. The release job signs each update index with K1 and
verifies it against the public keys before attaching the Windows assets to the same draft as the macOS build.

Setting up these prerequisites is a maintainer task; agents never handle the secrets.

| Item | Kind | Purpose |
| --- | --- | --- |
| `WINDOWS_UPDATE_ED_KEY_1` | Secret | Private half of update key K1, used by the Mac release job to sign each `releases.win-*.json`. |
| `WINDOWS_UPDATE_ED_KEYS` | `Config/app.env` | Public keys the app trusts, as `<keyId>:<base64>` entries. Committed. |
| `SIGNPATH_API_TOKEN` | Optional secret | Used only when enabling Authenticode signing. |
| `WINDOWS_SIGN_TEMPLATE` | Optional secret | The `vpk --signTemplate` command line. It must read the token from the environment (for example `%SIGNPATH_API_TOKEN%`), never inline. |
| `WINDOWS_SIGNER_THUMBPRINTS` | Optional repository variable | Comma-separated expected signer thumbprints; required with the two optional signing secrets to enforce the signing inventory. |

Leave all three optional Authenticode settings unset to build and release unsigned Windows installers. If any one is
set, all three must be set; an incomplete signing configuration fails the gate instead of falling back to unsigned.
`WINDOWS_UPDATE_ED_KEYS` and `WINDOWS_UPDATE_ED_KEY_1` remain required in either mode. The Windows signing inventory
is enforced when Authenticode is configured and report-only in unsigned mode.

### Optional SignPath Foundation signing

SignPath Foundation offers a free OSS subscription, but approval is discretionary. Its published requirements include
an OSI-approved license without commercial dual licensing, no proprietary components, active maintenance, documented
platform functionality, and an existing release in the form to be signed. The terms set no numeric project-age, star,
or download threshold; downloadable executables still need verifiable project reputation. FocusNotes has public macOS
releases but no Windows release, so ask the Foundation whether it can assess a Windows candidate before its first
public release; the published terms do not guarantee an exception. Apply at [SignPath Foundation](https://signpath.org/apply)
and include the [public repository](https://github.com/zerodoxxx/focusnotes), [`LICENSE`](../LICENSE),
[third-party notices](../THIRD_PARTY_NOTICES.md), [published releases](https://github.com/zerodoxxx/focusnotes/releases),
[Windows CI workflow](https://github.com/zerodoxxx/focusnotes/actions/workflows/checks.yml), and the Windows edition
details and source-build route in the [README](../README.md#windows-support) and
[contributing guide](../CONTRIBUTING.md#windows). See the [eligibility terms](https://signpath.org/terms).

Before applying, enable MFA for GitHub and SignPath, define author, reviewer and signing-approver roles with their
members, and publish a “Code signing policy” with team and privacy details on the project home page and Windows
download page. State that signing enrollment is pending; do not imply SignPath Foundation sponsorship. If accepted,
add this required attribution to those pages before distributing signed builds: “Free code signing provided by
SignPath.io, certificate by SignPath Foundation”. Require manual approval for each release signing request. See the
[Foundation terms](https://signpath.org/terms) for the policy requirements.

Foundation signing uses SignPath's GitHub trusted-build integration: configure the GitHub trusted build system, run
the OSS signing build on GitHub-hosted agents, upload the unsigned artifact to GitHub Actions, then submit that artifact
through SignPath's action and retrieve the signed output. The action needs the SignPath organization, project and
signing-policy identifiers plus a token with submitter permission. Enable origin verification and review the repo,
branch, commit and job metadata. The current VPK
`--signTemplate` path in [`pack.ps1`](../windows/scripts/pack.ps1) has not been established as this Foundation-approved
integration, so adapt and verify the workflow after a project and signing policy are approved. Follow the official
[GitHub integration](https://docs.signpath.io/trusted-build-systems/github) and [origin verification](https://docs.signpath.io/origin-verification/)
guides. The Windows Ed25519 update-index keys above are separate from Authenticode code signing.

### Windows update keys (K1 and K2)

The Windows update index is signed with Ed25519 keys that are separate from the Sparkle key, so a Mac key compromise
cannot extend to Windows. Every Windows build trusts two keys from the start: an online key (K1) and an offline
standby (K2).

```sh
scripts/make-windows-update-key.sh 1   # K1: online signing key
scripts/make-windows-update-key.sh 2   # K2: offline rotation key
```

Each run generates a key, writes the private half to a mode-0600 backup file `~/<app name>-windows-update-key-K<n>.txt`
(never printed), and appends the public half to `WINDOWS_UPDATE_ED_KEYS` in `Config/app.env`. Run it on the
maintainer's machine, never in CI. Then:

1. Store the K1 backup as the `WINDOWS_UPDATE_ED_KEY_1` secret.
2. Back K2 up separately and keep it out of CI until it is needed.
3. Delete both backup files after they are in the password manager, and commit `Config/app.env`.

The signature covers the exact index bytes and the channel, and installed copies refuse an index signed by an unknown
or dropped key, so never remove a key from `Config/app.env` without a release that trusts its replacement.

- **Planned rotation.** Sign with K2, ship a release that trusts K2 and a new K3, and later drop K1.
- **K1 compromise.** Ship an emergency release signed with K2 that drops K1 and adds a new standby. Installed copies
  already trust K2 and move over automatically.
- **Both keys lost.** Delete the affected index from the release assets so installed copies fail closed ("Update check
  failed") and never trust a new key, say so in the release notes, and have users reinstall from the new signed
  `Setup.exe`. Their notes and app state are kept.

Authenticode certificate renewals do not affect updates, because the app trusts the index key, not a certificate.

### What a Windows release contains

For each of `win-x64` and `win-arm64`, the Windows matrix packs `<app name>-win-<arch>-Setup.exe`, the full and delta
`.nupkg` files, `releases.win-<arch>.json` and `assets.win-<arch>.json`. The Mac `release` job downloads them, rejects
duplicate asset names across architectures, signs and verifies each `releases.win-*.json` (writing the `.sig` beside
it), adds all Windows files to `SHA256SUMS.txt`, attests the DMG and Windows binaries, and uploads everything to the
same draft release. This artifact flow runs whether or not Authenticode signing is configured.

### Signing inventory

Before upload, `windows/scripts/signing-inventory.ps1` installs each architecture's `Setup.exe`, then lists every
`.exe` and `.dll` in the installed layout and in every shipped installer artifact and writes
`signing-inventory-<arch>.json` (path, SHA-256, signer, chain). In enforced mode, every file must be one of:

1. **Ours**, signed by a certificate whose thumbprint is in `WINDOWS_SIGNER_THUMBPRINTS`.
2. **Vendor-signed** with a Trusted Root chain.
3. **An unmodified upstream binary** whose hash is on `windows/scripts/upstream-allowlist.json`.

When Authenticode signing is configured, the workflow passes `-Enforce`; anything else fails the release. With no
Authenticode configuration, the inventory runs report-only and unsigned FocusNotes binaries are expected. When a
dependency update changes an allow-listed binary, review it and update the allow-list in the same PR. Report-only mode
also runs in the full `checks.yml` profile when explicitly requested.

## Rollback

Sparkle never downgrades. To roll back a bad release, publish a new release
with a higher `VERSION` and `BUILD`, containing the fix or the previous code.

Deleting or unpublishing the bad release makes the feed point at the previous
latest release. That stops new updates, but it does not reach users who
already installed the bad build.

## CI

CI is set up but gated. The workflows run on GitHub Actions.

The checks workflow runs on the `xcode-27` GitHub-hosted runner (Xcode 27,
Swift 6.4) and checks that toolchain before it builds. The release workflow
uses `ubuntu-latest` to prepare a version branch and PR, then builds on
`xcode-27` after that PR changes `Config/app.env` on `main`.

- `.github/workflows/checks.yml` runs builds and tests only on request. Add `run-ci` to a PR for lean checks of changed platforms, or use a manual lean run for both platforms. Normal pushes do not start native checks. Add `run-ci-full`, or select Full checks in the manual workflow, for model-backed checks, performance workloads, galleries, both Windows architectures, packaging/update tests and the older-macOS smoke test. `skip-ci` permits merging with intentionally skipped required PR checks and no runner jobs; it does not waive maintainer approval or signed-release validation. Run the full profile before a release; local hooks validate only the developer's host platform. See [Choosing CI checks](../CONTRIBUTING.md#choosing-ci-checks).
- `.github/workflows/release.yml` runs only when manually started with a
  version input to prepare a version commit and PR. After that PR is merged,
  the workflow imports the signing identity from secrets, builds the merge
  commit with `scripts/release.sh` in tag mode, attests the DMG, and creates the
  draft release. A failed run removes only its own tag when no release exists
  for it; existing releases and tags are left untouched.

Secrets and Windows signing settings used by `release.yml`:

| Secret | Purpose |
| --- | --- |
| `SIGNING_P12_BASE64` | The signing identity `.p12`, base64-encoded |
| `SIGNING_P12_PASSWORD` | Password for the `.p12` |
| `SIGNING_KEYCHAIN_PASSWORD` | Password for the CI keychain |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle EdDSA private key for `appcast.xml` |
| `WINDOWS_UPDATE_ED_KEY_1` | Required Windows update-index signing key; see [Windows release prerequisites](#windows-release-prerequisites). |
| `SIGNPATH_API_TOKEN`, `WINDOWS_SIGN_TEMPLATE`, `WINDOWS_SIGNER_THUMBPRINTS` | Optional Authenticode signing configuration. Set all three to sign and enforce the inventory, or leave all three unset for unsigned installers. |

The maintainer still smoke-tests the draft and publishes it manually.

The repository variable `WINDOWS_SIGNER_THUMBPRINTS` is read by the Windows signing inventory when Authenticode signing is configured.

### `release.sh` environment variables

| Variable | Effect |
| --- | --- |
| `RELEASE_FROM_TAG` | Set to `1` for tag mode: releases the existing local tag `v<version>`, which must point at `HEAD`. Otherwise the script creates the tag and refuses if it already exists locally or on origin. |
| `SIGNING_KEYCHAIN_PASSWORD` | Unlocks the signing keychain non-interactively. If unset, the script asks the keychain to unlock. |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle EdDSA private key for `appcast.xml`. If unset, the script reads it from the login Keychain. |

In release mode the script always uses the dedicated `<app> Release Signing`
identity. An ambient `SIGN_IDENTITY` is ignored.

## Testing builds

`release.sh --adhoc` makes an ad-hoc signed test DMG:

```sh
scripts/release.sh --adhoc
```

It skips the release guards (clean tree, tag check, identity check) and the
appcast. The DMG is named `focusnotes-<version>-arm64-adhoc.dmg`.

Never publish an ad-hoc build. Do not attach it to a release, and do not point
the appcast at it.
