"""asyncio client for ``ark-voice serve``.

One reader task routes frames to per-request queues. Requests are queued for
the transport when the method is called, so these are pipelined::

    status = client.status()          # sent now
    voices = client.voices()          # sent now
    print(await status, await voices)
"""

from __future__ import annotations

import asyncio
import os
from collections import deque
from types import TracebackType
from typing import Any, AsyncIterator, Callable, Coroutine, Generator, Generic, Iterator, TypeVar

from ._audio import PCMAudio, SampleFormat
from ._core import END, Request, Router
from ._events import (
    AudioChunk,
    ServerStatus,
    SynthesisDone,
    SynthesisEvent,
    SynthesisResult,
    TranscriptEvent,
)
from ._wire import (
    KIND_JSON,
    PROTOCOL_VERSION,
    SYNTHESIS_SAMPLE_RATE,
    FrameDecoder,
    encode_frame,
    encode_message,
    resolve_socket_path,
)
from .client import upload_frames
from .errors import ConnectionClosedError, NotRunningError, ProtocolError, UnsupportedVersionError

__all__ = ["AsyncClient", "AsyncSynthesisStream", "AsyncTranscriptionStream", "Reply"]

_T = TypeVar("_T")
_RECV_SIZE = 256 * 1024
_CANCEL = encode_message({"op": "cancel"})


class Reply(Generic[_T]):
    """An already-sent request; ``await`` it for the result."""

    __slots__ = ("_factory",)

    def __init__(self, factory: Callable[[], Coroutine[Any, Any, _T]]) -> None:
        self._factory = factory

    def __await__(self) -> Generator[Any, None, _T]:
        return self._factory().__await__()


class _AsyncStream(Generic[_T]):
    """An eagerly-sent streaming request; ``async for`` it, cancel to stop."""

    def __init__(self, client: AsyncClient, request: Request) -> None:
        self._client = client
        self._request = request
        self._closed = False

    @property
    def request_id(self) -> int:
        return self._request.request_id

    @property
    def finished(self) -> bool:
        return self._closed or self._request.finished

    def __aiter__(self) -> AsyncIterator[_T]:
        return self

    async def __anext__(self) -> _T:
        if self._closed:
            raise StopAsyncIteration
        try:
            item = await self._client._next(self._request)
        except asyncio.CancelledError:
            self._closed = True
            raise
        if item is END:
            self._closed = True
            raise StopAsyncIteration
        return item  # type: ignore[no-any-return]

    def cancel(self) -> None:
        """Stops early: sends ``cancel`` unless the request already ended."""
        if self._closed:
            return
        self._closed = True
        self._client._cancel(self._request)

    async def aclose(self) -> None:
        self.cancel()

    async def __aenter__(self) -> _AsyncStream[_T]:
        return self

    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        self.cancel()

    def __del__(self) -> None:
        if not getattr(self, "_closed", True) and not self._request.finished:
            self._client._abandon(self._request)


class AsyncSynthesisStream(_AsyncStream[SynthesisEvent]):
    """Yields :class:`AudioChunk` items, then one :class:`SynthesisDone`."""


class AsyncTranscriptionStream(_AsyncStream[TranscriptEvent]):
    """Yields :class:`TranscriptPartial` / :class:`TranscriptFinal` items."""


