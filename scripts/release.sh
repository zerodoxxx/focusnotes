#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

usage() {
    printf 'Usage: %s [--adhoc]\n' "$0" >&2
    exit 2
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

ADHOC=0
case "$#" in
    0) ;;
    1) [[ "$1" == "--adhoc" ]] && ADHOC=1 || usage ;;
    *) usage ;;
esac

while IFS= read -r line; do key="${line%%=*}"; value="${line#*=}"
    case "$key" in
        APPNAME) APPNAME="$value" ;;
        VERSION) VERSION="$value" ;;
        BUILD) BUILD="$value" ;;
        GITHUB_REPO) GITHUB_REPO="$value" ;;
        SPARKLE_PUBLIC_ED_KEY) SPARKLE_PUBLIC_ED_KEY="$value" ;;
    esac
done < "$ROOT_DIR/Config/app.env"

REQ_FILE="$ROOT_DIR/Config/signing-requirement.txt"
SIGN_KEYCHAIN="${SIGN_KEYCHAIN:-$HOME/Library/Keychains/$APPNAME-signing.keychain-db}"

if [[ "$ADHOC" == 1 ]]; then
    MODE="adhoc (local or CI test build, not for release)"
    unset SIGN_IDENTITY SIGN_KEYCHAIN
    export SIGN_ADHOC=1
    DMG_NAME="$APPNAME-$VERSION-arm64-adhoc.dmg"
else
    MODE="release"
    DMG_NAME="$APPNAME-$VERSION-arm64.dmg"
fi
printf 'Mode: %s\n' "$MODE"
printf 'App: %s %s (build %s)\n' "$APPNAME" "$VERSION" "$BUILD"

cd "$ROOT_DIR"

