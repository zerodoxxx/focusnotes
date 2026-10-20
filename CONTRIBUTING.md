# Contributing

Last Updated: 2026-10-20 (previous commit: `80fd7b0`)

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

For CaptureKit changes, run `swift run CaptureChecks`. For semantic-search changes, follow the model-backed `EmbedChecks` procedure in [`docs/semantic-search.md`](docs/semantic-search.md); it uses the optional downloaded models and runtime.

In a pull request, describe the behavior changed, the checks you ran, and any manual checks that need a signed macOS host.

## Windows

The implemented Windows edition lives in `windows/` (.NET 10; the SDK version is pinned in `windows/global.json`). Windows installers are not part of the currently published releases. Build and test from `windows/`:

```sh
cd windows
dotnet build -c Release -warnaserror
dotnet test -c Release
```

Restore is locked (`packages.lock.json` files are committed), so a dependency change must update the lock files and
`Directory.Packages.props` together. RapidOcrNet 4.2.0 supplies the PP-OCRv5 Latin OCR assets used by the English-first
Windows POC; there is no separate OCR model fetch step. Semantic-search tests need model files that are not in the
repository: run `scripts/fetch-semantic-models.sh` (or `.ps1`) to download them into `windows/.semantic-models` and
verify their pinned SHA-256 hashes. Set `CAPTUREAPP_MODELS_DIR` to that folder, and set
`CAPTUREAPP_REQUIRE_OCR_MODELS=1` and `CAPTUREAPP_REQUIRE_MODELS=1` to fail instead of skip if the bundled OCR or
semantic assets are missing.

- `CaptureApp.Core`, `CaptureApp.AppCore`, `CaptureApp.Core.Tests`, `CaptureApp.AppCore.Tests`, `CaptureApp.Updates.Tests`, `CaptureApp.Embed.Tests` and `CaptureApp.Conformance.Tests` are platform neutral and run on any OS with the .NET SDK. `CaptureApp.Platform.Tests` and `CaptureApp.App.Tests` target Windows and are only built as test projects on a Windows host. Tests tagged `Needs=Windows` (file-layer behaviour such as reparse points and reserved names), `Needs=InteractiveDesktop` (hotkeys, focus, UI Automation, clipboard; also set `CAPTUREAPP_RUN_INTERACTIVE_TESTS=1`) and `Needs=OcrModels` (the English OCR corpus, using the NuGet-bundled assets; set `CAPTUREAPP_REQUIRE_OCR_MODELS=1` to fail instead of skip if those assets are missing) require a Windows desktop. `Category=Perf` timing gates should run serially (`--filter "Category=Perf" -m:1`).
- Behaviour shared with the Mac app is specified by `conformance/scenarios`. Swift is the reference, so change the Swift behaviour first, then regenerate the expected values with `swift run CoreChecks --write-conformance` and review the diff. Never edit an `expected` block by hand. `swift run CoreChecks` and `dotnet test` must both pass against the same files. See [`conformance/README.md`](conformance/README.md).
- CI runs the Windows build, tests, self-test and gallery check on `windows-latest` (x64) and `windows-11-arm` (arm64); packaging and update tests run in the `windows-package` job. `windows/scripts/pack.ps1 -Arch x64|arm64 -Version <ver> -OutDir <dir>` builds one architecture's installer locally on a matching Windows machine.

## Security reports

See [SECURITY.md](SECURITY.md) for the project's security scope and vulnerability reporting guidance. Do not post vulnerability details, exploit code, or sensitive reproduction steps in a public issue or pull request.
