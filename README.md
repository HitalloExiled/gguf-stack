# gguf-stack

`llama-server` launcher for Qwen3.8-27B GSQ/RCO GGUF on RTX 4090 via Docker.

- `serve-llama.sh` — profiles speed/single200/range/max/duo/duo128/quad/vision, VRAM pre-flight gate
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
connection reuse after streaming (#30492).

### Evaluated and rejected: b12679 (2026-11-24)

b12679 (revision `af5c5834`) carried the recurrent-state fixes #31913 (sticky
NaN), #32434 (slot_sched for LoRA/recurrent) and #32137 (k-pool layout prefix),
plus ~200 commits. A/B against b12464 (single200, `mtp_n=3`, ~4.8K-token prompt
+ 128-token decode, 3 runs per boot, 2 boots per image) showed **no real gain**:
prefill 2566.6 → 2423.8 t/s (**-5.6%**), decode 85.8 → 84.0 (-2.1%, noise),
slot save/restore 4915/4915 vs 4914/4914, tool call and vision at parity. The
three fixes are latent (never observed in our traffic), so the bump is deferred
until a release brings a measurable win or one of those failure modes shows up.

## MTP draft depth

`speed` and `single200` share `mtp_n` (top of `serve-llama.sh`). It is 3 as of
2026-11-20. The sweep below picked the depth (single200, 3 runs per depth,
sequential):

| n | decode t/s | vs n=2 | draft acceptance | VRAM |
|---|---|---|---|---|
| 1 | 77.6 | -11.8% | 76.4% | 19.4 GiB |
| 2 | 88.0 | — | 63.4% | 19.8 GiB |
| 3 | **92.1** | **+4.1%** | 57.1% | 19.9 GiB |
| 4 | 93.7 | +6.5% | 48.0% | 20.0 GiB |

n=4 gains only 1.7% over n=3 while acceptance drops 9 points and it costs
~100 MiB more, so the extra depth is paying for drafts that get rejected.

Decode drifts ±3% run to run, so the number to trust is the interleaved A/B
(n=2, n=3, n=2, n=3, ...), which also removes thermal/session drift:

| profile | n=2 | n=3 | paired delta | VRAM |
|---|---|---|---|---|
| single200 (200K) | 89.4 t/s | 96.0 t/s | **+6.7%** (+6.7/+8.0/+5.8 per cycle) | 19.95 → 20.06 GiB |
| speed (64K) | 85.6 t/s | 94.5 t/s | **+10.4%** | 16.5 → 16.6 GiB |

Acceptance stays deterministic (140 drafts / 80 accepted on single200, 112/71
at n=2); only wall-clock decode moves.

Rollback without editing the script: `-- --spec-draft-n-max 2` (extra args are
forwarded verbatim to llama-server).

Greedy output is deterministic *per depth* (5 runs: n=2 byte-identical, n=3
byte-identical) but flips between depths at near-ties: the first divergence
here is `n <= 1` vs `n == 0`, with a top-1/top-2 margin of 0.10-0.13 nats.
Different draft depth means different verification batch shapes, so the
reduction order changes and greedy argmax can flip. Both texts are valid; this
is not draft-token leakage.

## Prompt cache and the tool list

The server matches the cached prefix head-first, so the exact `tools` array is
part of the head. Measured on single200 with a 5-tool list:

| request | prompt_n | cache_n | prefill |
|---|---|---|---|
| same order, growing history | 453-494 | 490 → 1390 | ~360 ms |
| tools reversed | 2292 | 0 | 1035 ms |
| reversed again | 4 | 2288 | 81 ms |
| back to the original order | 453 | 1839 | 335 ms |

A reordered list costs one full re-prefill; repeating either order reuses.
The router forwards the body verbatim and does **not** canonicalize the array:
clients today send a stable order, and sorting would change what the model
sees for a case that has not been observed in real traffic. If a client is
seen shuffling tools mid-session, sort the list by name at the relay.
