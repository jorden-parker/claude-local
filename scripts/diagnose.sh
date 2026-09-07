#!/usr/bin/env bash
# claude-local diagnose: work out why a turn took minutes.
#
# Run this on the machine that serves the model (the work Mac), from the repo root:
#
#     ./scripts/diagnose.sh              # full run; sends 4 small probe requests
#     ./scripts/diagnose.sh --no-probe   # read-only: transcript, metrics, memory, log
#
# It writes the same output to ./diagnose-<timestamp>.txt so the report can be
# pasted back. Run it while Claude Code is idle: the probes queue behind an
# in-flight request, which makes every timing meaningless.
#
# It answers, in order:
#   1. Is the model thinking for thousands of tokens per turn? (transcript)
#   2. Does the prefix cache survive a growing conversation? (probes 2-4)
#   3. Is MTP speculative decoding actually on? (metrics)
#   4. Is the machine swapping? (vm_stat)
set -euo pipefail

PROBE=1
BRIEF=0
case "${1:-}" in
  --no-probe) PROBE=0 ;;
  --brief) BRIEF=1 ;;
  "") ;;
  *) echo "usage: $0 [--brief | --no-probe]" >&2; exit 2 ;;
esac
export BRIEF

# --- config: same precedence as the launcher (env > profile > default) ------
PROFILE_FILE="${HOME}/.config/claude-local/profile"
if [ -f "$PROFILE_FILE" ]; then
  # shellcheck disable=SC1090
  . "$PROFILE_FILE"
fi
MODEL="${CLAUDE_LOCAL_MODEL:-${MODEL:-qwen3.8-27b-4bit}}"
PORT="${CLAUDE_LOCAL_PORT:-${PORT:-8000}}"
EFFORT="${CLAUDE_LOCAL_EFFORT:-${EFFORT:-low}}"
BASE_URL="http://127.0.0.1:${PORT}"
LOG_FILE="${HOME}/.cache/claude-local/server.log"
PID_FILE="${HOME}/.cache/claude-local/server.pid"

OUT="diagnose-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee "$OUT") 2>&1

hr() {
  if [ "$BRIEF" = "1" ]; then printf '\n-- %s\n' "$1"
  else printf '\n== %s %s\n' "$1" "$(printf '=%.0s' $(seq 1 $((70 - ${#1}))))"; fi
}
have() { command -v "$1" >/dev/null 2>&1; }
# Sections that are only useful when reading the whole report.
verbose() { [ "$BRIEF" = "0" ]; }

# ---------------------------------------------------------------- 1. context
hr "1. context"
date
verbose && { sw_vers 2>/dev/null | tr '\n' ' '; echo; }
echo "hardware: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo '?'), $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 )) GB"
echo "resolved: MODEL=$MODEL PORT=$PORT EFFORT=$EFFORT"
if verbose; then
  echo "profile file: $PROFILE_FILE"
  if [ -f "$PROFILE_FILE" ]; then sed 's/^/  /' "$PROFILE_FILE"; else echo "  (absent, so defaults apply)"; fi
fi
for v in CLAUDE_LOCAL_MODEL CLAUDE_LOCAL_PORT CLAUDE_LOCAL_EFFORT ANTHROPIC_MODEL ANTHROPIC_BASE_URL; do
  [ -n "${!v:-}" ] && echo "env $v=${!v}"
done
echo "claude: $(have claude && claude --version 2>&1 | head -1 || echo 'not found')"
echo "rapid-mlx: $(have rapid-mlx && rapid-mlx --version 2>&1 | head -1 || echo 'not found')"

# ------------------------------------------------ 2. what really happened
# Claude Code writes one JSON line per turn with exact usage. This is the only
# exact record of thinking tokens; rapid-mlx does not expose them.
hr "2. last local-model turns, from Claude Code's own transcript"
python3 - "$MODEL" <<'PY'
import glob, json, os, sys
from datetime import datetime

