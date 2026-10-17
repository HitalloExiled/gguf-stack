#!/usr/bin/env bash
# serve-llama.sh: simplified llama-server launcher for the GGUF pilot
# (Qwen3.8-27B GSQ/RCO on RTX 4090). Companion to serve.sh (ninfer stack).
#
# Usage:
#   serve-llama.sh [--profile speed|range|max|duo|duo128|quad|vision] [--port N] [--host H]
#                  [--context N] [--parallel N]
#                  [--estimate] [--dry-run] [--no-vram-check] [--list] [--help]
#                  [-- <extra llama-server args...>]
#
# Profiles (article recipe, tuned for 24GB):
#   speed:  MTP draft file, 64K ctx, q4_0 KV, draft-mtp n=2  (~42 tok/s class)
#   range:  base file, 96K ctx, q8_0 KV                       (bigger window)
#
# Exit codes: 0 ok, 1 usage, 2 missing image/model, 3 insufficient VRAM.
set -euo pipefail
export LC_ALL=C LC_NUMERIC=C

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
gguf_dir_default="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/models"
docker_image="${NINFER_LLAMA_IMAGE:-ghcr.io/ggml-org/llama.cpp:server-cuda}"
base_file="Qwen3.8-27B-GSQ-RCO-IQ3_S.gguf"
mtp_file="Qwen3.8-27B-GSQ-RCO-IQ3_S-mtp.gguf"
mmproj_file_name="mmproj-Qwen3.8-27B-BF16.gguf"
mmproj_file=""

usage() {
  cat <<USAGE
usage: $(basename -- "$0") [--profile speed|range|max|duo|duo128|quad|vision] [--port N] [--host H]
       [--context N] [--parallel N]
       [--estimate] [--dry-run] [--no-vram-check] [--list] [--help]
       [-- <extra llama-server args...>]

  --profile speed|range|max|duo|duo128|quad|vision|single192  preset (default: range)
                            speed:  MTP draft file, 64K ctx, q4_0 KV, draft-mtp n=2
                            range:  base file, 96K ctx, q8_0 KV
                            single192: MTP draft file, 192K ctx, q4_0 KV, draft-mtp n=2
                            max:    base file, 256K ctx, q4_0 KV, no spec
                            duo:    base file, 2x96K slots, q4_0 KV, no spec
                                    (two independent sessions)
                            duo128: base file, 2x128K slots, q4_0 KV, no spec
                                    (widest dual setup)
                            quad:   base file, 4x64K slots, q4_0 KV, no spec
                                    (four parallel sessions)
  --port N        listen port (default: 18090)
  --host H        bind host for the log line (container binds 0.0.0.0)
  --context N     override total context tokens
  --parallel N    parallel slots (default: 1, duo/quad raise it)
  --mmproj on|off|auto  vision encoder: on (vision profile always on),
                        off, or auto=off (router upgrades on first image)
  --estimate      print VRAM estimate for the resolved setup and exit 0
  --dry-run       print the docker command and exit 0
  --no-vram-check skip the VRAM pre-flight gate
  --list          list available .gguf files and exit 0
  -- <args...>    extra args appended to llama-server

Profiles follow the 16GB-threshold recipe (GSQ/RCO IQ3_S); contexts are
scaled to the 24GB card. KV per-token numbers are calibrated from server
logs where measured, conservative otherwise.
USAGE
}

profile="range"
port="${NINFER_LLAMA_PORT:-18090}"
host="127.0.0.1"
ctx_override=""
parallel_slots="1"
mmproj_mode="auto"
estimate_only=0
dry_run=0
vram_check=1
if [[ "${NINFER_NO_VRAM_CHECK:-0}" == "1" ]]; then vram_check=0; fi
passthrough=()

