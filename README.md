# gguf-stack

`llama-server` launcher for Qwen3.8-27B GSQ/RCO GGUF on RTX 4090 via Docker.

- `serve-llama.sh` — profiles speed/range/max/duo/duo128/quad, VRAM pre-flight gate
- `models/` — local `.gguf` artifacts (git-ignored)

Run `./check.sh` to validate.

## Runtime pin

The CUDA image is pinned to `ghcr.io/ggml-org/llama.cpp:server-cuda-b12375`
(v1.0.0, 2026-11-14) in `BackendManager` and `serve-llama.sh`; `b12110`
(v0.9.0) remains the rollback tag via `MODEL_ROUTER_LLAMA_IMAGE`. The
2026-11-16 A/B across single200/max/duo/quad/vision showed no material
regression (prefill/decode within ~3%, MTP 112/71 unchanged, VRAM unchanged,
tool call/slot/vision pass); b12375 adds the v1.0.0 hardening, FP8 KV, GDN
cleanup, scheduler/graph reuse, few-row MMQ for MTP and tool-arg escaping.