want = sys.argv[1].lower()
rows = []
for path in glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")):
    prev_t = None
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                ts = e.get("timestamp")
                t = None
                if isinstance(ts, str):
                    try:
                        t = datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
                    except ValueError:
                        t = None
                msg = e.get("message") or {}
                model = str(msg.get("model") or "")
                if e.get("type") == "assistant" and (want in model.lower() or "qwen" in model.lower()):
                    u = msg.get("usage") or {}
                    content = msg.get("content") or []
                    think_chars = sum(len(b.get("thinking") or "") for b in content
                                      if isinstance(b, dict) and b.get("type") == "thinking")
                    text_chars = sum(len(b.get("text") or "") for b in content
                                     if isinstance(b, dict) and b.get("type") == "text")
                    tools = sum(1 for b in content if isinstance(b, dict) and b.get("type") == "tool_use")
                    details = u.get("output_tokens_details") or {}
                    rows.append({
                        "t": t, "dur": (t - prev_t) if (t and prev_t) else None,
                        "in": u.get("input_tokens"),
                        "cr": u.get("cache_read_input_tokens"),
                        "cc": u.get("cache_creation_input_tokens"),
                        "out": u.get("output_tokens"),
                        "think_tok": details.get("thinking_tokens"),
                        "think_chars": think_chars, "text_chars": text_chars, "tools": tools,
                        "model": model, "file": os.path.basename(path),
                    })
                if t:
                    prev_t = t
    except OSError:
        continue

if not rows:
    print("no transcript turns found for a local model.")
    print("looked in ~/.claude/projects/*/*.jsonl for message.model matching")
    print(f"'{want}' or 'qwen'. If you have run claude-local at all, the model")
    print("name in the transcript is the answer to a different question -- paste")
    print("this instead:  grep -ho '\"model\":\"[^\"]*\"' ~/.claude/projects/*/*.jsonl | sort | uniq -c")
    raise SystemExit(0)

BRIEF = os.environ.get("BRIEF") == "1"
rows.sort(key=lambda r: r["t"] or 0)
tail = rows[-5:] if BRIEF else rows[-20:]
print(f"{len(rows)} local-model turns on record; showing last {len(tail)}.")
if not BRIEF:
    print("thinkTok = exact if the runtime reports it; thinkCh = characters in thinking blocks.\n")
head = f"{'when':<20}{'dur_s':>8}{'in':>9}{'cacheRd':>9}{'out':>8}{'thinkTok':>10}{'thinkCh':>9}{'textCh':>8}{'tools':>6}{'tok/s':>8}"
print(head)
print("-" * len(head))
for r in tail:
    when = datetime.fromtimestamp(r["t"]).strftime("%Y-%m-%d %H:%M:%S") if r["t"] else "?"
    tps = (r["out"] / r["dur"]) if (r["out"] and r["dur"] and r["dur"] > 0) else None
    def f(v, w, dp=0):
        return (f"{v:>{w}.{dp}f}" if isinstance(v, float) else f"{v:>{w}}") if v is not None else f"{'-':>{w}}"
    print(f"{when:<20}{f(r['dur'],8,1)}{f(r['in'],9)}{f(r['cr'],9)}{f(r['out'],8)}"
          f"{f(r['think_tok'],10)}{f(r['think_chars'],9)}{f(r['text_chars'],8)}{f(r['tools'],6)}{f(tps,8,1)}")

