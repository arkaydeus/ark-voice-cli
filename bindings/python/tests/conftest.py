from __future__ import annotations

import json
import os
import shutil
import signal
import socket
import subprocess
import time
from pathlib import Path
from typing import Any, Iterator

import pytest

from fakeserver import socket_dir

BINDING_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = BINDING_ROOT.parents[1]
VECTORS_PATH = REPO_ROOT / "bindings" / "test-vectors" / "protocol.json"


@pytest.fixture(scope="session")
def vectors() -> dict[str, Any]:
    with open(VECTORS_PATH, encoding="utf-8") as file:
        data: dict[str, Any] = json.load(file)
    return data


def find_server_binary() -> tuple[str | None, str]:
    """$ARK_VOICE_BINARY, else <repo>/.build/release/ark-voice; with a reason when absent."""
    from_env = os.environ.get("ARK_VOICE_BINARY")
    if from_env:
        return from_env, "ARK_VOICE_BINARY"
    candidate = REPO_ROOT / ".build" / "release" / "ark-voice"
    if candidate.exists():
        return str(candidate), "default release build"
    return None, (
        "no ark-voice binary: set ARK_VOICE_BINARY or build "
        f"{candidate} (with mlx.metallib beside it)"
    )


def _connectable(path: str) -> bool:
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        probe.connect(path)
        return True
    except OSError:
        return False
    finally:
        probe.close()


@pytest.fixture(scope="session")
def server_socket() -> Iterator[str]:
    """Starts `ark-voice serve` on a fresh socket for the integration tests."""
    binary, source = find_server_binary()
    if binary is None:
        pytest.skip(source)
    if not os.access(binary, os.X_OK):
        pytest.skip(f"ark-voice binary from {source} is not executable: {binary}")

    directory = socket_dir()
    path = os.path.join(directory, "ark-voice.sock")
    log_path = os.path.join(directory, "server.log")
    log = open(log_path, "wb")
    process = subprocess.Popen(
        [binary, "serve", "--socket", path, "--idle-unload", "off"],
        stdout=log,
        stderr=subprocess.STDOUT,
    )
    try:
        deadline = time.monotonic() + 15
        while not (os.path.exists(path) and _connectable(path)):
            if process.poll() is not None or time.monotonic() > deadline:
                log.flush()
                with open(log_path, encoding="utf-8", errors="replace") as file:
                    output = file.read()
                pytest.fail(f"ark-voice serve did not start ({binary}):\n{output}")
            time.sleep(0.05)
        yield path
    finally:
        if process.poll() is None:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        log.close()
        shutil.rmtree(directory, ignore_errors=True)
