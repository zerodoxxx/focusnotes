#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/app-path-safety.XXXXXX")"
TEMP_ROOT="$(cd "$TEMP_ROOT" && pwd -P)"
trap 'rm -rf "$TEMP_ROOT"' EXIT

FIXTURE="$TEMP_ROOT/project"
FAKE_BIN="$TEMP_ROOT/fake-bin"
SWIFT_BIN="$TEMP_ROOT/swift-bin"
MOCK_LOG="$TEMP_ROOT/mock.log"
export FIXTURE
mkdir -p "$FIXTURE/scripts" "$FIXTURE/Config" "$FIXTURE/assets/icons" "$FIXTURE/licenses" "$FAKE_BIN" "$SWIFT_BIN" "$TEMP_ROOT/outside.app" "$TEMP_ROOT/home"
cp "$SCRIPT_DIR/build-app.sh" "$SCRIPT_DIR/run-app.sh" "$SCRIPT_DIR/check-app-path.py" "$FIXTURE/scripts/"
touch "$SWIFT_BIN/App" "$SWIFT_BIN/EmbedHelper"
touch "$FIXTURE/assets/icons/AppIcon.icns" "$FIXTURE/assets/icons/MenuBarIcon.pdf" "$FIXTURE/assets/icons/MenuBarIcon-active.pdf"
touch "$FIXTURE/licenses/Apache-2.0.txt" "$FIXTURE/licenses/EmbeddingGemma2-NOTICE.txt" "$FIXTURE/LICENSE" "$FIXTURE/THIRD_PARTY_NOTICES.md"

cat > "$FAKE_BIN/swift" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'swift %s\n' "$*" >> "$MOCK_LOG"
for arg in "$@"; do
    if [[ "$arg" == "--show-bin-path" ]]; then
        printf '%s\n' "$SWIFT_BIN"
        exit 0
    fi
done

# A real SwiftPM build resolves Sparkle into .build/artifacts. Keep that
# package output local to the fixture so this test never needs Swift or network
# access to validate the bundle assembly path.
mkdir -p "$FIXTURE/.build/artifacts/sparkle/Sparkle/macos-arm64_x86_64/Sparkle.framework/Versions/B"
printf 'fixture Sparkle binary\n' > "$FIXTURE/.build/artifacts/sparkle/Sparkle/macos-arm64_x86_64/Sparkle.framework/Versions/B/Sparkle"
SH

cat > "$FAKE_BIN/plutil" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat > "$FAKE_BIN/codesign" <<'SH'
#!/usr/bin/env bash
printf 'codesign %s\n' "$*" >> "$MOCK_LOG"
SH

cat > "$FAKE_BIN/ditto" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'ditto %s\n' "$*" >> "$MOCK_LOG"
cp -R "$1" "$2"
SH

cat > "$FAKE_BIN/otool" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'otool %s\n' "$*" >> "$MOCK_LOG"
case "$1" in
    -l)
        cat <<EOF
Load command 1
          cmd LC_RPATH
      cmdsize 32
         path $FIXTURE/.build/checkouts/Sparkle (offset 12)
Load command 2
          cmd LC_RPATH
      cmdsize 32
         path /Users/fixture/Library/Frameworks (offset 12)
EOF
        ;;
    -L)
        printf '%s:\n' "$2"
        if [[ "$2" == */EmbedHelper ]]; then
            printf '\t/usr/lib/libSystem.B.dylib\n'
        else
            printf '\t@rpath/Sparkle.framework/Versions/B/Sparkle\n'
        fi
        ;;
    *)
        exit 2
        ;;
esac
SH

cat > "$FAKE_BIN/install_name_tool" <<'SH'
#!/usr/bin/env bash
printf 'install_name_tool %s\n' "$*" >> "$MOCK_LOG"
SH

chmod +x "$FAKE_BIN/swift" "$FAKE_BIN/plutil" "$FAKE_BIN/codesign" "$FAKE_BIN/ditto" "$FAKE_BIN/otool" "$FAKE_BIN/install_name_tool"

