#!/usr/bin/env bash
# Exercise Git range selection and hook installation without building or downloading dependencies.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
temp_root="$(mktemp -d "${TMPDIR:-/tmp}/focusnotes-hooks.XXXXXX")"
trap 'rm -rf "$temp_root"' EXIT
fixture="$temp_root/project"
fake_bin="$temp_root/bin"
export HOOK_TEST_LOG="$temp_root/commands.log"
export HOOK_TEST_HOST=Darwin
export HOOK_TEST_PROJECT="$fixture"
# The performance helper deliberately skips real CI. These fixture commands are
# harmless mocks and must exercise the local path even when this test runs in CI.
unset CI GITHUB_ACTIONS
mkdir -p "$fixture/scripts" "$fixture/.githooks" "$fixture/windows/src" "$fixture/Sources/Core" "$fake_bin"
cp "$script_dir/check-local.sh" "$script_dir/check-performance.sh" "$script_dir/install-hooks.sh" "$fixture/scripts/"
cp "$script_dir/../.githooks/pre-commit" "$script_dir/../.githooks/pre-push" "$fixture/.githooks/"
for helper in test-local-hooks.sh test-app-path-safety.sh; do
  printf '#!/usr/bin/env bash\nprintf "shell-check %%s\\n" "${0##*/}" >> "$HOOK_TEST_LOG"\n' > "$fixture/scripts/$helper"
done
printf '# CI selector fixture: executed through a fake Python command.\n' > "$fixture/scripts/test-ci-selection.py"
cat > "$fake_bin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$HOOK_TEST_HOST"
SH
for command in swift dotnet; do
  cat > "$fake_bin/$command" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "$HOOK_TEST_LOG"
if [[ "${HOOK_TEST_FAIL_BUILD:-}" == "1" && "$1" == "build" ]]; then exit 7; fi
if [[ "${HOOK_TEST_DIRTY_BUILD:-}" == "1" && "$1" == "build" ]]; then
  printf 'changed while checking\n' >> "$HOOK_TEST_PROJECT/Sources/Core/Example.swift"
fi
SH
done
for command in python3 python; do
  cat > "$fake_bin/$command" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == '-c' ]]; then
  if [[ "${HOOK_TEST_NO_PYTHON:-}" == 1 || ( "${HOOK_TEST_NO_PYTHON3:-}" == 1 && "${0##*/}" == python3 ) ]]; then exit 1; fi
  exit 0
fi
printf '%s %s\n' "${0##*/}" "$*" >> "$HOOK_TEST_LOG"
SH
done
chmod +x "$fake_bin/"* "$fixture/.githooks/"*
export PATH="$fake_bin:$PATH"
cd "$fixture"
git init -q
git config user.name 'Hook tests'
git config user.email 'hooks@example.invalid'
git config core.autocrlf false
git config core.hooksPath .no-hooks
printf 'initial\n' > README.md
printf 'initial\n' > Sources/Core/Example.swift
printf 'initial\n' > windows/src/Example.cs
git add .
git commit -qm initial
base="$(git rev-parse HEAD)"
git update-ref refs/remotes/origin/main "$base"
zero='0000000000000000000000000000000000000000'

commit_file() {
  printf '%s\n' "$2" >> "$1"
  git add -- "$1"
  git commit -qm "$2"
}
push_update() {
  printf '%s %s %s %s\n' "${4:-refs/heads/topic}" "$1" refs/heads/topic "$2" |
    bash .githooks/pre-push origin https://example.invalid/repo.git > "$temp_root/output" 2>&1
}
expect_empty_log() {
  if [[ -s "$HOOK_TEST_LOG" ]]; then cat "$HOOK_TEST_LOG" >&2; echo "$1" >&2; exit 1; fi
}
expect_line() {
  if ! grep -Fqx -- "$1" "$HOOK_TEST_LOG"; then cat "$HOOK_TEST_LOG" >&2; echo "Missing command: $1" >&2; exit 1; fi
}

