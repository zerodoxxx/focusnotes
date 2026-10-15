# Third-party notices

This file records third-party components included in the source tree or
obtained by the in-app model downloader, or by `scripts/fetch-models.sh` for
developers and CI. Each component remains subject to
its own upstream license. Project-owned code is licensed under MIT; see
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
