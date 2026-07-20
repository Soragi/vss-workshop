#!/usr/bin/python3
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

"""Serve cached, Cosmos-compatible analysis copies of VST MP4 clips."""

from __future__ import annotations

import hashlib
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler
from http.server import ThreadingHTTPServer
import os
from pathlib import Path
import re
import subprocess
import threading
from urllib.parse import unquote
from urllib.parse import urlsplit


BIND_ADDRESS = os.environ.get("ANALYSIS_PROXY_BIND", "127.0.0.1")
PORT = int(os.environ.get("ANALYSIS_PROXY_PORT", "30900"))
INPUT_ROOT = Path(os.environ.get("ANALYSIS_INPUT_DIR", "/input"))
CACHE_ROOT = Path(os.environ.get("ANALYSIS_CACHE_DIR", "/output"))
VIDEO_PREFIX = "/vst/storage/temp_files/"
MAX_TRANSCODE_SECONDS = int(os.environ.get("ANALYSIS_TRANSCODE_TIMEOUT", "180"))
RANGE_PATTERN = re.compile(r"^bytes=(\d*)-(\d*)$")

_locks_guard = threading.Lock()
_locks: dict[str, threading.Lock] = {}


def output_lock(cache_key: str) -> threading.Lock:
    with _locks_guard:
        return _locks.setdefault(cache_key, threading.Lock())


def source_for_request(request_path: str) -> Path:
    path = unquote(urlsplit(request_path).path)
    if not path.startswith(VIDEO_PREFIX):
        raise FileNotFoundError("Only VST temporary MP4 clips are supported.")

    relative_name = path.removeprefix(VIDEO_PREFIX)
    if not relative_name or Path(relative_name).name != relative_name:
        raise FileNotFoundError("Invalid video path.")
    if Path(relative_name).suffix.lower() != ".mp4":
        raise FileNotFoundError("Only MP4 clips are supported.")

    source = INPUT_ROOT / relative_name
    if not source.is_file():
        raise FileNotFoundError("The VST clip is not ready.")
    return source


def cache_path_for(source: Path) -> Path:
    stat = source.stat()
    identity = f"{source.name}:{stat.st_size}:{stat.st_mtime_ns}".encode()
    cache_key = hashlib.sha256(identity).hexdigest()[:24]
    return CACHE_ROOT / f"{cache_key}.mp4"


def transcode_for_cosmos(source: Path, destination: Path) -> None:
    CACHE_ROOT.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(
        f".{destination.stem}-{os.getpid()}-{threading.get_ident()}.tmp.mp4"
    )
    command = [
        "gst-launch-1.0",
        "-q",
        "-e",
        "filesrc",
        f"location={source}",
        "!",
        "qtdemux",
        "!",
        "h264parse",
        "!",
        "nvh264dec",
        "!",
        "videoconvert",
        "!",
        "videoscale",
        "add-borders=true",
        "!",
        "video/x-raw,width=1920,height=1080,pixel-aspect-ratio=1/1",
        "!",
        "x264enc",
        "speed-preset=ultrafast",
        "tune=zerolatency",
        "bitrate=4000",
        "key-int-max=60",
        "!",
        "h264parse",
        "!",
        "qtmux",
        "faststart=true",
        "!",
        "filesink",
        f"location={temporary}",
    ]

    try:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=MAX_TRANSCODE_SECONDS,
        )
        if completed.returncode != 0 or not temporary.is_file():
            raise RuntimeError("GStreamer could not create the analysis copy.")
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def analysis_copy(source: Path) -> Path:
    destination = cache_path_for(source)
    if destination.is_file():
        return destination

    with output_lock(destination.name):
        if not destination.is_file():
            transcode_for_cosmos(source, destination)
    return destination


def requested_byte_range(header: str | None, size: int) -> tuple[int, int] | None:
    if not header:
        return None
    match = RANGE_PATTERN.fullmatch(header.strip())
    if not match:
        raise ValueError("Unsupported Range header.")

    start_text, end_text = match.groups()
    if not start_text:
        length = int(end_text)
        if length <= 0:
            raise ValueError("Invalid suffix range.")
        return max(0, size - length), size - 1

    start = int(start_text)
    end = int(end_text) if end_text else size - 1
    if start >= size or start > end:
        raise ValueError("Range is outside the file.")
    return start, min(end, size - 1)


class AnalysisHandler(BaseHTTPRequestHandler):
    server_version = "VSSAnalysisProxy/1.0"

    def do_GET(self) -> None:  # noqa: N802
        self._serve(send_body=True)

    def do_HEAD(self) -> None:  # noqa: N802
        self._serve(send_body=False)

    def _serve(self, *, send_body: bool) -> None:
        if urlsplit(self.path).path == "/health":
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", "3")
            self.end_headers()
            if send_body:
                self.wfile.write(b"ok\n")
            return

        try:
            source = source_for_request(self.path)
            video = analysis_copy(source)
            size = video.stat().st_size
            byte_range = requested_byte_range(self.headers.get("Range"), size)
        except FileNotFoundError as error:
            self.send_error(HTTPStatus.NOT_FOUND, str(error))
            return
        except ValueError as error:
            self.send_error(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE, str(error))
            return
        except (RuntimeError, subprocess.TimeoutExpired):
            self.send_error(
                HTTPStatus.UNPROCESSABLE_ENTITY,
                "The H.264 workshop clip could not be prepared for video analysis.",
            )
            return

        start, end = byte_range or (0, size - 1)
        length = end - start + 1
        self.send_response(HTTPStatus.PARTIAL_CONTENT if byte_range else HTTPStatus.OK)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if byte_range:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if not send_body:
            return

        with video.open("rb") as stream:
            stream.seek(start)
            remaining = length
            while remaining:
                chunk = stream.read(min(1024 * 1024, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)

    def log_message(self, message_format: str, *args) -> None:
        print(f"analysis-proxy: {message_format % args}", flush=True)


def main() -> None:
    CACHE_ROOT.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer((BIND_ADDRESS, PORT), AnalysisHandler)
    server.daemon_threads = True
    print(f"VSS analysis proxy listening on {BIND_ADDRESS}:{PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
