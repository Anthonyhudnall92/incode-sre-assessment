"""Checks one URL, safely.

Anyone can add a URL, so a check must never become a way into the network it
runs from (SSRF). Every hop is validated, then fetched from the exact address
that was validated:

  * http/https only, ports 80 and 443 only, no credentials in the URL
  * the host must resolve to public addresses only: loopback, private,
    link-local (including the instance metadata service), CGNAT, multicast
    and reserved ranges are refused, for IPv4 and IPv6
  * the connection goes to the resolved IP (with the original Host header and
    TLS server name), so a DNS answer cannot change between check and fetch
  * redirects are followed by hand, at most 3, each one validated again
  * GET or HEAD only, a short timeout, and at most 64 KiB of body is read

The pod's NetworkPolicy is a second layer: it only allows egress on 80/443 to
addresses outside the VPC, and never to the metadata service.
"""

from __future__ import annotations

import ipaddress
import socket
import ssl
import time
from dataclasses import dataclass
from urllib.parse import urljoin, urlsplit

import urllib3

ALLOWED_SCHEMES = {"http": 80, "https": 443}
ALLOWED_METHODS = {"GET", "HEAD"}
MAX_URL_LENGTH = 2048
MAX_REDIRECTS = 3
MAX_BODY_BYTES = 64 * 1024
CONNECT_TIMEOUT = 5.0
READ_TIMEOUT = 10.0

_TLS = ssl.create_default_context()
_getaddrinfo = socket.getaddrinfo  # replaced in tests


class Refused(ValueError):
    """The URL is not allowed. The message is safe to show to the user."""


@dataclass
class Target:
    url: str
    scheme: str
    host: str
    port: int
    path: str


@dataclass
class Result:
    ok: bool
    status_code: int | None
    latency_ms: int
    error: str | None


def parse_url(raw: str) -> Target:
    """Validate the shape of a URL (no DNS). Raises Refused."""
    raw = (raw or "").strip()
    if not raw:
        raise Refused("Enter a URL.")
    if len(raw) > MAX_URL_LENGTH:
        raise Refused("That URL is too long.")
    if "://" not in raw:
        raw = "https://" + raw

    try:
        parts = urlsplit(raw)
        port = parts.port
    except ValueError:
        raise Refused("That is not a valid URL.") from None

    scheme = parts.scheme.lower()
    if scheme not in ALLOWED_SCHEMES:
        raise Refused("Only http:// and https:// URLs can be monitored.")
    if parts.username or parts.password:
        raise Refused("URLs with a username or password are not allowed.")
    host = (parts.hostname or "").rstrip(".").lower()
    if not host:
        raise Refused("That URL has no host name.")

    port = port or ALLOWED_SCHEMES[scheme]
    if port not in (80, 443):
        raise Refused("Only ports 80 and 443 can be monitored.")

    if host == "localhost" or host.endswith((".localhost", ".local", ".internal")):
        raise Refused("Private and internal addresses cannot be monitored.")
    try:
        literal = ipaddress.ip_address(host)
    except ValueError:
        if "." not in host:
            raise Refused("Use a full domain name, like example.com.") from None
    else:
        _require_public(literal)

    path = parts.path or "/"
    if parts.query:
        path += "?" + parts.query
    netloc = host if port == ALLOWED_SCHEMES[scheme] else f"{host}:{port}"
    return Target(f"{scheme}://{netloc}{path}", scheme, host, port, path)


def _require_public(ip: ipaddress.IPv4Address | ipaddress.IPv6Address) -> None:
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    if not ip.is_global or ip.is_multicast:
        raise Refused("Private and internal addresses cannot be monitored.")


def resolve(host: str, port: int) -> str:
    """Resolve to one public address. Raises Refused if any answer is not public."""
    try:
        infos = _getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except socket.gaierror:
        raise Refused("That host name does not resolve.") from None
    addresses = []
    for info in infos:
        ip = ipaddress.ip_address(info[4][0].split("%", 1)[0])
        _require_public(ip)  # every answer, so a mixed answer cannot slip through
        addresses.append(ip)
    if not addresses:
        raise Refused("That host name does not resolve.")
    # Prefer IPv4: the cluster's egress is IPv4.
    addresses.sort(key=lambda a: a.version)
    return str(addresses[0])


def _fetch(target: Target, ip: str, method: str, user_agent: str):
    host_header = target.host if target.port == ALLOWED_SCHEMES[target.scheme] else f"{target.host}:{target.port}"
    timeout = urllib3.Timeout(connect=CONNECT_TIMEOUT, read=READ_TIMEOUT)
    if target.scheme == "https":
        pool = urllib3.HTTPSConnectionPool(
            ip,
            target.port,
            timeout=timeout,
            retries=False,
            maxsize=1,
            ssl_context=_TLS,
            server_hostname=target.host,
            assert_hostname=target.host,
        )
    else:
        pool = urllib3.HTTPConnectionPool(ip, target.port, timeout=timeout, retries=False, maxsize=1)
    try:
        response = pool.urlopen(
            method,
            target.path,
            headers={"Host": host_header, "User-Agent": user_agent, "Accept": "*/*"},
            redirect=False,
            preload_content=False,
            assert_same_host=False,
        )
        try:
            if method == "GET":
                response.read(MAX_BODY_BYTES)
        finally:
            response.release_conn()
        return response.status, response.headers.get("Location")
    finally:
        pool.close()


def check(url: str, method: str, user_agent: str) -> Result:
    """Run one check. Never raises; failures come back as a Result."""
    started = time.monotonic()

    def done(ok: bool, status: int | None, error: str | None) -> Result:
        return Result(ok, status, int((time.monotonic() - started) * 1000), error)

    try:
        target = parse_url(url)
        for _ in range(MAX_REDIRECTS + 1):
            ip = resolve(target.host, target.port)
            status, location = _fetch(target, ip, method, user_agent)
            if status in (301, 302, 303, 307, 308) and location:
                target = parse_url(urljoin(target.url, location))
                continue
            if 200 <= status < 400:
                return done(True, status, None)
            return done(False, status, f"HTTP {status}")
        return done(False, None, "Too many redirects")
    except Refused as exc:
        return done(False, None, str(exc))
    except urllib3.exceptions.SSLError:
        return done(False, None, "TLS error (certificate or handshake)")
    except (urllib3.exceptions.ConnectTimeoutError, urllib3.exceptions.ReadTimeoutError):
        return done(False, None, "Timed out")
    except urllib3.exceptions.NewConnectionError:
        return done(False, None, "Connection refused or unreachable")
    except (urllib3.exceptions.HTTPError, OSError) as exc:
        return done(False, None, f"Connection error ({type(exc).__name__})")
