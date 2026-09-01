#!/usr/bin/env python3
"""Ephemeral loopback HTTPS fixture for native-auth E2E tests.

The fixture accepts only synthetic local form submissions. It never retains request
bodies or field values: state consists solely of bounded counters and opaque fixture
handles.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import pathlib
import ssl
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

CASE_IDS = (
    "flat_username_password",
    "expiry",
    "replay",
    "target_replacement",
)
EXPECTED_OUTCOMES = {
    "flat_username_password": ["accepted"],
    "expiry": ["rejected_expired"],
    "replay": ["accepted", "rejected_replay"],
    "target_replacement": ["rejected_target_replaced", "accepted"],
}
COUNTER_KEYS = (
    "accepted",
    "contexts_issued",
    "password_present",
    "rejected_expired",
    "rejected_replay",
    "rejected_target_replaced",
    "submission_attempts",
    "username_present",
)
MAX_BODY_BYTES = 16 * 1024


def _empty_counters():
    return {key: 0 for key in COUNTER_KEYS}


class FixtureState:
    """Thread-safe protocol state containing no submitted values."""

    def __init__(self):
        self._lock = threading.Lock()
        self._tick = 0
        self._serial = 0
        self._target_generation = {case_id: 1 for case_id in CASE_IDS}
        self._contexts = {}
        self._cases = {case_id: _empty_counters() for case_id in CASE_IDS}

    def issue(self, case_id):
        with self._lock:
            self._serial += 1
            context_id = "ctx_{:04d}".format(self._serial)
            generation = self._target_generation[case_id]
            target_id = "target_{}_g{}".format(case_id, generation)
            expires_tick = self._tick + (1 if case_id == "expiry" else 1000)
            self._contexts[context_id] = {
                "case_id": case_id,
                "target_id": target_id,
                "generation": generation,
                "expires_tick": expires_tick,
                "consumed": False,
            }
            self._cases[case_id]["contexts_issued"] += 1
            return {
                "case_id": case_id,
                "context_id": context_id,
                "target_id": target_id,
                "target_generation": generation,
                "expires_tick": expires_tick,
                "login_path": "/v1/cases/{}/login/{}".format(case_id, context_id),
                "submit_path": "/v1/cases/{}/submit".format(case_id),
            }

    def page_metadata(self, case_id, context_id):
        with self._lock:
            context = self._contexts.get(context_id)
            if context is None or context["case_id"] != case_id:
                return None
            return {
                "context_id": context_id,
                "target_id": context["target_id"],
                "submit_path": "/v1/cases/{}/submit".format(case_id),
            }

    def advance(self):
        with self._lock:
            self._tick += 1
            return self._tick

    def replace_target(self, case_id):
        with self._lock:
            self._target_generation[case_id] += 1
            return self._target_generation[case_id]

    def submit(self, case_id, context_id, target_id, username_present, password_present):
        with self._lock:
            counters = self._cases[case_id]
            counters["submission_attempts"] += 1
            counters["username_present"] += int(username_present)
            counters["password_present"] += int(password_present)
            context = self._contexts.get(context_id)
            if context is None or context["case_id"] != case_id:
                return "rejected_target_replaced"
            if self._tick >= context["expires_tick"]:
                counters["rejected_expired"] += 1
                return "rejected_expired"
            current_generation = self._target_generation[case_id]
            if context["generation"] != current_generation or context["target_id"] != target_id:
                counters["rejected_target_replaced"] += 1
                return "rejected_target_replaced"
            if context["consumed"]:
                counters["rejected_replay"] += 1
                return "rejected_replay"
            context["consumed"] = True
            counters["accepted"] += 1
            return "accepted"

    def snapshot(self):
        with self._lock:
            return {
                "schema": "native-auth-observations.v1",
                "logical_tick": self._tick,
                "cases": {
                    case_id: dict(self._cases[case_id]) for case_id in CASE_IDS
                },
            }


class FixtureHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, state):
        super().__init__(address, FixtureHandler)
        self.fixture_state = state


class FixtureHandler(BaseHTTPRequestHandler):
    server_version = "NativeAuthE2EFixture/1"
    sys_version = ""

    def log_message(self, _format, *_args):
        # Intentionally silent: even metadata logs are unnecessary for this fixture.
        return

    def _json(self, status, payload):
        body = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        self._bytes(status, body, "application/json")

    def _bytes(self, status, body, content_type):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'none'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
        )
        self.end_headers()
        self.wfile.write(body)

    def _login_page(self, metadata):
        context_id = html.escape(metadata["context_id"], quote=True)
        target_id = html.escape(metadata["target_id"], quote=True)
        submit_path = html.escape(metadata["submit_path"], quote=True)
        return ("""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Native Auth Fixture</title></head>