# Documentation-only commits, including a new branch, require no compiler.
commit_file README.md docs
docs="$(git rev-parse HEAD)"
: > "$HOOK_TEST_LOG"
push_update "$base" "$zero"
push_update "$docs" "$base"
push_update "$docs" "$zero"
expect_empty_log 'Docs-only pushes ran app checks.'

# Inspect the complete pushed range, even if its last commit only changed docs.
commit_file Sources/Core/Example.swift source
source_tip="$(git rev-parse HEAD)"
commit_file README.md 'docs after source'
tip="$(git rev-parse HEAD)"
: > "$HOOK_TEST_LOG"
push_update "$tip" "$base"
expect_line 'swift build'
expect_line 'python3 scripts/test-ci-selection.py'
expect_line 'swift run --skip-build CoreChecks --skip-performance'
expect_line 'swift run --skip-build CaptureChecks'
expect_line 'swift run --skip-build ModelInstallChecks'
expect_line 'swift run --skip-build EmbedChecks'
expect_line 'swift run --skip-build OverlayGallery --check'
expect_line 'swift run --skip-build CoreChecks --performance-only'
[[ "$(grep -c '^swift build$' "$HOOK_TEST_LOG")" == 1 ]]

# Prefer Python 3, tolerate hosts where it is named python, and fail clearly
# before native builds when neither executable is a Python 3 interpreter.
: > "$HOOK_TEST_LOG"
export HOOK_TEST_NO_PYTHON3=1
push_update "$tip" "$base"
expect_line 'python scripts/test-ci-selection.py'
unset HOOK_TEST_NO_PYTHON3
export HOOK_TEST_NO_PYTHON=1
: > "$HOOK_TEST_LOG"
if push_update "$tip" "$base"; then echo 'Accepted missing Python 3.' >&2; exit 1; fi
if grep -q '^swift ' "$HOOK_TEST_LOG"; then echo 'Built before detecting missing Python 3.' >&2; exit 1; fi
grep -q 'require Python 3' "$temp_root/output"
unset HOOK_TEST_NO_PYTHON

# The same source range is detected for a new branch; HEAD refspecs are supported.
: > "$HOOK_TEST_LOG"
push_update "$tip" "$zero" ignored HEAD
expect_line 'swift build'
: > "$HOOK_TEST_LOG"
push_update "$tip" "$zero" ignored "$tip"
expect_line 'swift build'
: > "$HOOK_TEST_LOG"
push_update "$tip" ffffffffffffffffffffffffffffffffffffffff
expect_line 'swift build' # Missing remote objects conservatively inspect the new tree.

# Multiple branch updates run the suite once; tags and deletion-only pushes are free.
: > "$HOOK_TEST_LOG"
{
  printf 'refs/heads/topic %s refs/heads/topic %s\n' "$tip" "$base"
  printf 'refs/heads/other %s refs/heads/other %s\n' "$tip" "$base"
} | bash .githooks/pre-push origin ignored > "$temp_root/output" 2>&1
[[ "$(grep -c '^swift build$' "$HOOK_TEST_LOG")" == 1 ]]
: > "$HOOK_TEST_LOG"
printf 'refs/tags/v1 %s refs/tags/v1 %s\n' "$tip" "$zero" | bash .githooks/pre-push origin ignored > "$temp_root/output" 2>&1
printf '(delete) %s refs/heads/topic %s\n' "$zero" "$base" | bash .githooks/pre-push origin ignored > "$temp_root/output" 2>&1
expect_empty_log 'Tags/deletions ran app checks.'
bash .githooks/pre-push origin ignored </dev/null > "$temp_root/output" 2>&1
expect_empty_log 'An empty update list ran app checks.'

