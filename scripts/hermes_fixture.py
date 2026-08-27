#!/usr/bin/env python3
"""Deterministic local Hermes HTTP/SSE fixture for Semreh validation.

The fixture intentionally has no external dependencies or credentials.  Start it
with `python3 scripts/hermes_fixture.py --port 8765`, point the Simulator build at
http://127.0.0.1:8765, and use the /__fixture__ endpoints to emulate a TUI peer.

Useful admin calls (JSON bodies):
  POST /__fixture__/reset
  POST /__fixture__/append {"session_id":"fixture-session","content":"from TUI"}
  POST /__fixture__/publish {"session_id":"fixture-session","kind":"duplicate"}
  POST /__fixture__/publish {"session_id":"fixture-session","kind":"gap"}
  POST /__fixture__/failure {"operation":"delete","enabled":true}
  GET  /__fixture__/state
"""

from __future__ import annotations

import argparse
import json
import queue
import threading
import time
from collections import OrderedDict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs, urlparse


DEFAULT_SESSION_ID = "fixture-session"


def now() -> float:
    return time.time()


class FixtureState:
    def __init__(self) -> None:
        self.lock = threading.RLock()
        self.failures: set[str] = set()
        self.reset()

    def reset(self) -> None:
        with self.lock:
            self.sessions: OrderedDict[str, dict[str, Any]] = OrderedDict()
            self.session_events: dict[str, list[dict[str, Any]]] = {}
            self.stream_events: dict[str, list[dict[str, Any]]] = {}
            self.subscribers: dict[str, set[queue.Queue[dict[str, Any]]]] = {}
            self.next_event_id = 1
            self.next_message_id = 1
            self.revision = 1
            self.sessions[DEFAULT_SESSION_ID] = {
                "session_id": DEFAULT_SESSION_ID,
                "title": "Fixture Chat",
                "workspace": "/tmp/semreh-fixture",
                "model": "gpt-5.4",
                "model_provider": "openai",
                "profile": "default",
                "messages": [
                    self.message("user", "Fixture is ready.", "fixture-user-1"),
                    self.message("assistant", "Local Hermes fixture connected.", "fixture-assistant-1"),
                ],
                "updated_at": now(),
                "active_stream_id": None,
                "message_count": 2,
                "reasoning_effort": "medium",
            }
            self.session_events[DEFAULT_SESSION_ID] = []
            self.publish_snapshot(DEFAULT_SESSION_ID)

    def message(self, role: str, content: str, message_id: str | None = None) -> dict[str, Any]:
        if message_id is None:
            message_id = f"fixture-message-{self.next_message_id}"
            self.next_message_id += 1
        return {
            "role": role,
            "content": content,
            "message_id": message_id,
            "timestamp": now(),
        }

    def should_fail(self, operation: str) -> bool:
        with self.lock:
            return operation in self.failures

    def session(self, session_id: str) -> dict[str, Any] | None:
        with self.lock:
            session = self.sessions.get(session_id)
            return json.loads(json.dumps(session)) if session else None

    def public_summary(self, session: dict[str, Any]) -> dict[str, Any]:
        return {
            key: session.get(key)
            for key in (
                "session_id",
                "title",
                "workspace",
                "model",
                "model_provider",
                "profile",
                "updated_at",
                "message_count",
                "active_stream_id",
                "reasoning_effort",
            )
            if session.get(key) is not None
        }

    def next_event(self, event_type: str, data: dict[str, Any]) -> dict[str, Any]:
        event = {"id": f"fixture-event-{self.next_event_id:06d}", "event": event_type, "data": data}
        self.next_event_id += 1
        return event

    def publish_snapshot(self, session_id: str) -> dict[str, Any]:
        with self.lock:
            session = self.sessions[session_id]
            event = self.next_event(
                "session_snapshot",
                {"session": self.public_summary(session)},
            )
            self.session_events.setdefault(session_id, []).append(event)
            self.broadcast(f"session:{session_id}", event)
            self.revision += 1
            return event

    def publish_session_event(self, session_id: str, event_type: str = "session_snapshot") -> dict[str, Any]:
        with self.lock:
            if event_type == "session_snapshot":
                return self.publish_snapshot(session_id)
            event = self.next_event(event_type, {"session": self.public_summary(self.sessions[session_id])})
            self.session_events.setdefault(session_id, []).append(event)
            self.broadcast(f"session:{session_id}", event)
            self.revision += 1
            return event

    def append_message(self, session_id: str, role: str, content: str, message_id: str | None = None) -> dict[str, Any]:
        with self.lock:
            session = self.sessions[session_id]
            message = self.message(role, content, message_id)
            session["messages"].append(message)
            session["message_count"] = len(session["messages"])
            session["updated_at"] = now()
            self.revision += 1
            self.publish_snapshot(session_id)
            return message

    def broadcast(self, channel: str, event: dict[str, Any]) -> None:
        for subscriber in list(self.subscribers.get(channel, set())):
            subscriber.put(event)

    def subscribe(self, channel: str) -> queue.Queue[dict[str, Any]]:
        subscriber: queue.Queue[dict[str, Any]] = queue.Queue()
        with self.lock:
            self.subscribers.setdefault(channel, set()).add(subscriber)
        return subscriber

    def unsubscribe(self, channel: str, subscriber: queue.Queue[dict[str, Any]]) -> None:
        with self.lock:
            self.subscribers.get(channel, set()).discard(subscriber)

    def stream_event(self, stream_id: str, event_type: str, data: dict[str, Any]) -> dict[str, Any]:
        with self.lock:
            events = self.stream_events.setdefault(stream_id, [])
            sequence = len(events) + 1
            payload = dict(data)
            payload.setdefault("seq", sequence)
            event = {
                "id": f"{stream_id}:{sequence}",
                "event": event_type,
                "data": payload,
                "seq": sequence,
            }
            events.append(event)
            self.broadcast(f"stream:{stream_id}", event)
            return event