# Guards (release mode only). These run before any check or build.
if [[ "$ADHOC" == 0 ]]; then
    # Releases use the dedicated identity unless SIGN_IDENTITY is set explicitly in the environment.
    SIGN_IDENTITY="${SIGN_IDENTITY:-$APPNAME Release Signing}"
    export SIGN_IDENTITY SIGN_KEYCHAIN

    [[ -f "$SIGN_KEYCHAIN" && ! -L "$SIGN_KEYCHAIN" ]] || fail "release signing keychain not found: $SIGN_KEYCHAIN. Restore it with scripts/import-signing-identity.sh <identity.p12>, or create it once with scripts/make-signing-identity.sh (never replace an existing identity)."
    [[ -f "$REQ_FILE" ]] || fail "missing $REQ_FILE; the signing requirement must be committed."

    [[ -n "${GITHUB_REPO:-}" ]] || fail "GITHUB_REPO is empty in Config/app.env."
    [[ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]] || fail "SPARKLE_PUBLIC_ED_KEY is empty in Config/app.env; run scripts/make-update-key.sh."

    SPARKLE_BIN="$("$ROOT_DIR/scripts/fetch-sparkle-tools.sh")"
    if [[ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
        "$SPARKLE_BIN/generate_keys" --account "$APPNAME" -p >/dev/null 2>&1 \
            || fail "no Sparkle private key for account $APPNAME in the login Keychain, and SPARKLE_ED_PRIVATE_KEY is not set; run scripts/make-update-key.sh."
    fi

    if [[ -n "${SIGNING_KEYCHAIN_PASSWORD:-}" ]]; then
        security unlock-keychain -p "$SIGNING_KEYCHAIN_PASSWORD" "$SIGN_KEYCHAIN" || fail "could not unlock $SIGN_KEYCHAIN"
    else
        security unlock-keychain "$SIGN_KEYCHAIN" || fail "could not unlock $SIGN_KEYCHAIN"
    fi

    identities="$(security find-identity -p codesigning "$SIGN_KEYCHAIN")" || fail "could not list code signing identities in $SIGN_KEYCHAIN"
    grep -Fq -- "\"$SIGN_IDENTITY\"" <<<"$identities" || fail "signing identity not found in $SIGN_KEYCHAIN: $SIGN_IDENTITY"

    [[ -z "$(git -C "$ROOT_DIR" status --porcelain)" ]] || fail "git working tree is not clean; commit or stash changes first."

    if [[ "${RELEASE_FROM_TAG:-0}" == 1 ]]; then
        # Tag mode: release the already-tagged commit, which must be the one checked out.
        printf 'tag mode: releasing existing tag v%s\n' "$VERSION"
        tag_commit="$(git -C "$ROOT_DIR" rev-parse -q --verify "v$VERSION^{commit}")" || fail "local tag v$VERSION does not exist."
        [[ "$tag_commit" == "$(git -C "$ROOT_DIR" rev-parse HEAD)" ]] || fail "HEAD is not the commit tagged v$VERSION; check out the tag first."
    else
        [[ -z "$(git -C "$ROOT_DIR" tag -l "v$VERSION")" ]] || fail "local tag v$VERSION already exists."

        remote_tag="$(git -C "$ROOT_DIR" ls-remote --tags origin "refs/tags/v$VERSION")" || fail "could not query tags on origin"
        [[ -z "$remote_tag" ]] || fail "tag v$VERSION already exists on origin."
    fi
fi

EMBED_LOG=""
MNT=""
ATTACHED=0
APPCAST_SRC=""
cleanup() {
    if [[ "$ATTACHED" == 1 ]]; then
        hdiutil detach "$MNT" -quiet >/dev/null 2>&1 \
            || hdiutil detach "$MNT" -force -quiet >/dev/null 2>&1 \
            || true
        ATTACHED=0
    fi
    if [[ -n "$MNT" && -d "$MNT" ]]; then
        rmdir "$MNT" 2>/dev/null || true
    fi
    if [[ -n "$EMBED_LOG" ]]; then
        rm -f "$EMBED_LOG"
    fi
    if [[ -n "$APPCAST_SRC" && -d "$APPCAST_SRC" && ! -L "$APPCAST_SRC" ]]; then
        case "$APPCAST_SRC" in
            "$ROOT_DIR/dist/"*) rm -rf "$APPCAST_SRC" ;;
        esac
    fi
}
trap cleanup EXIT

# Checks, in order. The first failure stops the script (set -e).
printf '==> swift run CoreChecks\n'
swift run CoreChecks

printf '==> swift run CaptureChecks\n'
swift run CaptureChecks

printf '==> swift run OverlayGallery --check\n'
swift run OverlayGallery --check

printf '==> swift run ModelInstallChecks\n'
swift run ModelInstallChecks

printf '==> swift run EmbedChecks\n'
swift build --product EmbedHelper
EMBED_LOG="$(mktemp "${TMPDIR:-/tmp}/release-embedchecks.XXXXXX")"
swift run EmbedChecks 2>&1 | tee "$EMBED_LOG"
if [[ "$ADHOC" == 0 ]] && grep -Fq 'SKIP' "$EMBED_LOG"; then
    fail "EmbedChecks output contains SKIP; a release must run the model-backed checks."
fi

# Signed release build (identity and keychain are exported above; ad-hoc mode sets SIGN_ADHOC=1).
printf '==> scripts/build-app.sh release\n'
"$ROOT_DIR/scripts/build-app.sh" release

BUNDLE="$ROOT_DIR/build/$APPNAME.app"
MACOS="$BUNDLE/Contents/MacOS"
RES="$BUNDLE/Contents/Resources"
PLIST="$BUNDLE/Contents/Info.plist"

check() {
    local name="$1"
    shift
    if "$@"; then
        printf 'PASS  %s\n' "$name"
    else
        printf 'FAIL  %s\n' "$name"
        exit 1
    fi
}

check_codesign_verify() {
    codesign --verify --strict --verbose=2 "$BUNDLE"
}

check_signing_requirement() {
    local got want
    want="$(head -n 1 "$REQ_FILE")"
    got="$(codesign -d -r- "$BUNDLE" 2>&1 | sed -n 's/^designated => //p' | head -n 1)"
    if [[ "$got" != "$want" ]]; then
        printf 'signing requirement changed; every user'"'"'s Accessibility and Screen Recording permissions would reset\n' >&2
        printf '  expected: %s\n  got:      %s\n' "$want" "$got" >&2
        return 1
    fi
}

check_signature_identity() {
    local info
    info="$(codesign -dvv "$BUNDLE" 2>&1)" || return 1
    if [[ "$ADHOC" == 1 ]]; then
        grep -Fq 'Signature=adhoc' <<<"$info"
    else
        grep -Fxq "Authority=$SIGN_IDENTITY" <<<"$info"
    fi
}

check_archs() {
    local bin
    for bin in "$APPNAME" EmbedHelper; do
        [[ "$(lipo -archs "$MACOS/$bin" 2>/dev/null)" == "arm64" ]] || return 1
    done
}

check_no_build_paths() {
    local bin out
    for bin in "$APPNAME" EmbedHelper; do
        out="$(strings -a "$MACOS/$bin")" || return 1
        if grep -Fq -e '/Users/' -e '/.build/' <<<"$out"; then
            printf 'build path found in strings of %s\n' "$bin" >&2
            return 1
        fi
    done
}

check_no_build_rpaths() {
    local bin out rpaths
    for bin in "$APPNAME" EmbedHelper; do
        out="$(otool -l "$MACOS/$bin")" || return 1
        rpaths="$(awk '/cmd LC_RPATH/{f=1} f && /^ *path /{print; f=0}' <<<"$out")"
        if grep -Fq -e '/Users/' -e '.build' <<<"$rpaths"; then
            printf 'build path in LC_RPATH of %s\n' "$bin" >&2
            return 1
        fi
    done
}

check_plist_value() {
    local key="$1" want="$2" got
    got="$(plutil -extract "$key" raw "$PLIST")" || return 1
    [[ "$got" == "$want" ]]
}

check_resources() {
    local f
    for f in Apache-2.0.txt EmbeddingGemma2-NOTICE.txt LICENSE THIRD_PARTY_NOTICES.md; do
        if [[ ! -f "$RES/$f" ]]; then
            printf 'missing resource: %s\n' "$f" >&2
            return 1
        fi
    done
}

check_sparkle_framework() {
    local fw="$BUNDLE/Contents/Frameworks/Sparkle.framework"
    if [[ ! -d "$fw" ]]; then
        printf 'missing Sparkle.framework: %s\n' "$fw" >&2
        return 1
    fi
    codesign --verify --strict --verbose=2 "$fw"
}

printf '==> bundle checks: %s\n' "$BUNDLE"
check "codesign --verify --strict" check_codesign_verify
if [[ "$ADHOC" == 1 ]]; then
    check "codesign identity is adhoc" check_signature_identity
else
    check "codesign Authority matches SIGN_IDENTITY" check_signature_identity
    check "designated requirement matches Config/signing-requirement.txt" check_signing_requirement
fi
check "lipo -archs is arm64 (app, EmbedHelper)" check_archs
check "strings contain no /Users/ or /.build/" check_no_build_paths
check "LC_RPATH contains no /Users/ or .build" check_no_build_rpaths
check "CFBundleShortVersionString == $VERSION" check_plist_value CFBundleShortVersionString "$VERSION"
check "CFBundleVersion == $BUILD" check_plist_value CFBundleVersion "$BUILD"
check "license and notice files in Resources" check_resources
check "Sparkle.framework is embedded and signed" check_sparkle_framework
if [[ "$ADHOC" == 0 ]]; then
    check "Info.plist SUPublicEDKey == SPARKLE_PUBLIC_ED_KEY" check_plist_value SUPublicEDKey "$SPARKLE_PUBLIC_ED_KEY"
    check "Info.plist SUFeedURL == latest appcast on GitHub" check_plist_value SUFeedURL "https://github.com/$GITHUB_REPO/releases/latest/download/appcast.xml"
fi

# DMG.
DIST="$ROOT_DIR/dist"
mkdir -p "$DIST"
DIST_REAL="$(cd "$DIST" && pwd -P)"
DMG_PATH="$DIST/$DMG_NAME"

if [[ -e "$DMG_PATH" || -L "$DMG_PATH" ]]; then
    [[ ! -L "$DMG_PATH" && -f "$DMG_PATH" ]] || fail "refusing to remove non-regular file: $DMG_PATH"
    [[ "$(cd "$(dirname "$DMG_PATH")" && pwd -P)" == "$DIST_REAL" ]] || fail "DMG path is not inside dist/: $DMG_PATH"
    rm -f "$DMG_PATH"
fi

printf '==> make-dmg.sh\n'
"$ROOT_DIR/scripts/make-dmg.sh" "$BUNDLE" "$DMG_PATH"

# Checksums, relative names so `shasum -c` works from dist/.
printf '==> SHA256SUMS.txt\n'
(
    cd "$DIST_REAL"
    shasum -a 256 "$DMG_NAME" > SHA256SUMS.txt
    shasum -a 256 -c SHA256SUMS.txt
)

# Appcast (release only): EdDSA-signed, pointing at this release's DMG.
if [[ "$ADHOC" == 0 ]]; then
    printf '==> appcast.xml\n'
    APPCAST="$DIST_REAL/appcast.xml"
    APPCAST_SRC="$DIST_REAL/appcast-src"
    safe_remove_dir() {
        local d="$1" parent
        [[ ! -e "$d" && ! -L "$d" ]] && return 0
        [[ -d "$d" && ! -L "$d" ]] || fail "refusing to remove non-directory: $d"
        parent="$(cd "$(dirname "$d")" && pwd -P)"
        [[ "$parent" == "$DIST_REAL" ]] || fail "refusing to remove outside dist/: $d"
        rm -rf "$d"
    }

    safe_remove_dir "$APPCAST_SRC"
    mkdir "$APPCAST_SRC"
    cp "$DMG_PATH" "$APPCAST_SRC/"

    appcast_args=(--download-url-prefix "https://github.com/$GITHUB_REPO/releases/download/v$VERSION/" --link "https://github.com/$GITHUB_REPO" --maximum-deltas 0 -o "$APPCAST")
    if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
        printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SPARKLE_BIN/generate_appcast" --ed-key-file - "${appcast_args[@]}" "$APPCAST_SRC"
    else
        "$SPARKLE_BIN/generate_appcast" --account "$APPNAME" "${appcast_args[@]}" "$APPCAST_SRC"
    fi
    safe_remove_dir "$APPCAST_SRC"

    [[ -f "$APPCAST" ]] || fail "generate_appcast did not write $APPCAST"
    check "appcast.xml enclosure is EdDSA-signed" grep -Fq 'sparkle:edSignature=' "$APPCAST"
    check "appcast.xml points at $DMG_NAME on release v$VERSION" grep -Fq "url=\"https://github.com/$GITHUB_REPO/releases/download/v$VERSION/$DMG_NAME\"" "$APPCAST"
    check "appcast.xml sparkle:version == $BUILD" grep -Fq "<sparkle:version>$BUILD</sparkle:version>" "$APPCAST"
fi

# Mounted verify: the DMG must contain the signed app and an Applications link.
printf '==> mounted DMG verify\n'
MNT="$(mktemp -d "${TMPDIR:-/tmp}/release-mnt.XXXXXX")"
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG_PATH" >/dev/null
ATTACHED=1

check_mounted_app() {
    codesign --verify --strict --verbose=2 "$MNT/$APPNAME.app"
}

check_mounted_applications_link() {
    [[ -L "$MNT/Applications" && "$(readlink "$MNT/Applications")" == "/Applications" ]]
}

check "mounted $APPNAME.app passes codesign --verify --strict" check_mounted_app
check "mounted Applications is a symlink to /Applications" check_mounted_applications_link

hdiutil detach "$MNT" -quiet >/dev/null
ATTACHED=0

# Summary.
printf '\nDMG: %s\n' "$DMG_PATH"
printf 'Checksum: %s\n' "$(cat "$DIST_REAL/SHA256SUMS.txt")"
if [[ "$ADHOC" == 0 ]]; then
    printf '\nNext step (not run):\n'
    printf '  gh release create v%s --draft --title "%s %s" dist/%s dist/SHA256SUMS.txt dist/appcast.xml\n' "$VERSION" "$APPNAME" "$VERSION" "$DMG_NAME"
else
    printf '\nAdhoc test build complete. Not for release.\n'
fi
