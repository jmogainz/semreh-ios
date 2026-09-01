#!/usr/bin/env python3
"""Deterministic metadata-only HTTPS fixture for native-auth E2E.

The fixture deliberately records only allowlisted form-shape metadata. It never
logs requests and never stores request bodies, submitted strings, headers,
cookies, query contents, or referrers.
"""

from __future__ import annotations

from collections import deque
import copy
import html
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import shutil
import signal
import ssl
import subprocess
import tempfile
import threading
import time
from typing import Deque, Dict, List, Mapping, Optional, Sequence, Tuple
import urllib.parse

VERSION = 1
HOST = "127.0.0.1"
MAX_BODY_BYTES = 16 * 1024
MAX_FORM_FIELDS = 32
MAX_STATE_RECORDS = 64
DELAY_SECONDS = 0.20
NONCE = "native-auth-fixture-v1"


def _case(scenario_id: str, behavior: str, terminal: str) -> Dict[str, object]:
    return {
        "id": scenario_id,
        "path": f"/v{VERSION}/{scenario_id}",
        "expected_native_behavior": behavior,
        "terminal_fixture_metadata": {"state": terminal},
    }


SCENARIOS: List[Dict[str, object]] = [
    _case("email-password", "fillable", "submitted"),
    _case("username-password", "fillable", "submitted"),
    _case("aria-label-password", "fillable", "submitted"),
    _case("autocomplete-identifier-password", "fillable", "submitted"),
    _case("phone-password", "fillable", "submitted"),
    _case("identifier-then-password", "fillable", "submitted"),
    _case("multiple-fields", "fillable", "submitted"),
    _case("visible-submit-button", "fillable", "submitted"),
    _case("visible-submit-input", "fillable", "submitted"),
    _case("enter-submit", "unsupported", "missing_submit_control"),
    _case("ambiguous-duplicate-labels", "unsupported", "ambiguous_target"),
    _case("ambiguous-duplicate-selectors", "unsupported", "ambiguous_target"),
    _case("hidden-decoy-password", "fillable", "submitted"),
    _case("disabled-control", "unsupported", "disabled_target"),
    _case("readonly-control", "unsupported", "readonly_target"),
    _case("inert-control", "unsupported", "inert_target"),
    _case("dom-replacement-after-probe", "fail_closed_target_changed", "target_changed"),
    _case("same-path-pushstate-query-hash", "fail_closed_target_changed", "target_changed"),
    _case("reload-document-replacement", "fail_closed_target_changed", "target_changed"),
    _case("same-origin-iframe", "fillable", "submitted"),
    _case("cross-origin-iframe", "browser_owned", "cross_origin_frame"),
    _case("redirect-before-submit", "fail_closed_target_changed", "target_changed"),
    _case("redirect-after-submit-invalid-response", "fillable", "invalid_response"),
    _case("delayed-response", "fillable", "submitted"),
    _case("expiring-page", "fail_closed_target_changed", "expired"),
    _case("two-concurrent-forms", "unsupported", "ambiguous_form"),
    _case("two-concurrent-tabs", "fillable", "submitted"),
    _case("button-removed-after-probe", "fail_closed_target_changed", "target_changed"),
    _case("button-disabled-after-probe", "fail_closed_target_changed", "target_changed"),
    _case("form-method-post", "fillable", "submitted"),
    _case("form-method-get", "unsupported", "unsafe_method"),
    _case("form-method-dialog", "unsupported", "unsupported_method"),
    _case("captcha", "browser_owned", "browser_owned"),
    _case("passkey-webauthn", "browser_owned", "browser_owned"),
    _case("enterprise-sso-oidc", "browser_owned", "browser_owned"),
    _case("magic-link", "browser_owned", "browser_owned"),
    _case("push-approval", "browser_owned", "browser_owned"),
    _case("phone-verification", "browser_owned", "browser_owned"),
    _case("otp-checkpoint", "browser_owned", "browser_owned"),
]
CASE_BY_ID = {str(case["id"]): case for case in SCENARIOS}