STATE = FixtureState()


def json_bytes(value: Any) -> bytes:
    return json.dumps(value, separators=(",", ":"), sort_keys=True).encode("utf-8")


class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "SemrehHermesFixture/1.0"

    def log_message(self, format: str, *args: Any) -> None:
        # Keep fixture logs useful for a terminal-run Simulator test.
        print(f"[fixture] {self.address_string()} {format % args}", flush=True)

    def request_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            value = json.loads(raw.decode("utf-8"))
            return value if isinstance(value, dict) else {}
        except (ValueError, UnicodeDecodeError):
            return {}

    def send_json(self, status: int, value: Any) -> None:
        body = json_bytes(value)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_failure_if_configured(self, operation: str) -> bool:
        if not STATE.should_fail(operation):
            return False
        self.send_json(503, {"error": f"fixture failure injected for {operation}"})
        return True

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        if path == "/health" or path == "/__fixture__/health":
            self.send_json(200, {"status": "ok", "ok": True, "revision": STATE.revision})
            return
        if path == "/__fixture__/state":
            with STATE.lock:
                self.send_json(
                    200,
                    {
                        "revision": STATE.revision,
                        "sessions": [STATE.public_summary(session) for session in STATE.sessions.values()],
                        "event_ids": {
                            session_id: [event["id"] for event in events]
                            for session_id, events in STATE.session_events.items()
                        },
                    },
                )
            return
        if path == "/api/auth/status":
            self.send_json(
                200,
                {
                    "auth_enabled": False,
                    "password_auth_enabled": False,
                    "authenticated": True,
                    "logged_in": True,
                    "user": {"name": "fixture"},
                },
            )
            return
        if path == "/api/sessions":
            with STATE.lock:
                sessions = [STATE.public_summary(session) for session in STATE.sessions.values()]
            self.send_json(200, {"sessions": sessions, "archived_count": 0, "revision": STATE.revision})
            return
        if path == "/api/session":
            session_id = query.get("session_id", [DEFAULT_SESSION_ID])[0]
            session = STATE.session(session_id)
            if session is None:
                self.send_json(404, {"error": "session not found"})
                return
            before = query.get("msg_before", [None])[0]
            limit = int(query.get("msg_limit", [50])[0] or 50)
            messages = session.get("messages", [])
            if before is not None:
                end = max(0, min(len(messages), int(before)))
                messages = messages[max(0, end - limit) : end]
            else:
                messages = messages[-limit:]
            session["messages"] = messages
            self.send_json(200, {"session": session})
            return
        if path == "/api/session/status":
            session_id = query.get("session_id", [DEFAULT_SESSION_ID])[0]
            session = STATE.session(session_id)
            self.send_json(200, {"session_id": session_id, "active": bool(session and session.get("active_stream_id"))})
            return
        if path == "/api/reasoning":
            session_effort = query.get("session_effort", [None])[0]
            effective_effort = session_effort or "medium"
            self.send_json(
                200,
                {
                    "supports_reasoning_effort": True,
                    "supported_efforts": ["low", "medium", "high", "xhigh"],
                    "effective_effort": effective_effort,
                    "reasoning_effort": effective_effort,
                    "session_reasoning_effort": session_effort,
                    "session_scoped_reasoning": True,
                },
            )
            return
        if path in ("/api/models", "/api/models/live"):
            self.send_json(200, {"models": [{"id": "gpt-5.4", "name": "GPT-5.4", "provider": "openai"}, {"id": "gpt-5.5", "name": "GPT-5.5", "provider": "openai"}]})
            return
        if path == "/api/profiles":
            self.send_json(200, {"profiles": [{"name": "default", "model": "gpt-5.4", "model_provider": "openai"}], "active": "default"})
            return
        if path == "/api/commands":
            self.send_json(200, {"commands": []})
            return
        if path == "/api/default-model":
            self.send_json(200, {"model": "gpt-5.4", "model_provider": "openai"})
            return
        if path == "/api/sessions/search":
            self.send_json(200, {"sessions": []})
            return
        if path == "/api/sessions/" or (path.startswith("/api/sessions/") and path.endswith("/events")):
            session_id = path[len("/api/sessions/") : -len("/events")]
            self.stream_sse(f"session:{session_id}", session_id, STATE.session_events.get(session_id, []), query)
            return
        if path == "/api/chat/stream":
            stream_id = query.get("stream_id", [""])[0]
            self.stream_sse(f"stream:{stream_id}", stream_id, STATE.stream_events.get(stream_id, []), query)
            return

        self.send_json(404, {"error": f"unknown fixture GET path: {path}"})

    def stream_sse(
        self,
        channel: str,
        identity: str,
        existing: list[dict[str, Any]],
        query: dict[str, list[str]],
    ) -> None:
        if not identity:
            self.send_json(400, {"error": "missing stream or session ID"})
            return
        last_event_id = self.headers.get("Last-Event-ID") or query.get("last_event_id", [""])[0]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()
        subscriber = STATE.subscribe(channel)
        try:
            with STATE.lock:
                replay_requested = query.get("replay", [""])[0] == "1"
                if channel.startswith("stream:") and replay_requested:
                    try:
                        after_seq = max(0, int(query.get("after_seq", ["0"])[0]))
                    except ValueError:
                        after_seq = 0
                    replay = [event for event in existing if event.get("seq", 0) > after_seq]
                elif last_event_id:
                    replay = []
                    cursor_index = next(
                        (index for index, event in enumerate(existing) if event["id"] == last_event_id),
                        None,
                    )
                    if cursor_index is not None:
                        replay = existing[cursor_index + 1 :]
                    elif existing:
                        # Unknown/evicted opaque cursor: force a recovery
                        # snapshot instead of guessing an ordering relation.
                        replay = existing[-1:]
                elif channel.startswith("stream:"):
                    # Chat start returns before the app attaches the stream. A
                    # fresh run connection must receive the full journal.
                    replay = list(existing)
                else:
                    replay = existing[-1:] if existing else []
            for event in replay:
                self.write_event(event)
            while True:
                try:
                    event = subscriber.get(timeout=1.0)
                    self.write_event(event)
                except queue.Empty:
                    self.wfile.write(b": heartbeat\n\n")
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            STATE.unsubscribe(channel, subscriber)

    def write_event(self, event: dict[str, Any]) -> None:
        payload = json.dumps(event["data"], separators=(",", ":"))
        wire = f"id: {event['id']}\nevent: {event['event']}\ndata: {payload}\n\n".encode("utf-8")
        self.wfile.write(wire)
        self.wfile.flush()

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        body = self.request_json()

        if path == "/__fixture__/reset":
            STATE.reset()
            self.send_json(200, {"ok": True, "revision": STATE.revision})
            return
        if path == "/__fixture__/failure":
            operation = str(body.get("operation", ""))
            enabled = bool(body.get("enabled", True))
            with STATE.lock:
                if enabled:
                    STATE.failures.add(operation)
                else:
                    STATE.failures.discard(operation)
            self.send_json(200, {"ok": True, "operation": operation, "enabled": enabled})
            return
        if path == "/__fixture__/append":
            session_id = str(body.get("session_id", DEFAULT_SESSION_ID))
            with STATE.lock:
                if session_id not in STATE.sessions:
                    self.send_json(404, {"error": "session not found"})
                    return
            message = STATE.append_message(
                session_id,
                str(body.get("role", "user")),
                str(body.get("content", "")),
                body.get("message_id"),
            )
            self.send_json(200, {"ok": True, "message": message, "revision": STATE.revision})
            return
        if path == "/__fixture__/publish":
            session_id = str(body.get("session_id", DEFAULT_SESSION_ID))
            kind = str(body.get("kind", "snapshot"))
            with STATE.lock:
                if session_id not in STATE.sessions:
                    self.send_json(404, {"error": "session not found"})
                    return
                if kind == "duplicate" and STATE.session_events.get(session_id):
                    event = STATE.session_events[session_id][-1]
                    STATE.broadcast(f"session:{session_id}", event)
                elif kind == "stale" and STATE.session_events.get(session_id):
                    event = STATE.session_events[session_id][0]
                    STATE.broadcast(f"session:{session_id}", event)
                elif kind == "gap":
                    STATE.next_event_id += 2
                    event = STATE.next_event("session_snapshot", {"session": STATE.public_summary(STATE.sessions[session_id])})
                    # Deliberately leave a cursor-sized hole: the client should
                    # accept the snapshot and reconnect without Last-Event-ID.
                    STATE.session_events[session_id].append(event)
                    STATE.broadcast(f"session:{session_id}", event)
                else:
                    event = STATE.publish_snapshot(session_id)
            self.send_json(200, {"ok": True, "event": event, "revision": STATE.revision})
            return
        if path == "/api/session/update":
            if self.send_failure_if_configured("update"):
                return
            session_id = str(body.get("session_id", DEFAULT_SESSION_ID))
            with STATE.lock:
                session = STATE.sessions.get(session_id)
                if session is None:
                    self.send_json(404, {"error": "session not found"})
                    return
                for key in ("workspace", "model", "model_provider", "reasoning_effort"):
                    if key in body and body[key] is not None:
                        value = body[key]
                        session[key] = None if key == "reasoning_effort" and str(value).strip() == "" else value
                session["updated_at"] = now()
                STATE.publish_snapshot(session_id)
                self.send_json(200, {"session": session, "ok": True})
            return
        if path == "/api/reasoning":
            if self.send_failure_if_configured("reasoning"):
                return
            effort = str(body.get("effort", "medium"))
            session_id = body.get("session_id")
            if session_id:
                with STATE.lock:
                    if session_id in STATE.sessions:
                        STATE.sessions[session_id]["reasoning_effort"] = effort or "medium"
                        STATE.publish_snapshot(session_id)
            self.send_json(200, {"ok": True, "effective_effort": effort or "medium", "session_scoped_reasoning": bool(session_id), "reasoning_effort": effort or "medium"})
            return
        if path == "/api/session/delete":
            if self.send_failure_if_configured("delete"):
                return
            session_id = str(body.get("session_id", ""))
            with STATE.lock:
                existed = STATE.sessions.pop(session_id, None) is not None
                STATE.session_events.pop(session_id, None)
                STATE.revision += 1
            self.send_json(200, {"ok": existed, "error": None if existed else "session not found"})
            return
        if path == "/api/session/rename":
            if self.send_failure_if_configured("rename"):
                return
            session_id = str(body.get("session_id", DEFAULT_SESSION_ID))
            with STATE.lock:
                session = STATE.sessions.get(session_id)
                if session is None:
                    self.send_json(404, {"error": "session not found"})
                    return
                session["title"] = str(body.get("title", session["title"]))
                STATE.publish_snapshot(session_id)
                self.send_json(200, {"ok": True, "session": session})
            return
        if path == "/api/chat/start":
            if self.send_failure_if_configured("chat_start"):
                return
            session_id = str(body.get("session_id", DEFAULT_SESSION_ID))
            stream_id = f"fixture-stream-{int(time.time() * 1000)}"
            with STATE.lock:
                session = STATE.sessions.get(session_id)
                if session is None:
                    self.send_json(404, {"error": "session not found"})
                    return
                session["active_stream_id"] = stream_id
                text = str(body.get("message", body.get("prompt", "")))
                if text:
                    STATE.append_message(session_id, "user", text)
                STATE.stream_events[stream_id] = []
                STATE.stream_event(stream_id, "token", {"text": "Fixture response."})
                STATE.stream_event(stream_id, "done", {"session": STATE.sessions[session_id]})
                STATE.stream_event(stream_id, "stream_end", {})
                session["active_stream_id"] = None
            self.send_json(200, {"session_id": session_id, "stream_id": stream_id})
            return
        if path == "/api/chat/cancel":
            self.send_json(200, {"ok": True})
            return
        if path == "/api/auth/login":
            self.send_json(200, {"authenticated": True, "logged_in": True})
            return
        if path == "/api/auth/logout":
            self.send_json(200, {"ok": True})
            return

        self.send_json(404, {"error": f"unknown fixture POST path: {path}"})


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), FixtureHandler)
    print(f"Semreh Hermes fixture listening on http://{args.host}:{args.port}", flush=True)
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
