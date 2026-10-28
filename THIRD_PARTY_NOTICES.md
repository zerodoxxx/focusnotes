# Third-party notices

Last Updated: 2026-10-20 (previous commit: `a18015f`)

This file records third-party components included in the source tree or
shipped with the app, and models obtained by the optional semantic-search
downloader or model-fetch scripts for developers and CI. Each component remains
subject to its own upstream license. Project-owned code is licensed under MIT; see
[`LICENSE`](LICENSE). The project license does not replace upstream licenses
for third-party components.

## ONNX Runtime

- **Component:** ONNX Runtime 1.31.0, arm64 macOS shared library, downloaded
  by the in-app model downloader (or `scripts/fetch-models.sh`); the C API headers under `Sources/CORT/include/`
  use API version 31 from the same upstream release.
- **Copyright attribution:** Microsoft Corporation.
- **License:** MIT. The header-copy license is in `Sources/CORT/LICENSE`.
  The downloader places the upstream runtime license at `ORT-LICENSE` and its
  third-party dependency notices at `ORT-ThirdPartyNotices.txt` beside the
  extracted library. The runtime is extracted from its pinned archive, and only
  the three members the app needs are taken from it; each is verified against
  its pinned SHA-256.
- **Sources:** [ONNX Runtime v1.31.0 release](https://github.com/microsoft/onnxruntime/releases/tag/v1.31.0),
  [upstream license](https://github.com/microsoft/onnxruntime/blob/v1.31.0/LICENSE),
  and [upstream third-party notices](https://github.com/microsoft/onnxruntime/blob/v1.31.0/ThirdPartyNotices.txt).

The MIT license permits commercial use of ONNX Runtime under its terms. That
permission applies to ONNX Runtime itself and is independent of the license
for focusnotes code.

## EmbeddingGemma 2 ONNX model

- **Component:** selected model, tokenizer, and configuration files downloaded
  by the in-app model downloader (or `scripts/fetch-models.sh`) from
  [`onnx-community/embeddinggemma-2-ONNX`](https://huggingface.co/onnx-community/embeddinggemma-2-ONNX)
  at revision `daa72c51243991dfcaf9f9137d2c573d8f7790c0`.
- **Attribution:** the model card credits Google DeepMind as the model author
  and ONNX Community as the ONNX export publisher; the base model is
  [`google/embeddinggemma-2`](https://huggingface.co/google/embeddinggemma-2).
- **License:** Apache-2.0, as identified by the pinned model card. The complete
  license text is in [`licenses/Apache-2.0.txt`](licenses/Apache-2.0.txt),
  copied from the [Apache Software Foundation's canonical text](https://www.apache.org/licenses/LICENSE-2.0.txt)
  and pinned by SHA-256 `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30`.
  The downloader verifies this digest before using the file. After the model
  files are verified, the downloader copies it to
  `EMBEDDINGGEMMA-APACHE-2.0-LICENSE.txt` beside the downloaded model files and
  copies [`licenses/EmbeddingGemma2-NOTICE.txt`](licenses/EmbeddingGemma2-NOTICE.txt)
  as `EMBEDDINGGEMMA-NOTICE.txt`.
- **Sources:** [pinned model revision and card](https://huggingface.co/onnx-community/embeddinggemma-2-ONNX/tree/daa72c51243991dfcaf9f9137d2c573d8f7790c0),
  [Google's EmbeddingGemma 2 documentation](https://ai.google.dev/gemma/docs/embeddinggemma),
  and [Google's Apache-2.0 license text](https://ai.google.dev/gemma/apache_2).

Apache-2.0 grants broad rights to this model component, including commercial
use under its terms. Those upstream terms remain separate from the project's
MIT license. The pinned model card also refers deployers to the
[Gemma Prohibited Use Policy](https://ai.google.dev/gemma/prohibited_use_policy).

## Sparkle

- **Component:** Sparkle 2.10.0, the update framework embedded in the app
  bundle as `Sparkle.framework`.
- **Copyright attribution:** Andy Matuschak, Elgato Systems, Kornel Lesiński,
  Mayur Pawashe, C.W. Betts, Petroules Corporation, Big Nerd Ranch, and the
  other contributors listed in the upstream license.
- **License:** MIT for Sparkle's own code. The upstream license also lists
  external components bundled with Sparkle; each retains its own license terms
  as stated in that file.
- **Source:** [upstream license](https://github.com/sparkle-project/Sparkle/blob/2.10.0/LICENSE).
- **Bundled notices:** release bundles include `LICENSE`,
  `THIRD_PARTY_NOTICES.md`, `Apache-2.0.txt`, and `EmbeddingGemma2-NOTICE.txt`
  in `Contents/Resources`.

## Windows edition components

The implemented Windows edition is built from the NuGet packages below at the versions pinned
in `windows/Directory.Packages.props` and the committed `packages.lock.json` files; licenses were read from each
package's metadata (`.nuspec`). Each package keeps its own license, and the shipped installer includes the upstream
license files the packages carry. The app is published self-contained, so the .NET runtime and Windows Presentation
Foundation libraries (MIT, Microsoft Corporation) are bundled with it.

| Component | Version | License | Used for |
| --- | --- | --- | --- |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) (`Microsoft.ML.OnnxRuntime`, `.Managed`), win-x64 and win-arm64 | 1.31.0 | MIT | Runs the OCR and embedding models. Same upstream release as the macOS runtime above, bundled in the installer instead of downloaded. |
| [RapidOcrNet](https://github.com/BobLd/RapidOcrNet) | 4.2.0 | Apache-2.0 | .NET wrapper around the PaddleOCR detection, classification and recognition pipeline. |
| [Clipper2](https://github.com/AngusJohnson/Clipper2) (`Clipper2`, a RapidOcrNet dependency) | 2.0.0 | Boost Software License 1.0 | Polygon geometry for OCR text boxes. |
| [PaddleOCR PP-OCRv5 Latin model assets](https://github.com/PaddlePaddle/PaddleOCR), distributed in the [RapidOcrNet 4.2.0 NuGet package](https://www.nuget.org/packages/RapidOcrNet/4.2.0) with ONNX conversions from [RapidAI/RapidOCR](https://github.com/RapidAI/RapidOCR) | RapidOcrNet 4.2.0 bundled defaults | Apache-2.0 | The default detector, orientation classifier, Latin recognizer and dictionary provide English-first OCR. These assets are supplied by NuGet and ship with the Windows installer; the app does not fetch separate OCR models. See the [PaddleOCR license](https://github.com/PaddlePaddle/PaddleOCR/blob/main/LICENSE). |
| [SQLitePCLRaw](https://github.com/ericsink/SQLitePCL.raw) (`bundle_e_sqlite3`, `core`, `provider.e_sqlite3`, `config.e_sqlite3`) | 3.0.5 | Apache-2.0 | .NET bindings and the bundled native build of SQLite with FTS5. |
| [SQLite](https://www.sqlite.org/copyright.html) (native library from the `SQLite` package) | 3.53.4 | Public domain | The search index and vector store. |
| [Microsoft.Data.Sqlite](https://github.com/dotnet/efcore) (`Microsoft.Data.Sqlite`, `.Core`) | 10.0.13 | MIT | ADO.NET access to SQLite. |
| [Velopack](https://github.com/velopack/velopack) (library and the `vpk` packaging tool) | 1.2.161 | MIT | Per-user installer, delta updates and update application. |
| [AvalonEdit](https://github.com/icsharpcode/AvalonEdit) | 6.3.1.120 | MIT | The quick-note text editor control. |
| [SkiaSharp](https://github.com/mono/SkiaSharp) (with `SkiaSharp.NativeAssets.Win32`) | 3.119.1 | MIT; the bundled native Skia library keeps its upstream license | Image decoding and resizing for embeddings. |
| [BouncyCastle.Cryptography](https://github.com/bcgit/bc-csharp) | 2.6.2 | MIT (per package metadata) | Ed25519 verification of the signed update index. |
| [System.Numerics.Tensors](https://github.com/dotnet/runtime) (a RapidOcrNet dependency) | 9.0.0 | MIT | Tensor math. |

The EmbeddingGemma 2 model files are the same pinned Hugging Face revision described above; the Windows opt-in downloads
only those files, because ONNX Runtime ships with the app. The Windows build also carries Unicode case-folding data in
`windows/src/CaptureApp.Core/UnicodeCaseFolding.cs`, covered by the Unicode License v3 in
[`windows/src/CaptureApp.Core/UnicodeCaseFolding.LICENSE.txt`](windows/src/CaptureApp.Core/UnicodeCaseFolding.LICENSE.txt),
which is copied next to the build output.

Test-only packages are not distributed: xUnit (`xunit.v3.mtp-off` 4.0.2, `xunit.runner.visualstudio` 4.0.1, Apache-2.0)
and `Microsoft.NET.Test.Sdk` 18.11.0 (MIT).

## Project icon assets

The maintainer confirms that the source app-icon artwork in `assets/` was
created for focusnotes through Codex using GPT-6.1-sol. The icon variants under
`assets/icons/` are generated from that artwork by `scripts/make-icons.swift`.
This attribution records maintainer-reported provenance; the project MIT
license applies to these assets to the extent the project holds rights in
them.

## Platform-provided components

The application links the macOS-provided frameworks and SQLite library. They
are not vendored in this repository or fetched by its scripts, so this file
does not attempt to assign licenses to platform components.
