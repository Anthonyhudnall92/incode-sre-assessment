"""Uptime monitor for the SRE take-home.

A shared status board: anyone can add a public URL, and every replica checks
due URLs in the background and records the results in PostgreSQL.

Endpoints
  GET    /                    the status board (static HTML, CSS, JS)
  GET    /api/monitors        every monitor with its latest result, 24 h
                              uptime and recent checks
  POST   /api/monitors        add one: {"url", "method", "interval", "name"}
  DELETE /api/monitors/<id>   remove one (needs the token returned on add)
  GET    /demo/target         the demo service: healthy, down or slow on
                              an operator's command (see below)
  GET    /healthz             liveness: the process is up
  GET    /readyz              readiness: the database answers `SELECT 1`
  GET    /metrics             Prometheus metrics

Incident demo
  `make incident MODE=down|slow|ok` switches the demo service, which the
  board watches every minute and which pages on-call when it fails. The
  switch (POST /internal/demo-mode) only answers connections from inside the
  pod, so it is reachable through `kubectl exec` (IAM + RBAC), never the ALB.

Security notes
  * Checks are SSRF-safe: see checker.py.
  * Abuse limits: at most MAX_MONITORS on the board, intervals of 1 to 60
    minutes, GET or HEAD only, one monitor per URL and method, and monitors
    that visitors add expire after 7 days. WAF rate-limits per client IP.
  * Only whoever added a monitor can delete it: they get a random token; the
    database keeps its SHA-256 only.
  * The API only accepts JSON, so a cross-site form cannot call it.
  * Strict Content-Security-Policy; the page renders data as text, never HTML.
  * DB credentials come from AWS Secrets Manager at runtime via IRSA, and the
    connection to RDS verifies its certificate (sslmode=verify-full).
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import secrets
import signal
import socket
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

import checker

POD_NAME = os.environ.get("POD_NAME", socket.gethostname())
PORT = int(os.environ.get("PORT", "8080"))
PUBLIC_URL = os.environ.get("PUBLIC_URL", "").rstrip("/")
MAX_MONITORS = int(os.environ.get("MAX_MONITORS", "30"))
INTERVALS = (60, 300, 900, 3600)
SLO_TARGET = float(os.environ.get("SLO_TARGET", "99.9"))  # percent, over 7 days
DEMO_MODES = ("ok", "down", "slow")
DEMO_SLOW_SECONDS = 4
RETENTION_DAYS = 7
STATIC_DIR = Path(__file__).resolve().parent / "static"

# Identifies the checker to the sites it checks, with a page explaining it.
USER_AGENT = "UptimeMonitor/1.0 (SRE demo; GET/HEAD every 1-60 min" + (
    f"; +{PUBLIC_URL}/)" if PUBLIC_URL else ")"
)

# Always on the board, so the demo is never blank. They do not expire, have
# no delete token, and the last field says whether a failure pages on-call
# (only our own services do: a stranger's site going down is not our page).
SEEDS = [
    ("Example Domain", "https://example.com/", "GET", 60, False),
    ("GitHub", "https://github.com/", "HEAD", 300, False),
    ("AWS", "https://aws.amazon.com/", "HEAD", 300, False),
] + ([
    ("This board", f"{PUBLIC_URL}/healthz", "GET", 60, True),
    ("Demo service", f"{PUBLIC_URL}/demo/target", "GET", 60, True),
] if PUBLIC_URL else [])

# --- Logging: one JSON object per line (parsed by Fluent Bit -> CloudWatch) ---


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(record.created)),
            "level": record.levelname.lower(),
            "pod": POD_NAME,
            "msg": record.getMessage(),
        }
        payload.update(getattr(record, "fields", {}))
        return json.dumps(payload)


log = logging.getLogger("app")
_handler = logging.StreamHandler(sys.stdout)
_handler.setFormatter(JsonFormatter())
log.addHandler(_handler)
log.setLevel(os.environ.get("LOG_LEVEL", "INFO"))
log.propagate = False


def log_event(event: str, level: int = logging.INFO, **fields) -> None:
    log.log(level, event, extra={"fields": {"event": event, **fields}})


# --- Metrics -------------------------------------------------------------------

REQUESTS = Counter(
    "http_requests_total", "HTTP requests", ["route", "method", "status"]
)
LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency",
    ["route"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5),
)
DB_UP = Gauge("db_up", "1 if the last database check succeeded")
DB_ERRORS = Counter("db_errors_total", "Database errors", ["operation"])
CHECKS = Counter("uptime_checks_total", "Checks run by this replica", ["result"])
CHECK_LATENCY = Histogram(
    "uptime_check_duration_seconds",
    "Time to run one check, including redirects",
    buckets=(0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 20),
)
MONITORS = Gauge("uptime_monitors", "Monitors on the board")


# --- Database ------------------------------------------------------------------

SCHEMA = """
CREATE TABLE IF NOT EXISTS monitors (
    id            BIGSERIAL   PRIMARY KEY,
    name          TEXT        NOT NULL,
    url           TEXT        NOT NULL,
    method        TEXT        NOT NULL CHECK (method IN ('GET', 'HEAD')),
    interval_s    INTEGER     NOT NULL CHECK (interval_s BETWEEN 60 AND 3600),
    token_sha256  TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at    TIMESTAMPTZ,
    next_check_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (url, method)
);
CREATE INDEX IF NOT EXISTS monitors_due ON monitors (next_check_at);

