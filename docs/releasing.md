# Releasing focusnotes

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

### 1. Bump the version and commit

In `Config/app.env`, set `VERSION` and increase `BUILD`. `BUILD` must always go up.
Update `CHANGELOG.md`, then commit. The tree must be clean before the next step.

### 2. Build with `scripts/release.sh`

```sh
scripts/release.sh
```

The script:

- refuses a dirty working tree, a local tag `v<version>`, or a tag already on `origin`;
- unlocks the signing keychain;
- runs all checks (`CoreChecks`, `CaptureChecks`, `OverlayGallery --check`,
  `check-name.sh`, `ModelInstallChecks`, `EmbedChecks`). `EmbedChecks` must not SKIP;
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

### 3. Smoke-test on a fresh macOS user account

Use a clean macOS account, not your everyday one.

1. Install from the DMG and get past Gatekeeper with **System Settings → Privacy &
   Security → Open Anyway**.
2. In the permission guide panel, grant Accessibility and Screen Recording.
3. Download the semantic model from inside the app and wait for it to complete.
4. Update in place from the previous version (install the previous DMG first,
   then open the new one). Check that permissions are kept and
   **Check for Updates…** finds the new version.

If any step fails, do not publish. Fix it, bump `BUILD`, and start again.

### 4. Tag and create a draft release

```sh
git tag v<version>
git push origin v<version>
gh release create v<version> --draft --title "focusnotes <version>" \
  --notes-file <notes.md> \
  dist/focusnotes-<version>-arm64.dmg dist/SHA256SUMS.txt dist/appcast.xml
```

`<notes.md>` is the release notes for this version, for example taken from
`CHANGELOG.md`. Keep it outside the repository.

### 5. Publish the draft

Publish the draft in the GitHub UI or with `gh release edit v<version> --draft=false`.
Only then does `releases/latest/download/appcast.xml` point to this release, so
existing users are offered the update.

## Rollback

Sparkle never downgrades. To roll back a bad release, publish a new release
with a higher `VERSION` and `BUILD`, containing the fix or the previous code.

Deleting or unpublishing the bad release makes the feed point at the previous
latest release. That stops new updates, but it does not reach users who
already installed the bad build.

## CI

CI is set up but gated. The workflows run on GitHub Actions.

- `.github/workflows/checks.yml` runs the checks on pushes and pull requests.
- `.github/workflows/release.yml` runs on `v*` tags. It imports the signing
  identity from secrets, builds with `scripts/release.sh` in tag mode, attests
  the DMG, and creates the draft release.

Secrets used by `release.yml`:

| Secret | Purpose |
| --- | --- |
| `SIGNING_P12_BASE64` | The signing identity `.p12`, base64-encoded |
| `SIGNING_P12_PASSWORD` | Password for the `.p12` |
| `SIGNING_KEYCHAIN_PASSWORD` | Password for the CI keychain |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle EdDSA private key for `appcast.xml` |

The maintainer still smoke-tests the draft and publishes it manually.

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