class AsyncClient:
    """asyncio connection to ``ark-voice serve``; create with ``await AsyncClient.connect()``."""

    def __init__(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
        socket_path: str,
    ) -> None:
        self._reader = reader
        self._writer = writer
        self._socket_path = socket_path
        self._loop = asyncio.get_running_loop()
        self._router = Router()
        self._decoder = FrameDecoder()
        self._writes: deque[tuple[Request | None, Iterator[bytes]]] = deque()
        self._writer_task: asyncio.Task[None] | None = None
        self._server_version = PROTOCOL_VERSION
        self._sample_rate = SYNTHESIS_SAMPLE_RATE
        self._reader_task = self._loop.create_task(self._read_loop())

    @classmethod
    async def connect(cls, socket_path: str | os.PathLike[str] | None = None) -> AsyncClient:
        path = resolve_socket_path(socket_path)
        if not os.path.exists(path):
            raise NotRunningError(path)
        try:
            reader, writer = await asyncio.open_unix_connection(path)
        except (FileNotFoundError, ConnectionRefusedError) as error:
            raise NotRunningError(path) from error
        client = cls(reader, writer, path)
        try:
            await client._handshake()
        except BaseException:
            await client.close()
            raise
        return client

    async def _handshake(self) -> None:
        request = self._start("hello", {"op": "hello", "version": PROTOCOL_VERSION})
        reply: dict[str, Any] = await self._wait(request)
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
        return self._sample_rate

    @property
    def closed(self) -> bool:
        return self._router.closed

    # -- lifecycle -------------------------------------------------------

    async def close(self) -> None:
        """Closes the connection; pending requests fail with ConnectionClosedError."""
        self._router.fail_all(
            lambda _id: ConnectionClosedError("The client closed the connection."),
            "closed by the client",
        )
        self._close_transport()
        task = self._reader_task
        if task is not asyncio.current_task() and not task.done():
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
        if self._writer_task is not None:
            self._writer_task.cancel()
            try:
                await self._writer_task
            except asyncio.CancelledError:
                pass
        try:
            await asyncio.wait_for(self._writer.wait_closed(), timeout=1)
        except (OSError, RuntimeError, asyncio.TimeoutError):
            pass

    async def __aenter__(self) -> AsyncClient:
        return self

    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        await self.close()

    # -- operations ------------------------------------------------------

    def synthesize(
        self, text: str, *, voice: str | None = None, format: SampleFormat = "s16le"
    ) -> AsyncSynthesisStream:
        """Sends the request now; ``async for`` the chunks and the summary."""
        request = self._start(
            "tts", {"op": "tts", "text": text, "voice": voice, "format": format}, format=format
        )
        return AsyncSynthesisStream(self, request)

    def synthesize_audio(
        self, text: str, *, voice: str | None = None, format: SampleFormat = "s16le"
    ) -> Reply[SynthesisResult]:
        stream = self.synthesize(text, voice=voice, format=format)
        return Reply(lambda: _collect_synthesis(stream, format))

    def synthesize_to_wav(
        self,
        text: str,
        path: str | os.PathLike[str],
        *,
        voice: str | None = None,
        format: SampleFormat = "s16le",
    ) -> Reply[SynthesisDone]:
        stream = self.synthesize(text, voice=voice, format=format)

        async def run() -> SynthesisDone:
            result = await _collect_synthesis(stream, format)
            result.audio.write_wav(path)
            return result.summary

        return Reply(run)

    def transcribe(self, audio: PCMAudio, *, model: str | None = None) -> AsyncTranscriptionStream:
        """Uploads ``audio`` now; ``async for`` the partial and final text."""
        request = self._start(
            "stt",
            {"op": "stt", "format": audio.format, "sampleRate": audio.sample_rate, "model": model},
            upload=audio,
        )
        return AsyncTranscriptionStream(self, request)

    def transcribe_text(self, audio: PCMAudio, *, model: str | None = None) -> Reply[str]:
        stream = self.transcribe(audio, model=model)

        async def run() -> str:
            async for _ in stream:
                pass
            result = stream._request.result
            return result if isinstance(result, str) else ""

        return Reply(run)

    def transcribe_file(
        self, path: str | os.PathLike[str], *, model: str | None = None
    ) -> AsyncTranscriptionStream:
        return self.transcribe(PCMAudio.read_wav(path), model=model)

    def create_voice(self, name: str, audio: PCMAudio) -> Reply[str]:
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

        async def run() -> str:
            result = await self._wait(request)
            return result if isinstance(result, str) else ""

        return Reply(run)

    def voices(self) -> Reply[list[str]]:
        request = self._start("voices", {"op": "voices"})
        return Reply(lambda: self._wait(request))

    def status(self) -> Reply[ServerStatus]:
        request = self._start("status", {"op": "status"})
        return Reply(lambda: self._wait(request))

    def unload(self) -> Reply[None]:
        request = self._start("unload", {"op": "unload"})

        async def run() -> None:
            await self._wait(request)

        return Reply(run)

    # -- plumbing --------------------------------------------------------

    def _start(
        self,
        op: str,
        message: dict[str, Any],
        *,
        format: SampleFormat = "s16le",
        upload: PCMAudio | None = None,
    ) -> Request:
        request = self._router.register(op, format)
        event = asyncio.Event()
        request.waiter = event
        request.notify = event.set
        self._write([encode_frame(KIND_JSON, request.request_id, encode_message(message))])
        if upload is not None:
            self._write(upload_frames(request.request_id, upload), request)
        return request

    def _write(self, frames: Iterator[bytes] | list[bytes], request: Request | None = None) -> None:
        if self._router.closed or self._writer.is_closing():
            raise ConnectionClosedError(self._router.close_reason)
        self._writes.append((request, iter(frames)))
        if self._writer_task is None or self._writer_task.done():
            self._writer_task = self._loop.create_task(self._send_loop())

    async def _send_loop(self) -> None:
        try:
            while self._writes and not self.closed:
                request, frames = self._writes.popleft()
                if request is not None and (request.discarding or request.finished):
                    continue
                frame = next(frames, None)
                if frame is None:
                    continue
                self._writer.write(frame)
                # Keep just one encoded frame queued while a peer stops reading.
                await self._writer.drain()
                await asyncio.sleep(0)
                # Requests share the writer a frame at a time.
                self._writes.append((request, frames))
        except (OSError, RuntimeError) as error:
            self._lost(f"send failed: {error}")

    async def _next(self, request: Request) -> Any:
        try:
            while True:
                item = request.pop()
                if item is not None:
                    return item
                event: asyncio.Event = request.waiter
                event.clear()
                await event.wait()
        except asyncio.CancelledError:
            self._cancel(request)
            raise

    async def _wait(self, request: Request) -> Any:
        while await self._next(request) is not END:
            pass
        return request.result

    async def _read_loop(self) -> None:
        try:
            while True:
                data = await self._reader.read(_RECV_SIZE)
                try:
                    if not data:
                        self._decoder.finish()
                        self._lost("the server closed the connection")
                        return
                    for frame in self._decoder.feed(data):
                        if self._router.dispatch(frame):
                            self._close_transport()
                            return
                except ProtocolError as error:
                    self._router.fail_all(
                        lambda _id: ProtocolError(str(error), error.reason),
                        f"protocol error: {error}",
                    )
                    self._close_transport()
                    return
        except asyncio.CancelledError:
            self._lost("reader cancelled")
            raise
        except Exception as error:  # noqa: BLE001 - any failure ends the connection
            self._lost(f"receive failed: {error}")

    def _lost(self, reason: str) -> None:
        self._router.fail_all(
            lambda _id: ConnectionClosedError(f"The connection was lost ({reason})."), reason
        )
        self._close_transport()

    def _close_transport(self) -> None:
        self._writes.clear()
        # Graceful close can wait forever for buffered uploads to drain.
        self._writer.transport.abort()

    def _cancel(self, request: Request) -> None:
        if self._router.start_cancel(request):
            try:
                self._write([encode_frame(KIND_JSON, request.request_id, _CANCEL)])
            except ConnectionClosedError:
                pass

    def _abandon(self, request: Request) -> None:
        """From a stream's finaliser: cancel on the loop thread."""
        if self._loop.is_closed():
            return
        try:
            self._loop.call_soon_threadsafe(self._cancel, request)
        except RuntimeError:
            pass

    def __repr__(self) -> str:
        state = "closed" if self.closed else "open"
        return f"<ark_voice.AsyncClient {self._socket_path!r} {state}>"


async def _collect_synthesis(stream: AsyncSynthesisStream, format: SampleFormat) -> SynthesisResult:
    chunks: list[PCMAudio] = []
    summary: SynthesisDone | None = None
    async for event in stream:
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

