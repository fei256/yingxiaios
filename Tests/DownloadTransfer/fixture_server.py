"""Loopback HTTP fixtures; no download implementation lives in this module."""

from __future__ import annotations

import gzip
import json
import re
import socket
import threading
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


FILE_BODY = b"\x00\x00\x00\x18ftypisom" + bytes(range(256)) * 16
RANGE_BODY = (FILE_BODY + bytes(range(256)) * 32_769)[: (8 << 20) + 333]
VIDEO_BODY = bytes((index * 13 + 7) % 256 for index in range(288))
AUDIO_BODY = bytes((index * 17 + 3) % 256 for index in range(160))
KEY_BODY = bytes(range(16))
LEGACY_VIDEO = [b"\x47" + bytes([index + 1]) * 375 for index in range(2)]
LEGACY_AUDIO = [bytes([index + 9]) * 192 for index in range(2)]


def media_playlist(audio: bool = False, legacy: bool = False) -> str:
    if legacy:
        extension = "aac" if audio else "ts"
        track = "audio" if audio else "video"
        return (
            "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n"
            "#EXT-X-MEDIA-SEQUENCE:0\n"
            f"#EXTINF:4,\n{track}-0.{extension}\n"
            f"#EXTINF:4,\n{track}-1.{extension}\n#EXT-X-ENDLIST\n"
        )
    length = 64 if audio else 128
    resource = "audio.bin" if audio else "video.bin"
    return (
        "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:4\n"
        "#EXT-X-MEDIA-SEQUENCE:7\n"
        '#EXT-X-KEY:IV=0x00000000000000000000000000000007,KEYFORMAT="identity",'
        'METHOD=AES-128,URI="key.key"\n'
        f'#EXT-X-MAP:URI="{resource}",BYTERANGE="32@0"\n'
        f"#EXTINF:4,\n#EXT-X-BYTERANGE:{length}@32\n{resource}\n"
        f"#EXTINF:4,\n#EXT-X-BYTERANGE:{length}\n{resource}\n#EXT-X-ENDLIST\n"
    )


def master_playlist(family: str) -> str:
    default = "missing.m3u8" if family == "hls-fallback" else "audio.m3u8"
    fallback = (
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="sound",NAME="Alternative",'
        'AUTOSELECT=YES,URI="other.m3u8"\n'
    )
    if family == "hls-inband":
        default_line = (
            '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="sound",NAME="Main",'
            "DEFAULT=YES,AUTOSELECT=YES\n"
        )
    else:
        default_line = (
            '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="sound",NAME="中文, Main",'
            f'DEFAULT=YES,AUTOSELECT=YES,LANGUAGE="zh",URI="{default}"\n'
        )
    if family == "hls-autoselect":
        default_line = default_line.replace("DEFAULT=YES", "DEFAULT=NO").replace(
            "AUTOSELECT=YES", "AUTOSELECT=NO"
        )
    if family == "hls-unsupported":
        return (
            '#EXTM3U\n#EXT-X-SESSION-KEY:METHOD=AES-128,URI="key.key"\n'
            + fallback
            + default_line
            + '#EXT-X-STREAM-INF:BANDWIDTH=3000000,AUDIO="sound"\nvideo.m3u8\n'
        )
    return (
        "#EXTM3U\n#EXT-X-VERSION:7\n"
        + fallback
        + default_line
        + '#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=640x360\nlow.m3u8\n'
        + '#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1920x1080,'
        'CODECS="avc1.640028,mp4a.40.2",AUDIO="sound",SUBTITLES="subs"\n'
        "video.m3u8\n"
    )


