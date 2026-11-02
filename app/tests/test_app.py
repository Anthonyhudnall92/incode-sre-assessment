"""Route-level tests using a fake database (no AWS or PostgreSQL needed)."""

import json
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import app  # noqa: E402


class FakeDb:
    def __init__(self, healthy=True):
        self.healthy = healthy
        self.monitors = {}
        self.next_id = 1

    def _check(self):
        if not self.healthy:
            raise RuntimeError("db down")

    def ping(self):
        self._check()

    def list_monitors(self):
        self._check()
        return [{"id": i, **m} for i, m in self.monitors.items()]

    def add_monitor(self, name, url, method, interval):
        self._check()
        if any(m["url"] == url and m["method"] == method for m in self.monitors.values()):
            raise app.Duplicate()
        if len(self.monitors) >= app.MAX_MONITORS:
            raise app.BoardFull()
        mid, self.next_id = self.next_id, self.next_id + 1
        self.monitors[mid] = {"name": name, "url": url, "method": method,
                              "interval": interval, "token": f"tok{mid}"}
        return mid, f"tok{mid}"

    def delete_monitor(self, monitor_id, token):
        self._check()
        m = self.monitors.get(monitor_id)
        if m and m["token"] == token:
            del self.monitors[monitor_id]
            return True
        return False


def public_dns(host, port, type=0):  # noqa: A002 - mirrors socket.getaddrinfo
    return [(2, 1, 6, "", ("93.184.215.14", port))]


class AppTest(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch("checker._getaddrinfo", side_effect=public_dns)
        patcher.start()
        self.addCleanup(patcher.stop)

    def start(self, db):
        server = ThreadingHTTPServer(("127.0.0.1", 0), app.make_handler(db))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_address[1]}"

    def request(self, url, method="GET", body=None, headers=None):
        data = None if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
        hdrs = {"Content-Type": "application/json"} if body is not None else {}
        hdrs.update(headers or {})
        req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status, resp.read(), dict(resp.headers)
        except urllib.error.HTTPError as err:
            return err.code, err.read(), dict(err.headers)

    def add(self, base, **fields):
        body = {"url": "https://example.com/", "method": "GET", "interval": 300, **fields}
        status, raw, _ = self.request(base + "/api/monitors", "POST", body)
        return status, json.loads(raw)

    # Health and metrics ----------------------------------------------------------
    def test_healthz_does_not_touch_db(self):
        status, body, _ = self.request(self.start(FakeDb(healthy=False)) + "/healthz")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["status"], "ok")

    def test_readyz_reflects_db(self):
        self.assertEqual(self.request(self.start(FakeDb(True)) + "/readyz")[0], 200)
        self.assertEqual(self.request(self.start(FakeDb(False)) + "/readyz")[0], 503)

    def test_metrics_exposed_with_low_cardinality(self):
        base = self.start(FakeDb())
        self.request(base + "/does-not-exist-123")
        self.request(base + "/api/monitors/42", "DELETE")
        status, body, _ = self.request(base + "/metrics")
        self.assertEqual(status, 200)
        self.assertIn(b"http_requests_total", body)
        self.assertNotIn(b"does-not-exist-123", body)
        self.assertIn(b'route="other"', body)
        self.assertIn(b'route="/api/monitors/:id"', body)

    # The page ------------------------------------------------------------------
    def test_board_page_and_assets_with_security_headers(self):
        base = self.start(FakeDb(healthy=False))  # the page itself needs no database
        status, body, headers = self.request(base + "/")
        self.assertEqual(status, 200)
        self.assertIn(b"Uptime board", body)
        self.assertIn("script-src 'self'", headers["Content-Security-Policy"])
        self.assertNotIn("unsafe-inline", headers["Content-Security-Policy"])
        self.assertEqual(headers["X-Frame-Options"], "DENY")
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
        self.assertEqual(self.request(base + "/static/app.js")[0], 200)
        self.assertEqual(self.request(base + "/static/style.css")[0], 200)
        self.assertEqual(self.request(base + "/static/../app.py")[0], 404)

    # API -----------------------------------------------------------------------
    def test_add_list_and_delete_with_token(self):
        base = self.start(FakeDb())
        status, created = self.add(base, name="Example")
        self.assertEqual(status, 201)
        status, body, _ = self.request(base + "/api/monitors")
        monitors = json.loads(body)["monitors"]
        self.assertEqual([m["name"] for m in monitors], ["Example"])

        url = f"{base}/api/monitors/{created['id']}"
        self.assertEqual(self.request(url, "DELETE")[0], 403)
        self.assertEqual(self.request(url, "DELETE", headers={"X-Delete-Token": "wrong"})[0], 403)
        self.assertEqual(self.request(url, "DELETE", headers={"X-Delete-Token": created["token"]})[0], 200)

    def test_add_refuses_private_and_odd_targets(self):
        base = self.start(FakeDb())
        for url in (
            "http://169.254.169.254/latest/meta-data/",
            "http://10.0.0.5/",
            "http://localhost/",
            "http://[::1]/",
            "https://example.com:8443/",
            "ftp://example.com/",
            "https://user:pass@example.com/",
            "http://kubernetes.default.svc.cluster.local/",
        ):
            with self.subTest(url=url):
                status, body = self.add(base, url=url)
                self.assertEqual(status, 400, body)

    def test_add_refuses_hosts_that_resolve_privately(self):
        base = self.start(FakeDb())
        private = lambda host, port, type=0: [(2, 1, 6, "", ("10.40.1.20", port))]  # noqa: E731
        with mock.patch("checker._getaddrinfo", side_effect=private):
            status, body = self.add(base, url="https://sneaky.example.com/")
        self.assertEqual(status, 400)
        self.assertIn("Private", body["error"])

    def test_add_validates_method_interval_and_body(self):
        base = self.start(FakeDb())
        self.assertEqual(self.add(base, method="POST")[0], 400)
        self.assertEqual(self.add(base, interval=10)[0], 400)
        status, _, _ = self.request(base + "/api/monitors", "POST", b"url=https://example.com",
                                    headers={"Content-Type": "application/x-www-form-urlencoded"})
        self.assertEqual(status, 400)  # cross-site forms cannot post JSON
        self.assertEqual(self.request(base + "/api/monitors", "POST", b"[1]")[0], 400)

    def test_duplicates_and_cap(self):
        base = self.start(FakeDb())
        self.assertEqual(self.add(base)[0], 201)
        self.assertEqual(self.add(base)[0], 409)
        with mock.patch.object(app, "MAX_MONITORS", 1):
            status, body = self.add(base, url="https://example.org/")
        self.assertEqual(status, 409)
        self.assertIn("full", body["error"])

    def test_api_returns_503_when_db_down(self):
        base = self.start(FakeDb(False))
        self.assertEqual(self.request(base + "/api/monitors")[0], 503)
        self.assertEqual(self.add(base)[0], 503)


if __name__ == "__main__":
    unittest.main()
