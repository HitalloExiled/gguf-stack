#!/usr/bin/env bash
# gguf-stack check: serve-llama.sh syntax + estimate/dry-run forwarding.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

bash -n "$root/serve-llama.sh"

# File math on stubs (needs real docker image for inspect gate).
if command -v docker >/dev/null 2>&1 && docker image inspect ghcr.io/ggml-org/llama.cpp:server-cuda >/dev/null 2>&1; then
  mkdir -- "$tmp/gguf"
  truncate -s 1G "$tmp/gguf/Qwen3.8-27B-GSQ-RCO-IQ3_S.gguf"
  truncate -s 12G "$tmp/gguf/Qwen3.8-27B-GSQ-RCO-IQ3_S-mtp.gguf"
  truncate -s 100M "$tmp/gguf/mmproj-Qwen3.8-27B-BF16.gguf"
  NINFER_GGUF_DIR="$tmp/gguf" NINFER_NO_VRAM_CHECK=1 \
    "$root/serve-llama.sh" --profile range --estimate | grep -q '~11765 MiB'
  NINFER_GGUF_DIR="$tmp/gguf" NINFER_NO_VRAM_CHECK=1 \
    "$root/serve-llama.sh" --profile duo --dry-run | grep -q -- '--no-kv-unified'
  NINFER_GGUF_DIR="$tmp/gguf" NINFER_NO_VRAM_CHECK=1 \
    "$root/serve-llama.sh" --profile duo128 --dry-run | grep -q -- '--no-kv-unified'
  NINFER_GGUF_DIR="$tmp/gguf" NINFER_NO_VRAM_CHECK=1 \
    "$root/serve-llama.sh" --profile quad --dry-run | grep -q -- '--parallel 4'
  NINFER_GGUF_DIR="$tmp/gguf" NINFER_NO_VRAM_CHECK=1 \
    "$root/serve-llama.sh" --profile single192 --dry-run | grep -q -- '--spec-type draft-mtp'
fi

printf '%s\n' 'gguf-stack checks passed.'
