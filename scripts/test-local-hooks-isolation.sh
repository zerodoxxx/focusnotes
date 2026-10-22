#!/usr/bin/env bash
# Real Git hook context must not leak into the hook fixtures.
set -euo pipefail

git_local_env="$(git rev-parse --local-env-vars)"
while IFS= read -r name; do unset "$name"; done <<< "$git_local_env"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
temp_root="$(mktemp -d "${TMPDIR:-/tmp}/focusnotes-hook-isolation.XXXXXX")"
trap 'rm -rf "$temp_root"' EXIT
repository="$temp_root/source"
worktree="$temp_root/worktree"
remote="$temp_root/remote.git"
mkdir -p "$temp_root/hooks" "$temp_root/before" "$temp_root/after"

# Empty templates also exercise installations with no pre-created hooks folder.
git -c init.defaultBranch=main init -q --template= "$repository"
git -C "$repository" config user.name 'Hook isolation tests'
git -C "$repository" config user.email 'hooks@example.invalid'
git -C "$repository" config core.autocrlf false
git -C "$repository" config core.hooksPath "$temp_root/hooks"
printf 'initial\n' > "$repository/README.md"
git -C "$repository" add README.md
git -C "$repository" commit -qm initial
git -C "$repository" worktree add -qb topic "$worktree"
printf 'staged sentinel\n' > "$worktree/staged.txt"
git -C "$worktree" add staged.txt
git init -q --bare --template= "$remote"

cat > "$temp_root/hooks/pre-push" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ -n "${GIT_DIR:-}" ]] || { echo 'The isolation test did not receive Git hook context.' >&2; exit 1; }
printf '%s\n' "$GIT_DIR" > "$HOOK_ISOLATION_CONTEXT"
bash "$HOOK_ISOLATION_SUITE"
SH
chmod +x "$temp_root/hooks/pre-push"
export HOOK_ISOLATION_SUITE="$script_dir/test-local-hooks.sh"
export HOOK_ISOLATION_CONTEXT="$temp_root/hook-context"

snapshot() {
  local destination="$1"
  git -C "$repository" for-each-ref --format='%(refname) %(objectname)' > "$destination/refs"
  git -C "$repository" rev-parse HEAD > "$destination/root-head"
  git -C "$repository" symbolic-ref HEAD > "$destination/root-branch"
  git -C "$worktree" rev-parse HEAD > "$destination/worktree-head"
  git -C "$worktree" symbolic-ref HEAD > "$destination/worktree-branch"
  cp "$repository/.git/config" "$destination/config"
  cp "$repository/.git/index" "$destination/root-index"
  cp "$(git -C "$worktree" rev-parse --path-format=absolute --git-path index)" "$destination/worktree-index"
}

snapshot "$temp_root/before"
push_status=0
# Push by path so no remote-tracking ref is expected to change in the source.
git -C "$worktree" push -q "$remote" HEAD:refs/heads/topic > "$temp_root/push-output" 2>&1 || push_status=$?
snapshot "$temp_root/after"
if ! diff -r "$temp_root/before" "$temp_root/after"; then
  cat "$temp_root/push-output" >&2
  echo 'Hook fixtures changed the caller repository.' >&2
  exit 1
fi
if [[ "$push_status" != 0 || ! -s "$HOOK_ISOLATION_CONTEXT" ]]; then
  cat "$temp_root/push-output" >&2
  echo 'The real pre-push hook isolation check failed.' >&2
  exit 1
fi
[[ "$(git --git-dir="$remote" rev-parse refs/heads/topic)" == "$(git -C "$worktree" rev-parse HEAD)" ]]
echo 'Local hook repository isolation checks passed.'