FIXTURE_CONTROLS: Dict[str, Dict[str, object]] = {
    "identifier-then-password": {"id": "advance_to_password_step"},
    "dom-replacement-after-probe": {"id": "replace_password_control"},
    "same-path-pushstate-query-hash": {"id": "push_safe_history_state"},
    "reload-document-replacement": {"id": "reload_document"},
    "redirect-before-submit": {"id": "redirect_before_submit"},
    "redirect-after-submit-invalid-response": {"id": "redirect_after_submit"},
    "delayed-response": {"id": "delay_response_200ms", "delay_ms": 200},
    "expiring-page": {"id": "expire_page", "automatic_after_ms": 1500},
    "same-origin-iframe": {"id": "same_origin_frame"},
    "cross-origin-iframe": {"id": "cross_origin_frame"},
    "two-concurrent-tabs": {"id": "open_second_tab"},
    "button-removed-after-probe": {"id": "remove_submit_button"},
    "button-disabled-after-probe": {"id": "disable_submit_button"},
}

EXPECTED_FIELDS: Dict[str, Dict[str, str]] = {
    "email-password": {"email": "email", "password": "password"},
    "username-password": {"username": "username", "password": "password"},
    "aria-label-password": {"email": "email", "password": "password"},
    "autocomplete-identifier-password": {"identifier": "identifier", "password": "password"},
    "phone-password": {"phone": "phone", "password": "password"},
    "identifier-then-password": {"identifier": "identifier", "password": "password"},
    "multiple-fields": {
        "email": "email",
        "username": "username",
        "phone": "phone",
        "password": "password",
    },
    "visible-submit-button": {"username": "username", "password": "password"},
    "visible-submit-input": {"username": "username", "password": "password"},
    "enter-submit": {"username": "username", "password": "password"},
    "ambiguous-duplicate-labels": {"password_a": "password", "password_b": "password"},
    "ambiguous-duplicate-selectors": {"password_a": "password", "password_b": "password"},
    "hidden-decoy-password": {"email": "email", "password": "password"},
    "disabled-control": {"password": "password"},
    "readonly-control": {"password": "password"},
    "inert-control": {"password": "password"},
    "dom-replacement-after-probe": {"username": "username", "password": "password"},
    "same-path-pushstate-query-hash": {"username": "username", "password": "password"},
    "reload-document-replacement": {"username": "username", "password": "password"},
    "same-origin-iframe": {"username": "username", "password": "password"},
    "redirect-before-submit": {"username": "username", "password": "password"},
    "redirect-after-submit-invalid-response": {"email": "email", "password": "password"},
    "delayed-response": {"email": "email", "password": "password"},
    "expiring-page": {"username": "username", "password": "password"},
    "two-concurrent-forms": {"username": "username", "password": "password"},
    "two-concurrent-tabs": {"username": "username", "password": "password"},
    "button-removed-after-probe": {"username": "username", "password": "password"},
    "button-disabled-after-probe": {"username": "username", "password": "password"},
    "form-method-post": {"username": "username", "password": "password"},
}


def build_manifest(primary_origin: Optional[str] = None) -> Dict[str, object]:
    """Return a fresh manifest with exact count and safe shape metadata."""
    scenarios: List[Dict[str, object]] = []
    for case in SCENARIOS:
        scenario_id = str(case["id"])
        item: Dict[str, object] = {
            "id": scenario_id,
            "path": case["path"],
            "expected_native_behavior": case["expected_native_behavior"],
            "terminal_fixture_metadata": dict(case["terminal_fixture_metadata"]),
            "expected_fields": [
                {"name": name, "kind": kind}
                for name, kind in EXPECTED_FIELDS.get(scenario_id, {}).items()
            ],
        }
        if scenario_id in FIXTURE_CONTROLS:
            item["fixture_control"] = dict(FIXTURE_CONTROLS[scenario_id])
        if primary_origin is not None:
            item["url"] = primary_origin + str(case["path"])
        scenarios.append(item)
    return {"version": VERSION, "declared_count": len(scenarios), "scenarios": scenarios}


def _length_bucket(length: int) -> str:
    if length == 0:
        return "0"
    if length <= 4:
        return "1-4"
    if length <= 8:
        return "5-8"
    if length <= 16:
        return "9-16"
    return "17+"


