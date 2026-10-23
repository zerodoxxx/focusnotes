#!/usr/bin/env python3
"""Regressions for CI cost selection, including safe revision handling."""

import subprocess
import ast
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
import re
import sys
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
import ci_selection as ci


def pr_event(action="labeled", label="run-ci", labels=None):
    return {"action": action, "label": {"name": label},
            "pull_request": {"labels": [{"name": name} for name in (labels if labels is not None else [label])]}}


def workflow_expression(source, values):
    """Evaluate only the small boolean/string grammar used by our actual job gates."""
    source = source.strip().removeprefix("${{").removesuffix("}}").strip()
    replacements = {
        "github.event.pull_request.labels.*.name": "labels",
        "github.event_name": "event_name", "github.event.action": "action",
        "github.event.label.name": "label", "github.run_id": "run_id",
        "needs.select.result": "select_result", "needs.select.outputs.macos": "macos",
        "needs.select.outputs.windows": "windows", "needs.select.outputs.full": "full",
        "needs.build.result": "build_result",
    }
    for original, replacement in replacements.items():
        source = source.replace(original, replacement)
    source = re.sub(r"!(?!=)", "not ", source.replace("&&", " and ").replace("||", " or "))

    def visit(node):
        if isinstance(node, ast.Expression):
            return visit(node.body)
        if isinstance(node, ast.Constant):
            return node.value
        if isinstance(node, ast.Name):
            return values[node.id]
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
            return not visit(node.operand)
        if isinstance(node, ast.BoolOp):
            result = visit(node.values[0])
            for child in node.values[1:]:
                if isinstance(node.op, ast.And) and not result or isinstance(node.op, ast.Or) and result:
                    return result
                result = visit(child)
            return result
        if isinstance(node, ast.Compare) and len(node.ops) == 1 and isinstance(node.ops[0], (ast.Eq, ast.NotEq)):
            equal = visit(node.left) == visit(node.comparators[0])
            return equal if isinstance(node.ops[0], ast.Eq) else not equal
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
            arguments = [visit(argument) for argument in node.args]
            if node.func.id == "contains":
                return arguments[1] in arguments[0]
            if node.func.id == "always":
                return True
            if node.func.id == "cancelled":
                return values.get("cancelled", False)
        raise AssertionError(f"Unsupported workflow expression: {ast.dump(node)}")

    return visit(ast.parse(source, mode="eval"))


def workflow_job(workflow, name):
    return re.search(rf"(?ms)^  {re.escape(name)}:\n(.*?)(?=^  [\w-]+:\s*$|\Z)", workflow).group(1)


def workflow_scalar(block, key, indent=4):
    return re.search(rf"(?m)^{' ' * indent}{re.escape(key)}: (.+)$", block).group(1)


def workflow_steps(block):
    return re.findall(r"(?ms)^      - .*?(?=^      - |\Z)", block)


def actual_check_name(block, values):
    """GitHub leaves dynamic job names unexpanded when the job is skipped."""
    name = workflow_scalar(block, "name")
    return workflow_expression(name, values) if workflow_expression(workflow_scalar(block, "if"), values) else name


def gate_result(block, values):
    """Model step guards/fail-fast behavior, assuming selected native work succeeds."""
    if not workflow_expression(workflow_scalar(block, "if"), values):
        return "skipped"
    success = not values.get("cancelled", False)
    for step in workflow_steps(block):
        guard = workflow_scalar(step, "if", indent=8)
        # GitHub adds success() unless the guard contains a status function.
        if not any(function in guard for function in ("always()", "cancelled()")) and not success:
            continue
        if workflow_expression(guard, values) and re.search(r"(?m)^          exit 1$|^        run: exit 1$", step):
            success = False
    return "success" if success else "failure"


