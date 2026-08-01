from __future__ import annotations

import hashlib
import http.client
import json
import os
import queue
import socket
import tempfile
import threading
import time
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

from dashboard.reader import EventReader
from dashboard.server import (
    BUILD_VERSION,
    DashboardHTTPServer,
    clean_install_events_dir,
    resolve_events_dir,
    validate_bind_host,
)


def row(name: str, *, seconds_ago: int = 1, **fields: object) -> dict[str, object]:
    value: dict[str, object] = {
        "ts": (datetime.now(timezone.utc) - timedelta(seconds=seconds_ago)).isoformat().replace("+00:00", "Z"),
        "svc": fields.pop("svc", "alpha-build"),
        "event": name,
        "project": fields.pop("project", "alpha"),
        "role": fields.pop("role", "build"),
    }
    value.update(fields)
    return value


def encode(value: dict[str, object]) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"


def checksum(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class RunningServer:
    def __init__(self, root: Path, **kwargs: object):
        self.server = DashboardHTTPServer(("127.0.0.1", 0), root, **kwargs)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01})
        self.thread.start()

    @property
    def port(self) -> int:
        return self.server.server_port

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(2)
        if self.thread.is_alive():
            raise AssertionError("HTTP server thread did not stop")


class ServerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.today = self.root / (datetime.now(timezone.utc).strftime("%Y-%m-%d") + ".jsonl")
        self.today.write_bytes(
            encode(row("job.start", seconds_ago=3))
            + encode(row("job.end", seconds_ago=2, status="ok", duration_s=1.25))
            + b'{"bad":]\n'
        )
        self.running = RunningServer(self.root, poll_interval=0.01, heartbeat_interval=0.04)

    def tearDown(self) -> None:
        self.running.close()
        self.temporary.cleanup()

    def request(
        self, method: str, path: str, *, host: str | None = None, body: bytes | None = None
    ) -> tuple[int, dict[str, str], bytes]:
        connection = http.client.HTTPConnection("127.0.0.1", self.running.port, timeout=2)
        connection.putrequest(method, path, skip_host=host is not None)
        if host is not None:
            connection.putheader("Host", host)
        if body is not None:
            connection.putheader("Content-Length", str(len(body)))
        connection.endheaders(body)
        response = connection.getresponse()
        result = response.status, {key.lower(): value for key, value in response.getheaders()}, response.read()
        connection.close()
        return result

    def json_request(self, method: str, path: str, **kwargs: object) -> tuple[int, dict[str, str], object]:
        status, headers, body = self.request(method, path, **kwargs)
        return status, headers, json.loads(body)

    def open_stream(self) -> tuple[http.client.HTTPConnection, http.client.HTTPResponse]:
        connection = http.client.HTTPConnection("127.0.0.1", self.running.port, timeout=2)
        connection.request("GET", "/api/stream")
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        return connection, response

    def raw_status(self, request: bytes) -> int:
        client = socket.create_connection(("127.0.0.1", self.running.port), timeout=2)
        try:
            client.sendall(request)
            response = client.recv(1024)
        finally:
            client.close()
        return int(response.split(b" ", 2)[1])

    def read_sse(self, response: http.client.HTTPResponse, timeout: float = 2) -> bytes:
        received = queue.Queue[bytes]()

        def read() -> None:
            block = b""
            try:
                while not block.endswith(b"\n\n"):
                    line = response.readline()
                    if not line:
                        break
                    block += line
            except OSError as exc:
                block = f"ERROR:{exc}".encode()
            received.put(block)

        thread = threading.Thread(target=read)
        thread.start()
        try:
            return received.get(timeout=timeout)
        finally:
            thread.join(timeout)

    def read_sse_event(self, response: http.client.HTTPResponse, timeout: float = 2) -> bytes:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            block = self.read_sse(response, timeout=max(0.1, deadline - time.monotonic()))
            if b"data: " in block:
                return block
        self.fail("SSE data event was not received")

    def test_health_contract_headers_and_source_immutability(self) -> None:
        before = checksum(self.today)
        status, headers, payload = self.json_request("GET", "/api/health")
        self.assertEqual(status, 200)
        self.assertEqual(
            set(payload),
            {"schema_version", "build_version", "ready", "row_count", "error_count", "event_directory", "latest_timestamp", "host", "port"},
        )
        self.assertEqual(payload["build_version"], BUILD_VERSION)
        self.assertTrue(payload["ready"])
        self.assertEqual(payload["row_count"], 2)
        self.assertEqual(payload["error_count"], 1)
        self.assertEqual(payload["event_directory"], str(self.root))
        self.assertEqual(payload["host"], "127.0.0.1")
        self.assertEqual(payload["port"], self.running.port)
        self.assertEqual(headers["cache-control"], "no-store")
        self.assertEqual(headers["x-content-type-options"], "nosniff")
        self.assertIn("connect-src 'self'", headers["content-security-policy"])
        self.assertNotIn("access-control-allow-origin", headers)
        self.assertEqual(checksum(self.today), before)

    def test_summary_and_events_filters_return_raw_bounded_rows(self) -> None:
        status, _, summary = self.json_request("GET", "/api/summary?window=24h")
        self.assertEqual(status, 200)
        self.assertEqual(summary["counts"]["healthy"], 1)
        self.assertEqual(summary["errors"][0]["file"], self.today.name)
        status, _, events = self.json_request(
            "GET", "/api/events?window=24h&project=alpha&role=build&status=ok&event=job&limit=1"
        )
        self.assertEqual(status, 200)
        self.assertEqual(events["count"], 1)
        self.assertEqual(events["limit"], 1)
        self.assertEqual(events["events"][0]["event"], "job.end")
        self.assertEqual(events["events"][0]["status"], "ok")

    def test_operator_endpoint_is_versioned_background_and_window_only(self) -> None:
        release = threading.Event()
        entered = threading.Event()

        def loader(window: str) -> dict[str, object]:
            entered.set()
            self.assertTrue(release.wait(2))
            return {
                "inspection": {
                    "schema_version": 1,
                    "meta": {"rule_version": "shipyard-inspect-v1", "core_root": "/private/SECRET"},
                    "summary": {},
                    "fleet": [],
                    "effectiveness": [],
                    "priorities": [],
                    "attention": [],
                    "coverage": [],
                    "evidence": [],
                },
                "relationships": {
                    "schema_version": 1,
                    "kind": "shipyard.operator.relationships",
                    "window": window,
                    "sources": {},
                },
            }

        replacement = RunningServer(
            self.root,
            poll_interval=0.01,
            heartbeat_interval=0.04,
            operator_loader=loader,
        )
        previous = self.running
        self.running = replacement
        previous.close()
        try:
            status, _, cold = self.json_request("GET", "/api/operator?window=24h")
            self.assertEqual(status, 200)
            self.assertEqual(cold["schema_version"], 1)
            self.assertEqual(cold["kind"], "shipyard.operator")
            self.assertEqual(cold["metadata"]["window"], "24h")
            self.assertEqual(cold["metadata"]["inspection_state"], "unavailable")
            self.assertTrue(entered.wait(1))
            self.assertNotIn("/private/", json.dumps(cold))
            release.set()
            for _ in range(100):
                status, _, fresh = self.json_request("GET", "/api/operator?window=24h")
                if fresh["metadata"]["inspection_state"] == "fresh":
                    break
                time.sleep(0.01)
            self.assertEqual(status, 200)
            self.assertEqual(fresh["metadata"]["inspection_state"], "fresh")
            self.assertNotIn("/private/", json.dumps(fresh))
        finally:
            release.set()

        cases = {
            "/api/operator": "missing_query_key",
            "/api/operator?window=1h": "invalid_window",
            "/api/operator?window=7d&window=24h": "repeated_query_key",
            "/api/operator?window=": "invalid_query_value",
            "/api/operator?role=build": "unknown_query_key",
            "/api/operator?limit=1": "unknown_query_key",
            "/api/operator?wat=1": "unknown_query_key",
        }
        for path, code in cases.items():
            with self.subTest(path=path):
                status, _, payload = self.json_request("GET", path)
                self.assertEqual(status, 400)
                self.assertEqual(payload["error"]["code"], code)

    def test_event_details_are_lazily_read_and_limit_is_enforced(self) -> None:
        with mock.patch.object(EventReader, "read_event", wraps=self.running.server.reader.read_event) as read:
            status, _, payload = self.json_request("GET", "/api/events?window=24h&limit=1")
        self.assertEqual(status, 200)
        self.assertEqual(payload["count"], 1)
        self.assertEqual(read.call_count, 1)

    def test_api_index_advances_after_append_and_rotation(self) -> None:
        _, _, initial = self.json_request("GET", "/api/health")
        appended = row("dashboard.append", seconds_ago=0, status="ok")
        with self.today.open("ab") as output:
            output.write(encode(appended))
        _, _, advanced = self.json_request("GET", "/api/health")
        self.assertEqual(advanced["row_count"], initial["row_count"] + 1)
        self.assertEqual(advanced["latest_timestamp"], appended["ts"])
        replacement = row("dashboard.rotation", seconds_ago=0, status="ok")
        self.today.rename(self.today.with_suffix(".old"))
        self.today.write_bytes(encode(replacement))
        _, _, events = self.json_request("GET", "/api/events?window=24h")
        self.assertEqual(events["count"], 1)
        self.assertEqual(events["events"][0]["event"], "dashboard.rotation")

    def test_api_escapes_lone_surrogates_without_crashing(self) -> None:
        hostile = row("dashboard.hostile", seconds_ago=0, detail="\ud800")
        with self.today.open("ab") as output:
            output.write(encode(hostile))
        status, _, body = self.request("GET", "/api/events?window=24h&event=dashboard.hostile")
        self.assertEqual(status, 200)
        self.assertIn(b"\\ud800", body)
        self.assertEqual(json.loads(body)["events"][0]["detail"], "\ud800")

    def test_event_store_errors_use_a_stable_json_envelope(self) -> None:
        with mock.patch.object(self.running.server, "_event_signature", side_effect=OSError("gone")):
            status, headers, payload = self.json_request("GET", "/api/health")
        self.assertEqual(status, 503)
        self.assertEqual(payload["error"]["code"], "event_store_unavailable")
        self.assertEqual(headers["cache-control"], "no-store")

    def test_query_rejection_is_explicit_and_deterministic(self) -> None:
        cases = {
            "/api/events?window=1h": "invalid_window",
            "/api/events?window=7d&window=24h": "repeated_query_key",
            "/api/events?wat=1": "unknown_query_key",
            "/api/events?role=": "invalid_query_value",
            "/api/events?limit=0": "invalid_limit",
            "/api/events?limit=2001": "invalid_limit",
            "/api/events?limit=1.0": "invalid_limit",
            "/api/events?role=%ZZ": "invalid_query",
            "/api/health?x=1": "invalid_query",
            "/api/summary?role=build": "unknown_query_key",
            "/api/stream?window=7d": "invalid_query",
        }
        for path, code in cases.items():
            with self.subTest(path=path):
                status, headers, payload = self.json_request("GET", path)
                self.assertEqual(status, 400)
                self.assertEqual(payload["error"]["code"], code)
                self.assertEqual(headers["cache-control"], "no-store")

    def test_host_validation_requires_loopback_and_actual_port(self) -> None:
        accepted = ["localhost", "127.0.0.1", f"localhost:{self.running.port}", f"127.0.0.1:{self.running.port}"]
        for host in accepted:
            with self.subTest(host=host):
                self.assertEqual(self.request("GET", "/api/health", host=host)[0], 200)
        rejected = ["example.com", "0.0.0.0", "[::1]", "localhost:1", "localhost:bad", "localhost/path"]
        for host in rejected:
            with self.subTest(host=host):
                status, _, payload = self.json_request("GET", "/api/health", host=host)
                self.assertEqual(status, 400)
                self.assertEqual(payload["error"]["code"], "invalid_host")
        self.assertEqual(self.raw_status(b"GET /api/health HTTP/1.1\r\nConnection: close\r\n\r\n"), 400)
        self.assertEqual(
            self.raw_status(
                b"GET /api/health HTTP/1.1\r\nHost: localhost\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
            ),
            400,
        )

    def test_constructor_and_cli_host_policy_are_loopback_only(self) -> None:
        self.assertEqual(validate_bind_host("127.0.0.1"), "127.0.0.1")
        for host in ("localhost", "0.0.0.0", "::1"):
            with self.subTest(host=host), self.assertRaises(ValueError):
                validate_bind_host(host)
            with self.subTest(constructor=host), self.assertRaises(ValueError):
                DashboardHTTPServer((host, 0), self.root)

    def test_mutation_methods_are_refused_with_security_headers(self) -> None:
        for method in ("POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"):
            with self.subTest(method=method):
                status, headers, body = self.request(method, "/api/events", body=b"{}")
                self.assertEqual(status, 405)
                self.assertEqual(headers["allow"], "GET")
                self.assertEqual(headers["cache-control"], "no-store")
                if method != "HEAD":
                    self.assertEqual(json.loads(body)["error"]["code"], "method_not_allowed")

    def test_fixed_static_routes_cannot_traverse(self) -> None:
        static_root = self.root / "static"
        static_root.mkdir()
        (static_root / "index.html").write_text("<!doctype html><title>fixture</title>", encoding="utf-8")
        (static_root / "favicon.svg").write_text("<svg xmlns='http://www.w3.org/2000/svg'/>", encoding="utf-8")
        (static_root / "styles.css").write_text("body{}", encoding="utf-8")
        (static_root / "app.js").write_text("'use strict';", encoding="utf-8")
        with mock.patch("dashboard.server.STATIC_DIR", static_root):
            for path, content_type in (("/", "text/html"), ("/index.html", "text/html"), ("/favicon.svg", "image/svg+xml"), ("/styles.css", "text/css"), ("/app.js", "text/javascript")):
                with self.subTest(path=path):
                    status, headers, body = self.request("GET", path)
                    self.assertEqual(status, 200)
                    self.assertTrue(headers["content-type"].startswith(content_type))
                    self.assertTrue(body)
                    self.assertEqual(headers["cache-control"], "no-store")
        for path in ("/unknown", "/../reader.py", "/%2e%2e/reader.py", "/api/../reader.py"):
            with self.subTest(path=path):
                status, headers, payload = self.json_request("GET", path)
                self.assertEqual(status, 404)
                self.assertEqual(payload["error"]["code"], "not_found")
                self.assertNotIn("access-control-allow-origin", headers)

    def test_sse_append_and_partial_line_completion(self) -> None:
        connection, response = self.open_stream()
        time.sleep(0.04)
        appended = row("dashboard.append", seconds_ago=0, status="ok")
        raw = encode(appended)
        with self.today.open("ab") as output:
            output.write(raw[:-1])
            output.flush()
        time.sleep(0.03)
        with self.today.open("ab") as output:
            output.write(b"\n")
        block = self.read_sse_event(response)
        self.assertIn(b"event: shipyard", block)
        self.assertEqual(json.loads(block.split(b"data: ", 1)[1]), appended)
        response.close()
        connection.close()

    def test_sse_skips_nonstandard_json_constants(self) -> None:
        connection, response = self.open_stream()
        time.sleep(0.04)
        valid = row("dashboard.after-invalid", seconds_ago=0, status="ok")
        invalid = encode(row("dashboard.invalid", seconds_ago=0, value=float("nan")))
        with self.today.open("ab") as output:
            output.write(invalid)
            output.write(encode(valid))
        block = self.read_sse_event(response)
        self.assertNotIn(b"NaN", block)
        self.assertEqual(json.loads(block.split(b"data: ", 1)[1]), valid)
        response.close()
        connection.close()

    def test_sse_rotation_reopens_from_start(self) -> None:
        connection, response = self.open_stream()
        time.sleep(0.04)
        self.today.rename(self.today.with_suffix(".rotated"))
        rotated = row("dashboard.rotated", seconds_ago=0)
        self.today.write_bytes(encode(rotated))
        block = self.read_sse_event(response)
        self.assertEqual(json.loads(block.split(b"data: ", 1)[1]), rotated)
        response.close()
        connection.close()

    def test_sse_truncation_reopens_from_start(self) -> None:
        connection, response = self.open_stream()
        time.sleep(0.04)
        truncated = row("dashboard.truncated", seconds_ago=0)
        self.today.write_bytes(encode(truncated))
        block = self.read_sse_event(response)
        self.assertEqual(json.loads(block.split(b"data: ", 1)[1]), truncated)
        response.close()
        connection.close()

    def test_sse_heartbeat_and_security_headers(self) -> None:
        connection, response = self.open_stream()
        self.assertEqual(response.getheader("Cache-Control"), "no-store")
        self.assertEqual(response.getheader("X-Content-Type-Options"), "nosniff")
        self.assertIsNone(response.getheader("Access-Control-Allow-Origin"))
        self.assertEqual(self.read_sse(response), b": heartbeat\n\n")
        response.close()
        connection.close()

    def test_ninth_sse_client_is_rejected_and_disconnect_releases_slot(self) -> None:
        clients = [self.open_stream() for _ in range(8)]
        ninth = http.client.HTTPConnection("127.0.0.1", self.running.port, timeout=2)
        ninth.request("GET", "/api/stream")
        response = ninth.getresponse()
        self.assertEqual(response.status, 503)
        self.assertEqual(json.loads(response.read())["error"]["code"], "stream_capacity")
        ninth.close()
        clients[0][1].close()
        clients[0][0].close()
        deadline = time.monotonic() + 1
        admitted: tuple[http.client.HTTPConnection, http.client.HTTPResponse] | None = None
        while time.monotonic() < deadline:
            candidate = http.client.HTTPConnection("127.0.0.1", self.running.port, timeout=0.2)
            candidate.request("GET", "/api/stream")
            fresh = candidate.getresponse()
            if fresh.status == 200:
                admitted = candidate, fresh
                break
            fresh.read()
            candidate.close()
            time.sleep(0.02)
        self.assertIsNotNone(admitted, "disconnected SSE client did not promptly release its slot")
        if admitted is not None:
            admitted[1].close()
            admitted[0].close()
        for connection, stream in clients[1:]:
            stream.close()
            connection.close()


