"""PCM sample conversion, the :class:`PCMAudio` value type, and WAV I/O."""

from __future__ import annotations

import os
import struct
import sys
from array import array
from dataclasses import dataclass
from typing import Iterable, Literal

__all__ = [
    "SampleFormat",
    "SAMPLE_FORMATS",
    "PCMAudio",
    "bytes_per_sample",
    "encode_samples",
    "decode_samples",
    "encode_wav",
    "decode_wav",
]

SampleFormat = Literal["s16le", "f32le"]
SAMPLE_FORMATS: tuple[SampleFormat, ...] = ("s16le", "f32le")

_BIG_ENDIAN = sys.byteorder == "big"
_WAVE_FORMAT_PCM = 0x0001
_WAVE_FORMAT_IEEE_FLOAT = 0x0003
_WAVE_FORMAT_EXTENSIBLE = 0xFFFE
_UNBOUNDED_CHUNK = 0xFFFFFFFF
_SUPPORTED_WAV = (
    "16-bit integer PCM (format tag 1) or 32-bit IEEE float (format tag 3), "
    "plain or WAVE_FORMAT_EXTENSIBLE"
)


def bytes_per_sample(format: SampleFormat) -> int:
    """2 for ``s16le``, 4 for ``f32le``."""
    if format == "s16le":
        return 2
    if format == "f32le":
        return 4
    raise ValueError(f"unknown sample format {format!r}; use 's16le' or 'f32le'")


def _to_s16(value: float) -> int:
    if value != value:  # NaN
        return 0
    if value <= -1.0:
        return -32768
    if value >= 1.0:
        return 32767
    # int() truncates toward zero.
    return int(value * 32768.0) if value < 0 else int(value * 32767.0)


def encode_samples(samples: Iterable[float], format: SampleFormat = "s16le") -> bytes:
    """Encodes float samples as little-endian PCM.

    ``s16le`` clamps to [-1, 1], scales negatives by 32768 and positives by
    32767, and truncates toward zero. ``f32le`` is IEEE 754 single precision.
    """
    encoded: array[int] | array[float]
    if format == "s16le":
        encoded = array("h", (_to_s16(float(value)) for value in samples))
    elif format == "f32le":
        encoded = array("f", (float(value) for value in samples))
    else:
        bytes_per_sample(format)  # raises
        raise AssertionError("unreachable")
    if _BIG_ENDIAN:
        encoded.byteswap()
    return encoded.tobytes()


def decode_samples(data: bytes | bytearray | memoryview, format: SampleFormat = "s16le") -> list[float]:
    """Decodes little-endian PCM to floats (``s16le`` divides by 32768)."""
    width = bytes_per_sample(format)
    if len(data) % width:
        raise ValueError(f"{len(data)} bytes is not a whole number of {format} samples")
    if format == "s16le":
        integers = array("h")
        integers.frombytes(bytes(data))
        if _BIG_ENDIAN:
            integers.byteswap()
        return [value / 32768.0 for value in integers]
    floats = array("f")
    floats.frombytes(bytes(data))
    if _BIG_ENDIAN:
        floats.byteswap()
    return floats.tolist()


@dataclass(frozen=True, repr=False)
class PCMAudio:
    """Mono little-endian PCM: raw ``data`` bytes at ``sample_rate`` in ``format``."""

    data: bytes
    sample_rate: int
    format: SampleFormat = "s16le"

    def __post_init__(self) -> None:
        if not isinstance(self.data, bytes):
            object.__setattr__(self, "data", bytes(self.data))
        width = bytes_per_sample(self.format)
        if isinstance(self.sample_rate, bool) or not isinstance(self.sample_rate, int):
            raise TypeError("sample_rate must be an int")
        if self.sample_rate <= 0:
            raise ValueError("sample_rate must be positive")
        if len(self.data) % width:
            raise ValueError(
                f"{len(self.data)} bytes is not a whole number of {self.format} samples"
            )

    def __repr__(self) -> str:
        return (
            f"PCMAudio(sample_rate={self.sample_rate}, format={self.format!r}, "
            f"samples={self.sample_count}, duration={self.duration:.3f}s)"
        )

    @property
    def bytes_per_sample(self) -> int:
        return bytes_per_sample(self.format)

    @property
    def sample_count(self) -> int:
        return len(self.data) // self.bytes_per_sample

    @property
    def duration(self) -> float:
        """Length in seconds."""
        return self.sample_count / self.sample_rate

    def samples(self) -> list[float]:
        """The samples as floats in [-1, 1]."""
        return decode_samples(self.data, self.format)

    @classmethod
    def from_samples(
        cls, samples: Iterable[float], sample_rate: int, format: SampleFormat = "s16le"
    ) -> PCMAudio:
        """Encodes float samples (see :func:`encode_samples`)."""
        return cls(encode_samples(samples, format), sample_rate, format)

    @classmethod
    def concat(
        cls,
        chunks: Iterable[PCMAudio],
        *,
        sample_rate: int | None = None,
        format: SampleFormat | None = None,
    ) -> PCMAudio:
        """Joins chunks that share a sample rate and format.

        ``sample_rate`` and ``format`` describe the result when ``chunks`` is
        empty; when given they must also match every chunk.
        """
        parts = list(chunks)
        rate = sample_rate if sample_rate is not None else (parts[0].sample_rate if parts else None)
        fmt = format if format is not None else (parts[0].format if parts else None)
        if rate is None or fmt is None:
            raise ValueError("concat of no chunks needs sample_rate and format")
        for part in parts:
            if part.sample_rate != rate or part.format != fmt:
                raise ValueError(
                    f"cannot join {part.format}@{part.sample_rate} audio with {fmt}@{rate}"
                )
        return cls(b"".join(part.data for part in parts), rate, fmt)

    def to_wav(self) -> bytes:
        """A mono WAV file (16-bit PCM for ``s16le``, 32-bit float for ``f32le``)."""
        return encode_wav(self)

    def write_wav(self, path: str | os.PathLike[str]) -> None:
        with open(path, "wb") as file:
            file.write(self.to_wav())

    @classmethod
    def from_wav(cls, data: bytes | bytearray | memoryview) -> PCMAudio:
        """Decodes a WAV file (see :func:`decode_wav`)."""
        return decode_wav(data)

    @classmethod
    def read_wav(cls, path: str | os.PathLike[str]) -> PCMAudio:
        with open(path, "rb") as file:
            return decode_wav(file.read())


