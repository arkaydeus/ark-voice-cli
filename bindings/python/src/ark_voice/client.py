"""Blocking client for ``ark-voice serve``.

There is no background thread. Whoever needs the next event for a request
takes the reader role, reads one batch of frames from the socket and routes
each to its request's queue, waking any other thread waiting on one of them.
So several streams can be interleaved on one connection and several threads
can share a client.
"""

from __future__ import annotations

import os
import socket
import threading
from collections import deque
from types import TracebackType
from typing import Any, Generic, Iterator, TypeVar

from ._audio import PCMAudio, SampleFormat
from ._core import END, Request, Router
from ._events import (
    ServerStatus,
    SynthesisDone,
    SynthesisEvent,
    SynthesisResult,
    TranscriptEvent,
)
from ._wire import (
    KIND_JSON,
    KIND_PCM,
    PROTOCOL_VERSION,
    SYNTHESIS_SAMPLE_RATE,
    UPLOAD_CHUNK_SIZE,
    FrameDecoder,
    encode_frame,
    encode_message,
    resolve_socket_path,
)
from .errors import (
    ConnectionClosedError,
    NotRunningError,
    ProtocolError,
    UnsupportedVersionError,
)

__all__ = ["Client", "SynthesisStream", "TranscriptionStream"]

_T = TypeVar("_T")
_RECV_SIZE = 256 * 1024
_CANCEL = encode_message({"op": "cancel"})
_END_UPLOAD = encode_message({"op": "end"})


def _open_socket(path: str) -> socket.socket:
    if not os.path.exists(path):
        raise NotRunningError(path)
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(path)
    except (FileNotFoundError, ConnectionRefusedError) as error:
        sock.close()
        raise NotRunningError(path) from error
    except BaseException:
        sock.close()
        raise
    return sock


def upload_frames(request_id: int, audio: PCMAudio) -> Iterator[bytes]:
    """Lazily encode PCM frames of at most 256 KiB, then ``{"op":"end"}``."""
    data = memoryview(audio.data)
    for offset in range(0, len(data), UPLOAD_CHUNK_SIZE):
        yield encode_frame(KIND_PCM, request_id, data[offset : offset + UPLOAD_CHUNK_SIZE])
    yield encode_frame(KIND_JSON, request_id, _END_UPLOAD)


class _Stream(Generic[_T]):
    """An eagerly-sent streaming request. Iterate it; close it to cancel."""

    def __init__(self, client: Client, request: Request) -> None:
        self._client = client
        self._request = request
        self._closed = False

    @property
    def request_id(self) -> int:
        return self._request.request_id

    @property
    def finished(self) -> bool:
        """True once the terminal event arrived (or the stream was closed)."""
        return self._closed or self._request.finished

    def __iter__(self) -> Iterator[_T]:
        return self

    def __next__(self) -> _T:
        if self._closed:
            raise StopIteration
        item = self._client._next(self._request)
        if item is END:
            self._closed = True
            raise StopIteration
        return item  # type: ignore[no-any-return]

    def close(self) -> None:
        """Stops early: sends ``cancel`` unless the request already ended.

        The connection discards the request's remaining frames as they
        arrive; this call does not wait for them.
        """
        if self._closed:
            return
        self._closed = True
        self._client._cancel(self._request)

    cancel = close

    def __enter__(self) -> _Stream[_T]:
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        self.close()

    def __del__(self) -> None:
        if not getattr(self, "_closed", True) and not self._request.finished:
            self._client._abandon(self._request)


class SynthesisStream(_Stream[SynthesisEvent]):
    """Yields :class:`AudioChunk` items, then one :class:`SynthesisDone`."""


class TranscriptionStream(_Stream[TranscriptEvent]):
    """Yields :class:`TranscriptPartial` / :class:`TranscriptFinal` items."""


