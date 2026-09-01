#!/usr/bin/env python3
"""Contract tests for the local native-auth HTTPS fixture."""

from __future__ import annotations

import contextlib
import importlib.util
from html.parser import HTMLParser
import json
import os
import pathlib
import selectors
import ssl
import subprocess
import sys
import threading
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request
import uuid

HERE = pathlib.Path(__file__).resolve().parent
SERVER_PATH = HERE / "server.py"


def load_server():
    spec = importlib.util.spec_from_file_location("native_auth_fixture_server", SERVER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load fixture server")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


EXPECTED_SCENARIOS = {
    "email-password",
    "username-password",
    "aria-label-password",
    "autocomplete-identifier-password",
    "phone-password",
    "identifier-then-password",
    "multiple-fields",
    "visible-submit-button",
    "visible-submit-input",
    "enter-submit",
    "ambiguous-duplicate-labels",
    "ambiguous-duplicate-selectors",
    "hidden-decoy-password",
    "disabled-control",
    "readonly-control",
    "inert-control",
    "dom-replacement-after-probe",
    "same-path-pushstate-query-hash",
    "reload-document-replacement",
    "same-origin-iframe",
    "cross-origin-iframe",
    "redirect-before-submit",
    "redirect-after-submit-invalid-response",
    "delayed-response",
    "expiring-page",
    "two-concurrent-forms",
    "two-concurrent-tabs",
    "button-removed-after-probe",
    "button-disabled-after-probe",
    "form-method-post",
    "form-method-get",
    "form-method-dialog",
    "captcha",
    "passkey-webauthn",
    "enterprise-sso-oidc",
    "magic-link",
    "push-approval",
    "phone-verification",
    "otp-checkpoint",
}


SSL_CONTEXT = ssl.create_default_context()
SSL_CONTEXT.check_hostname = False
SSL_CONTEXT.verify_mode = ssl.CERT_NONE


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


NO_REDIRECT_OPENER = urllib.request.build_opener(
    urllib.request.HTTPSHandler(context=SSL_CONTEXT), _NoRedirect()
)


def https_request(url, *, data=None, method=None, follow_redirects=True):
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Content-Type", "application/x-www-form-urlencoded")
    opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=SSL_CONTEXT))
    try:
        response = (opener if follow_redirects else NO_REDIRECT_OPENER).open(request, timeout=5)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, dict(response.headers), response.read()