class FixtureState:
    """Lock-protected bounded state that never stores submitted strings."""

    def __init__(self, max_records: int = MAX_STATE_RECORDS) -> None:
        if max_records < 1:
            raise ValueError("max_records must be positive")
        self._lock = threading.Lock()
        self._records: Deque[Dict[str, object]] = deque(maxlen=max_records)
        self._total_attempts = 0
        self._scenario_attempts = {str(case["id"]): 0 for case in SCENARIOS}

    def record_submission(
        self,
        *,
        scenario: str,
        route: str,
        expected_fields: Mapping[str, str],
        submitted: Mapping[str, Sequence[str]],
        redirect_state: str = "none",
        invalid_result_state: str = "none",
    ) -> Dict[str, object]:
        fields: List[Dict[str, object]] = []
        for name, kind in expected_fields.items():
            entries = submitted.get(name)
            present = entries is not None
            lengths = [len(item) for item in entries] if entries else []
            longest = max(lengths, default=0)
            fields.append(
                {
                    "name": name,
                    "kind": kind,
                    "present": present,
                    "empty": present and longest == 0,
                    "length_bucket": _length_bucket(longest),
                }
            )
        unexpected_field_count = sum(1 for name in submitted if name not in expected_fields)

        with self._lock:
            self._total_attempts += 1
            if scenario in self._scenario_attempts:
                self._scenario_attempts[scenario] += 1
            record: Dict[str, object] = {
                "scenario": scenario,
                "route": route,
                "attempt": self._total_attempts,
                "scenario_attempt": self._scenario_attempts.get(scenario, 0),
                "fields": fields,
                "unexpected_field_count": unexpected_field_count,
                "redirect_state": redirect_state,
                "invalid_result_state": invalid_result_state,
            }
            self._records.append(record)
            return copy.deepcopy(record)

    def snapshot(self) -> Dict[str, object]:
        with self._lock:
            return {
                "total_attempts": self._total_attempts,
                "record_count": len(self._records),
                "records": copy.deepcopy(list(self._records)),
            }

    def reset(self) -> None:
        with self._lock:
            self._total_attempts = 0
            self._records.clear()
            for scenario in self._scenario_attempts:
                self._scenario_attempts[scenario] = 0


def _field(
    name: str,
    kind: str,
    label: str,
    *,
    field_id: Optional[str] = None,
    aria_only: bool = False,
    autocomplete: Optional[str] = None,
    extra: str = "",
) -> str:
    identifier = field_id or f"field-{name}"
    input_type = {"password": "password", "email": "email", "phone": "tel"}.get(kind, "text")
    autocomplete_attr = f' autocomplete="{html.escape(autocomplete)}"' if autocomplete else ""
    label_html = "" if aria_only else f'<label for="{html.escape(identifier)}">{html.escape(label)}</label>'
    aria = f' aria-label="{html.escape(label)}"' if aria_only else ""
    return (
        label_html
        + f'<input id="{html.escape(identifier)}" name="{html.escape(name)}" '
        + f'type="{input_type}"{aria}{autocomplete_attr} {extra}>'
    )


def _submit_button(button_id: str = "fixture-submit") -> str:
    return f'<button id="{button_id}" type="submit" aria-label="Submit sign-in form">Submit</button>'


def _standard_fields(identifier: str = "username") -> str:
    label = "Email" if identifier == "email" else "Username"
    kind = "email" if identifier == "email" else "username"
    auto = "email" if identifier == "email" else "username"
    return _field(identifier, kind, label, autocomplete=auto) + _field(
        "password", "password", "Password", autocomplete="current-password"
    )


