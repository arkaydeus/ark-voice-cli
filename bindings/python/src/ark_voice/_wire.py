"""Framing, control messages and socket-path resolution (no I/O)."""

from __future__ import annotations

import json
import os
import struct
from dataclasses import dataclass
from typing import Any, Mapping

from .errors import ProtocolError

__all__ = [
    "PROTOCOL_VERSION",
    "MAGIC",
    "KIND_JSON",
    "KIND_PCM",
    "HEADER_SIZE",
    "MAX_PAYLOAD_SIZE",
    "UPLOAD_CHUNK_SIZE",
    "SYNTHESIS_SAMPLE_RATE",
    "DEFAULT_SOCKET_PATH",
    "SOCKET_ENV_VAR",
    "default_socket_path",
    "resolve_socket_path",
    "Frame",
    "FrameHeader",
    "FrameDecoder",
    "parse_header",
    "encode_frame",
    "encode_message",
    "decode_message",
]

PROTOCOL_VERSION = 1
MAGIC = 0x41
KIND_JSON = 0
KIND_PCM = 1
HEADER_SIZE = 12
#: Largest payload accepted from the server; exactly 64 MiB is allowed.
MAX_PAYLOAD_SIZE = 64 * 1024 * 1024
#: Uploads are split into PCM frames of at most this many bytes.
UPLOAD_CHUNK_SIZE = 256 * 1024
#: Synthesis output rate, and the fallback when the server does not say.
SYNTHESIS_SAMPLE_RATE = 24_000
DEFAULT_SOCKET_PATH = "~/.ark-voice-cli/ark-voice.sock"
SOCKET_ENV_VAR = "ARK_VOICE_SOCKET"

_HEADER = struct.Struct("<BBHII")
_KINDS = (KIND_JSON, KIND_PCM)


def default_socket_path() -> str:
    """``~/.ark-voice-cli/ark-voice.sock``, expanded."""
    return os.path.expanduser(DEFAULT_SOCKET_PATH)


def resolve_socket_path(socket_path: str | os.PathLike[str] | None = None) -> str:
    """Explicit argument, else ``$ARK_VOICE_SOCKET``, else the default path."""
    if socket_path is not None:
        return os.fspath(socket_path)
    from_env = os.environ.get(SOCKET_ENV_VAR)
    if from_env:
        return from_env
    return default_socket_path()


@dataclass(frozen=True)
class FrameHeader:
    """The fields of a 12-byte frame header."""

    kind: int
    request_id: int
    payload_length: int


@dataclass(frozen=True)
class Frame:
    """One protocol frame: ``kind`` is :data:`KIND_JSON` or :data:`KIND_PCM`."""

    kind: int
    request_id: int
    payload: bytes

    def encode(self) -> bytes:
        return encode_frame(self.kind, self.request_id, self.payload)


def parse_header(header: bytes | bytearray | memoryview) -> FrameHeader:
    """Parses and validates exactly :data:`HEADER_SIZE` bytes.

    Raises :class:`~ark_voice.errors.ProtocolError` whose ``reason`` is one of
    ``bad-magic``, ``unknown-kind``, ``unsupported-flags``,
    ``payload-too-large`` or ``truncated``.
    """
    if len(header) != HEADER_SIZE:
        raise ProtocolError("Frame header is truncated.", "truncated")
    magic, kind, flags, request_id, length = _HEADER.unpack(header)
    if magic != MAGIC:
        raise ProtocolError(f"Not an ark-voice frame: leading byte 0x{magic:02x}.", "bad-magic")
    if kind not in _KINDS:
        raise ProtocolError(f"Unknown frame kind {kind}.", "unknown-kind")
    if flags != 0:
        raise ProtocolError(f"Unsupported frame flags 0x{flags:x}.", "unsupported-flags")
    if length > MAX_PAYLOAD_SIZE:
        raise ProtocolError(
            f"Frame payload of {length} bytes exceeds the {MAX_PAYLOAD_SIZE} byte limit.",
            "payload-too-large",
        )
    return FrameHeader(kind, request_id, length)


def encode_frame(kind: int, request_id: int, payload: bytes | bytearray | memoryview) -> bytes:
    """Header plus payload, ready to write to the socket."""
    if kind not in _KINDS:
        raise ValueError(f"unknown frame kind {kind}")
    if not 0 <= request_id <= 0xFFFFFFFF:
        raise ValueError(f"request id {request_id} does not fit in a u32")
    if len(payload) > MAX_PAYLOAD_SIZE:
        raise ValueError(f"payload of {len(payload)} bytes exceeds {MAX_PAYLOAD_SIZE}")
    return _HEADER.pack(MAGIC, kind, 0, request_id, len(payload)) + bytes(payload)


def encode_message(message: Mapping[str, Any]) -> bytes:
    """Compact JSON with sorted keys, ``None`` fields omitted, raw UTF-8."""
    present = {key: value for key, value in message.items() if value is not None}
    return json.dumps(
        present, separators=(",", ":"), sort_keys=True, ensure_ascii=False
    ).encode("utf-8")


def decode_message(payload: bytes | bytearray | memoryview) -> dict[str, Any]:
    """Parses a JSON control payload into a dict."""
    try:
        message = json.loads(bytes(payload).decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as error:
        raise ProtocolError(f"Malformed JSON control message: {error}") from error
    if not isinstance(message, dict):
        raise ProtocolError("JSON control message is not an object.")
    return message


class FrameDecoder:
    """Turns a byte stream, split anywhere, into frames.

    >>> decoder = FrameDecoder()
    >>> frames = decoder.feed(chunk)   # zero or more complete frames
    """

    def __init__(self) -> None:
        self._buffer = bytearray()
        self._header: FrameHeader | None = None

    def feed(self, data: bytes | bytearray | memoryview) -> list[Frame]:
        """Buffers ``data`` and returns every frame it completes.

        A bad header raises :class:`~ark_voice.errors.ProtocolError`; the
        stream cannot be resynchronised after that.
        """
        buffer = self._buffer
        buffer += data
        frames: list[Frame] = []
        while True:
            if self._header is None:
                if len(buffer) < HEADER_SIZE:
                    break
                self._header = parse_header(bytes(buffer[:HEADER_SIZE]))
                del buffer[:HEADER_SIZE]
            length = self._header.payload_length
            if len(buffer) < length:
                break
            payload = bytes(buffer[:length])
            del buffer[:length]
            frames.append(Frame(self._header.kind, self._header.request_id, payload))
            self._header = None
        return frames

    @property
    def buffered(self) -> int:
        """Bytes received that do not yet form a complete frame."""
        return len(self._buffer) + (HEADER_SIZE if self._header is not None else 0)

    def finish(self) -> None:
        """Call at end of stream: raises ``ProtocolError("truncated")`` mid-frame."""
        if self.buffered:
            raise ProtocolError(
                "Frame ended before its declared payload was complete.", "truncated"
            )
