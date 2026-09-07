#!/usr/bin/env python3
"""claude-local dashboard: one page that answers "why is this turn slow?".

Python 3 stdlib only. Started by `claude-local dashboard`, which passes the
launcher's paths via CLAUDE_LOCAL_* env vars. `--mock` serves fake data so the
page can be checked on a machine without rapid-mlx.
"""
import argparse
import json
import os
import random
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import webbrowser
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# --- verdict thresholds (tune on the work Mac) ---------------------------
PLAIN_DECODE_TPS = 15.0   # 27B 4-bit without MTP
MTP_ON_TPS = 25.0         # above this, MTP is clearly helping
CACHE_MISS_RATIO = 0.5    # cached/prompt below this = miss
LONG_OUTPUT_TOKENS = 2000 # completion above this on one turn = thinking wall?
SLOW_REQUEST_S = 120      # in-flight longer than this gets flagged
POLL_METRICS_S = 1.0
POLL_MEMORY_S = 5.0
HISTORY = 20

HERE = os.path.dirname(os.path.abspath(__file__))
ENV = os.environ
LAUNCHER = ENV.get("CLAUDE_LOCAL_LAUNCHER", "claude-local")
BASE_URL = ENV.get("CLAUDE_LOCAL_BASE_URL", "http://127.0.0.1:8000")
LOG_FILE = ENV.get("CLAUDE_LOCAL_LOG_FILE", os.path.expanduser("~/.cache/claude-local/server.log"))
PID_FILE = ENV.get("CLAUDE_LOCAL_PID_FILE", os.path.expanduser("~/.cache/claude-local/server.pid"))
PROFILE_FILE = ENV.get("CLAUDE_LOCAL_PROFILE_FILE", os.path.expanduser("~/.config/claude-local/profile"))
PORT = int(ENV.get("CLAUDE_LOCAL_DASHBOARD_PORT", "8001"))

NOTABLE_RE = re.compile(r"(?i)error|warn|cancel|abort|disconnect|traceback|timeout|oom|out of memory|swap")
LOG_LINE_RE = re.compile(r"Chat completion(?: \(stream\))?: (\d+) tokens in ([\d.]+)s \(([\d.]+) tok/s\)")
MTP_LINE_RE = re.compile(r"(?i)\b(mtp|spec(ulative)?|draft)\b")
PROM_RE = re.compile(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^}]*\})?\s+([-+0-9.eE]+|NaN|[+-]Inf)\s*$')
LABEL_RE = re.compile(r'(\w+)="([^"]*)"')