def encode_wav(audio: PCMAudio) -> bytes:
    """RIFF/WAVE bytes with a 16-byte ``fmt`` chunk; mono."""
    if audio.format == "s16le":
        tag, bits = _WAVE_FORMAT_PCM, 16
    else:
        tag, bits = _WAVE_FORMAT_IEEE_FLOAT, 32
    block_align = bits // 8
    data = audio.data
    fmt = struct.pack(
        "<HHIIHH", tag, 1, audio.sample_rate, audio.sample_rate * block_align, block_align, bits
    )
    pad = b"\x00" if len(data) % 2 else b""
    riff_size = 4 + (8 + len(fmt)) + (8 + len(data) + len(pad))
    return b"".join(
        [
            b"RIFF",
            struct.pack("<I", riff_size),
            b"WAVE",
            b"fmt ",
            struct.pack("<I", len(fmt)),
            fmt,
            b"data",
            struct.pack("<I", len(data)),
            data,
            pad,
        ]
    )


def decode_wav(data: bytes | bytearray | memoryview) -> PCMAudio:
    """Reads 16-bit PCM or 32-bit float WAV (plain or extensible), any channels.

    Multichannel audio is averaged to mono in float and re-encoded in the
    source format. A ``data`` chunk sized ``0xFFFFFFFF`` or running past the
    end of the file is read to the end of the file, which is what a streamed
    WAV (``ark-voice tts -o -``) looks like.
    """
    raw = bytes(data)
    if len(raw) < 12 or raw[0:4] != b"RIFF" or raw[8:12] != b"WAVE":
        raise ValueError("not a WAV file: missing RIFF/WAVE header")

    fmt_chunk: bytes | None = None
    pcm: bytes | None = None
    position = 12
    while position + 8 <= len(raw):
        chunk_id = raw[position : position + 4]
        (size,) = struct.unpack_from("<I", raw, position + 4)
        body = position + 8
        if chunk_id == b"data":
            if size == _UNBOUNDED_CHUNK or body + size > len(raw):
                pcm = raw[body:]
                break
            pcm = raw[body : body + size]
        elif chunk_id == b"fmt ":
            if body + size > len(raw):
                raise ValueError("WAV fmt chunk is truncated")
            fmt_chunk = raw[body : body + size]
        position = body + size + (size & 1)

    if fmt_chunk is None or len(fmt_chunk) < 16:
        raise ValueError("WAV file has no valid fmt chunk")
    if pcm is None:
        raise ValueError("WAV file has no data chunk")

    tag, channels, sample_rate, _byte_rate, _block_align, bits = struct.unpack_from(
        "<HHIIHH", fmt_chunk, 0
    )
    if tag == _WAVE_FORMAT_EXTENSIBLE:
        if len(fmt_chunk) < 40:
            raise ValueError("WAVE_FORMAT_EXTENSIBLE fmt chunk is too short")
        extension_size, valid_bits = struct.unpack_from("<HH", fmt_chunk, 16)
        if extension_size < 22 or 18 + extension_size > len(fmt_chunk) or valid_bits != bits:
            raise ValueError("Invalid WAVE_FORMAT_EXTENSIBLE structure")
        guid = fmt_chunk[24:40]
        if guid not in (bytes.fromhex("0100000000001000800000aa00389b71"),
                        bytes.fromhex("0300000000001000800000aa00389b71")):
            raise ValueError("Unsupported WAVE_FORMAT_EXTENSIBLE subformat GUID")
        tag = guid[0]

    format: SampleFormat
    if tag == _WAVE_FORMAT_PCM and bits == 16:
        format = "s16le"
    elif tag == _WAVE_FORMAT_IEEE_FLOAT and bits == 32:
        format = "f32le"
    else:
        raise ValueError(
            f"unsupported WAV encoding (format tag {tag}, {bits}-bit); "
            f"supported: {_SUPPORTED_WAV}"
        )
    if channels < 1:
        raise ValueError("WAV file declares no channels")
    if sample_rate < 1:
        raise ValueError("WAV file declares no sample rate")

    frame_bytes = bytes_per_sample(format) * channels
    pcm = pcm[: len(pcm) - len(pcm) % frame_bytes]
    if channels == 1:
        return PCMAudio(pcm, sample_rate, format)

    samples = decode_samples(pcm, format)
    mono = [
        sum(samples[start : start + channels]) / channels
        for start in range(0, len(samples), channels)
    ]
    return PCMAudio(encode_samples(mono, format), sample_rate, format)
