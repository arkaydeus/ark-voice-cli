"""Per-request state and frame routing shared by the sync and asyncio clients.

Nothing here does I/O or locking: the clients feed frames in, read the
per-request queues out, and supply their own synchronisation.
"""

from __future__ import annotations

from collections import deque
from typing import Any, Callable

from ._audio import PCMAudio, SampleFormat, bytes_per_sample
from ._events import AudioChunk, ServerStatus, SynthesisDone, TranscriptFinal, TranscriptPartial
from ._wire import KIND_PCM, SYNTHESIS_SAMPLE_RATE, Frame, decode_message
from .errors import ArkVoiceError, ConnectionClosedError, ProtocolError, error_from_message

#: Returned by ``Request.pop`` when the request has nothing more to give.
END: Any = object()

_TERMINAL_EVENTS = {
    "hello": "hello-ok",
    "tts": "done",
    "stt": "done",
    "create-voice": "done",
    "voices": "voices",
    "status": "status",
    "unload": "done",
}


class Request:
    """One in-flight request: its queued items, result and terminal state."""

    __slots__ = (
        "request_id",
        "op",
        "format",
        "sample_rate",
        "index",
        "items",
        "result",
        "error",
        "finished",
        "discarding",
        "abandoned",
        "notify",
        "waiter",
    )

    def __init__(self, request_id: int, op: str, format: SampleFormat = "s16le") -> None:
        self.request_id = request_id
        self.op = op
        self.format: SampleFormat = format
        self.sample_rate = SYNTHESIS_SAMPLE_RATE
        self.index = 0
        self.items: deque[Any] = deque()
        self.result: Any = None
        self.error: BaseException | None = None
        self.finished = False
        #: A cancel was sent: drop frames until the terminal event.
        self.discarding = False
        #: The stream was garbage collected; a cancel is still owed.
        self.abandoned = False
        #: Called after every change; the asyncio client wakes its waiter.
        self.notify: Callable[[], None] | None = None
        #: Client-specific wake-up object (an ``asyncio.Event`` in the asyncio client).
        self.waiter: Any = None

    def pop(self) -> Any:
        """Next queued item, ``END``, or raises the request's error (once).

        Returns ``None`` when nothing is ready yet and the request is open.
        """
        if self.items:
            return self.items.popleft()
        if not self.finished:
            return None
        if self.error is not None:
            error, self.error = self.error, None
            raise error
        return END

    def feed(self, frame: Frame) -> bool:
        """Applies one frame; returns ``True`` if it was the terminal event."""
        if frame.kind == KIND_PCM:
            if self.discarding or self.op != "tts":
                return False
            if len(frame.payload) % bytes_per_sample(self.format):
                raise ProtocolError(
                    f"PCM frame of {len(frame.payload)} bytes is not whole {self.format} samples"
                )
            audio = PCMAudio(frame.payload, self.sample_rate, self.format)
            self.items.append(AudioChunk(audio, self.index))
            self.index += 1
            return False

        message = decode_message(frame.payload)
        event = message.get("event")
        if event == "error":
            if not self.discarding:
                self.error = error_from_message(message, self.request_id)
            return True
        terminal = event == _TERMINAL_EVENTS.get(self.op)
        if self.discarding:
            return terminal

        if self.op == "tts":
            if event == "audio-format":
                rate = message.get("sampleRate")
                if isinstance(rate, int) and not isinstance(rate, bool) and rate > 0:
                    self.sample_rate = rate
                fmt = message.get("format")
                if fmt in ("s16le", "f32le"):
                    self.format = fmt
            elif terminal:
                done = SynthesisDone(
                    chunks=int(message.get("chunks", self.index)),
                    samples=int(message.get("samples", 0)),
                    seconds=float(message.get("seconds", 0.0)),
                    sample_rate=self.sample_rate,
                )
                self.result = done
                self.items.append(done)
        elif self.op == "stt":
            if event in ("partial", "final"):
                text = message.get("text")
                text = text if isinstance(text, str) else ""
                if event == "partial":
                    self.items.append(TranscriptPartial(text))
                else:
                    self.result = text
                    self.items.append(TranscriptFinal(text))
        elif self.op == "create-voice":
            if event == "voice-created":
                path = message.get("path")
                self.result = path if isinstance(path, str) else ""
        elif terminal:
            if self.op == "voices":
                names = message.get("names")
                self.result = [str(name) for name in names] if isinstance(names, list) else []
            elif self.op == "status":
                self.result = ServerStatus.from_message(message)
            elif self.op == "hello":
                self.result = message
        return terminal


class Router:
    """Allocates request ids and routes incoming frames to their requests."""

    def __init__(self) -> None:
        self.pending: dict[int, Request] = {}
        self.closed = False
        self.close_reason = "The connection is closed."
        self._next_id = 1

    def register(self, op: str, format: SampleFormat = "s16le") -> Request:
        if self.closed:
            raise ConnectionClosedError(self.close_reason)
        request_id = self._next_id
        while request_id in self.pending:
            request_id = request_id + 1 if request_id < 0xFFFFFFFF else 1
        self._next_id = request_id + 1 if request_id < 0xFFFFFFFF else 1
        request = Request(request_id, op, format)
        self.pending[request_id] = request
        return request

    def dispatch(self, frame: Frame) -> bool:
        """Routes one frame. Returns ``True`` when the connection must close.

        Raises :class:`ProtocolError` for a malformed JSON payload; the caller
        treats that as fatal to the connection.
        """
        if frame.request_id == 0:
            if frame.kind != KIND_PCM:
                message = decode_message(frame.payload)
                if message.get("event") == "error":
                    self.fail_all(lambda _id: error_from_message(message, 0), "connection-level error")
                    return True
            return False
        request = self.pending.get(frame.request_id)
        if request is None:
            return False
        if request.feed(frame):
            del self.pending[frame.request_id]
            request.finished = True
        if request.notify is not None:
            request.notify()
        return False

    def fail_all(self, make_error: Callable[[int], ArkVoiceError], reason: str) -> None:
        """Ends every pending request with a fresh error and refuses new ones."""
        if not self.closed:
            self.closed = True
            self.close_reason = f"The connection is closed ({reason})."
        pending = list(self.pending.values())
        self.pending.clear()
        for request in pending:
            if not request.discarding:
                request.error = make_error(request.request_id)
            request.finished = True
            if request.notify is not None:
                request.notify()

    def closed_error(self, _request_id: int = 0) -> ConnectionClosedError:
        return ConnectionClosedError(self.close_reason)

    def start_cancel(self, request: Request) -> bool:
        """Marks ``request`` as cancelled; ``True`` if a cancel frame must be sent."""
        if request.finished or request.discarding or self.closed:
            return False
        request.discarding = True
        request.items.clear()
        return True