outs = sorted(r["out"] for r in rows if r["out"])
durs = sorted(r["dur"] for r in rows if r["dur"])
crs = [r for r in rows if r["cr"] is not None]
def med(xs):
    return xs[len(xs) // 2] if xs else None
print()
print(f"median output tokens/turn : {med(outs)}")
print(f"median turn duration (s)  : {round(med(durs), 1) if med(durs) else '-'}")
print(f"turns over 2000 out tokens: {sum(1 for o in outs if o > 2000)} of {len(outs)}")
print(f"turns with a thinking block: {sum(1 for r in rows if r['think_chars'] > 0)} of {len(rows)}")
if crs:
    reuse = sum(1 for r in crs if (r["cr"] or 0) > 0)
    print(f"turns with cache_read > 0 : {reuse} of {len(crs)}   (low = prefix cache is not being reused)")
else:
    print("cache_read_input_tokens  : never reported by this runtime")
PY

# ------------------------------------------------------------- 3. the server
hr "3. server"
if curl -sf -m 3 "${BASE_URL}/health" >/dev/null 2>&1; then
  echo "health: up on ${BASE_URL}"
else
  echo "health: DOWN on ${BASE_URL} -- start it with 'claude-local start', then re-run."
fi
if verbose; then
  echo "--- actual serve flags (what is running, not what the script says) ---"
  pgrep -fl "rapid-mlx serve" || echo "(no rapid-mlx serve process)"
  [ -f "$PID_FILE" ] && echo "pid file: $(cat "$PID_FILE")"
  echo "--- /v1/models ---"
  curl -sf -m 3 "${BASE_URL}/v1/models" 2>/dev/null | head -c 800 || echo "(no answer)"
  echo
fi
echo "--- /v1/status ---"
curl -sf -m 3 "${BASE_URL}/v1/status" 2>/dev/null | head -c 400 || echo "(no answer)"
echo

hr "4. model profile and MTP"
# `rapid-mlx info` is the authority on whether this alias gets speculative
# decoding for free. For qwen3.8-27b-4bit it does NOT: the arch is hybrid, so
# spec decode is off and MTP is an opt-in sidecar behind --speculative-config.
if ! have rapid-mlx; then
  echo "(rapid-mlx not on PATH)"
elif verbose; then
  rapid-mlx info "$MODEL" 2>&1 | sed -n '1,22p'
else
  rapid-mlx info "$MODEL" 2>&1 | grep -iE 'Spec decode|MTP path|Architecture' || true
fi
echo "--- is --speculative-config actually on the running process? ---"
if pgrep -fl "rapid-mlx serve" 2>/dev/null | grep -q -- "--speculative-config"; then
  echo "yes: MTP requested"
else
  echo "NO: the server is running without --speculative-config, so decode is plain."
fi

hr "5. metrics that matter"
metrics() { curl -sf -m 5 "${BASE_URL}/metrics" 2>/dev/null || true; }
M_BEFORE="$(metrics)"
if [ -z "$M_BEFORE" ]; then
  echo "/metrics returned nothing."
else
  echo "--- speculative decoding (MTP). Zero or absent = MTP is off, so ~15 tok/s not ~26 ---"
  printf '%s\n' "$M_BEFORE" | grep -iE '^[a-z_]*(spec|draft|accept)' || echo "(no spec-decode metrics at all)"
  echo "--- prefix cache. misses climbing once per turn = every turn re-prefills ---"
  printf '%s\n' "$M_BEFORE" | grep -iE '^[a-z_]*(prefix|cache)' || echo "(no cache metrics)"
  if verbose; then
    echo "--- requests ---"
    printf '%s\n' "$M_BEFORE" | grep -iE '^[a-z_]*requests' || echo "(no request metrics)"
    echo "--- every metric name exposed (the dashboard guesses at these) ---"
    { printf '%s\n' "$M_BEFORE" | grep -oE '^[a-zA-Z_:][a-zA-Z0-9_:]*' || true; } | sort -u | tr '\n' ' '
    echo
  fi
fi

hr "6. memory and swap"
if verbose; then
  memory_pressure 2>/dev/null | tail -5 || echo "(memory_pressure unavailable)"
  vm_stat 2>/dev/null | grep -iE 'swapin|swapout|compress|pageout' || true
else
  memory_pressure 2>/dev/null | grep -i 'free percentage' || true
  vm_stat 2>/dev/null | grep -iE 'swapin|swapout' | tr '\n' ' ' || true; echo
fi
sysctl vm.swapusage 2>/dev/null || true
rmpid="$(pgrep -f 'rapid-mlx serve' | head -1 || true)"
[ -n "$rmpid" ] && ps -o rss= -p "$rmpid" | awk '{printf "rapid-mlx RSS: %.1f GB\n", $1/1048576}'

hr "7. notable log lines"
if [ -f "$LOG_FILE" ]; then
  # An /v1/oauth/token line here means Claude Code sent its user-OAuth refresh
  # to ANTHROPIC_BASE_URL, i.e. to this server, which 404s it. That produces the
  # red "User OAuth refresh failed (HTTP 404)" banner at launch.
  if grep -qi 'oauth' "$LOG_FILE" 2>/dev/null; then
    echo "OAUTH: this server was asked for an OAuth token endpoint:"
    grep -i 'oauth' "$LOG_FILE" | tail -3 | cut -c1-200
    echo "  -> set CLAUDE_LOCAL_ISOLATE_CONFIG=1 to give claude-local its own"
    echo "     CLAUDE_CONFIG_DIR, which has no stored login to refresh."
  fi
  grep -iE 'error|warn|cancel|abort|disconnect|timeout|oom|out of memory|swap|spec|mtp|draft|oauth' "$LOG_FILE" \
    | tail -"$( [ "$BRIEF" = 1 ] && echo 6 || echo 30 )" | cut -c1-300 || echo "(none)"
else
  echo "no log at $LOG_FILE"
fi

# ------------------------------------------------------------------ probes
if [ "$PROBE" = "0" ]; then
  hr "8. probes"
  echo "skipped (--no-probe)"
  echo
  echo "report written to $OUT"
  exit 0
fi

hr "8. probes"
python3 - "$BASE_URL" "$MODEL" <<'PY'
import json, time, urllib.error, urllib.request

import os
base, model = __import__("sys").argv[1], __import__("sys").argv[2]
BRIEF = os.environ.get("BRIEF") == "1"
HEADERS = {"content-type": "application/json", "x-api-key": "local",
           "anthropic-version": "2023-06-01"}


def metrics():
    out = {}
    try:
        with urllib.request.urlopen(base + "/metrics", timeout=5) as r:
            for line in r.read().decode("utf-8", "replace").splitlines():
                if line.startswith("#") or " " not in line:
                    continue
                name, _, val = line.rpartition(" ")
                name = name.split("{")[0].strip()
                try:
                    out[name] = float(val)
                except ValueError:
                    pass
    except (urllib.error.URLError, OSError):
        pass
    return out


def send(label, messages, max_tokens, extra=None):
    body = {"model": model, "max_tokens": max_tokens, "messages": messages}
    if extra:
        body.update(extra)
    data = json.dumps(body).encode()
    before = metrics()
    t0 = time.time()
    try:
        req = urllib.request.Request(base + "/v1/messages", data=data, headers=HEADERS)
        with urllib.request.urlopen(req, timeout=900) as r:
            resp = json.loads(r.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        print(f"{label}: HTTP {e.code} -- {e.read()[:300].decode('utf-8', 'replace')}")
        return None
    except (urllib.error.URLError, OSError, ValueError) as e:
        print(f"{label}: failed -- {e}")
        return None
    dur = time.time() - t0
    after = metrics()
    u = resp.get("usage") or {}
    content = resp.get("content") or []
    think = sum(len(b.get("thinking") or "") for b in content
                if isinstance(b, dict) and b.get("type") == "thinking")
    text = "".join(b.get("text") or "" for b in content
                   if isinstance(b, dict) and b.get("type") == "text")
    out_tok = u.get("output_tokens")
    r = {"label": label, "dur": dur, "usage": u, "think_chars": think,
         "text": text.strip()[:120], "stop": resp.get("stop_reason"),
         "out": out_tok,
         "have_cache_metrics": "prefix_cache_hits_total" in after,
         "hits": (after.get("prefix_cache_hits_total", 0) - before.get("prefix_cache_hits_total", 0)),
         "miss": (after.get("prefix_cache_misses_total", 0) - before.get("prefix_cache_misses_total", 0)),
         "saved": (after.get("prefix_cache_tokens_saved_total", 0) - before.get("prefix_cache_tokens_saved_total", 0))}
    tps = (out_tok / dur) if (out_tok and dur) else None
    if BRIEF:
        print(f"{label}: {dur:.1f}s, out={out_tok}, think_chars={think}, "
              f"{f'{tps:.1f} tok/s' if tps else '-'}, stop={r['stop']}, "
              f"cache hits+{r['hits']:.0f}/miss+{r['miss']:.0f}")
        return r
    print(f"\n{label}")
    print(f"  duration        : {dur:.1f} s")
    print(f"  usage           : {json.dumps(u)}")
    print(f"  decode          : {f'{tps:.1f} tok/s' if tps else '-'}   stop_reason={r['stop']}")
    print(f"  thinking chars  : {think}")
    print(f"  prefix cache    : hits +{r['hits']:.0f}  misses +{r['miss']:.0f}  tokens saved +{r['saved']:.0f}")
    print(f"  text            : {r['text']!r}")
    return r


if not BRIEF:
    print("Probes 1/1a/1b/1c ask the smallest possible question four ways, to see how")
    print("much the model thinks unasked and whether the effort cap changes that.")
    print("Probes 2-4 test whether the prefix cache survives a conversation that")
    print("grows, which is the shape Claude Code actually sends.")

TRIVIAL = [{"role": "user", "content": "Reply with exactly: OK"}]
p1 = send("probe 1: trivial prompt, no effort field (what the model does unasked)",
          TRIVIAL, 2048)
# rapid-mlx 0.13.4 maps output_config.effort to a reasoning cap:
# low=512, medium=2048, high=8192, xhigh=24000, max=uncapped
# (vllm_mlx/api/anthropic_models.py, ANTHROPIC_EFFORT_TO_REASONING_MAX_TOKENS).
# The cap only saves wall-clock if it is enforced by the force-close logits
# processor. If it is applied post-hoc the model still generates every thinking
# token and the trim happens afterwards -- same 10 minutes, shorter transcript.
# These two probes tell the difference.
p_low = send("probe 1a: same prompt, output_config.effort=low (cap 512)",
             TRIVIAL, 2048, {"output_config": {"effort": "low"},
                             "thinking": {"type": "adaptive"}})
p_max = send("probe 1b: same prompt, output_config.effort=max (uncapped)",
             TRIVIAL, 2048, {"output_config": {"effort": "max"},
                             "thinking": {"type": "adaptive"}})
p_off = send("probe 1c: same prompt, thinking disabled (the floor)",
             TRIVIAL, 2048, {"thinking": {"type": "disabled"}})

filler = ("The launcher starts the runtime, waits for health, then execs Claude Code. " * 320)
convo = [{"role": "user", "content": filler + "\n\nReply with exactly: A"}]
p2 = send("probe 2: ~6k-token prompt, cold", convo, 16)
p3 = send("probe 3: identical prompt again (should hit the prefix cache)", convo, 16)
convo4 = convo + [{"role": "assistant", "content": "A"},
                  {"role": "user", "content": "Reply with exactly: B"}]
p4 = send("probe 4: same conversation, one turn longer (the Claude Code shape)", convo4, 16)

print("\n--- reading of the probes ---")
if p_low and p_max:
    lo, mx = p_low["out"] or 0, p_max["out"] or 0
    print(f"* effort low vs max: {lo} vs {mx} output tokens, "
          f"{p_low['dur']:.1f}s vs {p_max['dur']:.1f}s")
    if lo >= 600:
        print("  -> effort=low did NOT hold the model to its 512-token reasoning cap.")
        print("     Either this runtime is older than the output_config.effort")
        print("     support, or the cap is being applied post-hoc, after every")
        print("     thinking token was already generated. Post-hoc saves no time.")
    else:
        print("  -> the effort cap is being enforced during generation. Good.")
if p_off and p_low:
    print(f"* thinking disabled: {p_off['out']} output tokens in {p_off['dur']:.1f}s "
          f"(vs {p_low['out']} at effort=low)")
if p1:
    o = p1["out"] or 0
    if p1["think_chars"] > 400 or o > 300:
        print(f"* OVERTHINKING: a one-word answer cost {o} output tokens "
              f"({p1['think_chars']} chars of thinking). The effort cap is not reaching the model.")
    else:
        print(f"* thinking looks capped: {o} output tokens for a one-word answer.")
    if p1["dur"] > 60:
        print(f"* a trivial prompt took {p1['dur']:.0f} s. That is the whole bug in one line.")
for a, b, what in ((p2, p3, "identical repeat"), (p2, p4, "conversation grown by one turn")):
    if a and b and a["dur"] > 0:
        ratio = b["dur"] / a["dur"]
        if not b["have_cache_metrics"]:
            state = "unknown (server exposes no prefix_cache_* metrics)"
        elif b["saved"] > 0 or b["hits"] > 0:
            state = "HIT"
        else:
            state = "MISS"
        print(f"* {what}: {a['dur']:.1f}s then {b['dur']:.1f}s ({ratio:.2f}x), "
              f"prefix cache {state}")
        if state == "MISS":
            print("  -> every turn re-prefills the whole context. Raise")
            print("     --hybrid-cache-entries (this alias is a hybrid arch, so")
            print("     prefix-extension reuse depends on it; 0 disables it).")
            print("     Do NOT blame --relocate-mid-conversation-system: that flag")
            print("     exists to PRESERVE the cache for clients like Claude Code")
            print("     that inject reminders mid-session.")
PY

echo
echo "report written to $OUT"
