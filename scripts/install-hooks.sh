#!/usr/bin/env bash
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"
configured="$(git config --get core.hooksPath || true)"
if [[ -n "$configured" && "$configured" != '.githooks' ]]; then
  echo "Existing core.hooksPath '$configured' was preserved. Add scripts/check-performance.sh to your pre-push hook manually." >&2
  exit 1
fi
if [[ -z "$configured" ]]; then
  for hook in "$(git rev-parse --git-path hooks)"/*; do
    if [[ -f "$hook" && -x "$hook" && "$hook" != *.sample ]]; then
      echo "Existing hook '$hook' was preserved. Add scripts/check-performance.sh to your pre-push hook manually without changing core.hooksPath." >&2
      exit 1
    fi
  done
fi
if [[ ! -x .githooks/pre-push ]]; then
  echo "The versioned .githooks/pre-push hook is missing or not executable in this checkout." >&2
  exit 1
fi

git config --local core.hooksPath .githooks
echo "Installed local pre-push performance checks (core.hooksPath=.githooks)."
