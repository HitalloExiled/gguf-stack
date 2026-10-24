# AGENT.md

Guidance for coding agents working in this repository.

## Release tags

- Tag system milestones with annotated semver tags: `vMAJOR.MINOR.PATCH`.
- `MINOR`: behavior or launcher change. `PATCH`: backward-compatible fix.
- Tag `gguf-stack` alongside `model-router` for the same system milestone.
- Never move or reuse a published tag. Push tags explicitly:
  `git push origin vX.Y.Z`.
- Run `./check.sh` before tagging.

## llama.cpp image pin

- `serve-llama.sh` pins
  `ghcr.io/ggml-org/llama.cpp:server-cuda-b11854`. The router's
  `LLAMA_IMAGE` must use the same tag.
- To bump: pull the new `server-cuda-bNNNNN` tag, boot a profile, smoke
  test reasoning/tool calls/prefix cache, then update both files.
- Avoid the floating `server-cuda` tag: it moved from b11641 to b11854
  in nine days.
