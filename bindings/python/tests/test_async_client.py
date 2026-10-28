"""AsyncClient behaviour against the scripted fake server (plain asyncio.run)."""

from __future__ import annotations

import asyncio
import gc
from pathlib import Path
from typing import Any

import pytest

from ark_voice import (
    KIND_PCM,
    AsyncClient,
    AudioChunk,
    BadRequestError,
    ConnectionClosedError,
    ModelsMissingError,
    NotRunningError,
    PCMAudio,
    ServerError,
    SynthesisDone,
    TranscriptFinal,
    TranscriptPartial,
    UnsupportedVersionError,
)
from fakeserver import FakeServer, Peer, socket_dir

STATUS = {
    "event": "status",
    "version": 1,
    "synthesisModelLoaded": False,
    "transcriptionModelLoaded": True,
    "transcriptionModel": "parakeet",
    "requestsServed": 7,
    "uptimeSeconds": 2.0,
}


def test_handshake_and_housekeeping() -> None:
    def script(peer: Peer) -> None:
        peer.handshake(sample_rate=24000)
        peer.send_json(peer.expect("status"), STATUS)
        peer.send_json(peer.expect("voices"), {"event": "voices", "names": ["n"]})
        peer.done(peer.expect("unload"))
        peer.wait_closed()

    async def main(path: str) -> None:
        async with await AsyncClient.connect(path) as client:
            assert client.server_version == 1 and client.sample_rate == 24000
            assert client.socket_path == path
            status = await client.status()
            assert status.transcription_model == "parakeet" and status.requests_served == 7
            assert await client.voices() == ["n"]
            assert await client.unload() is None
        assert client.closed

    with FakeServer(script) as server:
        asyncio.run(main(server.path))


def test_version_mismatch() -> None:
    def script(peer: Peer) -> None:
        peer.handshake(version=3)
        peer.wait_closed()

    with FakeServer(script) as server, pytest.raises(UnsupportedVersionError):
        asyncio.run(AsyncClient.connect(server.path))


@pytest.mark.parametrize("code,cls", [("models-missing", ModelsMissingError), ("odd", ServerError)])
def test_error_mapping(code: str, cls: type) -> None:
    def script(peer: Peer) -> None:
        peer.handshake()
        peer.error(peer.expect("status"), code)
        peer.send_json(peer.expect("status"), STATUS)
        peer.wait_closed()

    async def main(path: str) -> None:
        async with await AsyncClient.connect(path) as client:
            with pytest.raises(ServerError) as caught:
                await client.status()
            assert type(caught.value) is cls and caught.value.code == code
            assert (await client.status()).version == 1

    with FakeServer(script) as server:
        asyncio.run(main(server.path))


def test_connection_level_error_and_eof() -> None:
    def script(peer: Peer) -> None:
        peer.handshake()
        peer.expect("tts")
        peer.expect("voices")
        peer.error(0, "bad-request", "garbage")
        peer.wait_closed()

    async def main(path: str) -> None:
        client = await AsyncClient.connect(path)
        stream = client.synthesize("x")
        voices = client.voices()
        with pytest.raises(BadRequestError) as caught:
            await voices
        assert caught.value.request_id == 0
        with pytest.raises(BadRequestError):
            await stream.__anext__()
        with pytest.raises(ConnectionClosedError):
            await client.status()
        await client.close()

    with FakeServer(script) as server:
        asyncio.run(main(server.path))


def test_eof_fails_pending() -> None:
    def script(peer: Peer) -> None:
        peer.handshake()
        peer.expect("status")

    async def main(path: str) -> None:
        client = await AsyncClient.connect(path)
        with pytest.raises(ConnectionClosedError):
            await client.status()
        with pytest.raises(ConnectionClosedError):
            client.synthesize("later")
        await client.close()

    with FakeServer(script) as server:
        asyncio.run(main(server.path))


