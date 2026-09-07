# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A launcher for running Claude Code against a local Qwen3.8-27B served by
Rapid-MLX on Apple Silicon. Two bash scripts, one settings file, a stdlib-Python dashboard, no build.
See `README.md` for the rationale behind each tuning choice and `CONTEXT.md`
for the project glossary (local model, runtime, launcher, profile, MTP).

Target machine is the work MacBook Pro (M4 Pro, 48 GB). This repo is edited on
the 16 GB Mac, so the server cannot run here; changes are verified on the work Mac.

## Files

- `claude-local`: the launcher. Starts `rapid-mlx serve` if `/health` is down,
  waits up to 600 s, then `exec`s `claude` with env vars scoped to that process.
  Subcommands: `stop`, `status`, `logs`, `start` (server only), `dashboard`.
  Anything else passes through to `claude`.
- `dashboard/server.py` + `dashboard/index.html`: local web page on port 8001.
  Polls the runtime's `/metrics`, `/v1/status`, `/health` plus `sysctl`/`vm_stat`,
  shows a verdict line, per-request token/cache/tok-per-second rows, and
  start/stop/restart/profile controls that shell out to the launcher.
  Python 3 stdlib only. `--mock` serves fake data so it runs on the 16 GB Mac.
- `settings.local-model.json`: passed via `claude --settings`. Denies `Agent`,
  `Workflow`, `/code-review`, `/subtask`; disables workflows, agent view, and
  background tasks. Subagents are off because one local model cannot serve
  parallel agents at useful speed.
- `install.sh`: idempotent setup. Installs rapid-mlx, symlinks the launcher into
  `/opt/homebrew/bin` (fallback `~/.local/bin`), removes stale links, pulls the
  model unless `--no-pull`, then verifies in a fresh login shell.

## Key design points

- The launcher resolves its own symlink to find `settings.local-model.json`
  next to the real script. Keep the settings file beside `claude-local`.
- All model role env vars (`ANTHROPIC_MODEL`, `*_OPUS_MODEL`, `*_SONNET_MODEL`,
  `*_HAIKU_MODEL`, `*_FABLE_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL`) point at the
  same alias. Only one model is loaded.
- Profile overrides: env vars `CLAUDE_LOCAL_MODEL`, `CLAUDE_LOCAL_PORT`,
  `CLAUDE_LOCAL_EFFORT` win over `~/.config/claude-local/profile` (`KEY=value`,
  written by the dashboard), which wins over the script defaults. `SERVE_FLAGS`
  is edited in the script; `start_server` is the only place that launches it.
- Verdict thresholds (plain decode 15 tok/s, MTP on above 25, cache miss below
  50 % cached, long output above 2000 tokens) are constants in `server.py`.
- The server outlives Claude Code on purpose. `claude-local stop` frees the RAM.
- Server log and pid live in `~/.cache/claude-local/`.

## Commands

```sh
brew install pre-commit && pre-commit install   # one-time
pre-commit run --all-files                       # whitespace, JSON/YAML, shellcheck, bash -n
shellcheck claude-local install.sh
bash -n claude-local install.sh                  # syntax check both scripts
```

`python3 -m unittest dashboard/test_server.py` covers the dashboard's
request-row bookkeeping (scripted `/metrics` bodies, no server needed).
Everything else is verified manually on the work Mac: `claude-local status`, then
`claude-local` and check a tool call happens without a wall of thinking. See
"Verify it works" in `README.md`.

## Conventions

- Scripts stay plain bash (`#!/usr/bin/env bash`, `set -euo pipefail`) so they
  work from fish, zsh, and bash. Do not add fish-specific code.
- Keep `README.md` in sync when changing subcommands, env vars, or the deny list.