def _browser_owned_markup(scenario_id: str) -> str:
    labels = {
        "cross-origin-iframe": "Continue in cross-origin frame",
        "captcha": "Complete CAPTCHA in the browser",
        "passkey-webauthn": "Use browser passkey prompt",
        "enterprise-sso-oidc": "Continue with enterprise SSO or OIDC",
        "magic-link": "Open the provider-owned magic link",
        "push-approval": "Approve the provider push notification",
        "phone-verification": "Complete provider phone verification",
        "otp-checkpoint": "Complete the provider OTP checkpoint",
    }
    label = labels[scenario_id]
    return (
        '<section role="status" aria-live="polite" data-browser-owned-checkpoint="true">'
        f'<p>{html.escape(label)}</p>'
        f'<button type="button" aria-label="{html.escape(label)}">Continue in browser</button>'
        "</section>"
    )


def _scenario_body(scenario_id: str, primary_origin: str, cross_origin: str, *, frame: bool = False) -> str:
    action = f"/v{VERSION}/{scenario_id}/submit"
    standard = _standard_fields()
    form = lambda content, suffix="": f'<form method="post" action="{action}{suffix}">{content}</form>'

    if scenario_id == "email-password":
        return form(_standard_fields("email") + _submit_button())
    if scenario_id == "username-password":
        return form(standard + _submit_button())
    if scenario_id == "aria-label-password":
        return form(
            _field("email", "email", "Email address", aria_only=True, autocomplete="email")
            + _field("password", "password", "Password", aria_only=True, autocomplete="current-password")
            + _submit_button()
        )
    if scenario_id == "autocomplete-identifier-password":
        return form(
            _field("identifier", "identifier", "Account identifier", aria_only=True, autocomplete="username")
            + _field("password", "password", "Account password", aria_only=True, autocomplete="current-password")
            + _submit_button()
        )
    if scenario_id == "phone-password":
        return form(
            _field("phone", "phone", "Phone number", autocomplete="tel")
            + _field("password", "password", "Password", autocomplete="current-password")
            + _submit_button()
        )
    if scenario_id == "identifier-then-password":
        if frame:
            return form(_field("password", "password", "Password") + _submit_button())
        return (
            f'<form method="post" action="/v{VERSION}/{scenario_id}/step/identifier/submit">'
            + _field("identifier", "identifier", "Email, username, or phone", autocomplete="username")
            + _submit_button()
            + "</form>"
        )
    if scenario_id == "multiple-fields":
        return form(
            _field("email", "email", "Email", autocomplete="email")
            + _field("username", "username", "Username", autocomplete="username")
            + _field("phone", "phone", "Phone", autocomplete="tel")
            + _field("password", "password", "Password", autocomplete="current-password")
            + _submit_button()
        )
    if scenario_id == "visible-submit-button":
        return form(standard + _submit_button())
    if scenario_id == "visible-submit-input":
        return form(standard + '<input type="submit" aria-label="Submit sign-in form">')
    if scenario_id == "enter-submit":
        return form(standard + '<p id="enter-help">Press Enter to submit.</p>')
    if scenario_id == "ambiguous-duplicate-labels":
        return form(
            _field("password_a", "password", "Password", field_id="password-a")
            + _field("password_b", "password", "Password", field_id="password-b")
            + _submit_button()
        )
    if scenario_id == "ambiguous-duplicate-selectors":
        return form(
            _field("password_a", "password", "Primary password", field_id="duplicate-password")
            + _field("password_b", "password", "Confirm password", field_id="duplicate-password")
            + _submit_button()
        )
    if scenario_id == "hidden-decoy-password":
        return form(
            '<input id="decoy-password" type="password" hidden aria-hidden="true" tabindex="-1">'
            + _standard_fields("email")
            + _submit_button()
        )
    if scenario_id == "disabled-control":
        return form(_field("password", "password", "Disabled password", extra="disabled") + _submit_button())
    if scenario_id == "readonly-control":
        return form(_field("password", "password", "Read-only password", extra="readonly") + _submit_button())
    if scenario_id == "inert-control":
        return form('<fieldset inert>' + _field("password", "password", "Inert password") + "</fieldset>" + _submit_button())
    if scenario_id == "same-origin-iframe":
        if frame:
            return form(standard + _submit_button())
        return f'<iframe title="Same-origin sign-in form" src="{primary_origin}/v{VERSION}/{scenario_id}/frame"></iframe>'
    if scenario_id == "cross-origin-iframe":
        if frame:
            return _browser_owned_markup(scenario_id)
        return f'<iframe title="Cross-origin browser-owned checkpoint" src="{cross_origin}/v{VERSION}/{scenario_id}/frame"></iframe>'
    if scenario_id == "form-method-get":
        return f'<form method="get" action="{action}">{standard}{_submit_button()}</form>'
    if scenario_id == "form-method-dialog":
        return f'<form method="dialog" action="{action}">{standard}{_submit_button()}</form>'
    if scenario_id in {
        "captcha",
        "passkey-webauthn",
        "enterprise-sso-oidc",
        "magic-link",
        "push-approval",
        "phone-verification",
        "otp-checkpoint",
    }:
        return _browser_owned_markup(scenario_id)
    if scenario_id == "two-concurrent-forms":
        form_a = (
            _field("username", "username", "Username", field_id="form-a-username", autocomplete="username")
            + _field("password", "password", "Password", field_id="form-a-password", autocomplete="current-password")
            + _submit_button("submit-a")
        )
        form_b = (
            _field("username", "username", "Username", field_id="form-b-username", autocomplete="username")
            + _field("password", "password", "Password", field_id="form-b-password", autocomplete="current-password")
            + _submit_button("submit-b")
        )
        return (
            '<section aria-label="First sign-in form">'
            + form(form_a)
            + "</section><section aria-label=\"Second sign-in form\">"
            + form(form_b)
            + "</section>"
        )
    if scenario_id == "two-concurrent-tabs":
        return (
            form(standard + _submit_button())
            + f'<button type="button" aria-label="Open second fixture tab" onclick="window.open(\'/v{VERSION}/{scenario_id}\', \'fixture-second-tab\')">Open second tab</button>'
        )

    script = ""
    controls = ""
    if scenario_id == "dom-replacement-after-probe":
        script = "function fixtureTrigger(){const n=document.getElementById('field-password');n.replaceWith(n.cloneNode(true));}"
        controls = '<button type="button" aria-label="Replace password control" onclick="fixtureTrigger()">Replace target</button>'
    elif scenario_id == "same-path-pushstate-query-hash":
        script = "function fixtureTrigger(){history.pushState({fixture:true},'',location.pathname+'?fixture=changed#changed');}"
        controls = '<button type="button" aria-label="Change same-path history state" onclick="fixtureTrigger()">Change history</button>'
    elif scenario_id == "reload-document-replacement":
        script = "function fixtureTrigger(){location.reload();}"
        controls = '<button type="button" aria-label="Reload fixture document" onclick="fixtureTrigger()">Reload</button>'
    elif scenario_id == "redirect-before-submit":
        script = f"function fixtureTrigger(){{location.assign('/v{VERSION}/{scenario_id}/changed');}}"
        controls = '<button type="button" aria-label="Redirect before submit" onclick="fixtureTrigger()">Redirect</button>'
    elif scenario_id == "expiring-page":
        script = "function fixtureTrigger(){document.getElementById('fixture-form').replaceChildren(document.createTextNode('Expired'));}setTimeout(fixtureTrigger,1500);"
        standard_form = f'<form id="fixture-form" method="post" action="{action}">{standard}{_submit_button()}</form>'
        controls = '<button type="button" aria-label="Expire fixture page now" onclick="fixtureTrigger()">Expire now</button>'
        return standard_form + controls + f'<script nonce="{NONCE}">{script}</script>'
    elif scenario_id == "button-removed-after-probe":
        script = "function fixtureTrigger(){document.getElementById('fixture-submit').remove();}"
        controls = '<button type="button" aria-label="Remove submit button" onclick="fixtureTrigger()">Remove submit</button>'
    elif scenario_id == "button-disabled-after-probe":
        script = "function fixtureTrigger(){document.getElementById('fixture-submit').disabled=true;}"
        controls = '<button type="button" aria-label="Disable submit button" onclick="fixtureTrigger()">Disable submit</button>'

    result = form(standard + _submit_button()) + controls
    if script:
        result += f'<script nonce="{NONCE}">{script}</script>'
    return result


