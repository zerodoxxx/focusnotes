#!/usr/bin/env bash
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"
host="$(uname -s)"

is_host_source() {
  case "$1" in docs/*|.github/ISSUE_TEMPLATE/*) return 1 ;; esac
  # Markdown inside source/test trees can be a resource or fixture.
  if [[ "$1" != */* ]]; then
    case "$1" in *.md|LICENSE|NOTICE) return 1 ;; esac
  fi
  # Unknown tracked inputs are conservative: shared configuration can affect
  # either toolchain even when it is not in a familiar source directory.
  case "$host" in
    Darwin)
      case "$1" in windows/*) return 1 ;; esac
      ;;
    MINGW*|MSYS*|CYGWIN*)
      # ManifestSyncTests reads the Swift manifest/model ID; Windows embedding
      # and tokenizer parity tests use the Mac fixtures too. Keep in sync with
      # scripts/ci_selection.py before excluding other Swift-only inputs.
      case "$1" in
        Sources/EmbedKit/ModelManifest.swift|Sources/EmbedKit/Embedder.swift|Sources/EmbedChecks/Fixtures/*) return 0 ;;
      esac
      case "$1" in Sources/*|Package.swift|Package.resolved|assets/*) return 1 ;; esac
      ;;
  esac
  return 0
}

is_untracked_build_input() {
  # Unlike tracked changes, unknown scratch files do not affect a checkout.
  # Refuse recognized compiler/check inputs that could be globbed into a build.
  is_host_source "$1" || return 1
  case "$1" in
    Sources/*|windows/*|Config/*|conformance/*|scripts/*|.githooks/*|.github/*|Package.swift|Package.resolved|NuGet.Config|nuget.config|global.json|.editorconfig|.gitattributes|*.props|*.targets|*.csproj|*.sln|*.slnx) return 0 ;;
  esac
  return 1
}

assert_pushed_checkout() {
  if [[ "$(git rev-parse HEAD)" != "$1" ]]; then
    echo "Local checks must run on the exact commit being pushed. Check out '$1' and push that branch separately." >&2
    return 1
  fi
  if ! git diff --quiet --ignore-submodules=none || ! git diff --cached --quiet --ignore-submodules=none; then
    echo "Commit or stash tracked changes before pushing source. Local checks must validate the exact pushed tree." >&2
    return 1
  fi
  while IFS= read -r -d '' path; do
    if is_untracked_build_input "$path"; then
      echo "Untracked build/check input '$path' can change local results. Commit or move it before pushing; unrelated scratch files are allowed." >&2
      return 1
    fi
  done < <(git ls-files --others --exclude-standard -z)
}

expected_tip=''
case "${1:---all}" in
  --pre-push)
    remote="${2:-origin}"
    changed="$(mktemp "${TMPDIR:-/tmp}/focusnotes-push.XXXXXX")"
    trap 'rm -f "$changed"' EXIT
    needs_checks=0
    while read -r local_ref local_sha remote_ref remote_sha extra; do
      [[ -n "${local_ref:-}" ]] || continue
      if [[ -n "${extra:-}" || -z "${remote_sha:-}" ]]; then
        echo "Invalid pre-push input; refusing to skip local checks." >&2
        exit 1
      fi
      [[ "$local_sha" =~ ^0+$ ]] && continue # Branch deletion.
      [[ "$remote_ref" == refs/heads/* ]] || continue # Tags do not introduce a branch update.
      if [[ ! "$local_sha" =~ ^[0-9a-fA-F]+$ || ! "$remote_sha" =~ ^[0-9a-fA-F]+$ ]]; then
        echo "Invalid pre-push object ID." >&2
        exit 1
      fi
      relevant=0
      if [[ ! "$remote_sha" =~ ^0+$ ]] && git cat-file -e "$remote_sha^{commit}" 2>/dev/null; then
        git diff --no-renames --name-only -z "$remote_sha" "$local_sha" -- > "$changed"
      elif [[ "$remote_sha" =~ ^0+$ ]]; then
        # A new branch can contain several unpushed commits. Include each of them,
        # including merge changes; don't mistake a final docs commit for a docs-only push.
        git rev-list "$local_sha" --not "--remotes=$remote" |
          git diff-tree --stdin --root -m --no-renames --no-commit-id --name-only -r -z > "$changed"
      else
        # We cannot know which inputs were removed without the old tree.
        # Force checks rather than assuming the remaining paths describe the range.
        relevant=1
        : > "$changed"
      fi
      while IFS= read -r -d '' path; do
        if is_host_source "$path"; then relevant=1; break; fi
      done < "$changed"
      if [[ "$relevant" == "1" ]]; then
        assert_pushed_checkout "$local_sha"
        expected_tip="$local_sha"
        needs_checks=1
      fi
    done
    if [[ "$needs_checks" != "1" ]]; then
      echo "No source or check changes for this host in the pushed branches; local build and tests skipped."
      exit 0
    fi
    ;;
  --all) ;;
  *) echo "Usage: bash scripts/check-local.sh [--all | --pre-push REMOTE URL]" >&2; exit 2 ;;
esac

bash scripts/test-local-hooks.sh
python_command=''
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 &&
      "$candidate" -c 'import sys; sys.exit(sys.version_info[0] != 3)' >/dev/null 2>&1; then
    python_command="$candidate"
    break
  fi
done
if [[ -z "$python_command" ]]; then
  echo "Local checks require Python 3 (python3 or python on PATH) to validate CI selection. Install it, then retry." >&2
  exit 1
fi
"$python_command" scripts/test-ci-selection.py
case "$host" in
  Darwin)
    swift build
    FOCUSNOTES_PERF_GATES=0 swift run --skip-build CoreChecks --skip-performance
    swift run --skip-build CaptureChecks
    swift run --skip-build ModelInstallChecks
    swift run --skip-build EmbedChecks
    swift run --skip-build OverlayGallery --check
    bash scripts/test-app-path-safety.sh
    ;;
  MINGW*|MSYS*|CYGWIN*)
    (
      cd windows
      dotnet restore CaptureApp.sln --locked-mode
      dotnet build CaptureApp.sln -c Release --no-restore -m:1 -warnaserror
      FOCUSNOTES_PERF_GATES=0 dotnet test CaptureApp.sln -c Release --no-build --no-restore -m:1 --filter 'Category!=Perf'
    )
    ;;
  *) echo "Local app checks require macOS or Windows." >&2; exit 1 ;;
esac
FOCUSNOTES_LOCAL_ALREADY_BUILT=1 bash scripts/check-performance.sh
if [[ -n "$expected_tip" ]]; then assert_pushed_checkout "$expected_tip"; fi