<body><main><h1>Fixture sign in</h1>
<form method="post" action="{submit_path}" data-target-id="{target_id}">
<input type="hidden" name="context_id" value="{context_id}">
<input type="hidden" name="target_id" value="{target_id}">
<label for="fixture-username">Username</label>
<input id="fixture-username" name="username" type="text" autocomplete="username" required>
<label for="fixture-password">Password</label>
<input id="fixture-password" name="password" type="password" autocomplete="current-password" required>
<button type="submit">Sign in</button>
</form></main></body></html>""").format(
            submit_path=submit_path,
            target_id=target_id,
            context_id=context_id,
        ).encode("utf-8")

    def _read_form_presence(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return None
        if length < 0 or length > MAX_BODY_BYTES:
            return None
        body = self.rfile.read(length)
        try:
            fields = parse_qs(body.decode("utf-8"), keep_blank_values=True)
            return {
                "context_id": fields.get("context_id", [""])[0],
                "target_id": fields.get("target_id", [""])[0],
                "username_present": bool(fields.get("username", [""])[0]),
                "password_present": bool(fields.get("password", [""])[0]),
            }
        finally:
            # Keep the lifetime of submitted bytes bounded to this request method.
            body = b""

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/healthz":
            self._json(200, {"status": "ok"})
            return
        if path == "/v1/matrix":
            self._json(
                200,
                {
                    "schema": "native-auth-fixture-matrix.v1",
                    "cases": [
                        {"id": case_id, "expected_outcomes": EXPECTED_OUTCOMES[case_id]}
                        for case_id in CASE_IDS
                    ],
                },
            )
            return
        if path == "/v1/observations":
            self._json(200, self.server.fixture_state.snapshot())
            return
        parts = path.strip("/").split("/")
        if len(parts) == 5 and parts[:2] == ["v1", "cases"] and parts[3] == "login":
            case_id, context_id = parts[2], parts[4]
            if case_id not in CASE_IDS:
                self._json(404, {"error": "unknown_case"})
                return
            metadata = self.server.fixture_state.page_metadata(case_id, context_id)
            if metadata is None:
                self._json(404, {"error": "unknown_context"})
                return
            self._bytes(200, self._login_page(metadata), "text/html; charset=utf-8")
            return
        self._json(404, {"error": "not_found"})

    def do_POST(self):
        path = urlsplit(self.path).path
        if path == "/v1/controls/advance":
            self._json(200, {"logical_tick": self.server.fixture_state.advance()})
            return
        if path == "/v1/controls/target_replacement/replace":
            generation = self.server.fixture_state.replace_target("target_replacement")
            self._json(
                200,
                {"case_id": "target_replacement", "target_generation": generation},
            )
            return
        parts = path.strip("/").split("/")
        if len(parts) == 4 and parts[:2] == ["v1", "cases"] and parts[3] == "issue":
            case_id = parts[2]
            if case_id not in CASE_IDS:
                self._json(404, {"error": "unknown_case"})
                return
            self._json(201, self.server.fixture_state.issue(case_id))
            return
        if len(parts) == 4 and parts[:2] == ["v1", "cases"] and parts[3] == "submit":
            case_id = parts[2]
            if case_id not in CASE_IDS:
                self._json(404, {"error": "unknown_case"})
                return
            submission = self._read_form_presence()
            if submission is None:
                self._json(413, {"outcome": "rejected_body"})
                return
            outcome = self.server.fixture_state.submit(case_id=case_id, **submission)
            status = 200 if outcome == "accepted" else 409
            self._json(status, {"outcome": outcome})
            return
        self._json(404, {"error": "not_found"})


class FixtureRuntime:
    """Own an ephemeral certificate and dynamic loopback HTTPS listener."""

    def __init__(self):
        self.state = FixtureState()
        self._temporary_directory = None
        self._server = None
        self._thread = None
        self.origin = None

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, _type, _value, _traceback):
        self.close()

    def start(self):
        if self._server is not None:
            return
        self._temporary_directory = tempfile.TemporaryDirectory(prefix="native-auth-e2e-")
        directory = pathlib.Path(self._temporary_directory.name)
        cert_path = directory / "cert.pem"
        key_path = directory / "key.pem"
        subprocess.run(
            [
                "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", str(key_path), "-out", str(cert_path), "-days", "1",
                "-subj", "/CN=localhost",
                "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        os.chmod(key_path, 0o600)
        self._server = FixtureHTTPServer(("127.0.0.1", 0), self.state)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(str(cert_path), str(key_path))
        self._server.socket = context.wrap_socket(self._server.socket, server_side=True)
        port = self._server.server_address[1]
        self.origin = "https://127.0.0.1:{}".format(port)
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()

    def close(self):
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
            self._server = None
        if self._thread is not None:
            self._thread.join(timeout=5)
            self._thread = None
        if self._temporary_directory is not None:
            self._temporary_directory.cleanup()
            self._temporary_directory = None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serve", action="store_true", help="serve until interrupted")
    args = parser.parse_args()
    if not args.serve:
        parser.error("--serve is required")
    runtime = FixtureRuntime()
    runtime.start()
    print(json.dumps({"event": "ready", "origin": runtime.origin}), flush=True)
    try:
        runtime._thread.join()
    except KeyboardInterrupt:
        pass
    finally:
        runtime.close()


if __name__ == "__main__":
    main()

