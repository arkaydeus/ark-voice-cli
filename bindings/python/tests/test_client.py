"""Sync Client behaviour against a scripted fake server."""

from __future__ import annotations

import gc
import os
import socket
import threading
from pathlib import Path
from typing import Any

import pytest

from ark_voice import (
    KIND_PCM,
    AudioChunk,
    BadRequestError,
    Client,
    ConnectionClosedError,
    ModelsMissingError,
    NotRunningError,
    PCMAudio,
    ProtocolError,
    RequestCancelledError,
    ServerError,
    ServerFailedError,
    ServerStatus,
    SynthesisDone,
    TranscriptFinal,
    TranscriptPartial,
    UnknownRequestError,
    UnsupportedVersionError,
    default_socket_path,
    resolve_socket_path,
)
from fakeserver import FakeServer, Peer, socket_dir

STATUS = {
    "event": "status",
    "version": 1,
    "synthesisModelLoaded": True,
    "transcriptionModelLoaded": False,
    "requestsServed": 3,
    "uptimeSeconds": 1.5,
}


def test_handshake_sends_vector_bytes_and_reads_hello_ok(vectors: dict[str, Any]) -> None:
    hello_frame = bytes.fromhex(vectors["requests"][0]["frame"])

    def script(peer: Peer) -> None:
        raw = peer.conn.recv(len(hello_frame), socket.MSG_WAITALL)
        assert raw == hello_frame
        peer.send_json(1, {"event": "hello-ok", "version": 1, "sampleRate": 16000})
        peer.wait_closed()

    with FakeServer(script) as server, Client.connect(server.path) as client:
        assert client.server_version == 1
        assert client.sample_rate == 16000
        assert client.socket_path == server.path
        assert not client.closed
    assert client.closed


def test_hello_ok_with_other_version_raises() -> None:
    def script(peer: Peer) -> None:
        peer.handshake(version=2)
        peer.wait_closed()

    with FakeServer(script) as server, pytest.raises(UnsupportedVersionError) as caught:
        Client(server.path)
    assert caught.value.code == "unsupported-version"


def test_hello_error_raises_mapped_error() -> None:
    def script(peer: Peer) -> None:
        request_id = peer.expect("hello")
        peer.send_json(
            request_id,
            {"event": "error", "code": "unsupported-version", "message": "v1 only", "version": 1},
        )
        peer.wait_closed()

    with FakeServer(script) as server, pytest.raises(UnsupportedVersionError) as caught:
        Client(server.path)
    assert caught.value.message == "v1 only" and caught.value.request_id == 1


@pytest.mark.parametrize(
    "code,cls",
    [
        ("bad-request", BadRequestError),
        ("unsupported-version", UnsupportedVersionError),
        ("models-missing", ModelsMissingError),
        ("unknown-request", UnknownRequestError),
        ("cancelled", RequestCancelledError),
        ("failed", ServerFailedError),
        ("something-new", ServerError),
    ],
)
def test_error_codes_map_to_classes_and_connection_survives(code: str, cls: type) -> None:
    def script(peer: Peer) -> None:
        peer.handshake()
        peer.error(peer.expect("status"), code, "detail")
        peer.send_json(peer.expect("voices"), {"event": "voices", "names": ["a"]})
        peer.wait_closed()

    with FakeServer(script) as server, Client(server.path) as client:
        with pytest.raises(ServerError) as caught:
            client.status()
        assert type(caught.value) is cls
        assert caught.value.code == code
        assert caught.value.message == "detail"
        assert caught.value.request_id == 2
        assert client.voices() == ["a"]


def test_housekeeping_requests() -> None:
    def script(peer: Peer) -> None:
        peer.handshake()
        peer.send_json(peer.expect("status"), {**STATUS, "transcriptionModel": "qwen"})
        peer.send_json(peer.expect("voices"), {"event": "voices", "names": ["narrator", "robot"]})
        peer.done(peer.expect("unload"))
        peer.wait_closed()

    with FakeServer(script) as server, Client(server.path) as client:
        assert client.status() == ServerStatus(1, True, False, "qwen", 3, 1.5)
        assert client.voices() == ["narrator", "robot"]
        assert client.unload() is None


