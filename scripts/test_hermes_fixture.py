#!/usr/bin/env python3
"""Smoke tests for the deterministic local Hermes fixture."""

from __future__ import annotations

import http.client
import json
import socket
import subprocess
import sys
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "scripts" / "hermes_fixture.py"


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def request_json(base: str, path: str, value: dict[str, Any] | None = None) -> tuple[int, dict[str, Any]]:
    data = None
    headers: dict[str, str] = {}
    method = "GET"
    if value is not None:
        data = json.dumps(value).encode()
        headers["Content-Type"] = "application/json"
        method = "POST"
    request = urllib.request.Request(base + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=3) as response:
            return response.status, json.loads(response.read().decode())
    except urllib.error.HTTPError as error:
        payload = json.loads(error.read().decode())
        return error.code, payload


def read_sse_event(response: http.client.HTTPResponse) -> dict[str, Any]:
    event: dict[str, Any] = {"data": ""}
    while True:
        line = response.readline().decode("utf-8").rstrip("\r\n")
        if not line:
            return event
        if line.startswith("id: "):
            event["id"] = line[4:]
        elif line.startswith("event: "):
            event["event"] = line[7:]
        elif line.startswith("data: "):
            event["data"] += line[6:]


class FixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.port = free_port()
        cls.base = f"http://127.0.0.1:{cls.port}"
        cls.process = subprocess.Popen(
            [sys.executable, str(FIXTURE), "--port", str(cls.port)],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        deadline = time.time() + 5
        while time.time() < deadline:
            try:
                status, body = request_json(cls.base, "/health")
                if status == 200 and body.get("ok") is True:
                    return
            except (OSError, urllib.error.URLError):
                pass
            time.sleep(0.05)
        output = cls.process.stdout.read() if cls.process.stdout else ""
        raise RuntimeError(f"fixture did not start: {output}")

    @classmethod
    def tearDownClass(cls) -> None:
        cls.process.terminate()
        try:
            cls.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            cls.process.kill()
            cls.process.wait(timeout=3)

    def setUp(self) -> None:
        status, body = request_json(self.base, "/__fixture__/reset", {})
        self.assertEqual(status, 200, body)

    def test_append_is_visible_to_history_and_sse(self) -> None:
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        connection.request("GET", "/api/sessions/fixture-session/events", headers={"Accept": "text/event-stream"})
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        initial = read_sse_event(response)
        self.assertEqual(initial["event"], "session_snapshot")

        status, body = request_json(
            self.base,
            "/__fixture__/append",
            {"session_id": "fixture-session", "content": "message from TUI", "message_id": "tui-1"},
        )
        self.assertEqual(status, 200, body)
        self.assertEqual(body["message"]["message_id"], "tui-1")

        update = read_sse_event(response)
        self.assertEqual(update["event"], "session_snapshot")
        self.assertNotEqual(update["id"], initial["id"])
        snapshot = json.loads(update["data"])
        self.assertEqual(snapshot["session"]["message_count"], 3)
        connection.close()

        status, _ = request_json(
            self.base,
            "/__fixture__/append",
            {"session_id": "fixture-session", "content": "message after disconnect", "message_id": "tui-2"},
        )
        self.assertEqual(status, 200)

        replay_connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        replay_connection.request(
            "GET",
            "/api/sessions/fixture-session/events",
            headers={"Accept": "text/event-stream", "Last-Event-ID": update["id"]},
        )
        replay_response = replay_connection.getresponse()
        self.assertEqual(replay_response.status, 200)
        replay = read_sse_event(replay_response)
        replay_snapshot = json.loads(replay["data"])
        self.assertEqual(replay["event"], "session_snapshot")
        self.assertNotEqual(replay["id"], update["id"])
        self.assertEqual(replay_snapshot["session"]["message_count"], 4)
        replay_connection.close()

        status, history = request_json(
            self.base,
            "/api/session?session_id=fixture-session&messages=1&msg_limit=50",
        )
        self.assertEqual(status, 200)
        self.assertEqual(history["session"]["messages"][-2]["content"], "message from TUI")
        self.assertEqual(history["session"]["messages"][-1]["content"], "message after disconnect")

    def test_duplicate_stale_and_gap_admin_events_are_deterministic(self) -> None:
        status, state_before = request_json(self.base, "/__fixture__/state")
        self.assertEqual(status, 200)
        first_id = state_before["event_ids"]["fixture-session"][-1]

        status, duplicate = request_json(self.base, "/__fixture__/publish", {"kind": "duplicate"})
        self.assertEqual(status, 200)
        self.assertEqual(duplicate["event"]["id"], first_id)

        status, stale = request_json(self.base, "/__fixture__/publish", {"kind": "stale"})
        self.assertEqual(status, 200)
        self.assertEqual(stale["event"]["id"], state_before["event_ids"]["fixture-session"][0])

        status, gap = request_json(self.base, "/__fixture__/publish", {"kind": "gap"})
        self.assertEqual(status, 200)
        self.assertEqual(gap["event"]["event"], "session_snapshot")
        self.assertNotEqual(gap["event"]["id"], first_id)

    def test_chat_start_returns_replayable_run_journal(self) -> None:
        status, start = request_json(
            self.base,
            "/api/chat/start",
            {"session_id": "fixture-session", "message": "stream probe"},
        )
        self.assertEqual(status, 200)
        stream_id = start["stream_id"]

        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        connection.request(
            "GET",
            f"/api/chat/stream?stream_id={stream_id}",
            headers={"Accept": "text/event-stream"},
        )
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        events = [read_sse_event(response) for _ in range(3)]
        self.assertEqual([event["event"] for event in events], ["token", "done", "stream_end"])
        self.assertEqual(json.loads(events[0]["data"])["text"], "Fixture response.")
        connection.close()

        replay_connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        replay_connection.request(
            "GET",
            f"/api/chat/stream?stream_id={stream_id}&replay=1&after_seq=1",
            headers={"Accept": "text/event-stream"},
        )
        replay_response = replay_connection.getresponse()
        self.assertEqual(replay_response.status, 200)
        replay_events = [read_sse_event(replay_response) for _ in range(2)]
        self.assertEqual([event["event"] for event in replay_events], ["done", "stream_end"])
        replay_connection.close()

        status, _ = request_json(self.base, "/__fixture__/failure", {"operation": "delete", "enabled": True})
        self.assertEqual(status, 200)
        status, _ = request_json(
            self.base,
            "/api/session/update",
            {
                "session_id": "fixture-session",
                "model": "fixture-model",
                "model_provider": "fixture-provider",
                "reasoning_effort": "high",
            },
        )
        self.assertEqual(status, 200)
        status, updated = request_json(self.base, "/api/session?session_id=fixture-session")
        self.assertEqual(status, 200)
        self.assertEqual(updated["session"]["model"], "fixture-model")
        self.assertEqual(updated["session"]["model_provider"], "fixture-provider")
        self.assertEqual(updated["session"]["reasoning_effort"], "high")
        status, reasoning = request_json(
            self.base,
            "/api/reasoning?model=fixture-model&provider=fixture-provider&session_effort=high",
        )
        self.assertEqual(status, 200)
        self.assertEqual(reasoning["effective_effort"], "high")

        status, body = request_json(self.base, "/api/session/delete", {"session_id": "fixture-session"})
        self.assertEqual(status, 503)
        self.assertIn("delete", body["error"])

        status, _ = request_json(self.base, "/__fixture__/failure", {"operation": "delete", "enabled": False})
        self.assertEqual(status, 200)
        status, body = request_json(self.base, "/api/session/delete", {"session_id": "fixture-session"})
        self.assertEqual(status, 200)
        self.assertTrue(body["ok"])
        status, state = request_json(self.base, "/__fixture__/state")
        self.assertEqual(status, 200)
        self.assertEqual(state["sessions"], [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
