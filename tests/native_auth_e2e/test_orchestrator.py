#!/usr/bin/env python3
"""Tests for the repeatable native-auth E2E orchestrator skeleton."""

from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import unittest

HERE = pathlib.Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from fixture import FixtureRuntime
from orchestrator import HTTPSFixtureClient, MATRIX_CASE_IDS, MatrixOrchestrator, SyntheticLoopbackDriver


class OrchestratorTests(unittest.TestCase):
    def test_matrix_runs_in_declared_order_with_exact_terminal_outcomes(self):
        with FixtureRuntime() as runtime:
            report = MatrixOrchestrator(
                HTTPSFixtureClient(runtime.origin), SyntheticLoopbackDriver()
            ).run()

        self.assertTrue(report["passed"])
        self.assertEqual(report["schema"], "native-auth-e2e-report.v1")
        self.assertEqual([case["id"] for case in report["cases"]], list(MATRIX_CASE_IDS))
        self.assertEqual(
            [case["outcomes"] for case in report["cases"]],
            [
                ["accepted"],
                ["rejected_expired"],
                ["accepted", "rejected_replay"],
                ["rejected_target_replaced", "accepted"],
            ],
        )
        self.assertEqual(report["observations"]["logical_tick"], 1)
        self.assertEqual(
            {
                case_id: counters["submission_attempts"]
                for case_id, counters in report["observations"]["cases"].items()
            },
            {
                "flat_username_password": 1,
                "expiry": 1,
                "replay": 2,
                "target_replacement": 2,
            },
        )
        forbidden = ["username_value", "password_value", "credential", "cookie", "token"]
        serialized = json.dumps(report, sort_keys=True).lower()
        for term in forbidden:
            self.assertNotIn(term, serialized)

    def test_list_command_is_stable_metadata_only_json(self):
        completed = subprocess.run(
            [sys.executable, str(HERE / "orchestrator.py"), "--list"],
            cwd=str(HERE),
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stderr, "")
        self.assertEqual(
            json.loads(completed.stdout),
            {"count": 4, "cases": list(MATRIX_CASE_IDS)},
        )

    def test_local_command_runs_without_external_services_or_fixed_ports(self):
        completed = subprocess.run(
            [sys.executable, str(HERE / "orchestrator.py"), "--run-local"],
            cwd=str(HERE),
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stderr, "")
        report = json.loads(completed.stdout)
        self.assertTrue(report["passed"])
        self.assertNotIn("8787", completed.stdout)
        self.assertNotIn("9222", completed.stdout)
        self.assertNotIn("origin", report)


if __name__ == "__main__":
    unittest.main()

