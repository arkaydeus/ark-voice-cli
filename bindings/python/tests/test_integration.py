"""Against a real `ark-voice serve` (see conftest.server_socket).

Model-backed tests skip on ModelsMissingError. Only the server's default
recognizer is used; nothing is downloaded.
"""

from __future__ import annotations

import asyncio
import os
import secrets
import time
from pathlib import Path
from typing import Any, Iterator

import pytest

from ark_voice import (
    AsyncClient,
    AudioChunk,
    Client,
    ModelsMissingError,
    PCMAudio,
    ServerStatus,
    SynthesisDone,
    TranscriptFinal,
    TranscriptPartial,
)

pytestmark = pytest.mark.integration

FOX = "The quick brown fox jumps over the lazy dog."
LONG = " ".join(
    [
        "This is a deliberately long passage so that synthesis produces many chunks.",
        "It keeps going for several sentences, describing nothing in particular.",
        "The test stops listening after the first chunk and cancels the request.",
        "Then it checks that the connection still answers a status request.",
    ]
)
KEYWORDS = ("quick", "brown", "fox", "lazy", "dog")


@pytest.fixture(scope="module")
def client(server_socket: str) -> Iterator[Client]:
    with Client(server_socket) as connected:
        yield connected


@pytest.fixture(scope="module")
def fox(client: Client) -> dict[str, Any]:
    """One streamed synthesis of FOX, shared by the model-backed tests."""
    events: list[Any] = []
    try:
        for event in client.synthesize(FOX):
            events.append(event)
    except ModelsMissingError as error:
        pytest.skip(f"synthesis model missing: {error}")
    chunks = [event for event in events if isinstance(event, AudioChunk)]
    done = events[-1]
    assert isinstance(done, SynthesisDone)
    audio = PCMAudio.concat(event.audio for event in chunks)
    return {"events": events, "chunks": chunks, "done": done, "audio": audio}


def test_connect_status_voices_unload(server_socket: str) -> None:
    with Client(server_socket) as client:
        assert client.server_version == 1
        assert client.sample_rate == 24000
        status = client.status()
        assert isinstance(status, ServerStatus) and status.version == 1
        assert status.uptime_seconds >= 0
        assert isinstance(client.voices(), list)
        client.unload()
        after = client.status()
        assert not after.synthesis_model_loaded and not after.transcription_model_loaded


def test_synthesize_streaming(fox: dict[str, Any], tmp_path: Path) -> None:
    chunks, done, audio = fox["chunks"], fox["done"], fox["audio"]
    assert chunks, "no audio chunks"
    assert [chunk.index for chunk in chunks] == list(range(len(chunks)))
    assert all(chunk.audio.sample_rate == 24000 and chunk.audio.format == "s16le" for chunk in chunks)
    assert done.sample_rate == 24000
    assert done.chunks == len(chunks)
    assert audio.sample_count == done.samples > 0
    assert done.seconds == pytest.approx(done.samples / 24000)
    path = tmp_path / "fox.wav"
    audio.write_wav(path)
    assert PCMAudio.read_wav(path) == audio


def test_transcribe_default_model(client: Client, fox: dict[str, Any]) -> None:
    audio: PCMAudio = fox["audio"]
    assert audio.sample_rate == 24000
    try:
        events = list(client.transcribe(audio))
    except ModelsMissingError as error:
        pytest.skip(f"transcription model missing: {error}")
    assert all(isinstance(event, (TranscriptPartial, TranscriptFinal)) for event in events)
    finals = [event.text for event in events if isinstance(event, TranscriptFinal)]
    assert finals, f"no final transcript in {events}"
    text = finals[-1].lower()
    assert any(word in text for word in KEYWORDS), text