class SelectionTests(unittest.TestCase):
    def test_platform_paths_and_shared_inputs(self):
        cases = [
            (["README.md", "docs/manual-tests.md"], (False, False)),
            (["Sources/App/AppController.swift"], (True, False)),
            (["Package.swift", "Package.resolved"], (True, False)),
            (["windows/src/CaptureApp.App/AppController.cs"], (False, True)),
            (["Sources/Core/Fixtures/README.md"], (True, False)),
            (["Sources/EmbedKit/ModelManifest.swift"], (True, True)),
            (["Sources/EmbedKit/Embedder.swift"], (True, True)),
            (["Sources/EmbedChecks/Fixtures/tokenizer.json"], (True, True)),
            (["Sources/EmbedChecks/Fixtures/embeddings.json"], (True, True)),
            (["Sources/EmbedChecks/Fixtures/token-bucket.png"], (True, True)),
            (["Sources/EmbedChecks/Fixtures/bar-chart.png"], (True, True)),
            (["Sources/EmbedChecks/Fixtures/nested/README.md"], (True, True)),
            (["Sources/EmbedKit/Tokenizer.swift"], (True, False)),
            (["Sources/EmbedChecks/main.swift", "Sources/EmbedChecks/Fixtures-old/example.json"], (True, False)),
            (["conformance/scenarios/router/test.json"], (True, True)),
            (["Config/app.env"], (True, True)),
            ([".github/workflows/checks.yml"], (True, True)),
            (["scripts/check-local.sh"], (True, True)),
            (["new-build-tool.toml"], (True, True)),
            (["windows/old.cs", "Sources/new.swift"], (True, True)),
            ([], (False, False)),
        ]
        for paths, expected in cases:
            with self.subTest(paths=paths):
                self.assertEqual(ci.platforms_for_paths(paths), expected)

    def test_full_and_manual_do_not_need_a_diff(self):
        with patch.object(ci, "changed_paths", side_effect=AssertionError("unexpected diff")):
            for event_name, event, full in [("pull_request", pr_event(label="run-ci-full"), False),
                                           ("workflow_dispatch", {}, True)]:
                selected = ci.selection(event_name, event, full)
                self.assertEqual([selected[k] for k in ("full", "macos", "windows")], ["true"] * 3)
                self.assertEqual(selected["windows-runners"], '["windows-latest", "windows-11-arm"]')
            selected = ci.selection("workflow_dispatch", {}, False)
            self.assertEqual(selected["full"], "false")
            self.assertEqual(selected["windows-runners"], '["windows-latest"]')

    def test_lean_pr_selects_only_relevant_platforms(self):
        with patch.object(ci, "changed_paths", return_value=["windows/tests/NewTests.cs"]):
            selected = ci.selection("pull_request", pr_event(), False)
        self.assertEqual((selected["macos"], selected["windows"], selected["full"]), ("false", "true", "false"))

    def test_shared_embedding_inputs_select_both_lean_platforms(self):
        for path in ("Sources/EmbedKit/ModelManifest.swift", "Sources/EmbedKit/Embedder.swift",
                     "Sources/EmbedChecks/Fixtures/tokenizer.json", "Sources/EmbedChecks/Fixtures/embeddings.json",
                     "Sources/EmbedChecks/Fixtures/token-bucket.png", "Sources/EmbedChecks/Fixtures/bar-chart.png"):
            with self.subTest(path=path), patch.object(ci, "changed_paths", return_value=[path]):
                selected = ci.selection("pull_request", pr_event(), False)
                self.assertEqual((selected["macos"], selected["windows"], selected["full"]), ("true", "true", "false"))

    def test_bad_diff_falls_back_to_both_platforms(self):
        with patch.object(ci, "changed_paths", side_effect=subprocess.CalledProcessError(1, "git")), redirect_stdout(StringIO()):
            selected = ci.selection("pull_request", pr_event(), False)
        self.assertEqual((selected["macos"], selected["windows"]), ("true", "true"))

    def test_revision_values_cannot_be_options_or_shell_code(self):
        with patch.object(ci, "git") as git:
            for sha in ["--upload-pack=evil", "main", "a" * 39, "$(echo evil)", "a" * 40 + "\n"]:
                with self.subTest(sha=sha), self.assertRaises(ValueError):
                    ci.changed_paths({"pull_request": {"base": {"sha": sha}, "head": {"sha": "b" * 40}}})
            git.assert_not_called()

    def test_merge_base_and_nul_filenames(self):
        base, head, ancestor = "a" * 40, "b" * 40, "c" * 40
        responses = [b"", b"", ancestor.encode() + b"\n", b"windows/a file.cs\0Sources/a\nfile.swift\0"]
        with patch.object(ci, "git", side_effect=responses) as git:
            paths = ci.changed_paths({"pull_request": {"base": {"sha": base}, "head": {"sha": head}}})
        self.assertEqual(paths, ["windows/a file.cs", "Sources/a\nfile.swift"])
        self.assertEqual(git.call_args.args, ("diff", "--no-renames", "--name-only", "-z", ancestor, head, "--"))

    def test_missing_commit_fetches_only_validated_sha(self):
        base, head, ancestor = "a" * 40, "b" * 40, "c" * 40
        responses = [subprocess.CalledProcessError(1, "git"), b"", b"", ancestor.encode(), b"README.md\0"]
        with patch.object(ci, "git", side_effect=responses) as git:
            self.assertEqual(ci.changed_paths({"pull_request": {"base": {"sha": base}, "head": {"sha": head}}}), ["README.md"])
        self.assertEqual(git.call_args_list[1].args, ("fetch", "--no-tags", "origin", base))

    def test_actual_workflow_event_matrix(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/checks.yml").read_text(encoding="utf-8")

        def scalar(job, key):
            return workflow_scalar(workflow_job(workflow, job), key)

        concurrency = re.search(r"(?m)^  group: (.+)$", workflow).group(1)
        coordinated_expression = re.findall(r"\$\{\{(.*?)\}\}", concurrency)[-1]
        self.assertEqual(set(re.findall(r"(?m)^  ([\w-]+):\s*$", workflow.split("jobs:\n", 1)[1])),
                         {"select", "windows-release-gate", "build", "smoke-macos-15", "windows", "windows-package"})
        # expected: native runners requested, required-check names eligible, metadata-only revocation
        cases = [
            ("skip", "pull_request", pr_event(label="skip-ci"), False, (False, True, False)),
            ("skip beats lean", "pull_request", pr_event(labels=["run-ci", "skip-ci"]), False, (False, True, False)),
            ("skip beats full", "pull_request", pr_event(label="run-ci-full", labels=["run-ci-full", "skip-ci"]), True, (False, True, False)),
            ("skip persists on source push", "pull_request", pr_event("synchronize", None, ["skip-ci"]), False, (False, True, False)),
            ("skip persists on reopened", "pull_request", pr_event("reopened", None, ["skip-ci"]), False, (False, True, False)),
            ("skip present on opened", "pull_request", pr_event("opened", None, ["skip-ci"]), False, (False, True, False)),
            ("skip removed", "pull_request", pr_event("unlabeled", "skip-ci", []), False, (False, True, True)),
            ("similar skip label has no bypass", "pull_request", pr_event(label="skip-ci-extra"), False, (False, False, False)),
            ("similar skip label does not block lean", "pull_request", pr_event(labels=["run-ci", "skip-ci-extra"]), False, (True, True, False)),
            ("similar skip removal does not revoke", "pull_request", pr_event("unlabeled", "skip-ci-extra", []), False, (False, False, False)),
            ("lean", "pull_request", pr_event(), False, (True, True, False)),
            ("full", "pull_request", pr_event(label="run-ci-full"), False, (True, True, False)),
            ("manual quick", "workflow_dispatch", {}, False, (True, True, False)),
            ("manual full", "workflow_dispatch", {}, True, (True, True, False)),
            ("unrelated label", "pull_request", pr_event(label="enhancement"), False, (False, False, False)),
            ("unrelated stale skip snapshot", "pull_request", pr_event(label="enhancement", labels=["skip-ci", "enhancement"]), False, (False, False, False)),
            ("unrelated removal stale skip", "pull_request", pr_event("unlabeled", "enhancement", ["skip-ci"]), False, (False, False, False)),
            ("run-ci removal", "pull_request", pr_event("unlabeled", "run-ci", []), False, (False, False, False)),
            ("normal source push", "pull_request", pr_event("synchronize", None, ["run-ci"]), False, (False, False, False)),
            ("normal opened", "pull_request", pr_event("opened", None, []), False, (False, False, False)),
            ("push event", "push", {}, False, (False, False, False)),
        ]
        for case, event_name, event, full_input, expected in cases:
            with self.subTest(case=case), patch.object(ci, "changed_paths", return_value=["Sources/App/AppController.swift", "windows/src/App.cs"]):
                native, required_names, revoke = expected
                selected = ci.selection(event_name, event, full_input)
                policy = ci.event_policy(event_name, event)
                self.assertEqual((policy["native"], policy["required_names"], policy["revoke"]), expected)
                values = {"event_name": event_name, "action": event.get("action", ""),
                          "label": event.get("label", {}).get("name", ""),
                          "labels": [item["name"] for item in event.get("pull_request", {}).get("labels", [])],
                          "select_result": "success" if native else "skipped", "run_id": 123,
                          "build_result": "failure" if revoke else "success",
                          **selected}
                evaluate = lambda source: workflow_expression(source, values)
                self.assertEqual(bool(evaluate(scalar("select", "if"))), native)
                for job in ("build", "smoke-macos-15"):
                    block = workflow_job(workflow, job)
                    self.assertIn("always()", scalar(job, "if"))
                    self.assertEqual(bool(evaluate(scalar(job, "if"))), required_names)
                    if required_names:
                        self.assertEqual(actual_check_name(block, values), job)
                        self.assertEqual(gate_result(block, values), "failure" if revoke else "success")
                    else:
                        self.assertEqual(actual_check_name(block, values), scalar(job, "name"))
                        self.assertNotIn(actual_check_name(block, values), {"build", "smoke-macos-15"})
                self.assertEqual(evaluate(coordinated_expression), "requested" if required_names else 123)
                self.assertEqual(evaluate(scalar("build", "runs-on")), "xcode-27" if native else "ubuntu-latest")
                revocation_guard = workflow_scalar(workflow_job(workflow, "build"), "if", indent=8)
                self.assertEqual(bool(evaluate(revocation_guard)), revoke)
                self.assertEqual(bool(evaluate(scalar("windows", "if"))), native)
                self.assertEqual(bool(evaluate(scalar("windows-release-gate", "if"))), native)
                expected_full = native and (full_input or event.get("label", {}).get("name") == "run-ci-full")
                self.assertEqual(bool(evaluate(scalar("windows-package", "if"))), expected_full)
                self.assertEqual(evaluate(scalar("smoke-macos-15", "runs-on")), "macos-15" if expected_full else "ubuntu-latest")
                if not native:
                    self.assertEqual((selected["macos"], selected["windows"], selected["full"]), ("false", "false", "false"))
        # Labels never start native work on ordinary source updates, and no push trigger was added.
        triggers = workflow.split("permissions:", 1)[0]
        self.assertIn("types: [opened, reopened, synchronize, labeled, unlabeled]", triggers)
        self.assertNotRegex(triggers, r"(?m)^  push:")
        build = workflow_job(workflow, "build")
        self.assertLess(build.index("exit 1"), build.index("uses: actions/checkout"))
        self.assertEqual(scalar("windows-release-gate", "needs"), "select")
        self.assertEqual(scalar("windows-release-gate", "runs-on"), "ubuntu-latest")
        self.assertIn("run: bash scripts/test-windows-release-gate.sh", workflow_job(workflow, "windows-release-gate"))
        # The release-gate fixtures follow Windows scope for lean requests too.
        for path, expected in [("Sources/App/AppController.swift", False), ("windows/src/App.cs", True),
                               ("scripts/windows-release-gate.sh", True), ("README.md", False)]:
            with self.subTest(release_gate_path=path), patch.object(ci, "changed_paths", return_value=[path]):
                selected = ci.selection("pull_request", pr_event(), False)
                self.assertEqual(bool(workflow_expression(scalar("windows-release-gate", "if"), selected)), expected)

    def test_actual_workflow_selector_failure_or_cancellation_blocks_required_build(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/checks.yml").read_text(encoding="utf-8")
        build = re.search(r"(?ms)^  build:\n(.*?)(?=^  smoke-macos-15:)", workflow).group(1)
        failed_selector = re.search(r"(?m)^        if: (.+needs.select.result == 'failure'.+)$", build).group(1)
        for result in ("failure", "cancelled"):
            with self.subTest(result=result):
                values = {"event_name": "pull_request", "action": "labeled", "label": "run-ci", "labels": ["run-ci"],
                          "select_result": result, "cancelled": result == "cancelled", "macos": "", "windows": "", "full": ""}
                for key, expected in [("if", True), ("name", "build"), ("runs-on", "ubuntu-latest")]:
                    expression = re.search(rf"(?m)^    {key}: (.+)$", build).group(1)
                    self.assertEqual(workflow_expression(expression, values), expected)
                self.assertTrue(workflow_expression(failed_selector, values))
        # Intentional skips have a skipped selector, which must never take this failure path.
        values.update({"label": "skip-ci", "labels": ["skip-ci"], "select_result": "skipped", "cancelled": False})
        self.assertTrue(workflow_expression(re.search(r"(?m)^    if: (.+)$", build).group(1), values))
        self.assertFalse(workflow_expression(failed_selector, values))

    def test_required_gates_run_for_lean_scopes_and_guard_every_native_step(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/checks.yml").read_text(encoding="utf-8")
        build, smoke = (workflow_job(workflow, name) for name in ("build", "smoke-macos-15"))
        for path, macos, windows in [("Sources/App/AppController.swift", True, False),
                                     ("windows/src/App.cs", False, True), ("README.md", False, False),
                                     ("Sources/EmbedKit/ModelManifest.swift", True, True)]:
            with self.subTest(path=path), patch.object(ci, "changed_paths", return_value=[path]):
                selected = ci.selection("pull_request", pr_event(), False)
                values = {"event_name": "pull_request", "action": "labeled", "label": "run-ci", "labels": ["run-ci"],
                          "select_result": "success", "build_result": "success", **selected}
                for name, block in (("build", build), ("smoke-macos-15", smoke)):
                    self.assertEqual(actual_check_name(block, values), name)
                    self.assertEqual(gate_result(block, values), "success")
                self.assertEqual(workflow_expression(workflow_scalar(build, "runs-on"), values), "xcode-27" if macos else "ubuntu-latest")
                self.assertEqual(workflow_expression(workflow_scalar(smoke, "runs-on"), values), "ubuntu-latest")
                for job in ("windows", "windows-release-gate"):
                    self.assertEqual(bool(workflow_expression(workflow_scalar(workflow_job(workflow, job), "if"), values)), windows)

        skip_values = {"event_name": "pull_request", "action": "synchronize", "label": "", "labels": ["skip-ci"],
                       "select_result": "skipped", "build_result": "success", "macos": "", "windows": "", "full": ""}
        for name, block, first_native in (("build", build, "uses: actions/checkout"),
                                           ("smoke-macos-15", smoke, "name: Download ad-hoc DMG")):
            with self.subTest(job=name):
                self.assertEqual(actual_check_name(block, skip_values), name)
                self.assertEqual(gate_result(block, skip_values), "success")
                self.assertEqual(workflow_expression(workflow_scalar(block, "runs-on"), skip_values), "ubuntu-latest")
                self.assertNotRegex(workflow_scalar(block, "runs-on"), r"(?:always|cancelled|success|failure)\(")
                steps = workflow_steps(block)
                start = next(index for index, step in enumerate(steps) if first_native in step)
                # The final cancellation gate is intentionally not a native step.
                for step in steps[start:-1]:
                    guard = workflow_scalar(step, "if", indent=8)
                    self.assertFalse(workflow_expression(guard, skip_values), step)
                    self.assertIn("needs.select.result == 'success'", guard)
                    self.assertIn("needs.select.outputs.macos == 'true'" if name == "build" else "needs.select.outputs.full == 'true'", guard)
                    if "Detach DMG" in step:
                        self.assertIn("always()", guard) # Cleanup still runs after native failure/cancellation.
                    else:
                        # Ordinary native steps retain GitHub's implicit success() guard.
                        self.assertNotRegex(guard, r"(?:always|cancelled|success|failure)\(")
                tail_guard = workflow_scalar(steps[-1], "if", indent=8)
                self.assertEqual(tail_guard, "always() && cancelled()")
                self.assertTrue(workflow_expression(tail_guard, {**skip_values, "cancelled": True}))

    def test_required_gates_fail_closed_on_bad_selection_and_cancelled_bypass(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/checks.yml").read_text(encoding="utf-8")
        build, smoke = (workflow_job(workflow, name) for name in ("build", "smoke-macos-15"))
        normal = {"event_name": "pull_request", "action": "labeled", "label": "run-ci", "labels": ["run-ci"],
                  "select_result": "success", "build_result": "success", "macos": "false", "windows": "true", "full": "false"}
        cases = [{"select_result": result} for result in ("failure", "cancelled", "skipped")]
        cases += [{key: invalid} for key in ("macos", "windows", "full") for invalid in ("", "invalid")]
        cases += [{"cancelled": True}, {"cancelled": True, "label": "skip-ci", "labels": ["skip-ci"], "select_result": "skipped"}]
        for overrides in cases:
            with self.subTest(overrides=overrides):
                values = {**normal, **overrides}
                self.assertEqual(actual_check_name(build, values), "build")
                self.assertEqual(gate_result(build, values), "failure")
                values["build_result"] = "failure"
                self.assertEqual(actual_check_name(smoke, values), "smoke-macos-15")
                self.assertEqual(gate_result(smoke, values), "failure")
        for result in ("failure", "cancelled", "skipped"):
            values = {**normal, "macos": "true", "full": "true", "build_result": result}
            with self.subTest(full_build_result=result):
                self.assertEqual(gate_result(smoke, values), "failure")
                self.assertEqual(workflow_expression(workflow_scalar(smoke, "runs-on"), values), "ubuntu-latest")

    def test_bypass_removal_is_not_renewed_by_unrelated_events_or_new_commits(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/checks.yml").read_text(encoding="utf-8")
        checks = {}
        events = [
            ("head-a", pr_event(label="skip-ci"), False, "success"),
            ("head-a", pr_event("unlabeled", "skip-ci", []), False, "failure"),
            ("head-a", pr_event(label="enhancement", labels=["skip-ci", "enhancement"]), False, "failure"),
            ("head-a", pr_event(label="skip-ci"), True, "failure"), # Cancelled old bypass cannot replace revocation.
            ("head-b", pr_event("synchronize", None, ["run-ci"]), False, None),
            ("head-c", pr_event("synchronize", None, ["skip-ci"]), False, "success"),
        ]
        for sha, event, cancelled, expected in events:
            with self.subTest(sha=sha, event=event, cancelled=cancelled):
                selected = ci.selection("pull_request", event, False)
                values = {"event_name": "pull_request", "action": event["action"], "label": event["label"]["name"],
                          "labels": [item["name"] for item in event["pull_request"]["labels"]],
                          "select_result": "skipped", "build_result": "success", "cancelled": cancelled, **selected}
                for name in ("build", "smoke-macos-15"):
                    block = workflow_job(workflow, name)
                    if actual_check_name(block, values) == name:
                        checks[sha, name] = gate_result(block, values)
                    if name == "build":
                        values["build_result"] = checks.get((sha, name), "skipped")
                    self.assertEqual(checks.get((sha, name)), expected)


if __name__ == "__main__":
    unittest.main()
