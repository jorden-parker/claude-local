# Why a turn takes ten minutes

Written 2026-09-07 against `rapid-mlx 0.13.4` and Claude Code `2.1.263`,
investigating "Claude takes 10 minutes to think, then runs slowly after".

A slow turn is two separate costs, and they have different causes:

- **The ten minutes** is almost always *thinking tokens*. The model generates
  thousands of them before it says anything.
- **The slowness after** is *decode speed*. Every token after the thinking
  arrives at the plain rate because MTP is not on.

Fix them separately. The evidence for each is below.

## Finding 1: MTP was never enabled

`claude-local` used to carry this comment:

> MTP speculative decoding and the qwen3 parsers are auto-selected for this
> exact alias; no flag needed.

Half of that is wrong. The parsers are auto-selected. MTP is not:

```
$ rapid-mlx info qwen3.8-27b-4bit
 Tool format      : qwen3_coder_xml
 Reasoning parser : qwen3
 Architecture     : hybrid (linear-attention/Mamba)
 Spec decode      : ✗ disabled (hybrid arch)
 MTP path         : sidecar (opt-in: --speculative-config)
 Suffix tier      : n/a (hybrid arch — spec decode off)
```

The alias is a hybrid (linear-attention/Mamba) architecture, and Rapid-MLX
disables speculative decoding for hybrid models by default. MTP for this model
runs through a separate sidecar path that only starts when you ask for it.

**Fix**: `claude-local` now passes

```
--speculative-config '{"method":"mtp","num_speculative_tokens":3}'
```

`CLAUDE_LOCAL_SPEC_DECODE=0` (or `SPEC_DECODE=0` in the profile) turns it back
off for an A/B test. If the runtime rejects the config the server would exit at
startup, so `start_server` retries once without the flag and prints a warning
rather than leaving a dead port.

**Expected gain**: the Rapid-MLX release notes claim 1.43x to 2.34x
single-request decode on this model. Roughly 15 tok/s becomes roughly 26.
It does not touch the ten minutes.

## Finding 2: effort *is* plumbed, and that is worth knowing

It was reasonable to suspect `--effort low` never reached the server. It does.
Captured from a real Claude Code request to a stub endpoint:

```json
{
  "model": "qwen3.8-27b-4bit",
  "max_tokens": 32000,
  "thinking": {"type": "adaptive", "display": "omitted"},
  "output_config": {"effort": "low"},
  "context_management": {"edits": [{"type": "clear_thinking_20251015", "keep": "all"}]}
}
```

Two things follow.

`thinking.type` is `adaptive` with **no `budget_tokens`** — the model is being
told to decide for itself how long to think. On its own that is an uncapped
turn.

The cap arrives instead through `output_config.effort`, which Rapid-MLX 0.13.4
does implement (`vllm_mlx/api/anthropic_models.py`):

| effort | reasoning cap |
| --- | --- |
| low | 512 |
| medium | 2048 |
| high | 8192 |
| xhigh | 24000 |
| max | uncapped |

Changing `--effort` changes only that one field; `thinking` and `max_tokens`
stay identical. So `--effort low` asks for a 512-token reasoning cap, and the
runtime understands the request.

**The open question** is whether the cap saves wall-clock. Rapid-MLX enforces it
two ways (`vllm_mlx/request.py`):

- a **logits processor** that force-closes `</think>` once the budget is spent —
  this is the one that saves time, and it only installs when the model's
  `</think>` resolves to a single token;
- otherwise a **post-hoc cap in the postprocessor** — the model still generates
  every thinking token, and the trim happens after. The transcript looks short.
  The turn still took ten minutes.

`scripts/diagnose.sh` probes 1a and 1b measure exactly this: same prompt at
`effort=low` and `effort=max`, compared on output tokens and duration. If low
does not come out shorter and faster, the cap is post-hoc and that is the ten
minutes.

