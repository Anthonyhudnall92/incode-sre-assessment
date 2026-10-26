"""Demo API for the SRE take-home.

Endpoints
  GET /         records a visit in PostgreSQL and returns the running count
  GET /healthz  liveness: the process is up (no dependencies checked)
  GET /readyz   readiness: the database answers `SELECT 1`
  GET /metrics  Prometheus metrics

Security notes
  * DB credentials come from AWS Secrets Manager at runtime via IRSA
    (no env-var passwords, no Kubernetes Secret, nothing in the image).
  * TLS to RDS with full certificate verification (sslmode=verify-full).
  * If RDS rotates the password, the next auth failure triggers one
    credential refresh and a retry.
"""

from __future__ import annotations

import json
import logging
import os
import signal
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

POD_NAME = os.environ.get("POD_NAME", socket.gethostname())
PORT = int(os.environ.get("PORT", "8080"))

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

ROUTES = {"/", "/healthz", "/readyz", "/metrics"}

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
VISITS = Counter("visits_recorded_total", "Visits written to the database")


# --- Database ------------------------------------------------------------------


class Database:
    """Single shared connection, guarded by a lock, with lazy reconnect."""

    def __init__(self) -> None:
        self.host = os.environ["DB_HOST"]
        self.port = int(os.environ.get("DB_PORT", "5432"))
        self.name = os.environ["DB_NAME"]
        self.secret_arn = os.environ["DB_SECRET_ARN"]
        self.region = os.environ.get("AWS_REGION", "us-east-1")
        self.ca_bundle = os.environ.get(
            "DB_CA_BUNDLE", "/app/certs/rds-global-bundle.pem"
        )
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
            application_name="demo-app",
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
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS visits (
                id          BIGSERIAL PRIMARY KEY,
                pod         TEXT        NOT NULL,
                created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
            )
            """
        )
        self._schema_ready = True
        log_event("db_schema_ready")

    def _run(self, operation: str, fn):
        with self._lock:
            try:
                result = fn(self._get_conn())
                DB_UP.set(1)
                return result
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

    def record_visit(self, pod: str) -> int:
        def _visit(conn):
            conn.execute("INSERT INTO visits (pod) VALUES (%s)", (pod,))
            return conn.execute("SELECT count(*) FROM visits").fetchone()[0]

        count = self._run("record_visit", _visit)
        VISITS.inc()
        return int(count)

    def close(self) -> None:
        with self._lock:
            if self._conn is not None:
                self._conn.close()
                self._conn = None


# --- HTTP ----------------------------------------------------------------------


def make_handler(db):
    class Handler(BaseHTTPRequestHandler):
        server_version = "demo-app"
        sys_version = ""

        def log_message(self, fmt, *args):  # silence default stderr access log
            return

        def _send(self, status: int, body: bytes, content_type: str) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(body)

        def _json(self, status: int, payload: dict) -> None:
            self._send(status, json.dumps(payload).encode(), "application/json")

        def do_GET(self):  # noqa: N802 - stdlib naming
            start = time.perf_counter()
            path = self.path.split("?", 1)[0]
            route = path if path in ROUTES else "other"
            status = 500
            try:
                if path == "/healthz":
                    status = 200
                    self._json(status, {"status": "ok"})
                elif path == "/readyz":
                    try:
                        db.ping()
                        status = 200
                        self._json(status, {"status": "ready"})
                    except Exception:  # noqa: BLE001
                        status = 503
                        self._json(status, {"status": "database unavailable"})
                elif path == "/metrics":
                    status = 200
                    self._send(status, generate_latest(), CONTENT_TYPE_LATEST)
                elif path == "/":
                    try:
                        visits = db.record_visit(POD_NAME)
                        status = 200
                        self._json(
                            status,
                            {
                                "message": "Hello from the SRE demo app",
                                "pod": POD_NAME,
                                "visits": visits,
                            },
                        )
                    except Exception:  # noqa: BLE001
                        status = 503
                        self._json(status, {"error": "database unavailable"})
                else:
                    status = 404
                    self._json(status, {"error": "not found"})
            finally:
                elapsed = time.perf_counter() - start
                REQUESTS.labels(route=route, method="GET", status=str(status)).inc()
                LATENCY.labels(route=route).observe(elapsed)
                # Probes and scrapes are high-volume noise; log only real traffic.
                if route not in ("/healthz", "/readyz", "/metrics") or status >= 500:
                    log_event(
                        "http_request",
                        method="GET",
                        path=route,
                        status=status,
                        duration_ms=round(elapsed * 1000, 2),
                    )

        def _method_not_allowed(self):
            self._json(405, {"error": "method not allowed"})

        do_POST = do_PUT = do_DELETE = do_PATCH = _method_not_allowed  # noqa: N815

    return Handler


def main() -> None:
    db = Database()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), make_handler(db))  # noqa: S104
    server.daemon_threads = True

    def _shutdown(signum, _frame):
        log_event("shutdown", signal=signum)
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    # Warm up the DB connection, but never crash-loop on it: readiness
    # reports the failure and Kubernetes keeps the pod out of the Service.
    try:
        db.ping()
    except Exception:  # noqa: BLE001
        log_event("db_unavailable_at_startup", logging.WARNING)

    log_event("listening", port=PORT)
    server.serve_forever()
    db.close()
    log_event("stopped")


if __name__ == "__main__":
    main()
