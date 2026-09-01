#!/usr/bin/env python3
"""Contract tests for the metadata-only native-auth HTTPS fixture."""

from __future__ import annotations

import json
import pathlib
import ssl
import sys
import unittest
import urllib.error
import urllib.parse
import urllib.request
import uuid

HERE = pathlib.Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from fixture import FixtureRuntime


def synthetic_submission(issued):
    nonce = uuid.uuid4().hex
    return {
        "context_id": issued["context_id"],
        "target_id": issued["target_id"],
        "username": "u_" + nonce,
        "password": "p_" + nonce,
    }


class FixtureClient:
    def __init__(self, origin: str):
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        self.origin = origin
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=context)
        )

    def request(self, path: str, *, payload=None, method=None):
        data = None
        headers = {}
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            self.origin + path, data=data, headers=headers, method=method
        )
        try:
            response = self.opener.open(request, timeout=5)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            body = response.read()
            return response.status, json.loads(body) if body else None

    def post_form(self, path: str, fields: dict[str, str]):
        request = urllib.request.Request(
            self.origin + path,
            data=urllib.parse.urlencode(fields).encode("utf-8"),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            method="POST",
        )
        try:
            response = self.opener.open(request, timeout=5)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.status, json.loads(response.read())

    def raw(self, path: str):
        request = urllib.request.Request(self.origin + path)
        try:
            response = self.opener.open(request, timeout=5)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.status, dict(response.headers), response.read()


class FlatUsernamePasswordFixtureTests(unittest.TestCase):
    def test_matrix_manifest_and_flat_login_page_are_deterministic(self):
        with FixtureRuntime() as runtime:
            client = FixtureClient(runtime.origin)
            status, manifest = client.request("/v1/matrix")
            self.assertEqual(status, 200)
            self.assertEqual(
                manifest,
                {
                    "schema": "native-auth-fixture-matrix.v1",
                    "cases": [
                        {"id": "flat_username_password", "expected_outcomes": ["accepted"]},
                        {"id": "expiry", "expected_outcomes": ["rejected_expired"]},
                        {"id": "replay", "expected_outcomes": ["accepted", "rejected_replay"]},
                        {
                            "id": "target_replacement",
                            "expected_outcomes": ["rejected_target_replaced", "accepted"],
                        },
                    ],
                },
            )
            _, issued = client.request(
                "/v1/cases/flat_username_password/issue", payload={}, method="POST"
            )
            page_status, headers, body = client.raw(issued["login_path"])
            page = body.decode("utf-8")
            self.assertEqual(page_status, 200)
            self.assertIn("text/html", headers["Content-Type"])
            self.assertIn('autocomplete="username"', page)
            self.assertIn('autocomplete="current-password"', page)
            self.assertIn('type="password"', page)
            self.assertIn('action="{}"'.format(issued["submit_path"]), page)
            self.assertIn(issued["context_id"], page)
            self.assertIn(issued["target_id"], page)
            for forbidden in ("localStorage", "sessionStorage", "document.cookie", "http://"):
                self.assertNotIn(forbidden, page)

    def test_flat_submission_records_only_safe_presence_counters(self):
        canary = "NATIVE_AUTH_CANARY_" + uuid.uuid4().hex
        with FixtureRuntime() as runtime:
            client = FixtureClient(runtime.origin)
            status, issued = client.request(
                "/v1/cases/flat_username_password/issue", payload={}, method="POST"
            )
            self.assertEqual(status, 201)
            submit_status, result = client.post_form(
                issued["submit_path"],
                {
                    "context_id": issued["context_id"],
                    "target_id": issued["target_id"],
                    "username": canary,
                    "password": canary,
                },
            )
            self.assertEqual(submit_status, 200)
            self.assertEqual(result, {"outcome": "accepted"})

            state_status, state = client.request("/v1/observations")
            self.assertEqual(state_status, 200)
            serialized = json.dumps(state, sort_keys=True)
            self.assertNotIn(canary, serialized)
            self.assertEqual(
                state["cases"]["flat_username_password"],
                {
                    "accepted": 1,
                    "contexts_issued": 1,
                    "password_present": 1,
                    "rejected_expired": 0,
                    "rejected_replay": 0,
                    "rejected_target_replaced": 0,
                    "submission_attempts": 1,
                    "username_present": 1,
                },
            )


