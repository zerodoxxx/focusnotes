# Contributing

Last Updated: 2026-10-22 (previous commit: `f5794e4`)

Thanks for considering a contribution to focusnotes. The macOS edition targets macOS 14 or later and uses Swift 6.4; the Windows edition uses .NET 10. For substantial changes, open a GitHub issue first to agree on scope.

## Before submitting

- Keep each change focused and explain the problem it solves.
- Include or update checks for behavior that changes.
- Do not include secrets, signing credentials, private notes, screenshots or captures from your own vault, downloaded model files, or build output.
- Do not copy code or assets from another project unless you have the right to contribute them. Preserve their license and attribution notices.

## License and third-party material

The project is licensed under the MIT License in the root `LICENSE` file. MIT permits commercial use, modification, redistribution, sublicensing, and sale, provided that the copyright and permission notices remain with all copies or substantial portions of the software.

Some included and downloaded components have their own licenses and attribution requirements. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); the root MIT license does not replace those upstream terms.

By submitting a contribution, you confirm that you created it or have permission to submit it, and you agree to license it under the same MIT License as the project. You retain copyright in your contribution; no separate contributor license agreement or copyright assignment is required. If an employer or another rights holder owns the contribution, obtain authorization before submitting it.

## Build and checks

Run the checks that cover your change from the repository root:

```sh
swift build
swift run CoreChecks
swift run OverlayGallery --check
bash scripts/test-app-path-safety.sh
```

The checks do not require Accessibility or Screen Recording permissions. For changes to capture behavior that depend on macOS privacy permissions or focus handling, also consult the manual steps in [`docs/manual-tests.md`](docs/manual-tests.md) and describe what you verified. `scripts/build-app.sh` builds the app bundle without installing or launching it.

Routine CI runs functional checks without performance workloads. Full CI also records performance measurements, with `FOCUSNOTES_PERF_GATES=0` because shared runners vary in CPU, storage and scheduling. Local pre-push checks enforce the original speed thresholds on your own machine with `FOCUSNOTES_PERF_GATES=1`.

Install the local hooks once per clone (also applies to its worktrees), using Git Bash on Windows:

```sh
bash scripts/install-hooks.sh
```

The installer uses the versioned `.githooks` directory and preserves existing custom hooks/settings, explaining how to integrate manually if needed.

- **Pre-commit:** checks staged changes for whitespace errors. It does not build or run tests.
- **Pre-push:** checks the complete range of branch commits being pushed. Documentation-only changes, tag/deletion pushes, and changes limited to the other platform skip native checks. Relevant source changes run the hook and CI-selector regression checks, then the host's build, functional tests, and local performance checks once. The tested tip must be the checked-out commit, with no tracked local changes or untracked build inputs; unrelated scratch files are allowed.
- **Manual checks:** `bash scripts/check-local.sh` runs the host's complete local checks, including speed gates; `bash scripts/check-performance.sh` runs only the speed gates. Hooks do not download semantic models. Install them explicitly when testing semantic-search changes; missing optional model or desktop capabilities are reported as skips.

On macOS, local checks build Swift targets and run core, capture, overlay, model-install and embedding checks, plus path-safety checks. The functional `CoreChecks --skip-performance` invocation leaves the benchmark to the separate performance step. On Windows, they restore locked dependencies, build Release with warnings as errors, and run functional tests serially. The separate performance step reuses that build for the .NET index and bundled OCR workloads. Set `CAPTUREAPP_RUN_INTERACTIVE_TESTS=1` on an interactive desktop to include clipboard hold-time checks. Windows filesystem safety tests also need the operating system to permit symbolic-link creation; a missing privilege is a test failure, not an automatic exclusion.

The performance script enforces the original index limits (cold sync 6 s on macOS, 18 s on Windows; no-change sync 400 ms; search 40 ms), Windows OCR limits (first call 3 s and warm p95 1.5 s), and interactive clipboard restore p99 10 ms. Compare failures on a consistent local machine; these limits do not apply to CI. Product deadlines and behavior tests remain active.

For CaptureKit changes, run `swift run CaptureChecks`. For semantic-search changes, follow the model-backed `EmbedChecks` procedure in [`docs/semantic-search.md`](docs/semantic-search.md); it uses the optional downloaded models and runtime.

In a pull request, describe the behavior changed, the checks you ran, and any manual checks that need a signed macOS host.

## Choosing CI checks

Local hooks handle routine validation. Remote builds and tests remain opt-in; normal pushes and PR updates do not start native runner jobs.