write_config() {
    cat > "$FIXTURE/Config/app.env" <<EOF
APPNAME=$1
BUNDLE_PREFIX=com.example
VERSION=0.1.0
BUILD=1
MIN_MACOS=14.0
EOF
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

CURRENT_APPNAME=""
while IFS= read -r line; do key="${line%%=*}"; value="${line#*=}"
    if [[ "$key" == "APPNAME" ]]; then
        CURRENT_APPNAME="$value"
    fi
done < "$SCRIPT_DIR/../Config/app.env"
[[ -n "$CURRENT_APPNAME" ]] || fail "Config/app.env does not define APPNAME"

# A traversal name must fail before Swift runs and preserve the path it would
# otherwise have selected for recursive cleanup.
write_config ../../outside
printf 'keep me\n' > "$TEMP_ROOT/outside.app/sentinel"
if PATH="$FAKE_BIN:$PATH" MOCK_LOG="$MOCK_LOG" SWIFT_BIN="$SWIFT_BIN" \
    "$FIXTURE/scripts/build-app.sh" > "$TEMP_ROOT/invalid-build.out" 2>&1; then
    fail "build accepted a traversal APPNAME"
fi
[[ -f "$TEMP_ROOT/outside.app/sentinel" ]] || fail "invalid build removed the escaped sentinel"
[[ ! -e "$MOCK_LOG" ]] || fail "invalid build invoked Swift before rejecting APPNAME"

# SwiftPM's output directory must also remain a real directory inside the checkout.
write_config "$CURRENT_APPNAME"
mkdir -p "$TEMP_ROOT/swift-escape"
printf 'keep me\n' > "$TEMP_ROOT/swift-escape/sentinel"
ln -s "$TEMP_ROOT/swift-escape" "$FIXTURE/.build"
if PATH="$FAKE_BIN:$PATH" MOCK_LOG="$MOCK_LOG" SWIFT_BIN="$SWIFT_BIN" \
    "$FIXTURE/scripts/build-app.sh" > "$TEMP_ROOT/symlink-build.out" 2>&1; then
    fail "build accepted a symlinked SwiftPM output directory"
fi
[[ -f "$TEMP_ROOT/swift-escape/sentinel" ]] || fail "symlinked SwiftPM output check changed its target"
[[ ! -e "$MOCK_LOG" ]] || fail "build invoked Swift before rejecting its output directory"
rm "$FIXTURE/.build"

# The repository's current app name remains valid and produces only a fixture bundle.
write_config "$CURRENT_APPNAME"
PATH="$FAKE_BIN:$PATH" MOCK_LOG="$MOCK_LOG" SWIFT_BIN="$SWIFT_BIN" \
    "$FIXTURE/scripts/build-app.sh" > "$TEMP_ROOT/valid-build.out"
[[ -f "$FIXTURE/build/$CURRENT_APPNAME.app/Contents/MacOS/$CURRENT_APPNAME" ]] || fail "valid app name did not produce the expected fixture bundle"
[[ -f "$FIXTURE/build/$CURRENT_APPNAME.app/Contents/MacOS/EmbedHelper" ]] || fail "valid build omitted EmbedHelper"
SPARKLE_SOURCE="$FIXTURE/.build/artifacts/sparkle/Sparkle/macos-arm64_x86_64/Sparkle.framework"
SPARKLE_BUNDLE="$FIXTURE/build/$CURRENT_APPNAME.app/Contents/Frameworks/Sparkle.framework"
[[ -f "$SPARKLE_BUNDLE/Versions/B/Sparkle" ]] || fail "valid build did not embed the fixture Sparkle framework"
grep -Fq "ditto $SPARKLE_SOURCE $SPARKLE_BUNDLE" "$MOCK_LOG" || fail "valid build did not copy the discovered Sparkle artifact"
grep -Fq "install_name_tool -delete_rpath $FIXTURE/.build/checkouts/Sparkle" "$MOCK_LOG" || fail "valid build did not remove the SwiftPM build rpath"
grep -Fq "install_name_tool -delete_rpath /Users/fixture/Library/Frameworks" "$MOCK_LOG" || fail "valid build did not remove the developer-home rpath"
grep -Fq "install_name_tool -add_rpath @executable_path/../Frameworks" "$MOCK_LOG" || fail "valid build did not add the embedded-framework rpath"

# The install wrapper rejects the name before calling even a stub build command.
mv "$FIXTURE/scripts/build-app.sh" "$FIXTURE/scripts/build-app.real"
cat > "$FIXTURE/scripts/build-app.sh" <<'SH'
#!/usr/bin/env bash
printf 'called\n' >> "$BUILD_STUB_LOG"
SH
chmod +x "$FIXTURE/scripts/build-app.sh"
write_config ../../outside
if PATH="$FAKE_BIN:$PATH" HOME="$TEMP_ROOT/home" BUILD_STUB_LOG="$TEMP_ROOT/build-stub.log" \
    "$FIXTURE/scripts/run-app.sh" > "$TEMP_ROOT/invalid-run.out" 2>&1; then
    fail "run accepted a traversal APPNAME"
fi
[[ ! -e "$TEMP_ROOT/build-stub.log" ]] || fail "run invoked its build before rejecting APPNAME"

# A symlinked parent must be rejected without changing anything in its target.
mkdir -p "$TEMP_ROOT/install-escape"
printf 'keep me\n' > "$TEMP_ROOT/install-escape/sentinel"
ln -s "$TEMP_ROOT/install-escape" "$TEMP_ROOT/home/Applications"
if python3 "$SCRIPT_DIR/check-app-path.py" "$CURRENT_APPNAME" "$TEMP_ROOT/home/Applications" > "$TEMP_ROOT/symlink.out" 2>&1; then
    fail "path checker accepted a symlinked install parent"
fi
[[ -f "$TEMP_ROOT/install-escape/sentinel" ]] || fail "symlink-parent check changed its target"

python3 "$SCRIPT_DIR/check-app-path.py" Demo_2-test "$TEMP_ROOT/new-install-parent"
printf 'App path safety checks passed.\n'