def test_connection_level_error_fails_every_pending_request() -> None:
    def script(peer: Peer) -> None:
        peer.handshake()
        peer.expect("tts")
        peer.expect("status")
        peer.error(0, "bad-request", "Frame payload exceeds the limit.")
        peer.wait_closed()

    with FakeServer(script) as server, Client(server.path) as client:
        stream = client.synthesize("hello")
        with pytest.raises(BadRequestError) as caught:
            client.status()
        assert caught.value.request_id == 0
        with pytest.raises(BadRequestError):
            next(stream)
        assert client.closed
        with pytest.raises(ConnectionClosedError):
            client.voices()


def test_eof_fails_pending_and_later_calls() -> None:
    def script(peer: Peer) -> None:
        peer.handshake()
        peer.expect("status")

    with FakeServer(script) as server, Client(server.path) as client:
        with pytest.raises(ConnectionClosedError):
            client.status()
        with pytest.raises(ConnectionClosedError):
            client.status()
        with pytest.raises(ConnectionClosedError):
            client.synthesize("x")


def test_malformed_frame_is_a_protocol_error() -> None:
    def script(peer: Peer) -> None:
        peer.handshake()
        peer.expect("status")
        peer.send_raw(b"\x42" + b"\x00" * 11)
        peer.wait_closed()

    with FakeServer(script) as server, Client(server.path) as client:
        with pytest.raises(ProtocolError) as caught:
            client.status()
        assert caught.value.reason == "bad-magic"
        with pytest.raises(ConnectionClosedError):
            client.status()


def test_frames_for_unknown_ids_are_ignored() -> None:
    def script(peer: Peer) -> None:
        peer.handshake()
        request_id = peer.expect("status")
        peer.send_json(99, {"event": "done"})
        peer.send_pcm(99, b"\x00\x00")
        peer.send_json(0, {"event": "status"})  # not an error: ignored
        peer.send_pcm(0, b"\x00\x00")
        peer.send_json(1, {"event": "hello-ok", "version": 1})  # finished request
        peer.send_json(request_id, STATUS)
        peer.wait_closed()

    with FakeServer(script) as server, Client(server.path) as client:
        assert client.status().requests_served == 3


def test_interleaved_pipelined_responses() -> None:
    upload = PCMAudio(b"\x01\x00" * 10, 16000)

    def script(peer: Peer) -> None:
        peer.handshake()
        tts = peer.expect("tts")
        stt = peer.expect("stt")
        frame = peer.read_frame()
        assert frame.kind == KIND_PCM and frame.request_id == stt
        assert peer.expect("end") == stt
        status = peer.expect("status")
        peer.send_json(tts, {"event": "audio-format", "sampleRate": 22050, "format": "s16le"})
        peer.send_json(stt, {"event": "partial", "text": " the"})
        peer.send_pcm(tts, b"\x01\x00\x02\x00")
        peer.send_json(status, STATUS)
        peer.send_json(stt, {"event": "partial", "text": " quick"})
        peer.send_pcm(tts, b"\x03\x00")
        peer.send_json(stt, {"event": "final", "text": "The quick"})
        peer.done(tts, chunks=2, samples=3, seconds=3 / 22050)
        peer.done(stt)
        peer.wait_closed()

    with FakeServer(script) as server, Client(server.path) as client:
        synthesis = client.synthesize("hi")
        transcription = client.transcribe(upload)
        assert synthesis.request_id == 2 and transcription.request_id == 3
        assert client.status().requests_served == 3
        assert list(transcription) == [
            TranscriptPartial(" the"),
            TranscriptPartial(" quick"),
            TranscriptFinal("The quick"),
        ]
        events = list(synthesis)
        assert events == [
            AudioChunk(PCMAudio(b"\x01\x00\x02\x00", 22050), 0),
            AudioChunk(PCMAudio(b"\x03\x00", 22050), 1),
            SynthesisDone(chunks=2, samples=3, seconds=3 / 22050, sample_rate=22050),
        ]
        assert synthesis.finished and transcription.finished