@contextlib.contextmanager
def running_fixture():
    process = subprocess.Popen(
        [sys.executable, str(HERE / "launch.py")],
        cwd=str(HERE),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    assert process.stdout is not None
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    events = selector.select(timeout=30)
    if not events:
        process.terminate()
        process.wait(timeout=5)
        raise AssertionError("fixture did not emit a ready record")
    ready_line = process.stdout.readline()
    ready = json.loads(ready_line)
    if ready.get("event") != "ready":
        process.terminate()
        process.wait(timeout=5)
        raise AssertionError(f"fixture startup failed safely: {ready}")
    try:
        yield process, ready
    finally:
        if process.poll() is None:
            try:
                https_request(ready["endpoints"]["shutdown"], data=b"", method="POST")
            except Exception:
                process.terminate()
        process.wait(timeout=10)


class _FormAccessibilityParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.inputs = []
        self.labels_for = set()
        self.classifications = []
        self.iframes = []
        self.ids = []

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if attributes.get("id"):
            self.ids.append(attributes["id"])
        if tag == "input":
            self.inputs.append(attributes)
        elif tag == "label" and attributes.get("for"):
            self.labels_for.add(attributes["for"])
        elif tag == "iframe":
            self.iframes.append(attributes)
        if "data-native-auth-classification" in attributes:
            self.classifications.append(attributes["data-native-auth-classification"])


class ManifestContractTests(unittest.TestCase):
    def test_manifest_enumerates_the_complete_versioned_matrix(self):
        server = load_server()
        manifest = server.build_manifest()
        cases = manifest["scenarios"]

        self.assertEqual(manifest["version"], 1)
        self.assertEqual(manifest["declared_count"], len(cases))
        self.assertEqual({case["id"] for case in cases}, EXPECTED_SCENARIOS)
        self.assertEqual(len(cases), len(EXPECTED_SCENARIOS))
        self.assertEqual(len(cases), len({case["path"] for case in cases}))
        for case in cases:
            with self.subTest(case=case["id"]):
                self.assertTrue(case["path"].startswith("/v1/"))
                self.assertIn(
                    case["expected_native_behavior"],
                    {"fillable", "fail_closed_target_changed", "browser_owned", "unsupported"},
                )
                self.assertIn("terminal_fixture_metadata", case)
                self.assertNotIn("value", repr(case).lower())

    def test_manifest_declares_deterministic_fixture_controls(self):
        server = load_server()
        cases = {case["id"]: case for case in server.build_manifest()["scenarios"]}
        expected_controls = {
            "identifier-then-password": "advance_to_password_step",
            "dom-replacement-after-probe": "replace_password_control",
            "same-path-pushstate-query-hash": "push_safe_history_state",
            "reload-document-replacement": "reload_document",
            "redirect-before-submit": "redirect_before_submit",
            "redirect-after-submit-invalid-response": "redirect_after_submit",
            "delayed-response": "delay_response_200ms",
            "expiring-page": "expire_page",
            "same-origin-iframe": "same_origin_frame",
            "cross-origin-iframe": "cross_origin_frame",
            "two-concurrent-tabs": "open_second_tab",
            "button-removed-after-probe": "remove_submit_button",
            "button-disabled-after-probe": "disable_submit_button",
        }
        self.assertEqual(
            {scenario_id: cases[scenario_id]["fixture_control"]["id"] for scenario_id in expected_controls},
            expected_controls,
        )
        self.assertEqual(cases["expiring-page"]["fixture_control"]["automatic_after_ms"], 1500)
        self.assertEqual(cases["delayed-response"]["fixture_control"]["delay_ms"], 200)

    def test_run_matrix_list_is_machine_readable_and_exact(self):
        completed = subprocess.run(
            [sys.executable, str(HERE / "run_matrix.py"), "--list"],
            cwd=str(HERE),
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        listing = json.loads(completed.stdout)
        self.assertEqual(listing["count"], len(EXPECTED_SCENARIOS))
        self.assertEqual(set(listing["scenarios"]), EXPECTED_SCENARIOS)
        self.assertEqual(completed.stderr, "")


class MetadataStateTests(unittest.TestCase):
    def test_submission_records_only_allowlisted_shape_metadata(self):
        server = load_server()
        state = server.FixtureState(max_records=8)
        canary = "NATIVE_AUTH_CANARY_do-not-retain_9f4c"

        state.record_submission(
            scenario="email-password",
            route="/v1/email-password/submit",
            expected_fields={"email": "email", "password": "password"},
            submitted={"email": [canary], "password": [canary], canary: [canary]},
            redirect_state="none",
            invalid_result_state="none",
        )
        snapshot = state.snapshot()
        serialized = json.dumps(snapshot, sort_keys=True)

        self.assertNotIn(canary, serialized)
        self.assertEqual(snapshot["total_attempts"], 1)
        self.assertEqual(snapshot["record_count"], 1)
        record = snapshot["records"][0]
        self.assertEqual(record["scenario"], "email-password")
        self.assertEqual(record["route"], "/v1/email-password/submit")
        self.assertEqual(record["attempt"], 1)
        self.assertEqual(record["unexpected_field_count"], 1)
        self.assertEqual(
            record["fields"],
            [
                {"name": "email", "kind": "email", "present": True, "empty": False, "length_bucket": "17+"},
                {"name": "password", "kind": "password", "present": True, "empty": False, "length_bucket": "17+"},
            ],
        )

    def test_state_is_concurrency_safe_and_count_bounded(self):
        server = load_server()
        state = server.FixtureState(max_records=7)

        def submit_once(index):
            state.record_submission(
                scenario="two-concurrent-forms",
                route="/v1/two-concurrent-forms/submit",
                expected_fields={"username": "username"},
                submitted={"username": ["x" * ((index % 5) + 1)]},
            )

        threads = [threading.Thread(target=submit_once, args=(index,)) for index in range(40)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()

        snapshot = state.snapshot()
        self.assertEqual(snapshot["total_attempts"], 40)
        self.assertEqual(snapshot["record_count"], 7)
        self.assertEqual([record["attempt"] for record in snapshot["records"]], list(range(34, 41)))

        state.reset()
        self.assertEqual(state.snapshot(), {"total_attempts": 0, "record_count": 0, "records": []})


class RuntimeArtifactTests(unittest.TestCase):
    def test_ephemeral_certificate_has_loopback_san_and_is_removed(self):
        server = load_server()
        runtime = server.FixtureRuntime()
        temporary_path = None
        try:
            runtime.start()
            self.assertIsNotNone(runtime._temporary_directory)
            temporary_path = pathlib.Path(runtime._temporary_directory.name)
            self.assertNotEqual(
                os.path.commonpath([str(temporary_path.resolve()), str(HERE.resolve())]),
                str(HERE.resolve()),
            )
            certificate = temporary_path / "cert.pem"
            key = temporary_path / "key.pem"
            self.assertTrue(certificate.is_file())
            self.assertEqual(key.stat().st_mode & 0o777, 0o600)
            inspected = subprocess.run(
                ["openssl", "x509", "-in", str(certificate), "-noout", "-text"],
                check=True,
                capture_output=True,
                text=True,
                timeout=5,
            ).stdout
            self.assertIn("DNS:localhost", inspected)
            self.assertIn("IP Address:127.0.0.1", inspected)
        finally:
            runtime.close()
        self.assertIsNotNone(temporary_path)
        self.assertFalse(temporary_path.exists())


class HTTPSFixtureIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture_context = running_fixture()
        cls.process, cls.ready = cls.fixture_context.__enter__()
        cls.primary = cls.ready["primary_origin"]
        cls.cross = cls.ready["cross_origin"]

    @classmethod
    def tearDownClass(cls):
        cls.fixture_context.__exit__(None, None, None)

    def setUp(self):
        status, _, _ = https_request(self.ready["endpoints"]["reset"], data=b"", method="POST")
        self.assertEqual(status, 200)

    def test_ready_record_is_safe_loopback_dynamic_https_metadata(self):
        self.assertEqual(set(self.ready), {"event", "version", "primary_origin", "cross_origin", "endpoints"})
        self.assertEqual(self.ready["event"], "ready")
        self.assertNotEqual(self.primary, self.cross)
        for origin in (self.primary, self.cross):
            parsed = urllib.parse.urlsplit(origin)
            self.assertEqual(parsed.scheme, "https")
            self.assertEqual(parsed.hostname, "127.0.0.1")
            self.assertGreater(parsed.port, 0)
        self.assertNotIn("cert", json.dumps(self.ready).lower())
        status, _, body = https_request(self.ready["endpoints"]["health"])
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"status": "ok", "version": 1})

    def test_manifest_endpoint_and_every_declared_page(self):
        status, _, body = https_request(self.ready["endpoints"]["manifest"])
        self.assertEqual(status, 200)
        manifest = json.loads(body)
        self.assertEqual(manifest["declared_count"], len(manifest["scenarios"]))
        self.assertEqual(manifest["declared_count"], len(EXPECTED_SCENARIOS))
        for case in manifest["scenarios"]:
            with self.subTest(case=case["id"]):
                self.assertEqual(case["url"], self.primary + case["path"])
                page_status, headers, page = https_request(case["url"])
                text = page.decode("utf-8")
                self.assertEqual(page_status, 200)
                self.assertIn("text/html", headers["Content-Type"])
                self.assertIn("default-src 'self'", headers["Content-Security-Policy"])
                self.assertIn(f'data-scenario="{case["id"]}"', text)
                self.assertNotIn("http://", text)
                self.assertNotIn("localStorage", text)
                self.assertNotIn("serviceWorker", text)
                self.assertNotIn("document.cookie", text)

    def test_unsafe_form_matrix_cases_render_real_semantics(self):
        expected = {
            "form-method-get": ('<form method="get"', 1, 'type="submit"'),
            "form-method-dialog": ('<form method="dialog"', 1, 'type="submit"'),
            "enter-submit": ('<form method="post"', 1, None),
            "two-concurrent-forms": ('<form method="post"', 2, 'type="submit"'),
        }
        for scenario_id, (form_marker, form_count, submit_marker) in expected.items():
            with self.subTest(case=scenario_id):
                _, _, page = https_request(self.primary + f"/v1/{scenario_id}")
                text = page.decode("utf-8")
                self.assertEqual(text.count(form_marker), form_count)
                self.assertIn('type="password"', text)
                if submit_marker is None:
                    self.assertNotIn('type="submit"', text)
                else:
                    self.assertEqual(text.count(submit_marker), form_count)

    def test_manifest_classifies_enter_only_and_multiple_viable_forms_as_unsupported(self):
        _, _, body = https_request(self.ready["endpoints"]["manifest"])
        cases = {case["id"]: case for case in json.loads(body)["scenarios"]}
        self.assertEqual(cases["enter-submit"]["expected_native_behavior"], "unsupported")
        self.assertEqual(cases["two-concurrent-forms"]["expected_native_behavior"], "unsupported")

    def test_all_controls_are_accessible_and_unsupported_cases_are_marked(self):
        _, _, body = https_request(self.ready["endpoints"]["manifest"])
        manifest = json.loads(body)
        browser_owned = 0
        for case in manifest["scenarios"]:
            _, _, page = https_request(case["url"])
            parser = _FormAccessibilityParser()
            parser.feed(page.decode("utf-8"))
            for field in parser.inputs:
                if "hidden" in field or field.get("type") == "hidden":
                    continue
                field_id = field.get("id")
                accessible = bool(field.get("aria-label")) or bool(field_id and field_id in parser.labels_for)
                self.assertTrue(accessible, f"unlabelled control in {case['id']}: {field}")
            behavior = case["expected_native_behavior"]
            if behavior in {"browser_owned", "unsupported"}:
                self.assertIn(behavior, parser.classifications, case["id"])
            if behavior == "browser_owned":
                browser_owned += 1
                self.assertEqual(parser.inputs, [], case["id"])
        self.assertEqual(browser_owned, 8)

    def test_submission_state_and_reset_never_retain_canary_or_query(self):
        canary = "NATIVE_AUTH_" + "CANARY_" + uuid.uuid4().hex
        payload = urllib.parse.urlencode(
            {"email": canary, "password": canary, canary: canary}
        ).encode("ascii")
        status, _, _ = https_request(
            self.primary + "/v1/email-password/submit?ignored=" + urllib.parse.quote(canary),
            data=payload,
            method="POST",
        )
        self.assertEqual(status, 200)
        _, _, state_body = https_request(self.ready["endpoints"]["state"])
        state_text = state_body.decode("utf-8")
        self.assertNotIn(canary, state_text)
        state = json.loads(state_text)
        self.assertEqual(state["total_attempts"], 1)
        self.assertEqual(state["records"][0]["unexpected_field_count"], 1)
        self.assertNotIn("query", state_text.lower())
        status, _, body = https_request(self.ready["endpoints"]["reset"], data=b"", method="POST")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"status": "reset"})
        _, _, state_body = https_request(self.ready["endpoints"]["state"])
        self.assertEqual(json.loads(state_body)["record_count"], 0)

    def test_concurrent_submissions_are_linearized_and_bounded(self):
        def submit(index):
            payload = urllib.parse.urlencode({"username": f"user-{index}", "password": "x"}).encode("ascii")
            return https_request(
                self.primary + "/v1/two-concurrent-forms/submit",
                data=payload,
                method="POST",
            )[0]

        threads = []
        statuses = []
        statuses_lock = threading.Lock()

        def worker(index):
            status = submit(index)
            with statuses_lock:
                statuses.append(status)

        for index in range(80):
            thread = threading.Thread(target=worker, args=(index,))
            threads.append(thread)
            thread.start()
        for thread in threads:
            thread.join()
        self.assertEqual(statuses, [200] * 80)
        _, _, state_body = https_request(self.ready["endpoints"]["state"])
        state = json.loads(state_body)
        self.assertEqual(state["total_attempts"], 80)
        self.assertEqual(state["record_count"], 64)
        self.assertEqual([item["attempt"] for item in state["records"]], list(range(17, 81)))

    def test_concurrent_form_targets_have_unique_stable_ids(self):
        _, _, page = https_request(self.primary + "/v1/two-concurrent-forms")
        parser = _FormAccessibilityParser()
        parser.feed(page.decode("utf-8"))
        self.assertEqual(len(parser.ids), len(set(parser.ids)))
        self.assertEqual(
            {field["id"] for field in parser.inputs},
            {"form-a-username", "form-a-password", "form-b-username", "form-b-password"},
        )

    def test_redirect_delay_and_multistep_outcomes_are_deterministic(self):
        payload = urllib.parse.urlencode({"email": "x", "password": "y"}).encode("ascii")
        start = time.monotonic()
        status, _, _ = https_request(
            self.primary + "/v1/delayed-response/submit", data=payload, method="POST"
        )
        self.assertEqual(status, 200)
        self.assertGreaterEqual(time.monotonic() - start, 0.15)

        status, headers, _ = https_request(
            self.primary + "/v1/redirect-after-submit-invalid-response/submit",
            data=payload,
            method="POST",
            follow_redirects=False,
        )
        self.assertEqual(status, 303)
        self.assertEqual(headers["Location"], "/v1/redirect-after-submit-invalid-response/invalid")

        first_payload = urllib.parse.urlencode({"identifier": "x"}).encode("ascii")
        status, headers, _ = https_request(
            self.primary + "/v1/identifier-then-password/step/identifier/submit",
            data=first_payload,
            method="POST",
            follow_redirects=False,
        )
        self.assertEqual(status, 303)
        self.assertEqual(headers["Location"], "/v1/identifier-then-password/step/password")

    def test_iframe_origins_are_exact_and_distinct(self):
        _, _, same_page = https_request(self.primary + "/v1/same-origin-iframe")
        same_parser = _FormAccessibilityParser()
        same_parser.feed(same_page.decode("utf-8"))
        self.assertEqual(same_parser.iframes[0]["src"], self.primary + "/v1/same-origin-iframe/frame")

        _, _, cross_page = https_request(self.primary + "/v1/cross-origin-iframe")
        cross_parser = _FormAccessibilityParser()
        cross_parser.feed(cross_page.decode("utf-8"))
        self.assertEqual(cross_parser.iframes[0]["src"], self.cross + "/v1/cross-origin-iframe/frame")
        status, _, child = https_request(cross_parser.iframes[0]["src"])
        self.assertEqual(status, 200)
        self.assertIn(b'data-origin-role="cross"', child)

    def test_oversized_body_is_rejected_without_state(self):
        status, _, _ = https_request(
            self.primary + "/v1/email-password/submit",
            data=b"x=" + (b"a" * 17000),
            method="POST",
        )
        self.assertEqual(status, 413)
        _, _, state_body = https_request(self.ready["endpoints"]["state"])
        self.assertEqual(json.loads(state_body)["record_count"], 0)

    def test_no_canary_retention_in_process_output_or_fixture_artifacts(self):
        canary = "NATIVE_AUTH_" + "CANARY_" + uuid.uuid4().hex
        with running_fixture() as (process, ready):
            payload = urllib.parse.urlencode({"email": canary, "password": canary}).encode("ascii")
            status, _, _ = https_request(
                ready["primary_origin"] + "/v1/email-password/submit",
                data=payload,
                method="POST",
            )
            self.assertEqual(status, 200)
            _, _, state_body = https_request(ready["endpoints"]["state"])
            self.assertNotIn(canary.encode("ascii"), state_body)
        stdout_tail, stderr = process.communicate(timeout=1)
        self.assertNotIn(canary, stdout_tail)
        self.assertNotIn(canary, stderr)
        self.assertEqual(stdout_tail, "")
        self.assertEqual(stderr, "")
        for artifact in HERE.rglob("*"):
            if artifact.is_file():
                self.assertNotIn(canary.encode("ascii"), artifact.read_bytes(), str(artifact))


if __name__ == "__main__":
    unittest.main()