# Never validate a different checkout or tracked uncommitted text; scratch files are fine.
if push_update "$source_tip" "$base"; then echo 'Accepted a non-HEAD source tip.' >&2; exit 1; fi
printf 'dirty\n' >> Sources/Core/Example.swift
if push_update "$tip" "$base"; then echo 'Accepted unstaged source changes.' >&2; exit 1; fi
git add Sources/Core/Example.swift
if push_update "$tip" "$base"; then echo 'Accepted staged source changes.' >&2; exit 1; fi
git restore --staged --worktree Sources/Core/Example.swift
printf 'scratch\n' > scratch.log
push_update "$tip" "$base"
printf 'untracked build input\n' > Sources/Core/Untracked.swift
if push_update "$tip" "$base"; then echo 'Accepted an untracked Swift build input.' >&2; exit 1; fi
rm Sources/Core/Untracked.swift

# A Windows-only range is free on macOS and uses one locked build on Windows.
commit_file windows/src/Example.cs windows
windows_tip="$(git rev-parse HEAD)"
: > "$HOOK_TEST_LOG"
push_update "$windows_tip" "$tip"
expect_empty_log 'Windows-only source ran macOS checks.'
export HOOK_TEST_HOST=MINGW64_NT-10.0
push_update "$windows_tip" "$tip"
expect_line 'dotnet restore CaptureApp.sln --locked-mode'
expect_line 'dotnet build CaptureApp.sln -c Release --no-restore -m:1 -warnaserror'
expect_line 'dotnet test CaptureApp.sln -c Release --no-build --no-restore -m:1 --filter Category!=Perf'
expect_line 'dotnet test CaptureApp.sln -c Release --no-restore --no-build -m:1 --filter Category=Perf --logger console;verbosity=detailed'
[[ "$(grep -c '^dotnet restore ' "$HOOK_TEST_LOG")" == 1 ]]
[[ "$(grep -c '^dotnet build ' "$HOOK_TEST_LOG")" == 1 ]]
printf 'untracked build input\n' > windows/src/Untracked.cs
if push_update "$windows_tip" "$tip"; then echo 'Accepted an untracked C# build input.' >&2; exit 1; fi
rm windows/src/Untracked.cs
export HOOK_TEST_FAIL_BUILD=1
if push_update "$windows_tip" "$tip"; then echo 'Ignored a failing build.' >&2; exit 1; fi
unset HOOK_TEST_FAIL_BUILD

# Windows checks also consume Swift model metadata and the Mac embedding and
# tokenizer fixtures. Exercise each dependency independently on both hosts.
mkdir -p Sources/EmbedKit Sources/EmbedChecks/Fixtures/nested docs
for path in Sources/EmbedKit/ModelManifest.swift Sources/EmbedKit/Embedder.swift \
    Sources/EmbedChecks/Fixtures/tokenizer.json Sources/EmbedChecks/Fixtures/embeddings.json \
    Sources/EmbedChecks/Fixtures/token-bucket.png Sources/EmbedChecks/Fixtures/bar-chart.png \
    Sources/EmbedChecks/Fixtures/nested/README.md; do
  previous_tip="$(git rev-parse HEAD)"
  commit_file "$path" 'shared embedding input'
  shared_embedding_tip="$(git rev-parse HEAD)"
  for HOOK_TEST_HOST in MINGW64_NT-10.0 Darwin; do
    : > "$HOOK_TEST_LOG"
    push_update "$shared_embedding_tip" "$previous_tip"
    if [[ "$HOOK_TEST_HOST" == Darwin ]]; then
      expect_line 'swift build'
    else
      expect_line 'dotnet build CaptureApp.sln -c Release --no-restore -m:1 -warnaserror'
    fi
  done
done
export HOOK_TEST_HOST=MINGW64_NT-10.0
printf 'untracked fixture\n' > Sources/EmbedChecks/Fixtures/untracked.png
if push_update "$shared_embedding_tip" "$previous_tip"; then echo 'Accepted an untracked shared fixture on Windows.' >&2; exit 1; fi
rm Sources/EmbedChecks/Fixtures/untracked.png

# A shared fixture removed or moved into docs still affects Windows parity tests.
git mv Sources/EmbedChecks/Fixtures/tokenizer.json docs/removed-tokenizer.json
git commit -qm 'move shared fixture into docs'
removed_fixture_tip="$(git rev-parse HEAD)"
: > "$HOOK_TEST_LOG"
push_update "$removed_fixture_tip" "$shared_embedding_tip"
expect_line 'dotnet build CaptureApp.sln -c Release --no-restore -m:1 -warnaserror'

