# claude-local

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) against a local
**Qwen3.8-27B** on an Apple Silicon Mac, tuned for speed.

Target machine: MacBook Pro M4 Pro, 48 GB unified memory.

## What it does

`claude-local` is a bash script (works from zsh, bash, or fish) that:

1. Starts [Rapid-MLX](https://github.com/raullenchai/Rapid-MLX) serving
   `qwen3.8-27b-4bit` if it is not already running, and waits for it to be healthy.
2. Launches `claude` with environment variables pointing at the local server.
   Your normal `claude` command is untouched.
3. Leaves the server running after Claude Code exits so the next session starts warm.
   `claude-local stop` frees the memory.

## Why these choices

| Choice | Reason |
| --- | --- |
| Qwen3.8-27B | Only open-weight Qwen3.8 model. Dense, 256k context, tool calling, vision. |
| 4-bit quant | ~20 GB. Decode on Apple Silicon is bandwidth-bound, so smaller weights are faster. |
| Rapid-MLX | MLX runtime with native MTP (multi-token prediction) speculative decoding. Measured 1.4x to 2.3x decode over plain MLX on Qwen3.8-27B. llama.cpp's MTP path shows no gain on Metal. Serves the Anthropic Messages API directly. |
| Effort `low` | Qwen3.8 defaults to `xhigh` reasoning and can spend 20k+ tokens thinking. `--effort low` maps to a small reasoning cap on the server. |
| All model roles mapped to one model | Only one model is loaded. Opus, Sonnet, Haiku, and subagent aliases all resolve to Qwen3.8-27B. |
| Subagents off | A single local model cannot serve parallel agents at useful speed. See below. |

## Install (work Mac)

```sh
git clone https://github.com/jorden-parker/claude-local.git ~/src/claude-local
cd ~/src/claude-local
./install.sh
```

`install.sh` does everything, is safe to re-run, and verifies itself at the end:

- `brew install rapid-mlx` if missing
- links `claude-local` into `/opt/homebrew/bin` (already on PATH), or `~/.local/bin` as fallback
- removes stale `claude-local` links elsewhere, including a root-owned one in `/usr/local/bin` (asks for sudo)
- adds the bin dir to your shell rc file only if needed
- downloads the model (~20 GB) only if it is not already in the Rapid-MLX cache. Pass `--no-pull` to skip the check.
- opens a fresh login shell and confirms `claude-local` resolves, then runs `claude-local status`

Claude Code itself: `npm install -g @anthropic-ai/claude-code`.

## Use

```sh
claude-local            # start server if needed, open Claude Code
claude-local -p "hi"    # any claude args pass through
claude-local status     # server health and loaded model
claude-local logs       # tail the server log
claude-local stop       # stop the server
claude-local start      # start the server only, no Claude Code
claude-local dashboard  # web dashboard on http://127.0.0.1:8001 (Ctrl-C stops it)
```

## Dashboard

`claude-local dashboard` serves one local page (Python 3 stdlib, no install)
that answers "why is this turn slow?" at a glance:

- **Verdict line**: cache miss, MTP likely off, memory pressure, or long output.
  Rules and thresholds are constants at the top of `dashboard/server.py`.
- **Per request** (last 20): prompt tokens, cached tokens, completion tokens,
  tok/s, seconds. Built by diffing the runtime's `/metrics` counters each
  second, so it is exact only when requests are serial (one Claude Code session).
- **Live**: prefill and generation tok/s, Metal memory, prefix cache hit rate,
  macOS memory pressure and swap-ins, the MTP line from the startup log.
- **Control**: start, stop, restart, and edit the profile (model, port, effort).
  Saving writes `~/.config/claude-local/profile` and restarts the server.
- **Diagnostics**: raw `/metrics` counters (requests processed, cancelled,
  via disconnect), how long the current request has been running, metrics
  scrape health (ok/failed, last ms), MTP accept ratio, and the notable log
  lines (error, warn, cancel, abort, disconnect, timeout, memory). Cancelled
  requests appear as red rows in the request table; rapid-mlx does not count
  them as processed, so a Claude Code timeout-and-retry shows up here instead.
- **Log tail**, last 200 lines.

Thinking tokens are not exposed by Rapid-MLX. A huge completion count on a
short turn is the proxy.

`claude-local dashboard --mock` shows fake data for checking the page on a
machine without Rapid-MLX. Port override: `CLAUDE_LOCAL_DASHBOARD_PORT`.

## Verify it works

1. Run `claude-local status`. Expect `server: up` and `model: qwen3.8-27b-4bit`.
2. Run `claude-local` and ask: "List the files in this directory." Expect a tool call
   and a real answer, not a wall of thinking.
3. Check MTP is active and read the speed:

   ```sh
   curl -s http://127.0.0.1:8000/metrics | grep -iE 'spec|accept|tokens_per'
   ```

   Expect non-zero speculative-decode counters. Rapid-MLX reports roughly
   15 tok/s plain and 26 tok/s with MTP on an M4 Pro.

## How subagents are blocked

`--disallowedTools Agent` alone is not enough. Workflows, `/subtask`,
`/code-review`, and background tasks each have their own path. The launcher
passes `settings.local-model.json`, which covers all of them:

- `permissions.deny`: `Agent`, `Workflow`, `/code-review`, `/subtask`
- `disableWorkflows` and `disableAgentView`
- `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`

The CLI flags `--disallowedTools Agent Workflow` are also passed as a belt-and-braces measure.

## Tuning

Override via env vars, the profile file `~/.config/claude-local/profile`
(`KEY=value` lines: `MODEL`, `PORT`, `EFFORT`; written by the dashboard), or the
profile block at the top of `claude-local`. Env vars win over the file.

- `CLAUDE_LOCAL_MODEL`: any Rapid-MLX alias (`rapid-mlx models`). `qwen3.8-27b-8bit` is higher quality, about half the speed.
- `CLAUDE_LOCAL_EFFORT`: `low`, `medium`, `high`, `xhigh`.
- `CLAUDE_LOCAL_PORT`: server port, default `8000`. `CLAUDE_LOCAL_DASHBOARD_PORT`: default `8001`.
- `SERVE_FLAGS` (in the script): see `rapid-mlx serve --help`. `--no-spec-decode` turns MTP off for A/B testing.

Context: Rapid-MLX serves the model's native 256k window. Claude Code is capped
at 200k via `CLAUDE_CODE_DISABLE_1M_CONTEXT=1`. KV cache costs about 4 GB per 64k tokens.

## Development

```sh
brew install pre-commit
pre-commit install
```

Hooks: whitespace, JSON and YAML checks, `shellcheck`, `bash -n`.

## Sources

- Rapid-MLX release notes v0.13.4 (Qwen3.8-27B MTP path, +25.9% aggregate, 1.43x to 2.34x single-request decode)
- Rapid-MLX docs: `docs/agents/claude-code.md`, `docs/reference/cli.md`
- [qwen38-mtp Apple Silicon sweep](https://github.com/sudoingX/qwen38-mtp/blob/master/sweeps/apple-silicon.md) (llama.cpp MTP parity on Metal)
- [Simon Willison on Qwen3.8-27B overthinking](https://simonwillison.net/2026/Aug/16/qwen-38-27b/)
- Claude Code docs: settings reference, sub-agents, model config
