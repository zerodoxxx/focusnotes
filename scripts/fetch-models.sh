#!/usr/bin/env bash
# Immutable upstream revisions; SHA-256 values verified from HF LFS metadata and
# the official GitHub release digest (small JSONs hashed from that same revision).
# The checked-in Apache license text is pinned to the official ASF text digest.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -gt 1 ]]; then
    printf 'Usage: %s [models-directory]\n' "$0" >&2
    exit 2
fi
HF_REV=daa72c51243991dfcaf9f9137d2c573d8f7790c0
HF_BASE="https://huggingface.co/onnx-community/embeddinggemma-2-ONNX/resolve/$HF_REV"
ORT_VERSION=1.31.0
EMBEDDINGGEMMA_LICENSE_HASH=cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30
EMBEDDINGGEMMA_NOTICE_HASH=354b2cec84f3ee07c6102571a08af0d8c6262208f11087effb554e559b0f5138

valid() { [[ -f "$1" ]] && [[ "$(shasum -a 256 "$1" | cut -d ' ' -f 1)" == "$2" ]]; }
if ! valid "$ROOT_DIR/licenses/Apache-2.0.txt" "$EMBEDDINGGEMMA_LICENSE_HASH"; then
    printf 'Apache-2.0 license text failed integrity check: %s\n' "$ROOT_DIR/licenses/Apache-2.0.txt" >&2
    exit 1
fi
if ! valid "$ROOT_DIR/licenses/EmbeddingGemma2-NOTICE.txt" "$EMBEDDINGGEMMA_NOTICE_HASH"; then
    printf 'EmbeddingGemma notice failed integrity check: %s\n' "$ROOT_DIR/licenses/EmbeddingGemma2-NOTICE.txt" >&2
    exit 1
fi

DEST="${1:-$ROOT_DIR/build/models}"
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"
WORK="$(mktemp -d "$DEST/.fetch.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fetch() {
    local url="$1" path="$2" hash="$3"
    if valid "$path" "$hash"; then printf 'Verified %s\n' "${path#$DEST/}"; return; fi
    printf 'Fetching %s\n' "${path#$DEST/}"
    curl --fail --location --silent --show-error --retry 3 "$url" -o "$WORK/download"
    if ! valid "$WORK/download" "$hash"; then printf 'SHA-256 mismatch: %s\n' "$url" >&2; exit 1; fi
    mkdir -p "$(dirname "$path")"
    mv "$WORK/download" "$path"
}

# Keep in sync with the expected hash in Sources/EmbedKit/ModelManifest.swift.
DYLIB_HASH=2a50a63e7f41f8d4d551d3ee47248df3864f6540109fce8ad520ca3b51af4b70
LICENSE_HASH=2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c
NOTICES_HASH=143764b952fdb1a7c69ce653bfba74a7744d6a8a573bfb73e235fba356c83de3
if ! valid "$DEST/libonnxruntime.dylib" "$DYLIB_HASH" || ! valid "$DEST/ORT-LICENSE" "$LICENSE_HASH" || ! valid "$DEST/ORT-ThirdPartyNotices.txt" "$NOTICES_HASH"; then
    fetch "https://github.com/microsoft/onnxruntime/releases/download/v$ORT_VERSION/onnxruntime-osx-arm64-$ORT_VERSION.tgz" \
        "$WORK/runtime.tgz" 1031b36dd3bdaa8d976a6130d9cf2a05e9be320b93ae804f8427b91dc3432afc
    tar -xzf "$WORK/runtime.tgz" -C "$WORK"
    RUNTIME="$WORK/onnxruntime-osx-arm64-$ORT_VERSION"
    valid "$RUNTIME/lib/libonnxruntime.$ORT_VERSION.dylib" "$DYLIB_HASH"
    valid "$RUNTIME/LICENSE" "$LICENSE_HASH"
    valid "$RUNTIME/ThirdPartyNotices.txt" "$NOTICES_HASH"
    cp "$RUNTIME/lib/libonnxruntime.$ORT_VERSION.dylib" "$WORK/runtime.dylib"
    cp "$RUNTIME/LICENSE" "$WORK/runtime-license"
    cp "$RUNTIME/ThirdPartyNotices.txt" "$WORK/runtime-notices"
    mv "$WORK/runtime.dylib" "$DEST/libonnxruntime.dylib"
    mv "$WORK/runtime-license" "$DEST/ORT-LICENSE"
    mv "$WORK/runtime-notices" "$DEST/ORT-ThirdPartyNotices.txt"
fi
printf 'Verified ONNX Runtime %s arm64\n' "$ORT_VERSION"

while read -r hash name; do
    fetch "$HF_BASE/$name" "$DEST/$name" "$hash"
done <<'ARTIFACTS'
d06edd601f851c633a2519304cbeb8dc6170d7ceb61b436625c17fb9b6e74953 onnx/model_quantized.onnx
278a7ff1248c3618e4bd11a607fc54f7bdc7778854230f3956d3f86bd9db4f3b onnx/model_quantized.onnx_data
7ea284226d4938f0ad921ab091f1d80a9ca699aa802984ef5cd5eec4f4761d96 onnx/vision_encoder_q4.onnx
0a9d6c927334f152a33dd90874f65d6ea5228999abe6a450d3f7813677fa704c onnx/vision_encoder_q4.onnx_data
4d777ef5bdc1aa36227abdfb77c3e49e7b9c892d16e1b6bda41c393504828be4 tokenizer.json
17bd5d6e9364ca49a534e1502076593317c298d4a663623091ed45388f004874 tokenizer_config.json
8d011bfe08b5e345bbe0b81e5c6fd02c381920b345b986047bc2a33ce7b90d1d config.json
168f6a08522f3ce5dea596d94d003af2fd691742d4f41fe1f9d8cce76bfbf69c processor_config.json
9344893f8d0573a46ebb2ca54c03f56d044cea194c8dcfb1f4d652240ac21daa preprocessor_config.json
031e56a498d33c349ab489a21885bcfe25b4fcba841149dc99e1e90d4a7c28f5 config_sentence_transformers.json
ARTIFACTS
cp "$ROOT_DIR/licenses/Apache-2.0.txt" "$WORK/embeddinggemma-license"
cp "$ROOT_DIR/licenses/EmbeddingGemma2-NOTICE.txt" "$WORK/embeddinggemma-notice"
if ! valid "$WORK/embeddinggemma-license" "$EMBEDDINGGEMMA_LICENSE_HASH" || ! valid "$WORK/embeddinggemma-notice" "$EMBEDDINGGEMMA_NOTICE_HASH"; then
    printf 'Model license or notice failed integrity check\n' >&2
    exit 1
fi
mv "$WORK/embeddinggemma-license" "$DEST/EMBEDDINGGEMMA-APACHE-2.0-LICENSE.txt"
mv "$WORK/embeddinggemma-notice" "$DEST/EMBEDDINGGEMMA-NOTICE.txt"
printf 'Models ready: %s\n' "$DEST"