def render_page(
    scenario_id: str,
    primary_origin: str,
    cross_origin: str,
    *,
    origin_role: str,
    frame: bool = False,
    terminal_message: Optional[str] = None,
) -> bytes:
    case = CASE_BY_ID[scenario_id]
    behavior = str(case["expected_native_behavior"])
    terminal = str(case["terminal_fixture_metadata"]["state"])
    body = (
        f'<p role="status">{html.escape(terminal_message)}</p>'
        if terminal_message is not None
        else _scenario_body(scenario_id, primary_origin, cross_origin, frame=frame)
    )
    document = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Native Auth Fixture: {html.escape(scenario_id)}</title>
<style nonce="{NONCE}">body{{font-family:system-ui;max-width:42rem;margin:2rem auto}}label,input,button{{display:block;margin:.5rem 0}}iframe{{width:100%;min-height:20rem;border:1px solid}}</style>
</head>
<body>
<main data-scenario="{html.escape(scenario_id)}" data-origin-role="{origin_role}" data-native-auth-classification="{behavior}" data-expected-terminal="{terminal}">
<h1>{html.escape(scenario_id)}</h1>
{body}
</main>
</body>
</html>"""
    return document.encode("utf-8")


class FixtureHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 128
    tls_context: Optional[ssl.SSLContext] = None

    def get_request(self):
        """Accept quickly; perform each TLS handshake in its request thread."""
        request, client_address = super().get_request()
        context = self.tls_context
        if context is None:
            request.close()
            raise RuntimeError("fixture_tls_context_unavailable")
        try:
            return (
                context.wrap_socket(
                    request,
                    server_side=True,
                    do_handshake_on_connect=False,
                ),
                client_address,
            )
        except Exception:
            request.close()
            raise


class FixtureRuntime:
    """Own two loopback-only HTTPS origins and a shared metadata state."""

    def __init__(self) -> None:
        self.state = FixtureState()
        self.stop_event = threading.Event()
        self._temporary_directory: Optional[tempfile.TemporaryDirectory[str]] = None
        self._servers: List[FixtureHTTPServer] = []
        self._threads: List[threading.Thread] = []
        self.primary_origin = ""
        self.cross_origin = ""

    def _make_certificate(self) -> Tuple[str, str]:
        self._temporary_directory = tempfile.TemporaryDirectory(prefix="native-auth-fixture-cert-")
        directory = self._temporary_directory.name
        os.chmod(directory, 0o700)
        config_path = os.path.join(directory, "openssl.cnf")
        cert_path = os.path.join(directory, "cert.pem")
        key_path = os.path.join(directory, "key.pem")
        config = """[req]
