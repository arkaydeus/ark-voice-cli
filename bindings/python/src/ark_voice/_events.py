"""Values yielded and returned by the clients."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, ClassVar, Literal, Mapping, Union

from ._audio import PCMAudio

__all__ = [
    "AudioChunk",
    "SynthesisDone",
    "SynthesisEvent",
    "SynthesisResult",
    "TranscriptPartial",
    "TranscriptFinal",
    "TranscriptEvent",
    "ServerStatus",
]


@dataclass(frozen=True)
class AudioChunk:
    """One synthesized chunk; ``index`` counts from 0."""

    type: ClassVar[Literal["audio"]] = "audio"
    audio: PCMAudio
    index: int


@dataclass(frozen=True)
class SynthesisDone:
    """The last item of a synthesis stream."""

    type: ClassVar[Literal["done"]] = "done"
    chunks: int
    samples: int
    seconds: float
    sample_rate: int


SynthesisEvent = Union[AudioChunk, SynthesisDone]


@dataclass(frozen=True)
class SynthesisResult:
    """Returned by ``synthesize_audio``: every chunk joined, plus the summary."""

    audio: PCMAudio
    summary: SynthesisDone


@dataclass(frozen=True)
class TranscriptPartial:
    """Text recognized since the previous event, with its own spacing."""

    type: ClassVar[Literal["partial"]] = "partial"
    text: str


@dataclass(frozen=True)
class TranscriptFinal:
    """The whole transcript."""

    type: ClassVar[Literal["final"]] = "final"
    text: str


TranscriptEvent = Union[TranscriptPartial, TranscriptFinal]


@dataclass(frozen=True)
class ServerStatus:
    """Reply to ``status()``."""

    version: int
    synthesis_model_loaded: bool
    transcription_model_loaded: bool
    transcription_model: str | None
    requests_served: int
    uptime_seconds: float

    @classmethod
    def from_message(cls, message: Mapping[str, Any]) -> ServerStatus:
        model = message.get("transcriptionModel")
        return cls(
            version=int(message.get("version", 1)),
            synthesis_model_loaded=bool(message.get("synthesisModelLoaded", False)),
            transcription_model_loaded=bool(message.get("transcriptionModelLoaded", False)),
            transcription_model=model if isinstance(model, str) else None,
            requests_served=int(message.get("requestsServed", 0)),
            uptime_seconds=float(message.get("uptimeSeconds", 0.0)),
        )
