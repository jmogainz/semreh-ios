#!/usr/bin/env python3
"""Metadata-only orchestrator skeleton for native-auth E2E cases.

`SyntheticLoopbackDriver` is deliberately fixture-only. A native simulator driver can
implement `SubmissionDriver.submit` later while preserving the same case sequencing
and metadata-only report contract.
"""

from __future__ import annotations

import argparse
import json
import secrets
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Protocol

from fixture import FixtureRuntime

MATRIX_CASE_IDS = (
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


class HTTPSFixtureClient:
    """Small client scoped to an explicitly supplied loopback HTTPS origin."""

    def __init__(self, origin):
        parsed = urllib.parse.urlsplit(origin)
        if parsed.scheme != "https" or parsed.hostname not in {"127.0.0.1", "localhost"}:
            raise ValueError("fixture origin must be loopback HTTPS")
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        self._origin = origin.rstrip("/")
        self._opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=context)
        )

    def json_request(self, path, *, method="GET", payload=None):
        data = None
        headers = {}
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            self._origin + path, data=data, headers=headers, method=method
        )
        try:
            response = self._opener.open(request, timeout=5)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            body = response.read()
            return response.status, json.loads(body) if body else None

    def post_form(self, path, fields):
        request = urllib.request.Request(
            self._origin + path,
            data=urllib.parse.urlencode(fields).encode("utf-8"),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            method="POST",
        )
        try:
            response = self._opener.open(request, timeout=5)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.status, json.loads(response.read())


class SubmissionDriver(Protocol):
    """Adapter seam for a future simulator/native secure-input driver."""

    def submit(self, client: HTTPSFixtureClient, issued: dict) -> str:
        """Complete one fixture submission and return only its terminal outcome."""


class SyntheticLoopbackDriver:
    """Generate non-credential canaries in memory and submit only to loopback."""

    def submit(self, client, issued):
        # The generated values are never returned, logged, or persisted. Their sole
        # purpose is proving that the fixture reduces submitted bytes to counters.
        fields = {
            "context_id": issued["context_id"],
            "target_id": issued["target_id"],
            "username": secrets.token_urlsafe(24),
            "password": secrets.token_urlsafe(24),
        }
        _status, result = client.post_form(issued["submit_path"], fields)
        fields.clear()
        return result["outcome"]


class MatrixOrchestrator:
    def __init__(self, client, driver):
        self._client = client
        self._driver = driver

    def _issue(self, case_id):
        status, issued = self._client.json_request(
            "/v1/cases/{}/issue".format(case_id), method="POST", payload={}
        )
        if status != 201:
            raise RuntimeError("fixture failed to issue {}".format(case_id))
        return issued

    def _run_case(self, case_id):
        if case_id == "flat_username_password":
            outcomes = [self._driver.submit(self._client, self._issue(case_id))]
        elif case_id == "expiry":
            issued = self._issue(case_id)
            status, _ = self._client.json_request(
                "/v1/controls/advance", method="POST", payload={}
            )
            if status != 200:
                raise RuntimeError("fixture failed to advance logical clock")
            outcomes = [self._driver.submit(self._client, issued)]
        elif case_id == "replay":
            issued = self._issue(case_id)
            outcomes = [
                self._driver.submit(self._client, issued),
                self._driver.submit(self._client, issued),
            ]
        elif case_id == "target_replacement":
            stale = self._issue(case_id)
            status, _ = self._client.json_request(
                "/v1/controls/target_replacement/replace", method="POST", payload={}
            )
            if status != 200:
                raise RuntimeError("fixture failed to replace target")
            outcomes = [self._driver.submit(self._client, stale)]
            outcomes.append(self._driver.submit(self._client, self._issue(case_id)))
        else:
            raise ValueError("unknown case: {}".format(case_id))
        return {
            "id": case_id,
            "outcomes": outcomes,
            "passed": outcomes == EXPECTED_OUTCOMES[case_id],
        }

    def run(self):
        cases = [self._run_case(case_id) for case_id in MATRIX_CASE_IDS]
        status, observations = self._client.json_request("/v1/observations")
        if status != 200:
            raise RuntimeError("fixture observations unavailable")
        return {
            "schema": "native-auth-e2e-report.v1",
            "passed": all(case["passed"] for case in cases),
            "cases": cases,
            "observations": observations,
        }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--list", action="store_true", help="list cases as JSON")
    mode.add_argument(
        "--run-local",
        action="store_true",
        help="run the matrix against an ephemeral local HTTPS fixture",
    )
    args = parser.parse_args(argv)
    if args.list:
        print(json.dumps({"count": len(MATRIX_CASE_IDS), "cases": list(MATRIX_CASE_IDS)}))
        return 0
    with FixtureRuntime() as runtime:
        report = MatrixOrchestrator(
            HTTPSFixtureClient(runtime.origin), SyntheticLoopbackDriver()
        ).run()
    print(json.dumps(report, sort_keys=True, separators=(",", ":")))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())

