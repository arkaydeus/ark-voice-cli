"""PCMAudio and WAV encode/decode."""

from __future__ import annotations

import math
import struct
from pathlib import Path

import pytest

from ark_voice import PCMAudio, decode_wav, encode_samples, encode_wav


def tone(count: int = 480, rate: int = 24000) -> list[float]:
    return [0.5 * math.sin(2 * math.pi * 440 * i / rate) for i in range(count)]


def test_pcm_audio_basics() -> None:
    audio = PCMAudio.from_samples([0.0, 0.5, -0.5, 1.0], 24000)
    assert audio.format == "s16le"
    assert audio.sample_count == 4
    assert audio.duration == pytest.approx(4 / 24000)
    assert audio.samples() == [0.0, 16383 / 32768, -0.5, 32767 / 32768]
    f32 = PCMAudio.from_samples([0.25, -1.0], 16000, "f32le")
    assert f32.bytes_per_sample == 4 and f32.samples() == [0.25, -1.0]
    assert "samples=4" in repr(audio)
    with pytest.raises(ValueError):
        PCMAudio(b"\x00\x00\x00", 24000)
    with pytest.raises(ValueError):
        PCMAudio(b"", 24000, "u8")  # type: ignore[arg-type]
    with pytest.raises(ValueError):
        PCMAudio(b"", 0)
    assert PCMAudio(bytearray(b"\x01\x00"), 8000).data == b"\x01\x00"


def test_concat() -> None:
    a = PCMAudio(b"\x01\x00", 24000)
    b = PCMAudio(b"\x02\x00\x03\x00", 24000)
    joined = PCMAudio.concat([a, b])
    assert joined.data == b"\x01\x00\x02\x00\x03\x00" and joined.sample_count == 3
    empty = PCMAudio.concat([], sample_rate=24000, format="f32le")
    assert empty.sample_count == 0 and empty.format == "f32le"
    with pytest.raises(ValueError):
        PCMAudio.concat([])
    with pytest.raises(ValueError):
        PCMAudio.concat([a, PCMAudio(b"\x00\x00", 16000)])


@pytest.mark.parametrize("fmt,tag,bits", [("s16le", 1, 16), ("f32le", 3, 32)])
def test_wav_round_trip(tmp_path: Path, fmt: str, tag: int, bits: int) -> None:
    audio = PCMAudio.from_samples(tone(), 24000, fmt)  # type: ignore[arg-type]
    wav = audio.to_wav()
    assert wav[:4] == b"RIFF" and wav[8:16] == b"WAVEfmt "
    assert struct.unpack_from("<IHHIIHH", wav, 16) == (16, tag, 1, 24000, 24000 * bits // 8, bits // 8, bits)
    assert struct.unpack_from("<4sI", wav, 36) == (b"data", len(audio.data))
    assert struct.unpack_from("<I", wav, 4)[0] == len(wav) - 8
    assert PCMAudio.from_wav(wav) == audio
    path = tmp_path / "x.wav"
    audio.write_wav(path)
    assert PCMAudio.read_wav(path) == audio


def _wav(fmt_chunk: bytes, data: bytes, data_size: int | None = None, extra: bytes = b"") -> bytes:
    size = len(data) if data_size is None else data_size
    body = b"WAVE" + extra + b"fmt " + struct.pack("<I", len(fmt_chunk)) + fmt_chunk
    body += b"data" + struct.pack("<I", size) + data
    return b"RIFF" + struct.pack("<I", len(body)) + body


def test_stereo_downmix_s16() -> None:
    left = [0.5, -0.5, 0.25, 0.0]
    right = [0.0, -0.5, -0.25, 1.0]
    interleaved = [value for pair in zip(left, right) for value in pair]
    data = encode_samples(interleaved, "s16le")
    fmt = struct.pack("<HHIIHH", 1, 2, 22050, 22050 * 4, 4, 16)
    audio = decode_wav(_wav(fmt, data))
    assert audio.format == "s16le" and audio.sample_rate == 22050 and audio.sample_count == 4
    decoded = [v / 32768 for v in struct.unpack("<8h", data)]
    expected = [(decoded[2 * i] + decoded[2 * i + 1]) / 2 for i in range(4)]
    assert audio.data == encode_samples(expected, "s16le")


def test_extensible_float_quad_downmix() -> None:
    frames = [[0.5, 0.5, 0.5, 0.5], [1.0, -1.0, 0.25, 0.75]]
    data = encode_samples([v for frame in frames for v in frame], "f32le")
    guid_tail = b"\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38\x9b\x71"
    fmt = struct.pack("<HHIIHHHHI", 0xFFFE, 4, 48000, 48000 * 16, 16, 32, 22, 32, 0x33)
    fmt += struct.pack("<H", 3) + guid_tail
    audio = decode_wav(_wav(fmt, data, extra=b"LIST" + struct.pack("<I", 3) + b"abc\x00"))
    assert audio.format == "f32le" and audio.sample_rate == 48000
    assert audio.samples() == [0.5, 0.25]


def test_streamed_wav_with_unbounded_data_size() -> None:
    audio = PCMAudio.from_samples(tone(100), 24000)
    fmt = struct.pack("<HHIIHH", 1, 1, 24000, 48000, 2, 16)
    assert decode_wav(_wav(fmt, audio.data, data_size=0xFFFFFFFF)) == audio
    # A size past the end of file also means "to end of file".
    assert decode_wav(_wav(fmt, audio.data, data_size=len(audio.data) + 1000)) == audio
    # A trailing partial sample is dropped.
    assert decode_wav(_wav(fmt, audio.data + b"\x01", data_size=0xFFFFFFFF)) == audio


def test_unsupported_wav_names_supported_encodings() -> None:
    fmt = struct.pack("<HHIIHH", 1, 1, 8000, 8000, 1, 8)
    with pytest.raises(ValueError, match="16-bit integer PCM.*32-bit IEEE float"):
        decode_wav(_wav(fmt, b"\x80\x80"))
    with pytest.raises(ValueError, match="RIFF"):
        decode_wav(b"not a wav file")
    with pytest.raises(ValueError, match="data chunk"):
        decode_wav(_wav(struct.pack("<HHIIHH", 1, 1, 8000, 16000, 2, 16), b"")[:-8])


def test_encode_wav_is_mono_fmt16() -> None:
    wav = encode_wav(PCMAudio(b"", 24000, "f32le"))
    assert len(wav) == 44 and struct.unpack_from("<HH", wav, 20) == (3, 1)
