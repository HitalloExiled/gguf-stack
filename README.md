# gguf-stack

`llama-server` launcher for Qwen3.8-27B GSQ/RCO GGUF on RTX 4090 via Docker.

- `serve-llama.sh` — profiles speed/single200/range/max/duo/duo128/quad/vision, VRAM pre-flight gate
- `models/` — local `.gguf` artifacts (git-ignored)

Run `./check.sh` to validate.

## Runtime pin

The CUDA image is pinned **by digest** in `BackendManager` and `serve-llama.sh`:

    ghcr.io/ggml-org/llama.cpp:server-cuda@sha256:fbd1c7239e4a...

`b12679` (revision `af5c5834`, 2026-11-24). The digest also has a matching
per-build tag `server-cuda-b12679`; it is master HEAD, ~4 commits ahead of the
last release tag `b12675`. It stays pinned by digest because the mutable
`server-cuda` tag moves on every upstream build and the digest is what actually
freezes the build.

Rollback: `ghcr.io/ggml-org/llama.cpp:server-cuda@sha256:ae96e52f8b21...`
(= `b12464`) via `MODEL_ROUTER_LLAMA_IMAGE` (and `b12375` before that).

Previous A/B (2026-11-20, b12464 vs b12375), same model/prompt, 3 runs per
profile for single200: prefill 2461.8 → 2431.6 t/s (-1.2%), decode 89.1 → 88.5
(-0.7%), MTP 112/71 and VRAM unchanged. Across max/duo/quad/vision the deltas
stayed within run-to-run noise; slot save/restore 200/200 (cache_n 3,862), tool
call and vision pass.

b12679 brings the recurrent-state fixes that were the open bump target: sticky
NaN in recurrent state (#31913), `slot_sched` fix for LoRA and recurrent
(#32434) and the k-pool layout prefix on sequence edits (#32137), plus ~200
commits since b12464. These matter here because Qwen3.8 is hybrid/recurrent.

A/B 2026-11-24 (b12679 vs b12464), single200 with `mtp_n=3`, ~4.8K-token
prompt + 128-token decode, 3 runs per boot and 2 boots per image: prefill
2566.6 → 2423.8 t/s (-5.6%), decode 85.8 → 84.0 t/s (-2.1%, within noise),
MTP draft acceptance 0.49–0.58 and mean len 2.4–2.7 on both. Slot
save/restore 4915/4915 (b12464) vs 4914/4914 (b12679) with the draft state
restored; tool call and vision pass on both. The prefill delta tracked the
image (not boot order), so it looks real — likely one of the ~200 commits —
and is accepted in exchange for the recurrent-state fixes.

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
