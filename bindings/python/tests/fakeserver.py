"""A scripted stand-in for `ark-voice serve` on a temporary Unix socket.

The script runs on a thread with a :class:`Peer` for the one accepted
connection; exceptions raised by the script (failed assertions included) are
re-raised by :meth:`FakeServer.__exit__` so they fail the test.
"""

from __future__ import annotations

import os
import json
import shutil
import socket
import tempfile
import threading
from collections import deque
from typing import Any, Callable

from ark_voice import (
    KIND_JSON,
    KIND_PCM,
    Frame,
    FrameDecoder,
    encode_frame,
    encode_message,
)


def socket_dir() -> str:
    # Under /tmp, not $TMPDIR: macOS socket paths max out at 104 bytes.
    return tempfile.mkdtemp(prefix="arkv-py-", dir="/tmp")


class PeerClosed(Exception):
    pass


class Peer:
    def __init__(self, conn: socket.socket) -> None:
        self.conn = conn
        self.conn.settimeout(10)
        self.decoder = FrameDecoder()
        self.frames: deque[Frame] = deque()

    def read_frame(self) -> Frame:
        while not self.frames:
            data = self.conn.recv(65536)
            if not data:
                raise PeerClosed("client closed the connection")
            self.frames.extend(self.decoder.feed(data))
        return self.frames.popleft()

    def read_json(self) -> tuple[int, dict[str, Any]]:
        frame = self.read_frame()
        assert frame.kind == KIND_JSON, f"expected json, got pcm on {frame.request_id}"
        return frame.request_id, json.loads(frame.payload)

    def expect(self, op: str) -> int:
        request_id, message = self.read_json()
        assert message.get("op") == op, f"expected {op!r}, got {message!r}"
        return request_id

    def send_json(self, request_id: int, message: dict[str, Any]) -> None:
        self.conn.sendall(encode_frame(KIND_JSON, request_id, encode_message(message)))

    def send_pcm(self, request_id: int, payload: bytes) -> None:
        self.conn.sendall(encode_frame(KIND_PCM, request_id, payload))

    def send_raw(self, data: bytes) -> None:
        self.conn.sendall(data)

    def handshake(self, version: int = 1, sample_rate: int = 24000) -> int:
        frame = self.read_frame()
        assert frame.kind == KIND_JSON
        assert json.loads(frame.payload) == {"op": "hello", "version": 1}
        self.send_json(frame.request_id, {"event": "hello-ok", "version": version, "sampleRate": sample_rate})
        return frame.request_id

    def done(self, request_id: int, **fields: Any) -> None:
        self.send_json(request_id, {"event": "done", **fields})

    def error(self, request_id: int, code: str, message: str = "nope") -> None:
        self.send_json(request_id, {"event": "error", "code": code, "message": message})

    def expect_eof(self) -> None:
        """Asserts the client hangs up without sending anything more."""
        try:
            frame = self.read_frame()
        except (PeerClosed, ConnectionResetError):
            return
        raise AssertionError(f"unexpected frame before EOF: {frame!r}")

    def wait_closed(self) -> None:
        """Reads (and drops) frames until the client hangs up."""
        try:
            while True:
                self.read_frame()
        except (PeerClosed, ConnectionResetError, socket.timeout):
            return


class FakeServer:
    def __init__(self, script: Callable[[Peer], None]) -> None:
        self.script = script
        self.dir = socket_dir()
        self.path = os.path.join(self.dir, "fake.sock")
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(self.path)
        self.listener.listen(1)
        self.listener.settimeout(10)
        self.error: BaseException | None = None
        self.thread = threading.Thread(target=self._run, daemon=True)

    def _run(self) -> None:
        conn: socket.socket | None = None
        try:
            conn, _ = self.listener.accept()
            self.script(Peer(conn))
        except BaseException as error:  # noqa: BLE001 - surfaced in __exit__
            self.error = error
        finally:
            if conn is not None:
                try:
                    conn.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                conn.close()

    def __enter__(self) -> FakeServer:
        self.thread.start()
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        self.thread.join(15)
        self.listener.close()
        shutil.rmtree(self.dir, ignore_errors=True)
        if self.thread.is_alive():
            raise AssertionError("fake server script did not finish")
        if self.error is not None and exc_type is None:
            raise self.error