CREATE TABLE IF NOT EXISTS checks (
    id          BIGSERIAL   PRIMARY KEY,
    monitor_id  BIGINT      NOT NULL REFERENCES monitors (id) ON DELETE CASCADE,
    checked_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    ok          BOOLEAN     NOT NULL,
    status_code INTEGER,
    latency_ms  INTEGER     NOT NULL,
    error       TEXT,
    pod         TEXT        NOT NULL
);
CREATE INDEX IF NOT EXISTS checks_by_monitor ON checks (monitor_id, checked_at DESC);

ALTER TABLE monitors ADD COLUMN IF NOT EXISTS alert BOOLEAN NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS demo_target (
    id         INTEGER     PRIMARY KEY CHECK (id = 1),
    mode       TEXT        NOT NULL CHECK (mode IN ('ok', 'down', 'slow')),
    changed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO demo_target (id, mode) VALUES (1, 'ok') ON CONFLICT DO NOTHING;
"""

LIST_SQL = """
SELECT m.id, m.name, m.url, m.method, m.interval_s, m.created_at, m.expires_at, m.alert,
       l.checked_at, l.ok, l.status_code, l.latency_ms, l.error,
       s.total, s.up, s.p95_ms, w.total, w.up,
       COALESCE(r.recent, '[]'::json)
FROM monitors m
LEFT JOIN LATERAL (
    SELECT checked_at, ok, status_code, latency_ms, error
    FROM checks WHERE monitor_id = m.id ORDER BY checked_at DESC LIMIT 1
) l ON true
LEFT JOIN LATERAL (
    SELECT count(*) AS total, count(*) FILTER (WHERE ok) AS up,
           percentile_cont(0.95) WITHIN GROUP (ORDER BY latency_ms) FILTER (WHERE ok) AS p95_ms
    FROM checks WHERE monitor_id = m.id AND checked_at > now() - interval '24 hours'
) s ON true
LEFT JOIN LATERAL (
    SELECT count(*) AS total, count(*) FILTER (WHERE ok) AS up
    FROM checks WHERE monitor_id = m.id AND checked_at > now() - interval '7 days'
) w ON true
LEFT JOIN LATERAL (
    SELECT json_agg(json_build_object('t', checked_at, 'ok', ok, 'ms', latency_ms,
                                      'code', status_code, 'err', error)
                    ORDER BY checked_at) AS recent
    FROM (SELECT * FROM checks WHERE monitor_id = m.id
          ORDER BY checked_at DESC LIMIT 40) last40
) r ON true
ORDER BY m.created_at, m.id
"""

# One statement claims due monitors and pushes them out by their interval, so
# replicas never check the same monitor twice (SKIP LOCKED).
CLAIM_SQL = """
UPDATE monitors SET next_check_at = now() + make_interval(secs => interval_s)
WHERE id IN (
    SELECT id FROM monitors
    WHERE next_check_at <= now() AND (expires_at IS NULL OR expires_at > now())
    ORDER BY next_check_at
    LIMIT %s
    FOR UPDATE SKIP LOCKED
)
RETURNING id, url, method, name, alert
"""


class BoardFull(Exception):
    pass


class Duplicate(Exception):
    pass


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def _iso(value):
    return value.isoformat() if isinstance(value, datetime) else value


def error_budget(total: int, up: int, target: float = None) -> dict | None:
    """SLO over the window: allowed failures = total * (1 - target). Returns
    uptime, the target and how much of the budget is left (0 to 100)."""
    target = SLO_TARGET if target is None else target
    if not total:
        return None
    failed = total - up
    allowed = total * (100 - target) / 100
    if allowed > 0:
        left = max(0.0, 100 * (1 - failed / allowed))
    else:
        left = 100.0 if failed == 0 else 0.0
    return {
        "target": target,
        "uptime": round(100 * up / total, 3),
        "budget_left": round(left, 1),
        "failed": failed,
        "checks": total,
    }


class Database:
    """Single connection, guarded by a lock, with lazy reconnect. The web
    server and the checker each use their own instance."""

    def __init__(self, application_name: str = "uptime") -> None:
        self.host = os.environ["DB_HOST"]
        self.port = int(os.environ.get("DB_PORT", "5432"))
        self.name = os.environ["DB_NAME"]
        self.secret_arn = os.environ["DB_SECRET_ARN"]
        self.region = os.environ.get("AWS_REGION", "us-east-1")
        self.ca_bundle = os.environ.get(
            "DB_CA_BUNDLE", "/app/certs/rds-global-bundle.pem"
        )
        self.application_name = application_name
        self._creds: dict | None = None
        self._conn = None
        self._schema_ready = False
        self._lock = threading.Lock()

    # Credentials ---------------------------------------------------------------
    def _load_credentials(self, force: bool = False) -> dict:
        if self._creds is None or force:
            import boto3  # imported lazily so unit tests need no AWS SDK setup

            client = boto3.client("secretsmanager", region_name=self.region)
            secret = client.get_secret_value(SecretId=self.secret_arn)
            data = json.loads(secret["SecretString"])
            self._creds = {"user": data["username"], "password": data["password"]}
            log_event("db_credentials_loaded", refreshed=force)
        return self._creds

    # Connection ----------------------------------------------------------------
    def _connect(self, refresh_credentials: bool = False):
        import psycopg

        creds = self._load_credentials(force=refresh_credentials)
        return psycopg.connect(
            host=self.host,
            port=self.port,
            dbname=self.name,
            user=creds["user"],
            password=creds["password"],
            sslmode="verify-full",
            sslrootcert=self.ca_bundle,
            connect_timeout=5,
            application_name=self.application_name,
            autocommit=True,
        )

    def _get_conn(self):
        import psycopg

        if self._conn is not None and not self._conn.closed:
            return self._conn
        try:
            self._conn = self._connect()
        except psycopg.OperationalError as exc:
            # Most likely cause after a rotation: the cached password is stale.
            if "password authentication failed" in str(exc):
                log_event("db_auth_failed_refreshing_secret", logging.WARNING)
                self._conn = self._connect(refresh_credentials=True)
            else:
                raise
        if not self._schema_ready:
            self._ensure_schema(self._conn)
        return self._conn

    def _ensure_schema(self, conn) -> None:
        # Both replicas start at once: an advisory lock makes the first one
        # create the tables and seed the board, and the second one wait.
        with conn.transaction():
            conn.execute("SELECT pg_advisory_xact_lock(424242)")
            conn.execute(SCHEMA)
            for name, url, method, interval, alert in SEEDS:
                conn.execute(
                    "INSERT INTO monitors (name, url, method, interval_s, alert) "
                    "VALUES (%s, %s, %s, %s, %s) "
                    "ON CONFLICT (url, method) DO UPDATE SET alert = EXCLUDED.alert",
                    (name, url, method, interval, alert),
                )
        self._schema_ready = True
        log_event("db_schema_ready")

    def _run(self, operation: str, fn):
        with self._lock:
            try:
                result = fn(self._get_conn())
                DB_UP.set(1)
                return result
            except (BoardFull, Duplicate):
                raise
            except Exception as exc:  # noqa: BLE001 - reported, then re-raised
                DB_UP.set(0)
                DB_ERRORS.labels(operation=operation).inc()
                log_event(
                    "db_error",
                    logging.ERROR,
                    operation=operation,
                    error_type=type(exc).__name__,
                    error=str(exc)[:300],
                )
                if self._conn is not None:
                    try:
                        self._conn.close()
                    except Exception:  # noqa: BLE001
                        pass
                self._conn = None
                raise

    # Public API ------------------------------------------------------------------
    def ping(self) -> None:
        self._run("ping", lambda c: c.execute("SELECT 1").fetchone())

    def list_monitors(self) -> list[dict]:
        rows = self._run("list_monitors", lambda c: c.execute(LIST_SQL).fetchall())
        MONITORS.set(len(rows))
        monitors = []
        for (mid, name, url, method, interval, created, expires, alert, last_at, ok,
             code, ms, err, total, up, p95_ms, total_7d, up_7d, recent) in rows:
            monitors.append({
                "id": mid,
                "name": name,
                "url": url,
                "method": method,
                "interval": interval,
                "created_at": _iso(created),
                "expires_at": _iso(expires),
                "last": None if last_at is None else {
                    "at": _iso(last_at), "ok": ok, "status_code": code,
                    "latency_ms": ms, "error": err,
                },
                "alert": alert,
                "uptime_24h": round(100 * up / total, 2) if total else None,
                "p95_latency_ms": round(p95_ms) if p95_ms is not None else None,
                "slo": error_budget(total_7d, up_7d),
                "recent": recent,
            })
        return monitors

    def add_monitor(self, name: str, url: str, method: str, interval: int) -> tuple[int, str]:
        token = secrets.token_urlsafe(24)

        def _add(conn):
            import psycopg

            with conn.transaction():
                # Serialize adds so the cap holds across replicas.
                conn.execute("SELECT pg_advisory_xact_lock(424243)")
                count = conn.execute("SELECT count(*) FROM monitors").fetchone()[0]
                if count >= MAX_MONITORS:
                    raise BoardFull()
                try:
                    return conn.execute(
                        "INSERT INTO monitors (name, url, method, interval_s, token_sha256, expires_at) "
                        "VALUES (%s, %s, %s, %s, %s, now() + make_interval(days => %s)) RETURNING id",
                        (name, url, method, interval, _hash(token), RETENTION_DAYS),
                    ).fetchone()[0]
                except psycopg.errors.UniqueViolation:
                    raise Duplicate() from None

        return self._run("add_monitor", _add), token

    def delete_monitor(self, monitor_id: int, token: str) -> bool:
        def _delete(conn):
            cur = conn.execute(
                "DELETE FROM monitors WHERE id = %s AND token_sha256 = %s",
                (monitor_id, _hash(token)),
            )
            return cur.rowcount == 1

        return self._run("delete_monitor", _delete)

    def demo_mode(self) -> str:
        return self._run("demo_mode", lambda c: c.execute(
            "SELECT mode FROM demo_target WHERE id = 1").fetchone()[0])

    def set_demo_mode(self, mode: str) -> None:
        self._run("set_demo_mode", lambda c: c.execute(
            "UPDATE demo_target SET mode = %s, changed_at = now() WHERE id = 1", (mode,)))

    def claim_due(self, limit: int) -> list[tuple]:
        return self._run("claim_due", lambda c: c.execute(CLAIM_SQL, (limit,)).fetchall())

    def record_check(self, monitor_id: int, result: checker.Result) -> None:
        self._run("record_check", lambda c: c.execute(
            "INSERT INTO checks (monitor_id, ok, status_code, latency_ms, error, pod) "
            "SELECT %s, %s, %s, %s, %s, %s WHERE EXISTS (SELECT 1 FROM monitors WHERE id = %s)",
            (monitor_id, result.ok, result.status_code, result.latency_ms,
             result.error, POD_NAME, monitor_id),
        ))

    def clean_up(self) -> None:
        def _clean(conn):
            conn.execute("DELETE FROM monitors WHERE expires_at <= now()")
            conn.execute(
                "DELETE FROM checks WHERE checked_at < now() - make_interval(days => %s)",
                (RETENTION_DAYS,),
            )

        self._run("clean_up", _clean)

    def close(self) -> None:
        with self._lock:
            if self._conn is not None:
                self._conn.close()
                self._conn = None


# --- Background checks -----------------------------------------------------------


class Worker:
    """Every few seconds, claim due monitors and check them in parallel."""

    def __init__(self, db, poll_seconds: float = 5, batch: int = 10) -> None:
        self.db = db
        self.poll_seconds = poll_seconds
        self.batch = batch
        self.pool = ThreadPoolExecutor(max_workers=5, thread_name_prefix="check")
        self.stop = threading.Event()
        self._last_cleanup = 0.0

    def _check_one(self, monitor_id: int, url: str, method: str, name: str, alert: bool) -> None:
        result = checker.check(url, method, USER_AGENT)
        CHECKS.labels(result="up" if result.ok else "down").inc()
        CHECK_LATENCY.observe(result.latency_ms / 1000)
        if not result.ok:
            # alert=true failures feed the monitor-down alarm (CloudWatch
            # metric filter); the rest are only shown on the board.
            log_event("check_failed", logging.WARNING, monitor=name, alert=alert,
                      status_code=result.status_code, error=result.error)
        try:
            self.db.record_check(monitor_id, result)
        except Exception:  # noqa: BLE001 - logged as db_error by Database
            pass

    def run_once(self) -> int:
        claimed = self.db.claim_due(self.batch)
        for row in claimed:
            self.pool.submit(self._check_one, *row)
        if time.monotonic() - self._last_cleanup > 600:
            self.db.clean_up()
            self._last_cleanup = time.monotonic()
        return len(claimed)

    def loop(self) -> None:
        last_beat = 0.0
        while not self.stop.wait(self.poll_seconds):
            try:
                self.run_once()
            except Exception:  # noqa: BLE001 - the DB layer logged it; retry next tick
                pass
            # A line a minute proves the whole log path (app, Fluent Bit,
            # CloudWatch) is alive: the telemetry-silent alarm fires when
            # these stop arriving, so a quiet pipeline never reads as healthy.
            if time.monotonic() - last_beat >= 60:
                log_event("heartbeat")
                last_beat = time.monotonic()
        self.pool.shutdown(wait=False, cancel_futures=True)


# --- HTTP ----------------------------------------------------------------------

STATIC_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/static/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/static/style.css": ("style.css", "text/css; charset=utf-8"),
}

SECURITY_HEADERS = {
    "Content-Security-Policy": (
        "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
        "connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
    ),
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Strict-Transport-Security": "max-age=31536000",
    "Cross-Origin-Opener-Policy": "same-origin",
}

MONITOR_PATH = re.compile(r"^/api/monitors/(\d{1,12})$")
CONTROL_CHARS = re.compile(r"[\x00-\x1f\x7f]")
MAX_BODY = 4096


def _route(path: str) -> str:
    if path in STATIC_FILES or path.startswith("/static/"):
        return "static"
    if path in ("/demo/target", "/internal/demo-mode"):
        return path
    if MONITOR_PATH.match(path):
        return "/api/monitors/:id"
    if path in ("/api/monitors", "/healthz", "/readyz", "/metrics"):
        return path
    return "other"


def validate_new_monitor(body: dict) -> tuple[str, str, str, int]:
    """Return (name, url, method, interval) or raise checker.Refused."""
    target = checker.parse_url(str(body.get("url", "")))
    method = str(body.get("method", "GET")).upper()
    if method not in checker.ALLOWED_METHODS:
        raise checker.Refused("Method must be GET or HEAD.")
    try:
        interval = int(body.get("interval", 300))
    except (TypeError, ValueError):
        interval = -1
    if interval not in INTERVALS:
        raise checker.Refused("Interval must be 1, 5, 15 or 60 minutes.")
    name = CONTROL_CHARS.sub("", str(body.get("name") or "")).strip()[:60] or target.host
    checker.resolve(target.host, target.port)  # refuse private or unresolvable hosts now
    return name, target.url, method, interval


def make_handler(db, static_dir: Path = STATIC_DIR):
    static = {
        path: ((static_dir / filename).read_bytes(), ctype)
        for path, (filename, ctype) in STATIC_FILES.items()
    }

    class Handler(BaseHTTPRequestHandler):
        server_version = "uptime"
        sys_version = ""

        def log_message(self, fmt, *args):  # silence default stderr access log
            return

        def _send(self, status: int, body: bytes, content_type: str, cache: str = "no-store") -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", cache)
            for name, value in SECURITY_HEADERS.items():
                self.send_header(name, value)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def _json(self, status: int, payload) -> int:
            self._send(status, json.dumps(payload).encode(), "application/json")
            return status

        def _read_json(self) -> dict:
            if self.headers.get("Content-Type", "").split(";")[0].strip() != "application/json":
                raise checker.Refused("Send JSON (Content-Type: application/json).")
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0 or length > MAX_BODY:
                raise checker.Refused("Request body is missing or too large.")
            try:
                body = json.loads(self.rfile.read(length))
            except ValueError:
                raise checker.Refused("Request body is not valid JSON.") from None
            if not isinstance(body, dict):
                raise checker.Refused("Request body must be a JSON object.")
            return body

        def _handle(self, method: str) -> None:
            start = time.perf_counter()
            path = self.path.split("?", 1)[0]
            route = _route(path)
            status = 500
            try:
                status = self._dispatch(method, path)
            except (BrokenPipeError, ConnectionResetError):
                # The client went away mid-response (a probe timing out, a
                # closed tab). Not a server error: don't count it as a 5xx.
                status = 499
            except Exception as exc:  # noqa: BLE001 - never leak a traceback
                log_event("unhandled_error", logging.ERROR, error_type=type(exc).__name__)
                status = self._json(500, {"error": "Internal error."})
            finally:
                elapsed = time.perf_counter() - start
                REQUESTS.labels(route=route, method=method, status=str(status)).inc()
                LATENCY.labels(route=route).observe(elapsed)
                # Probes, scrapes, assets and the board's polling are noise;
                # log changes, failures and everything else.
                quiet = route in ("/healthz", "/readyz", "/metrics", "static") or (
                    route == "/api/monitors" and method == "GET"
                )
                if route == "/demo/target":
                    # The drill's 503s are the demo service failing on
                    # purpose; the monitor-down alarm reports them, so they
                    # stay out of the app's own 5xx metric (no "status").
                    log_event("demo_request", demo_status=status,
                              duration_ms=round(elapsed * 1000, 2))
                elif (not quiet or status >= 500) and status != 499:
                    log_event(
                        "http_request",
                        method=method,
                        path=route,
                        status=status,
                        duration_ms=round(elapsed * 1000, 2),
                    )

        def _dispatch(self, method: str, path: str) -> int:
            if method in ("GET", "HEAD"):
                if path in static:
                    body, ctype = static[path]
                    self._send(200, body, ctype, cache="public, max-age=300")
                    return 200
                if path == "/healthz":
                    return self._json(200, {"status": "ok"})
                if path == "/demo/target":
                    try:
                        mode = db.demo_mode()
                    except Exception:  # noqa: BLE001
                        return self._json(503, {"status": "database unavailable"})
                    if mode == "down":
                        return self._json(503, {"status": "down", "why": "incident drill"})
                    if mode == "slow":
                        time.sleep(DEMO_SLOW_SECONDS)
                    return self._json(200, {"status": "ok", "mode": mode})
                if path == "/readyz":
                    try:
                        db.ping()
                        return self._json(200, {"status": "ready"})
                    except Exception:  # noqa: BLE001
                        return self._json(503, {"status": "database unavailable"})
                if path == "/metrics":
                    self._send(200, generate_latest(), CONTENT_TYPE_LATEST)
                    return 200
                if path == "/api/monitors":
                    try:
                        monitors = db.list_monitors()
                    except Exception:  # noqa: BLE001
                        return self._json(503, {"error": "Database unavailable."})
                    return self._json(200, {"monitors": monitors, "max": MAX_MONITORS})
                return self._json(404, {"error": "Not found."})

            if method == "POST" and path == "/api/monitors":
                try:
                    name, url, verb, interval = validate_new_monitor(self._read_json())
                    monitor_id, token = db.add_monitor(name, url, verb, interval)
                except checker.Refused as exc:
                    return self._json(400, {"error": str(exc)})
                except BoardFull:
                    return self._json(409, {"error": f"The board is full ({MAX_MONITORS} monitors). Try again later."})
                except Duplicate:
                    return self._json(409, {"error": "That URL is already on the board."})
                except Exception:  # noqa: BLE001
                    return self._json(503, {"error": "Database unavailable."})
                log_event("monitor_added", monitor_id=monitor_id, method=verb, interval=interval)
                return self._json(201, {"id": monitor_id, "token": token})

            if method == "POST" and path == "/internal/demo-mode":
                # Only from inside the pod (kubectl exec): the ALB and the
                # other pods connect from VPC addresses, never loopback.
                if self.client_address[0] not in ("127.0.0.1", "::1"):
                    return self._json(404, {"error": "Not found."})
                try:
                    mode = str(self._read_json().get("mode", ""))
                except checker.Refused as exc:
                    return self._json(400, {"error": str(exc)})
                if mode not in DEMO_MODES:
                    return self._json(400, {"error": f"mode must be one of {', '.join(DEMO_MODES)}"})
                db.set_demo_mode(mode)
                log_event("demo_mode_changed", logging.WARNING, mode=mode)
                return self._json(200, {"mode": mode})

            match = MONITOR_PATH.match(path)
            if method == "DELETE" and match:
                token = self.headers.get("X-Delete-Token", "")
                if not token:
                    return self._json(403, {"error": "Only whoever added a monitor can remove it."})
                try:
                    deleted = db.delete_monitor(int(match.group(1)), token)
                except Exception:  # noqa: BLE001
                    return self._json(503, {"error": "Database unavailable."})
                if not deleted:
                    return self._json(403, {"error": "Only whoever added a monitor can remove it."})
                log_event("monitor_deleted", monitor_id=int(match.group(1)))
                return self._json(200, {"deleted": True})

            return self._json(405, {"error": "Method not allowed."})

        def do_GET(self):  # noqa: N802 - stdlib naming
            self._handle("GET")

        def do_HEAD(self):  # noqa: N802
            self._handle("HEAD")

        def do_POST(self):  # noqa: N802
            self._handle("POST")

        def do_DELETE(self):  # noqa: N802
            self._handle("DELETE")

        def do_PUT(self):  # noqa: N802
            self._handle("PUT")

        do_PATCH = do_PUT  # noqa: N815

    return Handler


def main() -> None:
    db = Database("uptime-web")
    worker = Worker(Database("uptime-checker"))
    server = ThreadingHTTPServer(("0.0.0.0", PORT), make_handler(db))  # noqa: S104
    server.daemon_threads = True

    def _shutdown(signum, _frame):
        log_event("shutdown", signal=signum)
        worker.stop.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    # Warm up the DB connection (and create the schema), but never crash-loop
    # on it: readiness reports the failure and Kubernetes keeps the pod out of
    # the Service.
    try:
        db.ping()
    except Exception:  # noqa: BLE001
        log_event("db_unavailable_at_startup", logging.WARNING)

    threading.Thread(target=worker.loop, name="worker", daemon=True).start()
    log_event("listening", port=PORT, user_agent=USER_AGENT)
    server.serve_forever()
    db.close()
    log_event("stopped")


if __name__ == "__main__":
    main()
