"""Route-level tests using a fake database (no AWS or PostgreSQL needed)."""

import json
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import app  # noqa: E402


class FakeDb:
    def __init__(self, healthy=True):
        self.healthy = healthy
        self.visits = 0

    def ping(self):
        if not self.healthy:
            raise RuntimeError("db down")

    def record_visit(self, pod):
        if not self.healthy:
            raise RuntimeError("db down")
        self.visits += 1
        return self.visits


class AppTest(unittest.TestCase):
    def start(self, db):
        server = ThreadingHTTPServer(("127.0.0.1", 0), app.make_handler(db))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_address[1]}"

    def get(self, url):
        try:
            with urllib.request.urlopen(url, timeout=5) as resp:
                return resp.status, resp.read(), dict(resp.headers)
        except urllib.error.HTTPError as err:
            return err.code, err.read(), dict(err.headers)

    def test_healthz_does_not_touch_db(self):
        base = self.start(FakeDb(healthy=False))
        status, body, _ = self.get(base + "/healthz")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["status"], "ok")

    def test_readyz_reflects_db(self):
        self.assertEqual(self.get(self.start(FakeDb(True)) + "/readyz")[0], 200)
        self.assertEqual(self.get(self.start(FakeDb(False)) + "/readyz")[0], 503)

    def test_root_counts_visits(self):
        base = self.start(FakeDb())
        self.get(base + "/")
        status, body, headers = self.get(base + "/")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["visits"], 2)
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")

    def test_root_returns_503_when_db_down(self):
        self.assertEqual(self.get(self.start(FakeDb(False)) + "/")[0], 503)

    def test_metrics_exposed(self):
        base = self.start(FakeDb())
        self.get(base + "/")
        status, body, _ = self.get(base + "/metrics")
        self.assertEqual(status, 200)
        self.assertIn(b"http_requests_total", body)

    def test_unknown_path_is_404_and_low_cardinality(self):
        base = self.start(FakeDb())
        self.assertEqual(self.get(base + "/does-not-exist-123")[0], 404)
        _, body, _ = self.get(base + "/metrics")
        self.assertNotIn(b"does-not-exist-123", body)
        self.assertIn(b'route="other"', body)


if __name__ == "__main__":
    unittest.main()
