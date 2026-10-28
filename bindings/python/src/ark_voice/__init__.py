"""Python client for the ``ark-voice serve`` Unix-socket protocol.

Standard library only. ``Client`` is blocking and thread-safe; ``AsyncClient``
is the asyncio equivalent. Both need a running ``ark-voice serve``.

    from ark_voice import Client

    with Client() as client:
        for event in client.synthesize("Hello there."):
            ...
"""

from ._audio import (
    SAMPLE_FORMATS,
    PCMAudio,
    SampleFormat,
    bytes_per_sample,
    decode_samples,
    decode_wav,
    encode_samples,
    encode_wav,
)
from ._events import (
    AudioChunk,
    ServerStatus,
    SynthesisDone,
    SynthesisEvent,
    SynthesisResult,
    TranscriptEvent,
    TranscriptFinal,
    TranscriptPartial,
)
from ._wire import (
    DEFAULT_SOCKET_PATH,
    HEADER_SIZE,
    KIND_JSON,
    KIND_PCM,
    MAGIC,
    MAX_PAYLOAD_SIZE,
    PROTOCOL_VERSION,
    SOCKET_ENV_VAR,
    SYNTHESIS_SAMPLE_RATE,
    UPLOAD_CHUNK_SIZE,
    Frame,
    FrameDecoder,
    FrameHeader,
    decode_message,
    default_socket_path,
    encode_frame,
    encode_message,
    parse_header,
    resolve_socket_path,
)
from .aio import AsyncClient, AsyncSynthesisStream, AsyncTranscriptionStream, Reply
from .client import Client, SynthesisStream, TranscriptionStream
from .errors import (
    ArkVoiceError,
    BadRequestError,
    ConnectionClosedError,
    ModelsMissingError,
    NotRunningError,
    ProtocolError,
    RequestCancelledError,
    ServerError,
    ServerFailedError,
    UnknownRequestError,
    UnsupportedVersionError,
    error_from_message,
)

__version__ = "0.1.0"

__all__ = [
    # clients
    "Client",
    "AsyncClient",
    "SynthesisStream",
    "TranscriptionStream",
    "AsyncSynthesisStream",
    "AsyncTranscriptionStream",
    "Reply",
    # values
    "PCMAudio",
    "SampleFormat",
    "AudioChunk",
    "SynthesisDone",
    "SynthesisEvent",
    "SynthesisResult",
    "TranscriptPartial",
    "TranscriptFinal",
    "TranscriptEvent",
    "ServerStatus",
    # errors
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
    # protocol pieces
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
    "SAMPLE_FORMATS",
    "bytes_per_sample",
    "encode_samples",
    "decode_samples",
    "encode_wav",
    "decode_wav",
    "__version__",
]