**Also worth knowing**: installing the reasoning-budget logits processor takes
the request *out* of speculative execution. `vllm_mlx/request.py` says grammar,
tool, reasoning and custom processors "fail closed instead of entering
speculative execution without a rollback contract". So on this runtime, a capped
reasoning budget and MTP do not both apply to the same request. Measure the
combination rather than assuming the gains add.

## Finding 3: two deny rules were silently doing nothing

Claude Code printed, on every launch:

```
Permission deny rule "/code-review" matches no known tool — check for typos.
Permission deny rule "/subtask" matches no known tool — check for typos.
```

`permissions.deny` takes tool names, not slash commands. Skills are denied as
`Skill(<name>)`. `settings.local-model.json` now uses `Skill(code-review)` and
`Skill(subtask)`, verified by the warning disappearing. `SlashCommand(...)` is
also not a thing — it produces the same warning.

This costs no speed. It did mean the README's claim to cover "each path"
was only true for `Agent` and `Workflow`.

## Finding 4: the OAuth 404 banner at launch

On the work Mac every launch shows:

```
API Error: User OAuth refresh failed (HTTP 404):
{"error":{"message":"Not Found","type":"not_found_error","code":null,"param":null}}
```

Claude Code refreshes its stored claude.ai login on startup even when
`ANTHROPIC_API_KEY` is set. The token endpoint is `/v1/oauth/token`, and with
`ANTHROPIC_BASE_URL` pointed at rapid-mlx the refresh goes there and 404s.

This is noise, not the ten minutes — the same screenshot shows the turn
finishing in 0 s. But it is red text on every launch.

**Fixed**: `claude-local` now runs Claude Code with its own `CLAUDE_CONFIG_DIR`
(`~/.config/claude-local/claude-home`), which holds no login, so no refresh is
attempted. Verified against a stub endpoint: with the isolated dir the only path
Claude Code touches is `/v1/messages`, and neither the OAuth warning nor the
connectors warning appears.

The isolation is made free rather than accepted as a cost. `setup_config_dir`
symlinks `CLAUDE.md`, `settings.json`, `skills`, `output-styles`, `plugins`,
`hooks` and `agents` from `~/.claude`, and `scripts/seed_config.py` copies the
onboarding flags and the `hasTrustDialogAccepted` entries already in
`~/.claude.json` — no new folder trust is granted. Only session history is
genuinely separate, which keeps local-model transcripts out of the hosted ones;
`diagnose` reads both. `CLAUDE_LOCAL_ISOLATE_CONFIG=0` opts out.

`forceLoginMethod: "console"` in a settings file was tried first and does
nothing here — the claude.ai login warning is identical with and without it.

To confirm the refresh really is hitting the local server rather than
Anthropic, look for an `oauth` line in `~/.cache/claude-local/server.log`;
`scripts/diagnose.sh` section 7 checks for exactly that.

## Ruled out

- **`--relocate-mid-conversation-system` busting the prefix cache.** Backwards:
  the flag exists to *preserve* the cache for clients that inject reminders
  mid-session, which is exactly what Claude Code does. Keep it.
- **The hybrid 200 ms admission throttle.** Default off since the mlx-lm
  0.30.6 fix (`vllm_mlx/engine_core.py`, `RAPID_HYBRID_THROTTLE`), and it spaces
  *request admissions*, not tokens. `rapid-mlx info` still prints
  "Throttle: ✓ 200ms gap", which is the profile's declared capability, not what
  the engine does.

## Not yet measured (needs the work Mac)

Everything above is from the code, the CLI, and a captured request. These need
the 48 GB machine and a loaded model:

1. How many thinking tokens a real slow turn actually spends
   (`scripts/diagnose.sh` section 2 reads it from Claude Code's own transcript).
2. Whether the 512-token cap is enforced during generation or post-hoc
   (probes 1a/1b).
3. Whether MTP starts at all with the sidecar config, and what it buys.
4. Whether the prefix cache holds across a growing conversation (probes 2-4).

Run `claude-local diagnose` on that machine and the report answers all four.