class ResolutionTest(unittest.TestCase):
    def test_cli_then_environment_then_platform_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
            with mock.patch.dict(os.environ, {"QUARTET_EVENTS_DIR": second}):
                self.assertEqual(resolve_events_dir(first), Path(first).resolve())
                self.assertEqual(resolve_events_dir(None), Path(second).resolve())
        with mock.patch.dict(os.environ, {"HOME": "/tmp/shipyard-home"}, clear=True), mock.patch(
            "dashboard.server.Path.home", return_value=Path("/tmp/shipyard-home")
        ):
            self.assertEqual(
                clean_install_events_dir(platform="darwin"),
                Path("/tmp/shipyard-home/Library/Application Support/Shipyard/events"),
            )
            self.assertEqual(
                clean_install_events_dir(platform="linux"), Path("/tmp/shipyard-home/.local/state/shipyard/events")
            )

    def test_non_directory_missing_and_direct_symlink_are_refused(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            file_path = root / "events-file"
            file_path.write_text("x", encoding="utf-8")
            link = root / "escape"
            link.symlink_to(root)
            for value in (file_path, root / "missing", link):
                with self.subTest(value=value), self.assertRaises(ValueError):
                    resolve_events_dir(str(value))


if __name__ == "__main__":
    unittest.main()