prompt = no
distinguished_name = dn
x509_extensions = ext
[dn]
CN = localhost
[ext]
subjectAltName = @san
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
[san]
DNS.1 = localhost
IP.1 = 127.0.0.1
"""
        with open(config_path, "w", encoding="utf-8") as handle:
            handle.write(config)
        command = [
            "openssl",
            "req",
            "-x509",
            "-nodes",
            "-newkey",
            "rsa:2048",
            "-sha256",
            "-days",
            "1",
            "-config",
            config_path,
            "-keyout",
            key_path,
            "-out",
            cert_path,
        ]
        subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        os.chmod(key_path, 0o600)
        return cert_path, key_path

    def _handler_class(self, origin_role: str):
        runtime = self

        class Handler(FixtureRequestHandler):
            fixture_runtime = runtime
            fixture_origin_role = origin_role

        return Handler

    def start(self) -> None:
        if shutil.which("openssl") is None:
            raise RuntimeError("openssl_unavailable")
        cert_path, key_path = self._make_certificate()
        primary = FixtureHTTPServer((HOST, 0), self._handler_class("primary"))
        cross = FixtureHTTPServer((HOST, 0), self._handler_class("cross"))
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(certfile=cert_path, keyfile=key_path)
        primary.tls_context = context
        cross.tls_context = context
        self._servers = [primary, cross]
        self.primary_origin = f"https://{HOST}:{primary.server_port}"
        self.cross_origin = f"https://{HOST}:{cross.server_port}"
        for index, server in enumerate(self._servers):
            thread = threading.Thread(target=server.serve_forever, name=f"fixture-https-{index}", daemon=True)
            self._threads.append(thread)
            thread.start()

    def ready_record(self) -> Dict[str, object]:
        endpoints = {
            "health": self.primary_origin + "/__test__/health",
            "manifest": self.primary_origin + "/__test__/manifest",
            "state": self.primary_origin + "/__test__/state",
            "reset": self.primary_origin + "/__test__/reset",
            "shutdown": self.primary_origin + "/__test__/shutdown",
        }
        return {
            "event": "ready",
            "version": VERSION,
            "primary_origin": self.primary_origin,
            "cross_origin": self.cross_origin,
            "endpoints": endpoints,
        }

    def request_shutdown(self) -> None:
        self.stop_event.set()

    def wait(self) -> None:
        self.stop_event.wait()

    def close(self) -> None:
        for server in self._servers:
            server.shutdown()
            server.server_close()
        for thread in self._threads:
            thread.join(timeout=2)
        self._servers.clear()
        self._threads.clear()
        if self._temporary_directory is not None:
            self._temporary_directory.cleanup()
            self._temporary_directory = None


class FixtureRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    fixture_runtime: FixtureRuntime
    fixture_origin_role: str

    def log_request(self, code: object = "-", size: object = "-") -> None:
        return

    def log_error(self, format: str, *args: object) -> None:
        return

    def log_message(self, format: str, *args: object) -> None:
        return

    def _security_headers(self) -> None:
        cross = self.fixture_runtime.cross_origin
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Permissions-Policy", "camera=(), microphone=(), geolocation=(), publickey-credentials-get=()")
        self.send_header(
            "Content-Security-Policy",
            f"default-src 'self'; base-uri 'none'; form-action 'self'; frame-src 'self' {cross}; "
            f"connect-src 'none'; img-src 'none'; font-src 'none'; object-src 'none'; "
            f"script-src 'nonce-{NONCE}'; style-src 'nonce-{NONCE}'",
        )

    def _send(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self._security_headers()
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, status: int, payload: Mapping[str, object]) -> None:
        body = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        self._send(status, body, "application/json; charset=utf-8")

    def _html(self, status: int, body: bytes) -> None:
        self._send(status, body, "text/html; charset=utf-8")

    def _redirect(self, location: str) -> None:
        self.send_response(HTTPStatus.SEE_OTHER)
        self._security_headers()
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self) -> None:
        path = urllib.parse.urlsplit(self.path).path
        runtime = self.fixture_runtime
        if path == "/__test__/health":
            self._json(HTTPStatus.OK, {"status": "ok", "version": VERSION})
            return
        if path == "/__test__/manifest":
            self._json(HTTPStatus.OK, build_manifest(runtime.primary_origin))
            return
        if path == "/__test__/state":
            self._json(HTTPStatus.OK, runtime.state.snapshot())
            return

        segments = [part for part in path.split("/") if part]
        if len(segments) < 2 or segments[0] != f"v{VERSION}":
            self._json(HTTPStatus.NOT_FOUND, {"status": "not_found"})
            return
        scenario_id = segments[1]
        if scenario_id not in CASE_BY_ID:
            self._json(HTTPStatus.NOT_FOUND, {"status": "not_found"})
            return
        frame = len(segments) == 3 and segments[2] == "frame"
        password_step = segments[2:] == ["step", "password"]
        terminal_page = len(segments) == 3 and segments[2] in {"invalid", "changed", "submitted"}
        if len(segments) > 2 and not (frame or password_step or terminal_page):
            self._json(HTTPStatus.NOT_FOUND, {"status": "not_found"})
            return
        message = None
        if terminal_page:
            message = {
                "invalid": "Invalid response fixture state",
                "changed": "Target changed fixture state",
                "submitted": "Submission recorded",
            }[segments[2]]
        self._html(
            HTTPStatus.OK,
            render_page(
                scenario_id,
                runtime.primary_origin,
                runtime.cross_origin,
                origin_role=self.fixture_origin_role,
                frame=password_step or frame,
                terminal_message=message,
            ),
        )

    def _read_form(self) -> Optional[Dict[str, List[str]]]:
        raw_length = self.headers.get("Content-Length", "0")
        try:
            length = int(raw_length)
        except (TypeError, ValueError):
            self._json(HTTPStatus.BAD_REQUEST, {"status": "invalid_length"})
            return None
        if length < 0 or length > MAX_BODY_BYTES:
            self._json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"status": "body_too_large"})
            return None
        content_type = self.headers.get_content_type()
        if content_type != "application/x-www-form-urlencoded":
            self._json(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, {"status": "unsupported_media_type"})
            return None
        body = self.rfile.read(length)
        try:
            decoded = body.decode("utf-8", errors="strict")
            return urllib.parse.parse_qs(
                decoded,
                keep_blank_values=True,
                strict_parsing=False,
                max_num_fields=MAX_FORM_FIELDS,
            )
        except (UnicodeDecodeError, ValueError):
            self._json(HTTPStatus.BAD_REQUEST, {"status": "invalid_form"})
            return None

    def do_POST(self) -> None:
        path = urllib.parse.urlsplit(self.path).path
        runtime = self.fixture_runtime
        if path == "/__test__/reset":
            if self._read_form() is None:
                return
            runtime.state.reset()
            self._json(HTTPStatus.OK, {"status": "reset"})
            return
        if path == "/__test__/shutdown":
            if self._read_form() is None:
                return
            self._json(HTTPStatus.OK, {"status": "shutting_down"})
            runtime.request_shutdown()
            return

        segments = [part for part in path.split("/") if part]
        if len(segments) < 3 or segments[0] != f"v{VERSION}" or segments[1] not in CASE_BY_ID:
            self._json(HTTPStatus.NOT_FOUND, {"status": "not_found"})
            return
        scenario_id = segments[1]
        is_identifier_step = segments[2:] == ["step", "identifier", "submit"]
        is_password_step = segments[2:] == ["step", "password", "submit"]
        is_generic_submit = segments[2:] == ["submit"]
        if not (is_identifier_step or is_password_step or is_generic_submit):
            self._json(HTTPStatus.NOT_FOUND, {"status": "not_found"})
            return
        submitted = self._read_form()
        if submitted is None:
            return
        expected_fields = EXPECTED_FIELDS.get(scenario_id, {})
        if is_identifier_step:
            expected_fields = {"identifier": "identifier"}
        elif is_password_step:
            expected_fields = {"password": "password"}
        invalid_state = "redirected_invalid_response" if scenario_id == "redirect-after-submit-invalid-response" else "none"
        redirect_state = "after_submit" if scenario_id == "redirect-after-submit-invalid-response" else "none"
        runtime.state.record_submission(
            scenario=scenario_id,
            route=path,
            expected_fields=expected_fields,
            submitted=submitted,
            redirect_state=redirect_state,
            invalid_result_state=invalid_state,
        )
        if scenario_id == "delayed-response":
            time.sleep(DELAY_SECONDS)
        if is_identifier_step:
            self._redirect(f"/v{VERSION}/{scenario_id}/step/password")
            return
        if scenario_id == "redirect-after-submit-invalid-response":
            self._redirect(f"/v{VERSION}/{scenario_id}/invalid")
            return
        self._html(
            HTTPStatus.OK,
            render_page(
                scenario_id,
                runtime.primary_origin,
                runtime.cross_origin,
                origin_role=self.fixture_origin_role,
                terminal_message="Submission recorded",
            ),
        )


def main() -> int:
    runtime = FixtureRuntime()

    def stop_handler(_signum: int, _frame: object) -> None:
        runtime.request_shutdown()

    signal.signal(signal.SIGINT, stop_handler)
    signal.signal(signal.SIGTERM, stop_handler)
    try:
        runtime.start()
    except Exception:
        print(json.dumps({"event": "error", "code": "fixture_start_failed"}, separators=(",", ":")), flush=True)
        runtime.close()
        return 1
    print(json.dumps(runtime.ready_record(), sort_keys=True, separators=(",", ":")), flush=True)
    try:
        runtime.wait()
    finally:
        runtime.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