class Client:
    """A connection to ``ark-voice serve``. Thread-safe.

    ``Client()`` and ``Client.connect()`` connect and handshake immediately.
    The socket path is ``socket_path``, else ``$ARK_VOICE_SOCKET``, else
    ``~/.ark-voice-cli/ark-voice.sock``.
    """

    def __init__(self, socket_path: str | os.PathLike[str] | None = None) -> None:
        self._socket_path = resolve_socket_path(socket_path)
        self._router = Router()
        self._cond = threading.Condition(threading.Lock())
        self._send_lock = threading.Lock()
        self._reading = False
        self._decoder = FrameDecoder()
        self._abandoned: deque[Request] = deque()
        self._server_version = PROTOCOL_VERSION
        self._sample_rate = SYNTHESIS_SAMPLE_RATE
        self._sock: socket.socket | None = None
        self._sock = _open_socket(self._socket_path)
        try:
            self._handshake()
        except BaseException:
            self.close()
            raise

    @classmethod
    def connect(cls, socket_path: str | os.PathLike[str] | None = None) -> Client:
        return cls(socket_path)

    def _handshake(self) -> None:
        request = self._start("hello", {"op": "hello", "version": PROTOCOL_VERSION})
        reply: dict[str, Any] = self._wait(request)
        version = reply.get("version")
        if version != PROTOCOL_VERSION:
            raise UnsupportedVersionError(
                "unsupported-version",
                f"The server speaks protocol version {version}; this client speaks "
                f"{PROTOCOL_VERSION}.",
                request.request_id,
            )
        self._server_version = version
        rate = reply.get("sampleRate")
        if isinstance(rate, int) and not isinstance(rate, bool) and rate > 0:
            self._sample_rate = rate

    # -- properties ------------------------------------------------------

    @property
    def socket_path(self) -> str:
        return self._socket_path

    @property
    def server_version(self) -> int:
        return self._server_version

    @property
    def sample_rate(self) -> int:
        """Synthesis sample rate announced in ``hello-ok`` (default 24000)."""
        return self._sample_rate

    @property
    def closed(self) -> bool:
        return self._router.closed

    # -- lifecycle -------------------------------------------------------

    def close(self) -> None:
        """Closes the connection; pending requests fail with ConnectionClosedError."""
        with self._cond:
            self._router.fail_all(
                lambda _id: ConnectionClosedError("The client closed the connection."),
                "closed by the client",
            )
            self._shutdown_locked()
            self._cond.notify_all()

    def __enter__(self) -> Client:
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        self.close()

    # -- operations ------------------------------------------------------

    def synthesize(
        self, text: str, *, voice: str | None = None, format: SampleFormat = "s16le"
    ) -> SynthesisStream:
        """Starts synthesis now; iterate the stream for chunks and the summary."""
        request = self._start(
            "tts", {"op": "tts", "text": text, "voice": voice, "format": format}, format=format
        )
        return SynthesisStream(self, request)

    def synthesize_audio(
        self, text: str, *, voice: str | None = None, format: SampleFormat = "s16le"
    ) -> SynthesisResult:
        """Synthesizes ``text`` and returns all of the audio joined."""
        return _collect_synthesis(self.synthesize(text, voice=voice, format=format), format)

    def synthesize_to_wav(
        self,
        text: str,
        path: str | os.PathLike[str],
        *,
        voice: str | None = None,
        format: SampleFormat = "s16le",
    ) -> SynthesisDone:
        """Synthesizes ``text`` into a WAV file at ``path``."""
        result = self.synthesize_audio(text, voice=voice, format=format)
        result.audio.write_wav(path)
        return result.summary

    def transcribe(self, audio: PCMAudio, *, model: str | None = None) -> TranscriptionStream:
        """Uploads ``audio`` now; iterate the stream for partial and final text.

        ``model`` is ``"parakeet"``, ``"parakeet-ultra"`` or ``"qwen"``;
        ``None`` uses the server's default.
        """
        request = self._start(
            "stt",
            {"op": "stt", "format": audio.format, "sampleRate": audio.sample_rate, "model": model},
            upload=audio,
        )
        return TranscriptionStream(self, request)

    def transcribe_text(self, audio: PCMAudio, *, model: str | None = None) -> str:
        """The final transcript of ``audio`` ("" if the server sent none)."""
        stream = self.transcribe(audio, model=model)
        for _ in stream:
            pass
        result = stream._request.result
        return result if isinstance(result, str) else ""

    def transcribe_file(
        self, path: str | os.PathLike[str], *, model: str | None = None
    ) -> TranscriptionStream:
        """Like :meth:`transcribe`, reading a WAV file."""
        return self.transcribe(PCMAudio.read_wav(path), model=model)

    def create_voice(self, name: str, audio: PCMAudio) -> str:
        """Saves a voice profile from reference audio; returns its path."""
        request = self._start(
            "create-voice",
            {
                "op": "create-voice",
                "name": name,
                "format": audio.format,
                "sampleRate": audio.sample_rate,
            },
            upload=audio,
        )
        result = self._wait(request)
        return result if isinstance(result, str) else ""

    def voices(self) -> list[str]:
        """Names of saved voice profiles."""
        result: list[str] = self._wait(self._start("voices", {"op": "voices"}))
        return result

    def status(self) -> ServerStatus:
        result: ServerStatus = self._wait(self._start("status", {"op": "status"}))
        return result

    def unload(self) -> None:
        """Releases the server's resident models."""
        self._wait(self._start("unload", {"op": "unload"}))

    # -- plumbing --------------------------------------------------------

    def _start(
        self,
        op: str,
        message: dict[str, Any],
        *,
        format: SampleFormat = "s16le",
        upload: PCMAudio | None = None,
    ) -> Request:
        """Registers a request and sends it (and its upload) right away."""
        with self._cond:
            self._flush_abandoned_locked()
            request = self._router.register(op, format)
        frames = [encode_frame(KIND_JSON, request.request_id, encode_message(message))]
        if upload is not None:
            frames.extend(upload_frames(request.request_id, upload))
        self._send(frames)
        return request

    def _send(self, frames: list[bytes]) -> None:
        try:
            self._write(frames)
        except OSError as error:
            with self._cond:
                self._lost_locked(f"send failed: {error}")
            raise ConnectionClosedError(self._router.close_reason) from error

    def _write(self, frames: list[bytes]) -> None:
        """Writes whole frames under the send lock; raises OSError on failure."""
        with self._send_lock:
            sock = self._sock
            if sock is None or self._router.closed:
                raise ConnectionClosedError(self._router.close_reason)
            for frame in frames:
                sock.sendall(frame)

    def _wait(self, request: Request) -> Any:
        while self._next(request) is not END:
            pass
        return request.result

    def _next(self, request: Request) -> Any:
        """Next item for ``request``, reading from the socket when needed."""
        while True:
            with self._cond:
                while True:
                    self._flush_abandoned_locked()
                    item = request.pop()
                    if item is not None:
                        return item
                    if not self._reading:
                        self._reading = True
                        sock = self._sock
                        break
                    self._cond.wait()
            self._read_once(sock)

    def _read_once(self, sock: socket.socket | None) -> None:
        """Reads one batch of bytes and routes the frames it completes."""
        data = b""
        failure: str | None = "connection closed"
        if sock is not None:
            try:
                data = sock.recv(_RECV_SIZE)
                failure = None if data else "the server closed the connection"
            except OSError as error:
                failure = f"receive failed: {error}"
            except BaseException:
                # KeyboardInterrupt and friends: give up the reader role so
                # other threads are not left waiting for it.
                with self._cond:
                    self._reading = False
                    self._cond.notify_all()
                raise
        with self._cond:
            self._reading = False
            try:
                try:
                    if failure is not None:
                        if not data:
                            self._decoder.finish()
                        self._lost_locked(failure)
                        return
                    for frame in self._decoder.feed(data):
                        if self._router.dispatch(frame):
                            self._shutdown_locked()
                            break
                except ProtocolError as error:
                    self._router.fail_all(
                        lambda _id: ProtocolError(str(error), error.reason),
                        f"protocol error: {error}",
                    )
                    self._shutdown_locked()
            finally:
                self._cond.notify_all()

    def _lost_locked(self, reason: str) -> None:
        self._router.fail_all(
            lambda _id: ConnectionClosedError(f"The connection was lost ({reason})."), reason
        )
        self._shutdown_locked()
        self._cond.notify_all()

    def _shutdown_locked(self) -> None:
        sock = self._sock
        if sock is None:
            return
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        if not self._reading:
            # Nobody is blocked in recv on it, so the descriptor can go now;
            # otherwise the reader sees EOF and closes it below.
            self._sock = None
            sock.close()

    def _cancel(self, request: Request) -> None:
        with self._cond:
            self._flush_abandoned_locked()
            if self._router.start_cancel(request):
                self._send_cancel_locked(request)

    def _send_cancel_locked(self, request: Request) -> None:
        # Holding the condition lock while sending means no reader can process
        # the request's terminal event first, so a cancel never follows one
        # this client has already seen.
        try:
            self._write([encode_frame(KIND_JSON, request.request_id, _CANCEL)])
        except ConnectionClosedError:
            pass
        except OSError as error:
            self._lost_locked(f"send failed: {error}")

    def _abandon(self, request: Request) -> None:
        """From a stream's finaliser: cancel now if safe, else at the next call."""
        request.abandoned = True
        self._abandoned.append(request)
        if self._cond.acquire(blocking=False):
            try:
                if self._send_lock.locked():
                    return
                self._flush_abandoned_locked()
            finally:
                self._cond.release()

    def _flush_abandoned_locked(self) -> None:
        while self._abandoned:
            request = self._abandoned.popleft()
            if self._router.start_cancel(request):
                self._send_cancel_locked(request)

    def __del__(self) -> None:
        sock = getattr(self, "_sock", None)
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass

    def __repr__(self) -> str:
        state = "closed" if self.closed else "open"
        return f"<ark_voice.Client {self._socket_path!r} {state}>"


def _collect_synthesis(stream: Iterator[SynthesisEvent], format: SampleFormat) -> SynthesisResult:
    from ._events import AudioChunk

    chunks: list[PCMAudio] = []
    summary: SynthesisDone | None = None
    for event in stream:
        if isinstance(event, AudioChunk):
            chunks.append(event.audio)
        else:
            summary = event
    if summary is None:  # pragma: no cover - the stream always ends with done
        raise ConnectionClosedError("Synthesis ended without a summary.")
    audio = PCMAudio.concat(
        chunks,
        sample_rate=chunks[0].sample_rate if chunks else summary.sample_rate,
        format=chunks[0].format if chunks else format,
    )
    return SynthesisResult(audio, summary)