class FixtureState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.condition = threading.Condition(self.lock)
        self.requests: list[dict] = []
        self.pending: set[int] = set()
        self.whole_attempts: dict[str, int] = {}
        self.held: dict[str, threading.Event] = {}

    def configure(self, command: dict) -> None:
        with self.lock:
            if command.get("reset"):
                for gate in self.held.values():
                    gate.set()
                self.held.clear()
                self.requests.clear()
                self.whole_attempts.clear()
            for path in command.get("release", []):
                gate = self.held.pop(path, None)
                if gate:
                    gate.set()
            for path in command.get("hold", []):
                self.held[path] = threading.Event()

    def record(self, path: str, headers) -> tuple[dict, int, threading.Event | None]:
        with self.lock:
            entry = {
                "path": path,
                "range": headers.get("Range"),
                "acceptEncoding": headers.get("Accept-Encoding"),
                "fixtureHeader": headers.get("X-Download-Fixture"),
                "status": 0,
                "sent": 0,
            }
            self.requests.append(entry)
            self.pending.add(id(entry))
            if headers.get("Range") is None:
                self.whole_attempts[path] = self.whole_attempts.get(path, 0) + 1
            return entry, self.whole_attempts.get(path, 0), self.held.get(path)

    def update(self, entry: dict, **values) -> None:
        with self.lock:
            entry.update(values)

    def snapshot(self) -> dict:
        with self.condition:
            self.condition.wait_for(lambda: not self.pending, timeout=3)
            return {"requests": [entry.copy() for entry in self.requests]}

    def complete(self, entry: dict) -> None:
        with self.condition:
            self.pending.discard(id(entry))
            self.condition.notify_all()

    def release_all(self) -> None:
        with self.lock:
            for gate in self.held.values():
                gate.set()
            self.held.clear()


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = False
    allow_reuse_address = True

    def __init__(self) -> None:
        self.state = FixtureState()
        super().__init__(("127.0.0.1", 0), FixtureHandler)