def test_threads_share_one_client() -> None:
    threads, calls = 4, 15

    def script(peer: Peer) -> None:
        peer.handshake()
        for _ in range(threads * calls):
            request_id = peer.expect("status")
            peer.send_json(request_id, {**STATUS, "requestsServed": request_id})
        peer.wait_closed()

    results: list[int] = []
    errors: list[BaseException] = []

    def worker(client: Client) -> None:
        try:
            for _ in range(calls):
                results.append(client.status().requests_served)
        except BaseException as error:  # noqa: BLE001
            errors.append(error)

    with FakeServer(script) as server, Client(server.path) as client:
        pool = [threading.Thread(target=worker, args=(client,)) for _ in range(threads)]
        for thread in pool:
            thread.start()
        for thread in pool:
            thread.join(10)
    assert not errors
    assert sorted(results) == list(range(2, 2 + threads * calls))


def _cancel_script(peer: Peer, after_cancel: str = "status") -> None:
    peer.handshake()
    tts = peer.expect("tts")
    peer.send_json(tts, {"event": "audio-format", "sampleRate": 24000, "format": "s16le"})
    peer.send_pcm(tts, b"\x01\x00")
    assert peer.expect("cancel") == tts
    # Late frames for the cancelled request must be discarded.
    peer.send_pcm(tts, b"\x02\x00")
    peer.send_json(tts, {"event": "error", "code": "cancelled", "message": "cancelled"})
    peer.send_json(tts, {"event": "error", "code": "unknown-request", "message": "late"})
    peer.send_json(peer.expect(after_cancel), STATUS)
    peer.wait_closed()


def test_early_stop_with_close_sends_cancel_and_drains() -> None:
    with FakeServer(_cancel_script) as server, Client(server.path) as client:
        with client.synthesize("a long text") as stream:
            first = next(stream)
            assert isinstance(first, AudioChunk)
        assert list(stream) == []
        assert client.status().requests_served == 3
        assert stream._request.finished
        assert stream.request_id not in client._router.pending


def test_breaking_out_of_a_for_loop_cancels() -> None:
    with FakeServer(_cancel_script) as server, Client(server.path) as client:
        for event in client.synthesize("a long text"):
            assert isinstance(event, AudioChunk)
            break
        gc.collect()
        assert client.status().requests_served == 3
        assert not client._router.pending


def test_no_cancel_after_terminal_event() -> None:
    def script(peer: Peer) -> None:
        peer.handshake()
        tts = peer.expect("tts")
        peer.done(tts, chunks=0, samples=0, seconds=0.0)
        peer.send_json(peer.expect("status"), STATUS)
        peer.expect_eof()  # in particular, no cancel for the finished stream

    with FakeServer(script) as server, Client(server.path) as client:
        stream = client.synthesize("x")
        assert client.status().version == 1  # reads the done for the stream too
        stream.close()
        del stream
        gc.collect()