def test_pipelining(client: Client) -> None:
    try:
        stream = client.synthesize("Pipelining works.")
        status = client.status()  # answered while the synthesis is in flight
        voices = client.voices()
        events = list(stream)
    except ModelsMissingError as error:
        pytest.skip(f"synthesis model missing: {error}")
    assert status.version == 1
    assert isinstance(voices, list)
    assert isinstance(events[-1], SynthesisDone)
    assert any(isinstance(event, AudioChunk) for event in events)


def test_cancel_then_status(client: Client) -> None:
    try:
        with client.synthesize(LONG) as stream:
            for event in stream:
                if isinstance(event, AudioChunk):
                    break
            else:
                pytest.fail("synthesis finished without audio")
    except ModelsMissingError as error:
        pytest.skip(f"synthesis model missing: {error}")
    assert client.status().version == 1
    # The server ends the cancelled request; the client swallows that.
    deadline = time.monotonic() + 60
    while not stream._request.finished and time.monotonic() < deadline:
        client.status()
        time.sleep(0.05)
    assert stream._request.finished
    assert client.voices() is not None


def test_create_voice(client: Client, fox: dict[str, Any], server_socket: str) -> None:
    name = f"bindings-test-python-{secrets.token_hex(4)}"
    path = ""
    try:
        try:
            path = client.create_voice(name, fox["audio"])
        except ModelsMissingError as error:
            pytest.skip(f"voice model missing: {error}")
        assert path
        assert name in client.voices()
    finally:
        if path:
            created = Path(path)
            if created.parent.resolve() == (Path(server_socket).parent / "voices").resolve() and created.stem == name:
                created.unlink(missing_ok=True)
    assert name not in client.voices()


def test_async_client_round_trip(server_socket: str) -> None:
    async def main() -> None:
        async with await AsyncClient.connect(server_socket) as client:
            assert client.server_version == 1
            synthesis = client.synthesize_audio("Hello from asyncio.")
            status, voices = await asyncio.gather(client.status(), client.voices())
            assert status.version == 1 and isinstance(voices, list)
            try:
                result = await synthesis
            except ModelsMissingError as error:
                pytest.skip(f"synthesis model missing: {error}")
            assert result.audio.sample_count == result.summary.samples > 0

            async with client.synthesize(LONG) as stream:
                async for event in stream:
                    if isinstance(event, AudioChunk):
                        break
            assert (await client.status()).version == 1

    asyncio.run(main())


def test_default_binary_discovery(monkeypatch: pytest.MonkeyPatch) -> None:
    from conftest import REPO_ROOT, find_server_binary

    monkeypatch.setenv("ARK_VOICE_BINARY", "/somewhere/ark-voice")
    assert find_server_binary() == ("/somewhere/ark-voice", "ARK_VOICE_BINARY")
    monkeypatch.delenv("ARK_VOICE_BINARY")
    binary, reason = find_server_binary()
    default = REPO_ROOT / ".build" / "release" / "ark-voice"
    if default.exists():
        assert binary == str(default)
    else:
        assert binary is None and "ARK_VOICE_BINARY" in reason
    assert os.path.basename(str(default)) == "ark-voice"


def test_profile_root_is_removed_after_failure(fox: dict[str, Any]) -> None:
    from conftest import find_server_binary, running_server
    binary, reason = find_server_binary()
    if binary is None:
        pytest.skip(reason)
    voices = Path.home() / ".ark-voice-cli" / "voices"
    def snapshot() -> dict[str, bytes]:
        return {p.name: p.read_bytes() for p in voices.glob("*") if p.is_file()}
    before = snapshot()
    class InjectedFailure(Exception):
        pass
    directory = None
    try:
        with pytest.raises(InjectedFailure):
            with running_server(binary) as socket_path:
                directory = Path(socket_path).parent
                with Client(socket_path) as connected:
                    saved = Path(connected.create_voice("failure-test", fox["audio"]))
                    assert saved.parent == directory / "voices"
                    assert saved.exists()
                    raise InjectedFailure()
    except ModelsMissingError as error:
        pytest.skip(str(error))
    finally:
        assert directory is None or not directory.exists()
        assert snapshot() == before
