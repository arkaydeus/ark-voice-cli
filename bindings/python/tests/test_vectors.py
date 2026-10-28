"""Every entry of bindings/test-vectors/protocol.json."""

from __future__ import annotations

import struct
from typing import Any

import pytest

from ark_voice import (
    HEADER_SIZE,
    KIND_JSON,
    KIND_PCM,
    MAX_PAYLOAD_SIZE,
    PROTOCOL_VERSION,
    FrameDecoder,
    ProtocolError,
    decode_message,
    decode_samples,
    encode_frame,
    encode_message,
    encode_samples,
    parse_header,
)


def test_constants(vectors: dict[str, Any]) -> None:
    assert vectors["protocolVersion"] == PROTOCOL_VERSION
    assert vectors["headerSize"] == HEADER_SIZE
    assert vectors["maximumPayloadSize"] == MAX_PAYLOAD_SIZE


def test_requests_encode_to_exact_bytes(vectors: dict[str, Any]) -> None:
    assert vectors["requests"]
    for entry in vectors["requests"]:
        payload = encode_message(entry["message"])
        assert payload == entry["payload"].encode("utf-8"), entry["name"]
        frame = encode_frame(KIND_JSON, entry["requestId"], payload)
        assert frame.hex() == entry["frame"], entry["name"]


def test_request_encoding_omits_none() -> None:
    assert encode_message({"op": "tts", "text": "Hi", "voice": None, "format": "f32le"}) == (
        b'{"format":"f32le","op":"tts","text":"Hi"}'
    )


def _decode_all(data: bytes, split: str) -> list[Any]:
    decoder = FrameDecoder()
    frames = []
    if split == "whole":
        frames.extend(decoder.feed(data))
    else:
        for index in range(len(data)):
            frames.extend(decoder.feed(data[index : index + 1]))
    assert decoder.buffered == 0
    return frames


@pytest.mark.parametrize("split", ["whole", "bytewise"])
def test_events_decode(vectors: dict[str, Any], split: str) -> None:
    for entry in vectors["events"]:
        frames = _decode_all(bytes.fromhex(entry["frame"]), split)
        assert len(frames) == 1, entry["name"]
        frame = frames[0]
        assert frame.kind == KIND_JSON
        assert frame.request_id == entry["requestId"]
        assert decode_message(frame.payload) == entry["message"], entry["name"]
        header = parse_header(bytes.fromhex(entry["frame"])[:HEADER_SIZE])
        assert header.payload_length == len(frame.payload)


@pytest.mark.parametrize("split", ["whole", "bytewise"])
def test_pcm_frames_decode(vectors: dict[str, Any], split: str) -> None:
    for entry in vectors["pcmFrames"]:
        frames = _decode_all(bytes.fromhex(entry["frame"]), split)
        assert len(frames) == 1, entry["name"]
        frame = frames[0]
        assert frame.kind == entry["kind"] == KIND_PCM
        assert frame.request_id == entry["requestId"]
        assert frame.payload.hex() == entry["payload"]
        assert encode_frame(KIND_PCM, entry["requestId"], frame.payload).hex() == entry["frame"]


@pytest.mark.parametrize("split", ["whole", "bytewise"])
def test_all_frames_concatenated(vectors: dict[str, Any], split: str) -> None:
    entries = vectors["requests"] + vectors["events"] + vectors["pcmFrames"]
    stream = b"".join(bytes.fromhex(entry["frame"]) for entry in entries)
    frames = _decode_all(stream, split)
    assert len(frames) == len(entries)
    for frame, entry in zip(frames, entries):
        assert frame.request_id == entry["requestId"], entry["name"]
        assert frame.encode().hex() == entry["frame"], entry["name"]


def test_invalid_headers(vectors: dict[str, Any]) -> None:
    for entry in vectors["invalidHeaders"]:
        header = bytes.fromhex(entry["header"])
        with pytest.raises(ProtocolError) as caught:
            parse_header(header)
        assert caught.value.reason == entry["error"], entry["name"]
        with pytest.raises(ProtocolError) as caught:
            FrameDecoder().feed(header)
        assert caught.value.reason == entry["error"], entry["name"]


def test_valid_headers(vectors: dict[str, Any]) -> None:
    for entry in vectors["validHeaders"]:
        header = parse_header(bytes.fromhex(entry["header"]))
        assert header.kind == entry["kind"]
        assert header.request_id == entry["requestId"]
        assert header.payload_length == entry["payloadLength"]


def test_truncated() -> None:
    with pytest.raises(ProtocolError) as caught:
        parse_header(b"\x41\x00\x00")
    assert caught.value.reason == "truncated"
    decoder = FrameDecoder()
    assert decoder.feed(struct.pack("<BBHII", 0x41, 0, 0, 1, 10) + b"abc") == []
    with pytest.raises(ProtocolError) as caught:
        decoder.finish()
    assert caught.value.reason == "truncated"


def test_samples(vectors: dict[str, Any]) -> None:
    samples = vectors["samples"]
    encode = samples["s16leEncode"]
    assert encode_samples(encode["floats"], "s16le").hex() == encode["hex"]
    decode = samples["s16leDecode"]
    assert decode_samples(bytes.fromhex(decode["hex"]), "s16le") == decode["floats"]
    f32 = samples["f32le"]
    assert encode_samples(f32["floats"], "f32le").hex() == f32["hex"]
    assert decode_samples(bytes.fromhex(f32["hex"]), "f32le") == f32["floats"]
