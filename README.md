# gguf-stack

`llama-server` launcher for Qwen3.8-27B GSQ/RCO GGUF on RTX 4090 via Docker.

- `serve-llama.sh` — profiles speed/range/max/duo/duo128/quad, VRAM pre-flight gate
- `models/` — local `.gguf` artifacts (git-ignored)

Run `./check.sh` to validate.

## Runtime pin

The CUDA image is pinned **by digest** in `BackendManager` and `serve-llama.sh`:

    ghcr.io/ggml-org/llama.cpp:server-cuda@sha256:ae96e52f8b21...

`b12464` (revision `d3c3e24`, 2026-11-17). Per-build `server-cuda-bXXXX` tags
stopped at `b12429`, so the mutable `server-cuda` tag is the only channel and
the digest is what actually freezes the build.

Rollback: `ghcr.io/ggml-org/llama.cpp:server-cuda-b12375` via
`MODEL_ROUTER_LLAMA_IMAGE` (and `b12110`/v0.9.0 before that).

A/B 2026-11-20, same model/prompt, 3 runs per profile for single200:
prefill 2461.8 → 2431.6 t/s (-1.2%), decode 89.1 → 88.5 (-0.7%), MTP 112/71 and
VRAM unchanged. Across max/duo/quad/vision the deltas stayed within run-to-run
noise; slot save/restore 200/200 (cache_n 3,862), tool call and vision pass.
b12464 brings the jinja rendering cut (#32023), `server_slot_sched` refactor
(#32154), kv-cells removal scan (#32380), CUDA cooperative softmax (#28982) and
connection reuse after streaming (#30492). The recurrent-state fixes
(#31913/#32434/#32137) are **not** in this build and remain the next bump.
