"""Exceptions raised by the ark-voice client.

Every exception derives from :class:`ArkVoiceError`. Protocol ``error`` events
become :class:`ServerError` (or the subclass for their ``code``); problems
with the connection itself are :class:`NotRunningError`,
:class:`ConnectionClosedError` and :class:`ProtocolError`.
"""

from __future__ import annotations

from typing import Any, Mapping

__all__ = [
    "ArkVoiceError",
    "ServerError",
    "BadRequestError",
    "UnsupportedVersionError",
    "ModelsMissingError",
    "UnknownRequestError",
    "RequestCancelledError",
    "ServerFailedError",
    "NotRunningError",
    "ConnectionClosedError",
    "ProtocolError",
    "error_from_message",
]


class ArkVoiceError(Exception):
    """Base class of every error raised by this package."""


class ServerError(ArkVoiceError):
    """The server answered a request with an ``error`` event.

    ``code`` is the raw protocol code (for example ``"models-missing"``),
    ``message`` the server's explanation and ``request_id`` the request the
    error ended (``0`` for a connection-level error).
    """

    def __init__(self, code: str, message: str, request_id: int | None = None) -> None:
        super().__init__(f"{message} ({code})" if message else code)
        self.code = code
        self.message = message
        self.request_id = request_id


class BadRequestError(ServerError):
    """``bad-request``: malformed frame, missing field, or no handshake yet."""


class UnsupportedVersionError(ServerError):
    """``unsupported-version``: the server speaks another protocol version."""


class ModelsMissingError(ServerError):
    """``models-missing``: run ``ark-voice download`` on the server's machine."""


class UnknownRequestError(ServerError):
    """``unknown-request``: audio or ``end`` for a request that is not open."""


class RequestCancelledError(ServerError):
    """``cancelled``: the request was cancelled."""


class ServerFailedError(ServerError):
    """``failed``: anything else; ``message`` carries the detail."""


class NotRunningError(ArkVoiceError):
    """Nothing is listening on the socket path."""

    def __init__(self, socket_path: str) -> None:
        super().__init__(
            f"No ark-voice server is listening at {socket_path}. "
            "Start one with `ark-voice serve`."
        )
        self.socket_path = socket_path


class ConnectionClosedError(ArkVoiceError):
    """The connection ended (EOF, socket error, or :meth:`close`)."""


class ProtocolError(ArkVoiceError):
    """The server sent a malformed frame or JSON payload.

    ``reason`` is set for frame errors: ``"bad-magic"``, ``"unknown-kind"``,
    ``"unsupported-flags"``, ``"payload-too-large"`` or ``"truncated"``.
    """

    def __init__(self, message: str, reason: str | None = None) -> None:
        super().__init__(message)
        self.reason = reason


_ERROR_CLASSES: dict[str, type[ServerError]] = {
    "bad-request": BadRequestError,
    "unsupported-version": UnsupportedVersionError,
    "models-missing": ModelsMissingError,
    "unknown-request": UnknownRequestError,
    "cancelled": RequestCancelledError,
    "failed": ServerFailedError,
}


def error_from_message(message: Mapping[str, Any], request_id: int | None = None) -> ServerError:
    """Builds the exception for a server ``error`` event.

    An unrecognised code gives a plain :class:`ServerError`; a missing code is
    treated as ``failed``, as the Swift client does.
    """
    raw_code = message.get("code")
    code = raw_code if isinstance(raw_code, str) else "failed"
    raw_text = message.get("message")
    text = raw_text if isinstance(raw_text, str) else ""
    return _ERROR_CLASSES.get(code, ServerError)(code, text, request_id)
