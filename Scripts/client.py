#!/usr/bin/env python3
"""Reference client for `ark-voice serve`, using only the standard library.

The point of this file is to show that the socket protocol needs nothing but a
socket and `struct`: control messages are JSON, audio is raw little-endian PCM,
and every frame carries the request it belongs to.

    ark-voice serve &
    ./Scripts/client.py speak "Hello from Python" out.wav
    ./Scripts/client.py transcribe recording.wav
    ./Scripts/client.py transcribe recording.wav parakeet-ultra

The socket defaults to ~/.ark-voice-cli/ark-voice.sock; set ARK_VOICE_SOCKET
to use another.
"""

import json
import os
import socket
import struct
import sys
import wave

MAGIC = 0x41
KIND_JSON = 0
KIND_PCM = 1
HEADER = struct.Struct("<BBHII")  # magic, kind, flags, request id, payload length
PROTOCOL_VERSION = 1
SYNTHESIS_RATE = 24_000
TRANSCRIPTION_RATE = 16_000


def default_socket_path():
    return os.path.expanduser("~/.ark-voice-cli/ark-voice.sock")


class ArkVoice:
    def __init__(self, path=None):
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.connect(path or default_socket_path())
        self.next_request = 1
        reply = self.request({"op": "hello", "version": PROTOCOL_VERSION})[0][0]
        if reply["event"] != "hello-ok":
            raise RuntimeError(reply.get("message", "handshake refused"))

    # -- framing ---------------------------------------------------------

    def send(self, kind, request_id, payload):
        self.socket.sendall(HEADER.pack(MAGIC, kind, 0, request_id, len(payload)) + payload)

    def send_json(self, request_id, message):
        self.send(KIND_JSON, request_id, json.dumps(message).encode())

    def read_frame(self):
        header = self.read_exactly(HEADER.size)
        magic, kind, _flags, request_id, length = HEADER.unpack(header)
        if magic != MAGIC:
            raise RuntimeError("not an ark-voice frame")
        return kind, request_id, self.read_exactly(length)

    def read_exactly(self, count):
        chunks = []
        remaining = count
        while remaining:
            chunk = self.socket.recv(remaining)
            if not chunk:
                raise RuntimeError("server closed the connection")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    # -- requests --------------------------------------------------------

    def request(self, message, audio=None, sample_format="s16le"):
        """Sends one request and collects everything the server answers with."""
        request_id = self.next_request
        self.next_request += 1
        self.send_json(request_id, message)

        if audio is not None:
            for offset in range(0, len(audio), 262_144):
                self.send(KIND_PCM, request_id, audio[offset : offset + 262_144])
            self.send_json(request_id, {"op": "end"})

        events, pcm = [], bytearray()
        while True:
            kind, frame_id, payload = self.read_frame()
            if frame_id != request_id:
                continue
            if kind == KIND_PCM:
                pcm += payload
                continue
            event = json.loads(payload)
            events.append(event)
            if event["event"] == "error":
                raise RuntimeError(f"{event.get('code')}: {event.get('message')}")
            if event["event"] in ("done", "hello-ok", "voices", "status"):
                break
        return events, bytes(pcm)

    def speak(self, text, voice=None, sample_format="s16le"):
        message = {"op": "tts", "text": text, "format": sample_format}
        if voice:
            message["voice"] = voice
        events, pcm = self.request(message)
        rate = next(
            (e["sampleRate"] for e in events if e["event"] == "audio-format"), SYNTHESIS_RATE
        )
        return rate, pcm

    def transcribe(self, pcm, sample_rate=TRANSCRIPTION_RATE, sample_format="s16le", model=None):
        message = {"op": "stt", "format": sample_format, "sampleRate": sample_rate}
        if model:
            message["model"] = model
        events, _ = self.request(message, audio=pcm)
        return next((e["text"] for e in events if e["event"] == "final"), "")

    def voices(self):
        return self.request({"op": "voices"})[0][0].get("names", [])

    def status(self):
        return self.request({"op": "status"})[0][0]


def read_wav_as_s16le(path):
    """Reads a 16-bit mono WAV. Other formats belong to a real audio library."""
    with wave.open(path, "rb") as source:
        if source.getnchannels() != 1 or source.getsampwidth() != 2:
            raise SystemExit(f"{path}: expected 16-bit mono WAV")
        return source.getframerate(), source.readframes(source.getnframes())


def main(argv):
    if len(argv) < 2:
        raise SystemExit(__doc__)
    command, args = argv[1], argv[2:]
    client = ArkVoice(os.environ.get("ARK_VOICE_SOCKET"))

    if command == "speak":
        text, destination = args[0], args[1]
        rate, pcm = client.speak(text)
        with wave.open(destination, "wb") as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(rate)
            output.writeframes(pcm)
        print(destination)
    elif command == "transcribe":
        rate, pcm = read_wav_as_s16le(args[0])
        model = args[1] if len(args) > 1 else None
        print(client.transcribe(pcm, sample_rate=rate, model=model))
    elif command == "voices":
        print("\n".join(client.voices()) or "No saved voices.")
    elif command == "status":
        print(json.dumps(client.status(), indent=2))
    else:
        raise SystemExit(f"unknown command '{command}'")


if __name__ == "__main__":
    main(sys.argv)
