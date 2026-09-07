"""Regression tests for the dashboard's request-row bookkeeping.

Run: python3 -m unittest dashboard/test_server.py

Feeds scripted /metrics bodies (shaped like rapid-mlx 0.13.4 emits them)
through State.poll_metrics and checks a request row is recorded.
"""
import importlib.util
import os
import socket
import unittest

os.environ["CLAUDE_LOCAL_LOG_FILE"] = "/dev/null"
_SPEC = importlib.util.spec_from_file_location(
    "dashboard_server", os.path.join(os.path.dirname(__file__), "server.py"))
srv = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(srv)
srv.run = lambda *a, **k: ""  # rapid-mlx binary is not needed here

TIMEOUT = object()
BARE = 'rapid_mlx_build_info{version="0.13.4",model="qwen"} 1\n'  # engine.get_stats() failed: no counters


def body(processed, prompt, completion, saved=0, cancelled=0, running=0):
    return "\n".join([
        f"rapid_mlx_requests_cancelled_total {cancelled}",
        f"rapid_mlx_requests_running {running}",
        "# HELP rapid_mlx_build_info Build info",
        "# TYPE rapid_mlx_build_info gauge",
        'rapid_mlx_build_info{version="0.13.4",model="qwen"} 1',
        "# TYPE rapid_mlx_requests_processed_total counter",
        f"rapid_mlx_requests_processed_total {processed}",
        f"rapid_mlx_prompt_tokens_total {prompt}",
        f"rapid_mlx_completion_tokens_total {completion}",
        f"rapid_mlx_prefix_cache_tokens_saved_total {saved}",
        f'rapid_mlx_model_requests_total{{model="qwen",outcome="ok"}} {processed}',
        'rapid_mlx_model_ttft_seconds_bucket{le="+Inf"} 1',
        "rapid_mlx_spec_decode_accept_ratio NaN",
    ]) + "\n"


def poll(script):
    it = iter(script)

    def fake_get(path, timeout=2.0):
        v = next(it)
        if v is TIMEOUT:
            raise socket.timeout("timed out")
        return v

    srv.http_get = fake_get
    st = srv.State()
    for _ in script:
        st.poll_metrics()
    return list(st.requests)


class RequestRows(unittest.TestCase):
    def test_plain_request(self):
        rows = poll([body(0, 0, 0), body(1, 500, 80, 400)])
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]["prompt"], rows[0]["cached"], rows[0]["completion"]), (500, 400, 80))

    def test_scrape_timeout_during_generation_keeps_baseline(self):
        rows = poll([body(0, 0, 0), TIMEOUT, body(1, 500, 80, 400)])
        self.assertEqual(len(rows), 1)

    def test_counters_missing_mid_generation_keeps_baseline(self):
        rows = poll([body(0, 0, 0), BARE, body(1, 500, 80, 400)])
        self.assertEqual(len(rows), 1)

    def test_idle_scrapes_add_no_rows(self):
        rows = poll([body(0, 0, 0), body(0, 0, 0), body(1, 500, 80), body(1, 500, 80)])
        self.assertEqual(len(rows), 1)

    def test_server_restart_resets_baseline(self):
        rows = poll([body(7, 9000, 900), body(0, 0, 0), body(1, 500, 80)])
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["prompt"], 500)


class Diagnostics(unittest.TestCase):
    def test_cancelled_request_gets_a_row(self):
        rows = poll([body(0, 0, 0), body(0, 0, 0, cancelled=1)])
        self.assertEqual(len(rows), 1)
        self.assertTrue(rows[0]["cancelled"])

    def test_scrape_health_and_inflight(self):
        srv.http_get = lambda path, timeout=2.0: body(0, 0, 0, running=1)
        st = srv.State()
        st.poll_metrics()
        self.assertEqual(st.scrape["ok"], 1)
        self.assertIsNotNone(st.inflight_since)
        self.assertEqual(st.counters["running"], 1)
        srv.http_get = lambda path, timeout=2.0: body(0, 0, 0, running=0)
        st.poll_metrics()
        self.assertIsNone(st.inflight_since)


if __name__ == "__main__":
    unittest.main()