- Add **`run-ci`** to run a lean check for the changed platforms: a macOS build and core checks, and/or one Windows x64 build and functional test run. Documentation-only changes start no native runner jobs. This profile does not download semantic models, run performance workloads, render galleries, or build installers.
- Add **`run-ci-full`**, or select **Full checks** under **Actions → checks → Run workflow**, for the complete platform matrix: model-backed checks, performance workloads, galleries, the macOS DMG and older-OS smoke test, Windows x64/arm64, and installer/update/tamper tests. Use it for packaging, native-runtime, architecture, model, or release-readiness changes.
- Add **`skip-cli`** to allow a PR to merge without running CI builds or tests. GitHub records the required `build` and `smoke-macos-15` jobs as skipped, which satisfies those check requirements without starting any runner, including the platform selector. Maintainer/codeowner approval and the other merge rules still apply. The label takes precedence over `run-ci` and `run-ci-full` and stays effective after new commits. Unrelated labels do not grant a bypass. Removing `skip-cli` runs only a short Ubuntu check that restores the CI requirement; then add `run-ci` or `run-ci-full` to validate the PR before merging. Local hooks continue to run as usual.
- A manual run without Full checks selects lean checks for both platforms. To repeat PR checks after another commit, remove and re-add the desired label. Adding the label is an explicit request for that run; leaving it attached does not make later pushes trigger CI. A newer requested run cancels an older run for the same PR.

`skip-cli` creates workflow/check records, but executes no workflow jobs. Skipping the whole workflow would leave required checks pending; see [GitHub's skipped-check behavior](https://docs.github.com/en/pull-requests/reference/status-checks). Manual workflow runs and release validation remain explicitly available and are separate from PR-label selection. Use the PR labels when satisfying the PR's required check records.

Dependency/build caches reduce repeated setup, and diagnostic artifacts have short retention. Signed release validation still runs in the release workflow. Hooks are local and can be bypassed, so platform builds and the full validation profile remain available as independent checks.

GitHub's standard hosted runners are free for public repositories. The 2,000-minute GitHub Free allowance applies to private repository usage; see [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions). These changes reduce runner work and waiting time in either case; actual billed usage depends on the repository visibility and runner type.

## Windows

The implemented Windows edition lives in `windows/` (.NET 10; the SDK version is pinned in `windows/global.json`). Local hooks also require Git Bash and Python 3 on `PATH`. Windows installers are not part of the currently published releases. Build and test from `windows/`:

```sh
cd windows
dotnet build -c Release -warnaserror
dotnet test -c Release -m:1
```

Restore is locked (`packages.lock.json` files are committed), so a dependency change must update the lock files and
`Directory.Packages.props` together. RapidOcrNet 4.2.0 supplies the PP-OCRv5 Latin OCR assets used by the English-first
Windows POC; there is no separate OCR model fetch step. Semantic-search tests need model files that are not in the
repository: run `scripts/fetch-semantic-models.sh` (or `.ps1`) to download them into `windows/.semantic-models` and
verify their pinned SHA-256 hashes. Set `CAPTUREAPP_MODELS_DIR` to that folder, and set
`CAPTUREAPP_REQUIRE_OCR_MODELS=1` and `CAPTUREAPP_REQUIRE_MODELS=1` to fail instead of skip if the bundled OCR or
semantic assets are missing.

- `CaptureApp.Core`, `CaptureApp.AppCore`, `CaptureApp.Core.Tests`, `CaptureApp.AppCore.Tests`, `CaptureApp.Updates.Tests`, `CaptureApp.Embed.Tests` and `CaptureApp.Conformance.Tests` are platform neutral and run on any OS with the .NET SDK. `CaptureApp.Platform.Tests` and `CaptureApp.App.Tests` target Windows and are only built as test projects on a Windows host. Tests tagged `Needs=Windows` (file-layer behaviour such as reparse points and reserved names), `Needs=InteractiveDesktop` (hotkeys, focus, UI Automation, clipboard; also set `CAPTUREAPP_RUN_INTERACTIVE_TESTS=1`) and `Needs=OcrModels` (the English OCR corpus, using the NuGet-bundled assets; set `CAPTUREAPP_REQUIRE_OCR_MODELS=1` to fail instead of skip if those assets are missing) require a Windows desktop. `Category=Perf` workloads always retain correctness assertions and report timings; run them serially with `--filter "Category=Perf" -m:1 --logger "console;verbosity=detailed"` to see the measurements. The local pre-push script also opts into their speed assertions.
- Behaviour shared with the Mac app is specified by `conformance/scenarios`. Swift is the reference, so change the Swift behaviour first, then regenerate the expected values with `swift run CoreChecks --write-conformance` and review the diff. Never edit an `expected` block by hand. `swift run CoreChecks` and `dotnet test` must both pass against the same files. See [`conformance/README.md`](conformance/README.md).
- Lean CI runs the Windows build and functional tests on `windows-latest` (x64). Full CI adds `windows-11-arm` (arm64), model-backed and performance checks, published-app self-tests, galleries, and the `windows-package` installer/update tests. `windows/scripts/pack.ps1 -Arch x64|arm64 -Version <ver> -OutDir <dir>` builds one architecture's installer locally on a matching Windows machine.
- Run solution tests with `-m:1` so model inference and other test assemblies do not compete with desktop fixtures. CI bounds test and job duration, retains TRX reports in `test-results-<runner>` artifacts, and provides runner capability diagnostics; a passing ARM64 run can include skipped desktop tests, so check the report's skipped counts when comparing architectures.

## Security reports

See [SECURITY.md](SECURITY.md) for the project's security scope and vulnerability reporting guidance. Do not post vulnerability details, exploit code, or sensitive reproduction steps in a public issue or pull request.
