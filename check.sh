#!/usr/bin/env bash
# gguf-stack check: serve-llama.sh syntax + estimate/dry-run forwarding.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

bash -n "$root/serve-llama.sh"

# The serve script pins the image by digest, and a tag lookup would not tell
# whether that exact build is present locally.
image="$(sed -n 's/^docker_image="${MODEL_ROUTER_LLAMA_IMAGE:-\(.*\)}"$/\1/p' "$root/serve-llama.sh")"
image="${image:-ghcr.io/ggml-org/llama.cpp:server-cuda}"

# File math on stubs (needs real docker image for inspect gate).
if command -v docker >/dev/null 2>&1 && docker image inspect "$image" >/dev/null 2>&1; then
  mkdir -- "$tmp/gguf"
  truncate -s 1G "$tmp/gguf/Qwen3.8-27B-GSQ-RCO-IQ3_S.gguf"
  truncate -s 12G "$tmp/gguf/Qwen3.8-27B-GSQ-RCO-IQ3_S-mtp.gguf"
  truncate -s 100M "$tmp/gguf/mmproj-Qwen3.8-27B-BF16.gguf"
  MODEL_ROUTER_GGUF_DIR="$tmp/gguf" MODEL_ROUTER_NO_VRAM_CHECK=1 \
    "$root/serve-llama.sh" --profile range --estimate | grep -q '~11765 MiB'
  MODEL_ROUTER_GGUF_DIR="$tmp/gguf" MODEL_ROUTER_NO_VRAM_CHECK=1 \
    "$root/serve-llama.sh" --profile duo --dry-run | grep -q -- '--no-kv-unified'
  MODEL_ROUTER_GGUF_DIR="$tmp/gguf" MODEL_ROUTER_NO_VRAM_CHECK=1 \
    "$root/serve-llama.sh" --profile duo128 --dry-run | grep -q -- '--no-kv-unified'
  MODEL_ROUTER_GGUF_DIR="$tmp/gguf" MODEL_ROUTER_NO_VRAM_CHECK=1 \
    "$root/serve-llama.sh" --profile quad --dry-run | grep -q -- '--parallel 4'
  # Both MTP profiles must keep the measured draft depth (n=3) in sync.
  for profile in speed single200; do
    out="$(MODEL_ROUTER_GGUF_DIR="$tmp/gguf" MODEL_ROUTER_NO_VRAM_CHECK=1 \
      "$root/serve-llama.sh" --profile "$profile" --dry-run)"
    grep -q -- '--spec-type draft-mtp' <<<"$out"
    grep -q -- '--spec-draft-n-max 3' <<<"$out"
  done
  MODEL_ROUTER_GGUF_DIR="$tmp/gguf" MODEL_ROUTER_NO_VRAM_CHECK=1 \
    "$root/serve-llama.sh" --profile max --dry-run | grep -qv -- '--spec-type'
fi

printf '%s\n' 'gguf-stack checks passed.'
