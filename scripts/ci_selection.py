#!/usr/bin/env python3
"""Select opt-in CI platforms without loading third-party dependencies."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import sys


def platforms_for_paths(paths: list[str]) -> tuple[bool, bool]:
    macos = windows = False
    for path in paths:
        # Only known documentation locations are ignored. Unknown files select both
        # platforms so a new build tool/configuration never silently loses coverage.
        if path.startswith(("docs/", ".github/ISSUE_TEMPLATE/")) or (
            "/" not in path and (path.endswith(".md") or path in {"LICENSE", "SECURITY.txt"})
        ):
            continue
        if path.startswith("Sources/") or path in {"Package.swift", "Package.resolved"}:
            macos = True
        elif path.startswith("windows/"):
            windows = True
        else:
            macos = windows = True
    return macos, windows


def git(*arguments: str) -> bytes:
    return subprocess.run(
        ["git", *arguments], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    ).stdout


def checked_sha(value: object) -> str:
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?", value) is None:
        raise ValueError("Expected a complete Git commit SHA")
    return value


def changed_paths(event: dict) -> list[str]:
    pull_request = event["pull_request"]
    base = checked_sha(pull_request["base"]["sha"])
    head = checked_sha(pull_request["head"]["sha"])
    for sha in (base, head):
        try:
            git("cat-file", "-e", f"{sha}^{{commit}}")
        except subprocess.CalledProcessError:
            # Arguments are validated SHAs and passed directly, never evaluated by a shell.
            git("fetch", "--no-tags", "origin", sha)
    ancestor = checked_sha(git("merge-base", base, head).decode("ascii").strip())
    # Include both sides of renames and deletions; filenames may contain whitespace/newlines.
    names = git("diff", "--no-renames", "--name-only", "-z", ancestor, head, "--")
    return [name.decode("utf-8", errors="surrogateescape") for name in names.split(b"\0") if name]


def event_policy(event_name: str, event: dict) -> dict[str, bool]:
    """Mirror the runner-free workflow gates; unrelated snapshots never renew a bypass."""
    manual = event_name == "workflow_dispatch"
    pr = event_name == "pull_request"
    action = event.get("action")
    label = event.get("label", {}).get("name")
    labels = [item.get("name") for item in event.get("pull_request", {}).get("labels", [])]
    attached = pr and "skip-cli" in labels
    request_event = pr and action == "labeled" and label in {"run-ci", "run-ci-full"}
    removal = pr and action == "unlabeled" and label == "skip-cli"
    skip_event = attached and (action in {"opened", "reopened", "synchronize"}
                              or (action == "labeled" and label == "skip-cli"))
    required_names = manual or request_event or removal or skip_event
    return {
        "native": manual or (request_event and not attached),
        "skip": attached and required_names,
        "revoke": removal and not attached,
        "required_names": required_names,
        "coordinated": required_names,
    }


def selection(event_name: str, event: dict, full_input: bool) -> dict[str, str]:
    policy = event_policy(event_name, event)
    full = policy["native"] and (full_input or event.get("label", {}).get("name") == "run-ci-full")
    if policy["skip"]:
        macos = windows = False
        reason = "skip-cli is attached; all CI jobs are intentionally skipped."
    elif not policy["native"]:
        macos = windows = False
        reason = "No explicit CI request for this event; native checks are not selected."
    elif full:
        macos = windows = True
        reason = "Full verification explicitly requested; both platforms selected."
    elif event_name == "workflow_dispatch":
        macos = windows = True
        reason = "Manual quick verification; both platforms selected."
    else:
        try:
            paths = changed_paths(event)
            macos, windows = platforms_for_paths(paths)
            reason = f"Selected platforms from {len(paths)} changed path(s) since the PR merge base."
        except (KeyError, TypeError, ValueError, UnicodeError, OSError, subprocess.CalledProcessError):
            macos = windows = True
            reason = "Path selection unavailable; conservatively selected both platforms."
            print(f"::warning::{reason}")
    return {
        "macos": str(macos).lower(),
        "windows": str(windows).lower(),
        "full": str(full).lower(),
        "windows-runners": json.dumps(["windows-latest", "windows-11-arm"] if full else ["windows-latest"]),
        "reason": reason,
    }


def main() -> None:
    event_path = os.environ.get("GITHUB_EVENT_PATH")
    event = json.loads(Path(event_path).read_text(encoding="utf-8")) if event_path else {}
    selected = selection(os.environ.get("GITHUB_EVENT_NAME", "workflow_dispatch"), event,
                         os.environ.get("CI_FULL", "false").lower() == "true")
    output = "".join(f"{key}={value}\n" for key, value in selected.items() if key != "reason")
    if output_path := os.environ.get("GITHUB_OUTPUT"):
        with Path(output_path).open("a", encoding="utf-8") as stream:
            stream.write(output)
    sys.stdout.write(output)
    print(selected["reason"])
    if summary_path := os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(summary_path).open("a", encoding="utf-8") as stream:
            stream.write(f"### Selected checks\n\n{selected['reason']}\n\n"
                         f"- Full suite: **{selected['full']}**\n"
                         f"- macOS: **{selected['macos']}**\n"
                         f"- Windows: **{selected['windows']}**\n\n"
                         "Quick runs omit packaging, model downloads, galleries and performance workloads. "
                         "Use `run-ci-full` or the manual **full** input for those checks.\n")


if __name__ == "__main__":
    main()
