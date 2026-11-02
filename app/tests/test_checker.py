"""SSRF guards and check results, with DNS and HTTP faked."""

import unittest
from pathlib import Path
from unittest import mock
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import checker  # noqa: E402


def dns(answers):
    def fake(host, port, type=0):  # noqa: A002
        return [(2 if ":" not in a else 10, 1, 6, "", (a, port)) for a in answers.get(host, [])]
    return fake


class ParseUrlTest(unittest.TestCase):
    def test_normalises(self):
        t = checker.parse_url("Example.COM/status?x=1")
        self.assertEqual(t.url, "https://example.com/status?x=1")
        self.assertEqual((t.host, t.port, t.path), ("example.com", 443, "/status?x=1"))

    def test_refuses(self):
        for raw in (
            "", "ftp://example.com", "https://a:b@example.com", "https://example.com:22/",
            "http://127.0.0.1/", "http://169.254.169.254/", "http://[::ffff:10.0.0.1]/",
            "http://100.64.0.1/", "http://intranet/", "http://db.internal/", "http://x.local/",
            "https://" + "a" * 2050 + ".com",
        ):
            with self.subTest(raw=raw), self.assertRaises(checker.Refused):
                checker.parse_url(raw)


class ResolveTest(unittest.TestCase):
    def test_public_prefers_ipv4(self):
        with mock.patch("checker._getaddrinfo", dns({"h.com": ["2606:4700::1", "93.184.215.14"]})):
            self.assertEqual(checker.resolve("h.com", 443), "93.184.215.14")

    def test_any_private_answer_is_refused(self):
        with mock.patch("checker._getaddrinfo", dns({"h.com": ["93.184.215.14", "10.0.0.7"]})):
            with self.assertRaises(checker.Refused):
                checker.resolve("h.com", 443)


class CheckTest(unittest.TestCase):
    def setUp(self):
        p = mock.patch("checker._getaddrinfo", dns({
            "good.com": ["93.184.215.14"], "evil.com": ["169.254.169.254"],
        }))
        p.start()
        self.addCleanup(p.stop)

    def test_up(self):
        with mock.patch("checker._fetch", return_value=(200, None)) as fetch:
            r = checker.check("https://good.com/", "HEAD", "ua")
        self.assertTrue(r.ok)
        self.assertEqual(r.status_code, 200)
        # Connected to the resolved address, not the name.
        self.assertEqual(fetch.call_args.args[1], "93.184.215.14")

    def test_http_error_is_down(self):
        with mock.patch("checker._fetch", return_value=(503, None)):
            r = checker.check("https://good.com/", "GET", "ua")
        self.assertFalse(r.ok)
        self.assertEqual(r.error, "HTTP 503")

    def test_redirect_to_metadata_service_is_refused(self):
        with mock.patch("checker._fetch", return_value=(302, "http://evil.com/latest/meta-data/")) as fetch:
            r = checker.check("https://good.com/", "GET", "ua")
        self.assertFalse(r.ok)
        self.assertIn("Private", r.error)
        self.assertEqual(fetch.call_count, 1)  # never fetched the second hop

    def test_redirect_loop_stops(self):
        with mock.patch("checker._fetch", return_value=(301, "/again")) as fetch:
            r = checker.check("https://good.com/", "GET", "ua")
        self.assertEqual(r.error, "Too many redirects")
        self.assertEqual(fetch.call_count, checker.MAX_REDIRECTS + 1)

    def test_network_errors_never_raise(self):
        with mock.patch("checker._fetch", side_effect=OSError("boom")):
            r = checker.check("https://good.com/", "GET", "ua")
        self.assertFalse(r.ok)
        self.assertIn("Connection error", r.error)


if __name__ == "__main__":
    unittest.main()