def test_upload_chunking_and_transcribe_text() -> None:
    data = bytes(range(256)) * 2344 + b"\x00" * 16  # 600_080 bytes
    audio = PCMAudio(data, 44100)
    expected_sizes = [262144, 262144, len(data) - 2 * 262144]

    def script(peer: Peer) -> None:
        peer.handshake()
        request_id, message = peer.read_json()
        assert message == {"op": "stt", "format": "s16le", "sampleRate": 44100, "model": "parakeet"}
        received = bytearray()
        sizes = []
        while True:
            frame = peer.read_frame()
            assert frame.request_id == request_id
            if frame.kind != KIND_PCM:
                break
            sizes.append(len(frame.payload))
            received += frame.payload
        assert frame.payload == b'{"op":"end"}'
        assert sizes == expected_sizes and bytes(received) == data
        peer.send_json(request_id, {"event": "partial", "text": "hel"})
        peer.send_json(request_id, {"event": "final", "text": "hello"})
        peer.done(request_id)

        request_id, message = peer.read_json()
        assert message == {"op": "create-voice", "name": "narrator", "format": "f32le", "sampleRate": 24000}
        frame = peer.read_frame()
        assert frame.kind == KIND_PCM and len(frame.payload) == 8
        assert peer.expect("end") == request_id
        peer.send_json(request_id, {"event": "voice-created", "path": "/v/narrator.safetensors"})
        peer.done(request_id)

        request_id, message = peer.read_json()
        assert message == {"op": "stt", "format": "s16le", "sampleRate": 16000}
        assert peer.expect("end") == request_id  # empty audio: no pcm frames
        peer.done(request_id)
        peer.wait_closed()

    with FakeServer(script) as server, Client(server.path) as client:
        assert client.transcribe_text(audio, model="parakeet") == "hello"
        voice = PCMAudio.from_samples([0.1, 0.2], 24000, "f32le")
        assert client.create_voice("narrator", voice) == "/v/narrator.safetensors"
        assert client.transcribe_text(PCMAudio(b"", 16000)) == ""


def test_synthesize_audio_and_wav(tmp_path: Path) -> None:
    def script(peer: Peer) -> None:
        peer.handshake()
        for _ in range(2):
            request_id, message = peer.read_json()
            assert message == {"op": "tts", "text": "hi", "voice": "robot", "format": "f32le"}
            peer.send_json(request_id, {"event": "audio-format", "sampleRate": 24000, "format": "f32le"})
            peer.send_pcm(request_id, b"\x00\x00\x00\x3f")
            peer.send_pcm(request_id, b"\x00\x00\x80\x3e")
            peer.done(request_id, chunks=2, samples=2, seconds=2 / 24000)
        peer.wait_closed()

    with FakeServer(script) as server, Client(server.path) as client:
        result = client.synthesize_audio("hi", voice="robot", format="f32le")
        assert result.audio.samples() == [0.5, 0.25]
        assert result.summary.samples == result.audio.sample_count == 2
        path = tmp_path / "out.wav"
        summary = client.synthesize_to_wav("hi", path, voice="robot", format="f32le")
        assert summary.chunks == 2
        assert PCMAudio.read_wav(path) == result.audio


def test_transcribe_file(tmp_path: Path) -> None:
    audio = PCMAudio.from_samples([0.1] * 100, 16000)
    path = tmp_path / "in.wav"
    audio.write_wav(path)

    def script(peer: Peer) -> None:
        peer.handshake()
        request_id, message = peer.read_json()
        assert message == {"op": "stt", "format": "s16le", "sampleRate": 16000}
        frame = peer.read_frame()
        assert frame.payload == audio.data
        peer.expect("end")
        peer.send_json(request_id, {"event": "final", "text": "ok"})
        peer.done(request_id)
        peer.wait_closed()

    with FakeServer(script) as server, Client(server.path) as client:
        assert list(client.transcribe_file(path)) == [TranscriptFinal("ok")]


def test_not_running(monkeypatch: pytest.MonkeyPatch) -> None:
    directory = socket_dir()
    missing = os.path.join(directory, "missing.sock")
    with pytest.raises(NotRunningError, match="ark-voice serve"):
        Client(missing)
    # A stale socket file with no listener: ECONNREFUSED.
    stale = os.path.join(directory, "stale.sock")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.bind(stale)
    sock.close()
    with pytest.raises(NotRunningError) as caught:
        Client(stale)
    assert caught.value.socket_path == stale
    monkeypatch.setenv("ARK_VOICE_SOCKET", missing)
    with pytest.raises(NotRunningError) as caught:
        Client()
    assert caught.value.socket_path == missing
    os.unlink(stale)
    os.rmdir(directory)