class ExpiryFixtureTests(unittest.TestCase):
    def test_expiry_uses_logical_clock_and_rejects_without_sleeping(self):
        with FixtureRuntime() as runtime:
            client = FixtureClient(runtime.origin)
            _, issued = client.request(
                "/v1/cases/expiry/issue", payload={}, method="POST"
            )
            advance_status, tick = client.request(
                "/v1/controls/advance", payload={}, method="POST"
            )
            self.assertEqual((advance_status, tick), (200, {"logical_tick": 1}))
            status, result = client.post_form(
                issued["submit_path"], synthetic_submission(issued)
            )
            self.assertEqual(status, 409)
            self.assertEqual(result, {"outcome": "rejected_expired"})
            _, observations = client.request("/v1/observations")
            self.assertEqual(observations["cases"]["expiry"]["rejected_expired"], 1)
            self.assertEqual(observations["cases"]["expiry"]["accepted"], 0)


class ReplayFixtureTests(unittest.TestCase):
    def test_reusing_consumed_context_is_rejected_and_counted(self):
        with FixtureRuntime() as runtime:
            client = FixtureClient(runtime.origin)
            _, issued = client.request(
                "/v1/cases/replay/issue", payload={}, method="POST"
            )
            fields = synthetic_submission(issued)
            first_status, first = client.post_form(issued["submit_path"], fields)
            second_status, second = client.post_form(issued["submit_path"], fields)
            self.assertEqual((first_status, first), (200, {"outcome": "accepted"}))
            self.assertEqual(
                (second_status, second),
                (409, {"outcome": "rejected_replay"}),
            )
            _, observations = client.request("/v1/observations")
            counters = observations["cases"]["replay"]
            self.assertEqual(counters["submission_attempts"], 2)
            self.assertEqual(counters["accepted"], 1)
            self.assertEqual(counters["rejected_replay"], 1)


class TargetReplacementFixtureTests(unittest.TestCase):
    def test_replaced_target_rejects_stale_binding_and_accepts_reissue(self):
        with FixtureRuntime() as runtime:
            client = FixtureClient(runtime.origin)
            _, stale = client.request(
                "/v1/cases/target_replacement/issue", payload={}, method="POST"
            )
            replace_status, replaced = client.request(
                "/v1/controls/target_replacement/replace", payload={}, method="POST"
            )
            self.assertEqual(
                (replace_status, replaced),
                (200, {"case_id": "target_replacement", "target_generation": 2}),
            )
            stale_status, stale_result = client.post_form(
                stale["submit_path"], synthetic_submission(stale)
            )
            self.assertEqual(
                (stale_status, stale_result),
                (409, {"outcome": "rejected_target_replaced"}),
            )

            _, fresh = client.request(
                "/v1/cases/target_replacement/issue", payload={}, method="POST"
            )
            fresh_status, fresh_result = client.post_form(
                fresh["submit_path"], synthetic_submission(fresh)
            )
            self.assertEqual((fresh_status, fresh_result), (200, {"outcome": "accepted"}))
            self.assertEqual(fresh["target_generation"], 2)
            _, observations = client.request("/v1/observations")
            counters = observations["cases"]["target_replacement"]
            self.assertEqual(counters["contexts_issued"], 2)
            self.assertEqual(counters["submission_attempts"], 2)
            self.assertEqual(counters["rejected_target_replaced"], 1)
            self.assertEqual(counters["accepted"], 1)


class RuntimeSafetyTests(unittest.TestCase):
    def test_certificate_and_key_are_ephemeral_and_listener_is_dynamic_loopback(self):
        runtime = FixtureRuntime()
        runtime.start()
        temporary_path = pathlib.Path(runtime._temporary_directory.name)
        try:
            parsed = urllib.parse.urlsplit(runtime.origin)
            self.assertEqual((parsed.scheme, parsed.hostname), ("https", "127.0.0.1"))
            self.assertNotIn(parsed.port, {8787, 9222})
            self.assertEqual((temporary_path / "key.pem").stat().st_mode & 0o777, 0o600)
            self.assertTrue((temporary_path / "cert.pem").is_file())
        finally:
            runtime.close()
        self.assertFalse(temporary_path.exists())


if __name__ == "__main__":
    unittest.main()