# The exception must not make unrelated Swift source trigger Windows builds.
commit_file Sources/Core/Example.swift 'Mac-only source'
: > "$HOOK_TEST_LOG"
push_update "$(git rev-parse HEAD)" "$removed_fixture_tip"
expect_empty_log 'Mac-only source ran Windows checks.'

# A merge commit can add source that appears in neither of its own branch's
# ordinary commits. New-branch selection must include merge-parent diffs.
export HOOK_TEST_HOST=Darwin
git checkout -qb hook-test-side
commit_file windows/src/Example.cs 'side branch'
git checkout -q -
git merge --no-ff --no-commit hook-test-side > "$temp_root/output" 2>&1
printf 'merge-only source\n' >> Sources/Core/Example.swift
git add Sources/Core/Example.swift
git commit -qm 'merge with source'
merge_tip="$(git rev-parse HEAD)"
git update-ref refs/remotes/origin/main "$windows_tip"
: > "$HOOK_TEST_LOG"
push_update "$merge_tip" "$zero"
expect_line 'swift build'
export HOOK_TEST_DIRTY_BUILD=1
if push_update "$merge_tip" "$windows_tip"; then echo 'Accepted edits made during checks.' >&2; exit 1; fi
unset HOOK_TEST_DIRTY_BUILD
git restore --worktree Sources/Core/Example.swift

# Embedded Markdown and configuration text are build/check inputs, while docs
# remain cheap. Disable rename detection so source moved into docs still checks.
mkdir -p Sources/Core/Fixtures Config docs
commit_file Sources/Core/Fixtures/README.md fixture
fixture_tip="$(git rev-parse HEAD)"
: > "$HOOK_TEST_LOG"
push_update "$fixture_tip" "$merge_tip"
expect_line 'swift build'
commit_file Config/signing-requirement.txt requirement
config_tip="$(git rev-parse HEAD)"
: > "$HOOK_TEST_LOG"
push_update "$config_tip" "$fixture_tip"
expect_line 'swift build'
git mv Sources/Core/Fixtures/README.md docs/removed-fixture.md
git commit -qm 'move fixture into docs'
rename_tip="$(git rev-parse HEAD)"
: > "$HOOK_TEST_LOG"
push_update "$rename_tip" "$config_tip"
expect_line 'swift build'
commit_file .editorconfig 'unknown shared build configuration'
shared_tip="$(git rev-parse HEAD)"
: > "$HOOK_TEST_LOG"
push_update "$shared_tip" "$rename_tip"
expect_line 'swift build'

# Staged whitespace is checked independently of the expensive pre-push commands.
printf 'trailing whitespace \n' >> README.md
git add README.md
if bash .githooks/pre-commit > "$temp_root/output" 2>&1; then echo 'Accepted staged whitespace errors.' >&2; exit 1; fi
git restore --staged --worktree README.md
bash .githooks/pre-commit

# Install idempotently, but never replace another hooksPath or an active loose hook.
git config --unset core.hooksPath
bash scripts/install-hooks.sh > "$temp_root/output"
[[ "$(git config --local core.hooksPath)" == .githooks ]]
bash scripts/install-hooks.sh > "$temp_root/output"
git config --local core.hooksPath custom-hooks
if bash scripts/install-hooks.sh > "$temp_root/output" 2>&1; then echo 'Overwrote custom hooksPath.' >&2; exit 1; fi
[[ "$(git config --local core.hooksPath)" == custom-hooks ]]
git config --unset core.hooksPath
printf '#!/usr/bin/env bash\nexit 0\n' > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
if bash scripts/install-hooks.sh > "$temp_root/output" 2>&1; then echo 'Replaced an existing loose hook.' >&2; exit 1; fi
[[ -z "$(git config --get core.hooksPath || true)" ]]
echo 'Local hook checks passed.'