class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self) -> None:
        super().setup()
        self.connection.settimeout(3)

    def log_message(self, _format: str, *_args) -> None:
        pass

    def handle(self) -> None:
        try:
            super().handle()
        except (ConnectionResetError, BrokenPipeError, TimeoutError):
            pass

    @property
    def state(self) -> FixtureState:
        return self.server.state

    def reply(
        self,
        body: bytes,
        status: int = 200,
        headers: dict[str, str] | None = None,
        *,
        declared: int | None = None,
        unknown: bool = False,
        chunked: bool = False,
        gate: threading.Event | None = None,
        entry: dict | None = None,
    ) -> None:
        self.send_response(status)
        response_headers = dict(headers or {})
        self.send_header("Content-Type", response_headers.pop("Content-Type", "application/octet-stream"))
        self.send_header("Cache-Control", "no-store")
        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
        elif not unknown:
            self.send_header("Content-Length", str(len(body) if declared is None else declared))
        for key, value in response_headers.items():
            self.send_header(key, value)
        if unknown or declared is not None:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        if entry is not None:
            self.state.update(entry, status=status)
        try:
            if gate is not None:
                count = min(16, len(body)) if self.headers.get("Range") else min(1024, len(body))
                self.wfile.write(body[:count])
                self.wfile.flush()
                if entry is not None:
                    self.state.update(entry, sent=count)
                if not gate.wait(15):
                    self.close_connection = True
                    return
                self.wfile.write(body[count:])
            elif chunked:
                for start in range(0, len(body), 257):
                    piece = body[start : start + 257]
                    self.wfile.write(f"{len(piece):x}\r\n".encode() + piece + b"\r\n")
                self.wfile.write(b"0\r\n\r\n")
            else:
                self.wfile.write(body)
            self.wfile.flush()
            if entry is not None:
                self.state.update(entry, sent=len(body))
        except (BrokenPipeError, ConnectionResetError, TimeoutError, OSError):
            self.close_connection = True
        if declared is not None:
            try:
                self.connection.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    def do_POST(self) -> None:
        if urlsplit(self.path).path != "/control":
            self.reply(b"missing", 404)
            return
        command = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        self.state.configure(command)
        self.reply(b"{}")

    def do_GET(self) -> None:
        path = urlsplit(self.path).path
        if path == "/stats":
            self.reply(json.dumps(self.state.snapshot()).encode())
            return
        entry, attempt, gate = self.state.record(path, self.headers)
        try:
            self.serve_fixture(path, entry, attempt, gate)
        finally:
            self.state.complete(entry)

    def serve_fixture(self, path: str, entry: dict, attempt: int, gate: threading.Event | None) -> None:
        if self.headers.get("X-Download-Fixture") != "allowed":
            self.reply(b"missing fixture header", 403, entry=entry)
            return
        family, _, leaf = path.lstrip("/").partition("/")
        if family.startswith("hls") and leaf.endswith(".m3u8"):
            if leaf == "missing.m3u8":
                self.reply(b"expired", 404, entry=entry)
                return
            if leaf == "master.m3u8":
                text = master_playlist(family)
            else:
                text = media_playlist(leaf in ("audio.m3u8", "other.m3u8"), family == "hls-legacy")
                if family == "hls-bad-audio" and leaf in ("audio.m3u8", "other.m3u8"):
                    text = text.replace("METHOD=AES-128", "METHOD=SAMPLE-AES")
            self.reply(text.encode(), headers={"Content-Type": "application/vnd.apple.mpegurl"}, entry=entry)
            return
        if family.startswith("hls"):
            body = {"video.bin": VIDEO_BODY, "audio.bin": AUDIO_BODY, "key.key": KEY_BODY}.get(leaf)
            if family == "hls-bad-key" and leaf == "key.key":
                body = KEY_BODY[:7]
            match = re.fullmatch(r"(video|audio)-([01])\.(ts|aac)", leaf)
            if match:
                body = (LEGACY_VIDEO if match[1] == "video" else LEGACY_AUDIO)[int(match[2])]
            if body is None:
                self.reply(b"missing", 404, entry=entry)
                return
        elif path.startswith("/range"):
            body = RANGE_BODY
        elif path.endswith(".mp4"):
            body = FILE_BODY
        else:
            self.reply(b"missing", 404, entry=entry)
            return
        ranged = path.startswith("/range") or family.startswith("hls")
        range_header = self.headers.get("Range")
        if range_header and ranged:
            match = re.fullmatch(r"bytes=(\d+)-(\d+)", range_header)
            if not match:
                self.reply(b"invalid range", 416, entry=entry)
                return
            first, last = int(match[1]), min(int(match[2]), len(body) - 1)
            if first > last:
                self.reply(b"invalid range", 416, entry=entry)
                return
            probe = first == 0 and int(match[2]) == 65_535
            if path == "/range-ignore.mp4" and not probe:
                self.reply(body, entry=entry)
                return
            headers = {}
            if path == "/range-versioned.mp4":
                headers["ETag"] = '"current"'
                if self.headers.get("If-Match", '"current"') != '"current"':
                    self.reply(b"version changed", 412, entry=entry)
                    return
            answered_first = first + 1 if path == "/range-mismatch.mp4" and not probe else first
            self.reply(
                body[first : last + 1],
                206,
                {**headers, "Content-Range": f"bytes {answered_first}-{last}/{len(body)}"},
                gate=gate,
                entry=entry,
            )
            return
        if path in ("/plain-retry.mp4", "/mirror-broken.mp4") and not range_header and attempt == 1:
            self.reply(body[:1024], declared=len(body), entry=entry)
        elif path == "/coded.mp4":
            self.reply(gzip.compress(body, mtime=0), headers={"Content-Encoding": "gzip"}, entry=entry)
        elif path == "/unknown.mp4":
            self.reply(body, unknown=True, entry=entry)
        elif path == "/chunked.mp4":
            self.reply(body, chunked=True, entry=entry)
        else:
            self.reply(body, gate=gate if not range_header else None, entry=entry)


@contextmanager
def running_server():
    server = FixtureServer()
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05})
    thread.start()
    try:
        yield server, f"http://127.0.0.1:{server.server_port}"
    finally:
        server.state.release_all()
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        if thread.is_alive():
            raise RuntimeError("The fixture HTTP server did not stop")