def test_pipelined_interleaving_and_unknown_ids() -> None:
    upload = PCMAudio(b"\x00\x00" * 4, 16000)

    def script(peer: Peer) -> None:
        peer.handshake()
        tts = peer.expect("tts")
        stt = peer.expect("stt")
        assert peer.read_frame().kind == KIND_PCM
        assert peer.expect("end") == stt
        status = peer.expect("status")
        peer.send_json(77, {"event": "done"})
        peer.send_pcm(tts, b"\x01\x00")
        peer.send_json(stt, {"event": "partial", "text": "a"})
        peer.send_json(status, STATUS)
        peer.send_json(stt, {"event": "final", "text": "A"})
        peer.done(stt)
        peer.send_pcm(tts, b"\x02\x00")
        peer.done(tts, chunks=2, samples=2, seconds=2 / 24000)
        peer.wait_closed()

    async def main(path: str) -> None:
        async with await AsyncClient.connect(path) as client:
            synthesis = client.synthesize("hi")
            transcription = client.transcribe(upload)
            status = client.status()

            async def collect(stream: Any) -> list[Any]:
                return [event async for event in stream]

            tts_events, stt_events, status_value = await asyncio.gather(
                collect(synthesis), collect(transcription), status
            )
            assert status_value.requests_served == 7
            assert stt_events == [TranscriptPartial("a"), TranscriptFinal("A")]
            assert tts_events == [
                AudioChunk(PCMAudio(b"\x01\x00", 24000), 0),
                AudioChunk(PCMAudio(b"\x02\x00", 24000), 1),
                SynthesisDone(2, 2, 2 / 24000, 24000),
            ]

    with FakeServer(script) as server:
        asyncio.run(main(server.path))


def _cancel_script(peer: Peer) -> None:
    peer.handshake()
    tts = peer.expect("tts")
    peer.send_pcm(tts, b"\x01\x00")
    seen: set[str] = set()
    # The status request may be written before a finaliser-scheduled cancel.
    while seen != {"cancel", "status"}:
        request_id, message = peer.read_json()
        if message["op"] == "cancel":
            assert request_id == tts
            peer.send_pcm(tts, b"\x02\x00")
            peer.error(tts, "cancelled")
        else:
            assert message["op"] == "status"
            status_id = request_id
        seen.add(message["op"])
    peer.send_json(status_id, STATUS)
    peer.wait_closed()


def test_early_stop_with_async_with_cancels_and_drains() -> None:
    async def main(path: str) -> None:
        async with await AsyncClient.connect(path) as client:
            async with client.synthesize("long") as stream:
                async for event in stream:
                    assert isinstance(event, AudioChunk)
                    break
            assert [event async for event in stream] == []
            assert (await client.status()).version == 1
            assert stream._request.finished and not client._router.pending

    with FakeServer(_cancel_script) as server:
        asyncio.run(main(server.path))


def test_break_without_close_cancels_via_finaliser() -> None:
    async def main(path: str) -> None:
        async with await AsyncClient.connect(path) as client:
            async for event in client.synthesize("long"):
                assert isinstance(event, AudioChunk)
                break
            gc.collect()
            await asyncio.sleep(0)
            assert (await client.status()).version == 1
            for _ in range(100):
                if not client._router.pending:
                    break
                await asyncio.sleep(0.01)
            assert not client._router.pending

    with FakeServer(_cancel_script) as server:
        asyncio.run(main(server.path))


def test_uploads_and_helpers(tmp_path: Path) -> None:
    data = b"\x01\x02" * 200_000  # 400_000 bytes
    audio = PCMAudio(data, 48000)

    def script(peer: Peer) -> None:
        peer.handshake()
        request_id, message = peer.read_json()
        assert message == {"op": "stt", "format": "s16le", "sampleRate": 48000}
        sizes = []
        while (frame := peer.read_frame()).kind == KIND_PCM:
            sizes.append(len(frame.payload))
        assert sizes == [262144, 400_000 - 262144]
        assert frame.payload == b'{"op":"end"}'
        peer.send_json(request_id, {"event": "final", "text": "words"})
        peer.done(request_id)

        request_id, message = peer.read_json()
        assert message["op"] == "create-voice" and message["name"] == "v"
        assert peer.read_frame().kind == KIND_PCM
        peer.expect("end")
        peer.send_json(request_id, {"event": "voice-created", "path": "/p/v.safetensors"})
        peer.done(request_id)

        request_id = peer.expect("tts")
        peer.send_json(request_id, {"event": "audio-format", "sampleRate": 24000, "format": "s16le"})
        peer.send_pcm(request_id, b"\x05\x00")
        peer.done(request_id, chunks=1, samples=1, seconds=1 / 24000)
        peer.wait_closed()

    async def main(path: str) -> None:
        async with await AsyncClient.connect(path) as client:
            assert await client.transcribe_text(audio) == "words"
            assert await client.create_voice("v", PCMAudio(b"\x00\x00", 24000)) == "/p/v.safetensors"
            summary = await client.synthesize_to_wav("x", tmp_path / "o.wav")
            assert summary.samples == 1
            assert PCMAudio.read_wav(tmp_path / "o.wav").data == b"\x05\x00"

    with FakeServer(script) as server:
        asyncio.run(main(server.path))


def test_not_running() -> None:
    import os

    directory = socket_dir()
    with pytest.raises(NotRunningError):
        asyncio.run(AsyncClient.connect(os.path.join(directory, "none.sock")))
    os.rmdir(directory)