# --- helpers --------------------------------------------------------------
def http_get(path, timeout=2.0):
    with urllib.request.urlopen(BASE_URL + path, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


def http_json(path):
    try:
        return json.loads(http_get(path))
    except (urllib.error.URLError, ValueError, OSError):
        return None


def run(cmd, timeout=5):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def parse_prometheus(text):
    """Return ({name: value}, {name: labels}) for single-series metrics."""
    values, labels = {}, {}
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        m = PROM_RE.match(line)
        if not m:
            continue
        name, lab, val = m.groups()
        try:
            values[name] = float(val)
        except ValueError:
            continue
        if lab:
            labels[name] = dict(LABEL_RE.findall(lab))
    return values, labels


def metric(values, *suffixes):
    """First metric whose name ends with any suffix; tolerant to renames."""
    for suf in suffixes:
        for k, v in values.items():
            if k.endswith(suf):
                return v
    return None


def tail_lines(path, n):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            block = 4096
            data = b""
            while size > 0 and data.count(b"\n") <= n:
                step = min(block, size)
                size -= step
                f.seek(size)
                data = f.read(step) + data
                block *= 2
        return data.decode("utf-8", "replace").splitlines()[-n:]
    except OSError:
        return []


def read_profile():
    prof = {"MODEL": "", "PORT": "", "EFFORT": ""}
    try:
        with open(PROFILE_FILE) as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    prof[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return prof


def write_profile(prof):
    os.makedirs(os.path.dirname(PROFILE_FILE), exist_ok=True)
    with open(PROFILE_FILE, "w") as f:
        f.write("# written by claude-local dashboard\n")
        for k in ("MODEL", "PORT", "EFFORT"):
            v = prof.get(k, "").strip()
            if v and re.fullmatch(r"[A-Za-z0-9._:-]+", v):
                f.write(f"{k}={v}\n")


def server_pid():
    try:
        with open(PID_FILE) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return None


def serve_flags(pid):
    if not pid:
        return ""
    out = run(["ps", "-o", "command=", "-p", str(pid)]).strip()
    return out.split("rapid-mlx", 1)[-1].strip() if "rapid-mlx" in out else out


def memory_snapshot():
    level = run(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"]).strip()
    level = int(level) if level.isdigit() else None
    vm = run(["vm_stat"])
    swapins = free = page = None
    m = re.search(r"page size of (\d+)", vm)
    page = int(m.group(1)) if m else 16384
    m = re.search(r"Swapins:\s+(\d+)", vm)
    swapins = int(m.group(1)) if m else None
    m = re.search(r"Pages free:\s+(\d+)", vm)
    free = int(m.group(1)) * page / 2**30 if m else None
    return {"level": level, "swapins": swapins, "free_gb": free}


# --- state ---------------------------------------------------------------
class State:
    def __init__(self, mock=False):
        self.mock = mock
        self.lock = threading.Lock()
        self.requests = deque(maxlen=HISTORY)
        self.prev = None          # last metrics snapshot (values dict)
        self.memory = {"level": None, "swapins": None, "free_gb": None}
        self.swapins_prev = None
        self.swapins_delta = 0
        self.mtp_line = ""
        self.version = run(["rapid-mlx", "--version"]).strip() if not mock else "rapid-mlx mock 0.0"
        self.action = ""          # "starting" | "stopping" | "restarting" | ""
        self.action_out = ""
        self.mock_seq = 0
        self.log_seen = 0
        # raw counters from the last good scrape, shown on the diagnostics card
        self.counters = {}
        self.scrape = {"ok": 0, "failed": 0, "last_ms": None, "last_error": "", "last_ok_t": None}
        self.inflight_since = None   # time the current request was first seen running

    # -- polling ---------------------------------------------------------
    def poll_metrics(self):
        if self.mock:
            return self.mock_tick()
        t0 = time.time()
        try:
            values, labels = parse_prometheus(http_get("/metrics"))
        except (urllib.error.URLError, OSError) as e:
            # Keep the last good baseline. A scrape can time out while the
            # model is busy generating; dropping prev here would make the
            # next good scrape the new baseline and lose the request delta.
            with self.lock:
                self.scrape["failed"] += 1
                self.scrape["last_ms"] = int((time.time() - t0) * 1000)
                self.scrape["last_error"] = str(e)[:120]
            if self.prev is not None:
                print("metrics scrape failed, keeping baseline:", e, file=sys.stderr)
            return
        with self.lock:
            self.scrape["ok"] += 1
            self.scrape["last_ms"] = int((time.time() - t0) * 1000)
            self.scrape["last_ok_t"] = time.time()
        processed = metric(values, "requests_processed_total", "requests_total")
        if processed is None:
            # rapid-mlx returns build_info only when engine.get_stats() fails
            # (e.g. during warmup). Not a baseline; keep the previous one.
            with self.lock:
                self.scrape["last_error"] = "metrics body has no request counters (engine not ready?)"
            return
        running = metric(values, "requests_running")
        cancelled = metric(values, "requests_cancelled_total")
        snap = {
            "processed": processed,
            "prompt": metric(values, "prompt_tokens_total"),
            "completion": metric(values, "completion_tokens_total"),
            "saved": metric(values, "prefix_cache_tokens_saved_total", "cache_tokens_saved_total"),
            "hits": metric(values, "prefix_cache_hits_total"),
            "misses": metric(values, "prefix_cache_misses_total"),
            "cancelled": cancelled,
            "labels": labels.get(next((k for k in labels if k.endswith("build_info")), ""), {}),
            "values": values,
        }
        with self.lock:
            prev = self.prev
            self.prev = snap
            self.counters = {
                "processed": processed, "running": running,
                "waiting": metric(values, "requests_waiting"),
                "cancelled": cancelled,
                "disconnects": metric(values, "requests_cancelled_via_disconnect_total"),
                "accept_ratio": metric(values, "spec_decode_accept_ratio"),
                "uptime_s": metric(values, "uptime_seconds"),
            }
            if running:
                self.inflight_since = self.inflight_since or time.time()
            else:
                self.inflight_since = None
            if prev:
                n = int(processed - prev["processed"])
                if n > 0:
                    self.add_request(prev, snap, n)
                # n < 0: counters reset (server restarted); snap is the new baseline.
                if cancelled is not None and prev.get("cancelled") is not None:
                    c = int(cancelled - prev["cancelled"])
                    if c > 0:
                        self.requests.append({"t": time.time(), "n": c, "cancelled": True,
                                              "prompt": None, "cached": None, "completion": None,
                                              "tps": None, "duration": None})

    def add_request(self, prev, snap, n):
        def d(k):
            a, b = prev.get(k), snap.get(k)
            return int(b - a) if a is not None and b is not None else None
        row = {
            "t": time.time(),
            "n": n,                       # >1 means requests overlapped; numbers are a sum
            "prompt": d("prompt"),
            "cached": d("saved"),
            "completion": d("completion"),
            "tps": None, "duration": None,
        }
        for line in reversed(tail_lines(LOG_FILE, 50)):
            m = LOG_LINE_RE.search(line)
            if m:
                row["duration"] = float(m.group(2))
                row["tps"] = float(m.group(3))
                break
        self.requests.append(row)

    def poll_memory(self):
        mem = memory_snapshot() if not self.mock else {
            "level": random.choice([1, 1, 1, 2]), "swapins": (self.swapins_prev or 0) + random.choice([0, 0, 0, 40]),
            "free_gb": round(random.uniform(2, 9), 1)}
        with self.lock:
            if mem["swapins"] is not None and self.swapins_prev is not None:
                self.swapins_delta = mem["swapins"] - self.swapins_prev
            self.swapins_prev = mem["swapins"]
            self.memory = mem
        if not self.mtp_line:
            for line in tail_lines(LOG_FILE, 400)[:200] if not self.mock else ["[mock] MTP speculative decoding enabled (draft head)"]:
                if MTP_LINE_RE.search(line):
                    with self.lock:
                        self.mtp_line = line.strip()[:200]
                    break

    def mock_tick(self):
        self.mock_seq += 1
        with self.lock:
            self.scrape = {"ok": self.mock_seq, "failed": self.mock_seq // 10, "last_ms": random.choice([3, 5, 2100]),
                           "last_error": "timed out" if self.mock_seq % 10 == 0 else "", "last_ok_t": time.time()}
            self.counters = {"processed": self.mock_seq // 8, "running": self.mock_seq % 8 > 5, "waiting": 0,
                             "cancelled": self.mock_seq // 30, "disconnects": self.mock_seq // 30,
                             "accept_ratio": 0.71, "uptime_s": 3600 + self.mock_seq}
            self.inflight_since = (time.time() - 40) if self.mock_seq % 8 > 5 else None
        if self.mock_seq % 8 == 0:
            prompt = random.choice([1200, 22000, 24000, 800])
            miss = random.random() < 0.4
            comp = random.choice([120, 340, 60, 4100])
            tps = random.choice([14.2, 41.5, 38.0, 12.9])
            with self.lock:
                self.requests.append({
                    "t": time.time(), "n": 1, "prompt": prompt,
                    "cached": 0 if miss else int(prompt * 0.95),
                    "completion": comp, "tps": tps, "duration": round(comp / tps + (prompt / 300 if miss else 0.4), 1)})

    # -- control -----------------------------------------------------------
    def do_action(self, name):
        with self.lock:
            if self.action:
                return False
            self.action = name
            self.action_out = ""
        threading.Thread(target=self._run_action, args=(name,), daemon=True).start()
        return True

    def _run_action(self, name):
        out = ""
        if self.mock:
            time.sleep(2)
            out = f"[mock] {name} done"
        else:
            steps = {"start": ["start"], "stop": ["stop"], "restart": ["stop", "start"]}[name]
            for step in steps:
                try:
                    r = subprocess.run([LAUNCHER, step], capture_output=True, text=True, timeout=660)
                    out += r.stdout + r.stderr
                    if r.returncode != 0:
                        out += f"\n{step} failed (exit {r.returncode})"
                        break
                except (OSError, subprocess.SubprocessError) as e:
                    out += f"\n{step} error: {e}"
                    break
        with self.lock:
            self.action = ""
            self.action_out = out.strip()[-2000:]

    # -- view ----------------------------------------------------------------
    def snapshot(self):
        if self.mock:
            up = True
            status = {"generation_tps": round(random.uniform(10, 45), 1), "prompt_tps": round(random.uniform(200, 900), 0),
                      "num_running": random.choice([0, 0, 1]), "num_waiting": 0,
                      "metal_active_memory_gb": 16.4, "metal_peak_memory_gb": 19.1, "uptime_s": 3600 + self.mock_seq}
            models = ["qwen3.8-27b-4bit"]
            flags = "serve qwen3.8-27b-4bit --port 8000 --pin-system-prompt --hybrid-cache-entries 4"
            pid = 4242
        else:
            up = http_json("/health") is not None
            status = http_json("/v1/status") or {}
            mj = http_json("/v1/models") or {}
            models = [m.get("id") for m in mj.get("data", []) if isinstance(m, dict)]
            pid = server_pid()
            flags = serve_flags(pid)
        with self.lock:
            reqs = list(self.requests)
            mem = dict(self.memory)
            swap_delta = self.swapins_delta
            mtp_line = self.mtp_line
            prev = self.prev
            action, action_out = self.action, self.action_out
            counters, scrape = dict(self.counters), dict(self.scrape)
            inflight_s = (time.time() - self.inflight_since) if self.inflight_since else None
        cache = None
        if prev and prev.get("hits") is not None and prev.get("misses") is not None:
            tot = prev["hits"] + prev["misses"]
            cache = {"hits": prev["hits"], "misses": prev["misses"], "rate": (prev["hits"] / tot) if tot else None}
        build = (prev or {}).get("labels", {})
        verdict = self.verdict(up, status, reqs, mem, swap_delta, mtp_line, action, inflight_s)
        notable = [ln.rstrip()[:300] for ln in tail_lines(LOG_FILE, 400) if NOTABLE_RE.search(ln)][-30:] if not self.mock else [
            "[mock] WARNING request abc123 cancelled via client disconnect"]
        return {
            "counters": counters, "scrape": scrape, "inflight_s": inflight_s, "notable": notable,
            "up": up, "pid": pid, "models": models, "status": status, "flags": flags,
            "version": self.version or build.get("version", ""), "build": build,
            "requests": list(reversed(reqs)), "memory": mem, "swapins_delta": swap_delta,
            "mtp_line": mtp_line, "cache": cache, "profile": read_profile(),
            "action": action, "action_out": action_out, "verdict": verdict,
            "thresholds": {"plain_tps": PLAIN_DECODE_TPS, "mtp_tps": MTP_ON_TPS, "cache_ratio": CACHE_MISS_RATIO, "long_output": LONG_OUTPUT_TOKENS},
            "mock": self.mock, "now": time.time(),
        }

    @staticmethod
    def verdict(up, status, reqs, mem, swap_delta, mtp_line, action, inflight_s=None):
        if action:
            return {"level": "info", "text": f"{action}..."}
        if not up:
            return {"level": "bad", "text": "Server down."}
        problems = []
        if mem.get("level") and mem["level"] > 1:
            problems.append("memory pressure %s" % ("critical" if mem["level"] >= 4 else "warning"))
        if swap_delta and swap_delta > 0:
            problems.append(f"{swap_delta} swap-ins since last poll")
        if status.get("num_running"):
            ptps = status.get("prompt_tps")
            text = "Request in progress" + (f" for {inflight_s / 60:.1f} min" if inflight_s else "") + (f", prefill {ptps:.0f} tok/s" if ptps else "")
            if inflight_s and inflight_s > SLOW_REQUEST_S:
                problems.insert(0, "slow: check memory pressure and cache miss")
            return {"level": "warn" if problems else "info", "text": "; ".join([text] + problems)}
        if reqs and reqs[-1].get("cancelled"):
            return {"level": "bad", "text": f"Last request cancelled ({reqs[-1]['n']}): client disconnected or timed out and retried. Not counted as processed."}
        if reqs:
            r = reqs[-1]
            p, c = r.get("prompt"), r.get("cached")
            if p and c is not None and p > 0 and c / p < CACHE_MISS_RATIO:
                problems.insert(0, f"cache miss: {p - c:,} tokens prefilled")
            if r.get("tps") is not None and r["tps"] < MTP_ON_TPS:
                problems.append(f"MTP likely off: {r['tps']:.1f} tok/s" + ("" if mtp_line else ", no MTP line in log"))
            if r.get("completion") and r["completion"] > LONG_OUTPUT_TOKENS:
                problems.append(f"long output: {r['completion']:,} tokens, thinking wall?")
        elif not mtp_line:
            problems.append("no MTP line in server log")
        if problems:
            return {"level": "bad" if "cache miss" in problems[0] or "critical" in problems[0] else "warn", "text": "; ".join(problems)}
        return {"level": "good", "text": "Healthy: last request cached, MTP on, memory normal."}


# --- http --------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    state: State = None  # set in main

    def log_message(self, *a):  # quiet
        pass

    def send_json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/":
            with open(os.path.join(HERE, "index.html"), "rb") as f:
                body = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif path == "/api/state":
            self.send_json(self.state.snapshot())
        elif path == "/api/log":
            n = 200
            m = re.search(r"[?&]n=(\d+)", self.path)
            if m:
                n = min(int(m.group(1)), 2000)
            lines = tail_lines(LOG_FILE, n) if not self.state.mock else [
                f"[mock] {time.strftime('%H:%M:%S')} Chat completion (stream): 340 tokens in 8.2s (41.5 tok/s)"] * 3
            self.send_json({"lines": lines})
        else:
            self.send_json({"error": "not found"}, 404)

    def do_POST(self):
        if self.client_address[0] not in ("127.0.0.1", "::1"):
            return self.send_json({"error": "local only"}, 403)
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}") if length else {}
        path = self.path
        if path in ("/api/start", "/api/stop", "/api/restart"):
            ok = self.state.do_action(path.rsplit("/", 1)[1])
            return self.send_json({"ok": ok, "error": None if ok else "action already running"})
        if path == "/api/profile":
            write_profile({k: str(body.get(k, "")) for k in ("MODEL", "PORT", "EFFORT")})
            ok = self.state.do_action("restart") if body.get("restart") else True
            return self.send_json({"ok": ok, "profile": read_profile()})
        self.send_json({"error": "not found"}, 404)


def poller(state):
    last_mem = 0
    while True:
        try:
            state.poll_metrics()
            if time.time() - last_mem >= POLL_MEMORY_S:
                state.poll_memory()
                last_mem = time.time()
        except Exception as e:  # keep polling no matter what
            print("poll error:", e, file=sys.stderr)
        time.sleep(POLL_METRICS_S)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--mock", action="store_true", help="serve fake data (no rapid-mlx needed)")
    ap.add_argument("--no-open", action="store_true", help="do not open the browser")
    ap.add_argument("--port", type=int, default=PORT)
    args = ap.parse_args()

    Handler.state = State(mock=args.mock)
    threading.Thread(target=poller, args=(Handler.state,), daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    url = f"http://127.0.0.1:{args.port}/"
    print(f"dashboard on {url}" + ("  (mock data)" if args.mock else "") + "  Ctrl-C to stop")
    if not args.no_open:
        webbrowser.open(url)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
