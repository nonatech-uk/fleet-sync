"""Fleet config server — serves per-host config bundles over HTTP.

Runs on the hub host (nas), bound to the WireGuard interface(s). Each
client presents a Bearer token; the server maps the token to a host
identity and scope-limits the paths that token can fetch. WireGuard
provides transport encryption; plain HTTP keeps this service simple.

Scope of this process:
- GET /<path>  → returns file contents from CONTENT_ROOT/<path>
- GET /_health → returns {"ok":true}  (no auth required)

Anything else is rejected.

The token database is a JSON file reloaded on every request (cheap, keeps
this process stateless — rotating a token means editing the file and
saving, no restart).

Logs one line per request to stdout (captured by journald via systemd).
"""

import fnmatch
import json
import logging
import os
import signal
import sys
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

CONTENT_ROOT = Path(os.environ.get("FLEET_CONTENT_ROOT", "/zfs/git/fleet-config")).resolve()
TOKENS_PATH = Path(os.environ.get("FLEET_TOKENS", "/etc/fleet-sync/tokens.json"))
BIND_HOST = os.environ.get("FLEET_BIND", "0.0.0.0")
BIND_PORT = int(os.environ.get("FLEET_PORT", "8443"))


def load_tokens() -> dict[str, dict]:
    """Read tokens.json on every request. Keeps the server stateless."""
    try:
        with TOKENS_PATH.open() as fh:
            return json.load(fh).get("tokens", {})
    except FileNotFoundError:
        return {}
    except json.JSONDecodeError as exc:
        logging.error("tokens.json parse error: %s", exc)
        return {}


def path_is_in_scope(requested: str, scopes: list[str]) -> bool:
    """Match requested path against each glob-style scope.

    Supports shell-style `*` and `**` via fnmatch; treat `**` as "any
    segment depth" by pre-expanding into fnmatch-friendly form.
    """
    for scope in scopes:
        # fnmatch treats `*` as "any chars"; `**/x` → `*/x` is equivalent.
        pattern = scope.replace("**", "*")
        if fnmatch.fnmatch(requested, pattern):
            return True
    return False


def resolve_safe(path: str) -> Path | None:
    """Resolve a request path under CONTENT_ROOT, refusing traversal."""
    try:
        # Reject anything with .. or absolute paths *before* join.
        if path.startswith("/") or ".." in Path(path).parts:
            return None
        target = (CONTENT_ROOT / path).resolve()
        target.relative_to(CONTENT_ROOT)  # raises if escape
        return target
    except (ValueError, OSError):
        return None


class Handler(BaseHTTPRequestHandler):
    server_version = "FleetConfig/1.0"

    def log_message(self, fmt, *args):
        # Route access log through Python logging so journald gets a
        # consistent, grep-friendly format.
        logging.info("%s - %s", self.client_address[0], fmt % args)

    def _respond(self, status: int, body: bytes, content_type: str = "text/plain; charset=utf-8"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802 (API name)
        path = self.path.lstrip("/")

        # Unauth health endpoint for monitoring.
        if path == "_health":
            self._respond(HTTPStatus.OK, b'{"ok":true}\n', "application/json")
            return

        # Bearer auth.
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            self._respond(HTTPStatus.UNAUTHORIZED, b"missing bearer token\n")
            return
        token = auth[len("Bearer "):]

        tokens = load_tokens()
        entry = tokens.get(token)
        if entry is None:
            logging.warning("auth denied from %s for %s", self.client_address[0], path)
            self._respond(HTTPStatus.UNAUTHORIZED, b"unknown token\n")
            return

        scopes = entry.get("scopes", [])
        if not path_is_in_scope(path, scopes):
            logging.warning(
                "scope denied token=%s host=%s path=%s scopes=%s",
                token[:8] + "…", entry.get("host", "?"), path, scopes,
            )
            self._respond(HTTPStatus.FORBIDDEN, b"path not in token scope\n")
            return

        safe = resolve_safe(path)
        if safe is None or not safe.is_file():
            self._respond(HTTPStatus.NOT_FOUND, b"not found\n")
            return

        try:
            data = safe.read_bytes()
        except OSError as exc:
            logging.error("read failed %s: %s", safe, exc)
            self._respond(HTTPStatus.INTERNAL_SERVER_ERROR, b"read failed\n")
            return

        logging.info(
            "served host=%s path=%s bytes=%d", entry.get("host", "?"), path, len(data)
        )
        self._respond(HTTPStatus.OK, data)


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    if not CONTENT_ROOT.is_dir():
        logging.error("CONTENT_ROOT %s does not exist", CONTENT_ROOT)
        return 1

    server = ThreadingHTTPServer((BIND_HOST, BIND_PORT), Handler)

    def handle_signal(signum, _frame):
        logging.info("received signal %d, shutting down", signum)
        server.shutdown()

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    logging.info("serving %s on %s:%d", CONTENT_ROOT, BIND_HOST, BIND_PORT)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