def test_socket_path_resolution(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("ARK_VOICE_SOCKET", raising=False)
    assert default_socket_path() == os.path.expanduser("~/.ark-voice-cli/ark-voice.sock")
    assert resolve_socket_path() == default_socket_path()
    monkeypatch.setenv("ARK_VOICE_SOCKET", "/tmp/env.sock")
    assert resolve_socket_path() == "/tmp/env.sock"
    assert resolve_socket_path(Path("/tmp/arg.sock")) == "/tmp/arg.sock"
    monkeypatch.setenv("ARK_VOICE_SOCKET", "")
    assert resolve_socket_path() == default_socket_path()


def test_request_ids_wrap_and_skip_zero() -> None:
    from ark_voice._core import Router

    router = Router()
    router._next_id = 0xFFFFFFFF
    assert router.register("status").request_id == 0xFFFFFFFF
    assert router.register("status").request_id == 1
    assert router.register("status").request_id == 2


def test_reply_reaches_a_waiting_thread_while_another_thread_reads() -> None:
    status_returned = threading.Event()

    def script(peer: Peer) -> None:
        peer.handshake()
        tts = peer.expect("tts")
        status = peer.expect("status")
        peer.send_json(status, STATUS)
        # Audio only follows once the main thread has its status, so the
        # streaming thread is parked in recv while the status is delivered.
        assert status_returned.wait(5), "status() did not return while another thread read"
        peer.send_pcm(tts, b"\x01\x00")
        peer.done(tts, chunks=1, samples=1, seconds=1 / 24000)
        peer.wait_closed()

    with FakeServer(script) as server, Client(server.path) as client:
        stream = client.synthesize("hi")
        events: list[Any] = []
        reader = threading.Thread(target=lambda: events.extend(stream))
        reader.start()
        assert client.status().version == 1
        status_returned.set()
        reader.join(5)
        assert [type(event) for event in events] == [AudioChunk, SynthesisDone]


@pytest.mark.parametrize("operation,payload", [
    ("tts", b'{"op":"status"}'),
    ("tts", b'{"event":"done","samples":null}'),
    ("status", b'{"event":"status","uptimeSeconds":{}}'),
])
def test_malformed_control_fails_both_in_same_read(operation: str, payload: bytes) -> None:
    from ark_voice import KIND_JSON, encode_frame, encode_message
    def script(peer: Peer) -> None:
        peer.handshake()
        first = peer.expect(operation)
        second = peer.expect("status")
        peer.send_raw(encode_frame(KIND_JSON, first, payload) +
                      encode_frame(KIND_JSON, second, encode_message(STATUS)))
        peer.wait_closed()
    with FakeServer(script) as server, Client(server.path) as client:
        first = client._start(operation, {"op": operation})
        status = client._start("status", {"op": "status"})
        with pytest.raises(ProtocolError):
            client._wait(first)
        with pytest.raises(ProtocolError):
            client._wait(status)
        assert client.closed and not client._router.pending


@pytest.mark.parametrize("cut", [5, 14])
def test_truncated_eof_is_protocol_error(cut: int) -> None:
    from ark_voice import KIND_JSON, encode_frame
    def script(peer: Peer) -> None:
        peer.handshake()
        request = peer.expect("status")
        peer.send_raw(encode_frame(KIND_JSON, request, b'{"event":"status"}')[:cut])
    with FakeServer(script) as server, Client(server.path) as client:
        with pytest.raises(ProtocolError) as caught:
            client.status()
        assert caught.value.reason == "truncated"


def test_cancel_crosses_normal_reply_while_another_request_is_pending() -> None:
    def script(peer: Peer) -> None:
        peer.handshake()
        tts = peer.expect("tts")
        other = peer.expect("tts")
        peer.send_json(peer.expect("status"), STATUS)
        assert peer.expect("cancel") == tts
        peer.done(tts, chunks=0, samples=0, seconds=0)
        peer.error(tts, "unknown-request")
        peer.send_json(peer.expect("status"), STATUS)
        peer.done(other, chunks=0, samples=0, seconds=0)
        peer.expect_eof()
    with FakeServer(script) as server, Client(server.path) as client:
        stream = client.synthesize("cancel")
        other = client.synthesize("pending")
        client.status()
        stream.close()
        assert client.status().version == 1
        assert len(list(other)) == 1
        assert not client._router.pending