while (( $# )); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --profile) profile="${2:?--profile needs speed|range|max|duo|duo128|quad|vision}"; shift 2 ;;
    --profile=*) profile="${1#--profile=}"; shift ;;
    --port) port="${2:?--port needs a value}"; shift 2 ;;
    --port=*) port="${1#--port=}"; shift ;;
    --host) host="${2:?--host needs a value}"; shift 2 ;;
    --host=*) host="${1#--host=}"; shift ;;
    --context) ctx_override="${2:?--context needs tokens}"; shift 2 ;;
    --context=*) ctx_override="${1#--context=}"; shift ;;
    --parallel) parallel_slots="${2:?--parallel needs slots}"; shift 2 ;;
    --parallel=*) parallel_slots="${1#--parallel=}"; shift ;;
    --mmproj) mmproj_mode="${2:?--mmproj needs on|off|auto}"; shift 2 ;;
    --mmproj=*) mmproj_mode="${1#--mmproj=}"; shift ;;
    --estimate) estimate_only=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --no-vram-check) vram_check=0; shift ;;
    --list)
      shopt -s nullglob
      for f in "${NINFER_GGUF_DIR:-$gguf_dir_default}"/*.gguf; do
        printf '%s\n' "$(basename -- "$f")"
      done
      exit 0 ;;
    --) shift; while (( $# )); do passthrough+=("$1"); shift; done ;;
    --*) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    *) printf 'Unexpected arg (no positional MODEL; files are per-profile): %s\n' "$1" >&2; exit 1 ;;
  esac
done

gguf_dir="${NINFER_GGUF_DIR:-$gguf_dir_default}"
# Multimodal is lazy: the mmproj encoder (+0.9GB resident) loads only for the
# vision profile or an explicit --mmproj on. The router upgrades a running
# text tier in place on the first image request instead (same tier, reboot).
if [[ "$profile" == "vision" || "$mmproj_mode" == "on" ]]; then
  mmproj_file="$gguf_dir/$mmproj_file_name"
elif [[ "$mmproj_mode" != "off" && "$mmproj_mode" != "auto" ]]; then
  printf 'Unknown --mmproj: %s (want on|off|auto)\n' "$mmproj_mode" >&2
  exit 1
fi
case "$profile" in
  speed)
    file="$gguf_dir/$mtp_file"; ctx=65536; kv_type="q4_0"
    spec=(--spec-type draft-mtp --spec-draft-n-max 2)
    profile_label="MTP draft file, 64K context, q4_0 KV, draft-mtp n=2" ;;
  range)
    file="$gguf_dir/$base_file"; ctx=98304; kv_type="q8_0"
    spec=()
    profile_label="base file, 96K context, q8_0 KV" ;;
  max)
    # No speculative decoding: MTP needs the mtp file + draft KV, which left
    # ~1.1GB free and no margin for desktop creep. Decode without spec was
    # acceptable (37 tok/s at 256K); stability wins for the flagship.
    file="$gguf_dir/$base_file"; ctx=262144; kv_type="q4_0"
    spec=()
    profile_label="base file, 256K context, q4_0 KV, no spec" ;;
  duo)
    # -c is the TOTAL pool; --no-kv-unified splits it into per-slot arenas
    # below (2x96K independent sessions, article's parallel pattern).
    file="$gguf_dir/$base_file"; ctx=196608; kv_type="q4_0"
    spec=()
    profile_label="base file, 2x96K slots, q4_0 KV, no spec" ;
    if [[ "$parallel_slots" == "1" ]]; then parallel_slots="2"; fi ;;
  duo128)
    file="$gguf_dir/$base_file"; ctx=262144; kv_type="q4_0"
    spec=()
    profile_label="base file, 2x128K slots, q4_0 KV, no spec" ;
    if [[ "$parallel_slots" == "1" ]]; then parallel_slots="2"; fi ;;
  quad)
    file="$gguf_dir/$base_file"; ctx=262144; kv_type="q4_0"
    spec=()
    profile_label="base file, 4x64K slots, q4_0 KV, no spec" ;
    if [[ "$parallel_slots" == "1" ]]; then parallel_slots="4"; fi ;;
  vision)
    # 64K ctx leaves room for image tokens (each photo costs thousands of
    # patch tokens). Same mmproj-backed stack as every other profile.
    file="$gguf_dir/$base_file"; ctx=65536; kv_type="q8_0"
    spec=()
    profile_label="base file + mmproj, 64K context, q8_0 KV, no spec" ;;
  single192)
    # MTP draft file, 192K context, q4_0 KV, draft-mtp n=2, single session.
    # MTP needs ~draft/28 of KV overhead; 192K * q4_0 fits the 24GB card.
    file="$gguf_dir/$mtp_file"; ctx=196608; kv_type="q4_0"
    spec=(--spec-type draft-mtp --spec-draft-n-max 2)
    profile_label="MTP draft file, 192K context, q4_0 KV, draft-mtp n=2" ;;
  *) printf 'Unknown --profile: %s (want speed|range|max|duo|duo128|quad|vision|single192)\n' "$profile" >&2; exit 1 ;;
esac
if [[ -n "$ctx_override" ]]; then ctx="$ctx_override"; fi

if ! command -v docker >/dev/null 2>&1; then
  printf 'error: docker not found\n' >&2
  exit 2
fi
if ! docker image inspect "$docker_image" >/dev/null 2>&1; then
  printf 'Missing image %s; run: docker pull %s\n' "$docker_image" "$docker_image" >&2
  exit 2
fi
if [[ ! -f "$file" ]]; then
  printf 'Missing model: %s\n' "$file" >&2
  printf 'Download the GSQ/RCO GGUF files into %s first.\n' "$gguf_dir" >&2
  exit 2
fi
if [[ -n "$mmproj_file" && ! -f "$mmproj_file" ]]; then
  printf 'Missing mmproj encoder: %s\n' "$mmproj_file" >&2
  exit 2
fi

# Per-token KV estimate (MiB per 1024 tokens) by llama cache type.
# q4_0 calibrated 2026-10-15 from a 256K boot on RTX 4090 (true ~25, +margin);
# q8_0 conservative until measured.
kv_mib_per_1k() {
  case "$1" in
    q8_0) printf '96' ;;
    q4_0) printf '28' ;;
    *) printf '96' ;;
  esac
}

# required_mib <file> <total_ctx> <kv_type> [extra_weights] [draft_0/1] -> "total|weights|kv".
# ctx is the TOTAL pool (slots share it); per-slot = ctx/slots. Draft KV is
# ~1/28 of target (single-layer draft head, measured 2026-10-15).
required_mib() {
  local f="$1" cap="$2" dtype="$3" extra="${4:-}" draft="${5:-0}"
  local bytes per_1k kv_mib draft_mib weights_mib overhead total
  bytes="$(stat -c%s -- "$f" 2>/dev/null || wc -c < "$f" | tr -d ' ')"
  if [[ -n "$extra" ]]; then
    bytes=$((bytes + $(stat -c%s -- "$extra" 2>/dev/null || wc -c < "$extra" | tr -d ' ')))
  fi
  per_1k="$(kv_mib_per_1k "$dtype")"
  kv_mib="$(awk -v c="$cap" -v k="$per_1k" \
    'BEGIN { printf "%d", (c / 1024) * k }')"
  weights_mib="$(awk -v b="$bytes" 'BEGIN { printf "%d", (b / 1048576) * 0.99 }')"
  overhead=1536  # CUDA graphs/workspace/slack; recalibrate from boot logs
  draft_mib=0
  if [[ "$draft" == "1" ]]; then
    draft_mib="$(awk -v k="$kv_mib" 'BEGIN { printf "%d", k / 28 }')"
  fi
  total=$((weights_mib + kv_mib + draft_mib + overhead))
  printf '%d|%d|%d|%d' "$total" "$weights_mib" "$kv_mib" "$draft_mib"
}

draft_flag=0
if (( ${#spec[@]} > 0 )); then draft_flag=1; fi
estimate="$(required_mib "$file" "$ctx" "$kv_type" "$mmproj_file" "$draft_flag")"
need_mib="${estimate%%|*}"; rest="${estimate#*|}"
weights_mib="${rest%%|*}"; rest2="${rest#*|}"
kv_mib="${rest2%%|*}"; draft_mib="${rest2##*|}"

if [[ "$estimate_only" == "1" ]]; then
  printf 'Estimate: weights ~%d MiB + kv ~%d MiB (x%s slots) + draft ~%d MiB + overhead 1536 MiB = ~%d MiB (%.1f GiB)\n' \
    "$weights_mib" "$kv_mib" "$parallel_slots" "$draft_mib" "$need_mib" \
    "$(awk -v m="$need_mib" 'BEGIN { printf "%.1f", m / 1024 }')"
  exit 0
fi

# VRAM pre-flight gate (exit 3 when short).
if [[ "$vram_check" == "1" ]]; then
  if command -v nvidia-smi >/dev/null 2>&1; then
    read -r free_mib total_mib <<< "$(nvidia-smi --query-gpu=memory.free,memory.total \
      --format=csv,noheader,nounits | head -1 | tr -d ' ' | tr ',' ' ' || true)"
    if [[ -n "${free_mib:-}" && -n "${total_mib:-}" ]]; then
      printf 'VRAM: free %d MiB / total %d MiB; need ~%d MiB (weights ~%d + kv ~%d + draft ~%d + overhead 1536)\n' \
        "$free_mib" "$total_mib" "$need_mib" "$weights_mib" "$kv_mib" "$draft_mib"
      if (( need_mib > total_mib )); then
        printf 'error: setup needs more than total VRAM\n' >&2
        exit 3
      fi
      if (( need_mib > free_mib )); then
        printf 'error: insufficient free VRAM: %d MiB free, ~%d MiB required\n' \
          "$free_mib" "$need_mib" >&2
        printf 'Free VRAM (close GPU-hungry apps?) or set NINFER_MIN_FREE_GIB to override.\n' >&2
        exit 3
      fi
      if (( need_mib + 1024 > free_mib )); then
        printf 'warning: <1 GiB headroom after launch\n' >&2
      fi
    else
      printf 'warning: nvidia-smi unreadable; skipping VRAM check\n' >&2
    fi
  else
    printf 'warning: nvidia-smi not found; skipping VRAM check\n' >&2
  fi
fi

model_basename="$(basename -- "$file")"
args=(
  -m "/models/$model_basename"
  --alias "qwen3.8-gguf-$profile"
  -ngl 99 -c "$ctx" --parallel "$parallel_slots"
  --cache-type-k "$kv_type" --cache-type-v "$kv_type"
  -fa on --jinja
  --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.00
  "${spec[@]}"
  --host 0.0.0.0 --port "$port"
)
if [[ -n "$mmproj_file" ]]; then
  args+=(--mmproj "/models/$(basename -- "$mmproj_file")")
fi
if (( parallel_slots > 1 )); then
  # Split the -c pool into independent per-slot arenas (article's pattern).
  args+=(--no-kv-unified)
fi
if (( ${#passthrough[@]} )); then
  args+=("${passthrough[@]}")
fi

if [[ "$dry_run" == "1" ]]; then
  printf 'docker run --gpus all --rm -p %s:%s -v %s:/models:ro %s' \
    "$port" "$port" "$gguf_dir" "$docker_image"
  printf ' %q' "${args[@]}"
  printf '\n'
  exit 0
fi

printf 'Starting llama-server Qwen3.8-GSQ-RCO (%s) at http://%s:%s/v1\n' \
  "$profile_label" "$host" "$port"
exec docker run --gpus all --rm --init -p "$port:$port" \
  -v "$gguf_dir:/models:ro" "$docker_image" "${args[@]}"
