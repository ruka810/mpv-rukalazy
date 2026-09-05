#!/usr/bin/env python3
"""Session-only ffmpeg/yt-dlp bridge for mpv realtime Whisper subtitles.

The service owns only process memory.  It resolves webpage audio through the
same mpv Cookie Bridge used for playback, captures PCM through ffmpeg's
stdout, and sends that byte stream to whisper-server without creating media,
cookie, or subtitle files.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parent
WORKSPACE = ROOT.parent.parent
# Same publish_v13 build the bilibili scripts depend on (current Chrome
# extension protocol); the older v12 build could not reach the extension.
COOKIE_BRIDGE = ROOT / "chrome_cookie_bridge" / "publish_v13" / "mpv-cookie-bridge.exe"
MAX_REQUEST_BYTES = 128 * 1024
# A WAV is 44 bytes of header + 16-bit mono PCM at 16 kHz (32000 B/s).  When a
# capture seeks past the audio stream's end, ffmpeg emits a header-only (or
# trivially short) WAV.  Such a clip must never be sent to Whisper, which
# rejects it as an invalid request.  1024 bytes (~0.03 s) still filters out the
# empty WAV while never dropping a meaningful final chunk.
MIN_AUDIO_BYTES = 1024

# Persistent live-capture session parameters.  One long-lived ffmpeg reader
# follows the live edge and appends 16 kHz mono PCM into an in-memory ring
# buffer; every /transcribe request slices the newest window out of it, which
# removes per-chunk connection setup and keeps coverage gapless.
LIVE_SAMPLE_RATE = 16000
LIVE_BYTES_PER_SECOND = LIVE_SAMPLE_RATE * 2
LIVE_BUFFER_SECONDS = 90.0
# A freshly spawned reader may need a few seconds before the first segment
# arrives; an established reader that stops producing PCM for this long is
# considered broken and gets respawned.
LIVE_SPAWN_GRACE_SECONDS = 15.0
LIVE_STALL_SECONDS = 12.0
LIVE_IDLE_SECONDS = 120.0


class BridgeError(RuntimeError):
    def __init__(self, message: str, stage: str = "capture", empty: bool = False) -> None:
        super().__init__(message)
        self.stage = stage
        self.empty = empty


def wav_bytes(pcm: bytes) -> bytes:
    """Wrap raw 16 kHz mono s16le PCM in a minimal WAV header."""
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF", 36 + len(pcm), b"WAVE", b"fmt ",
        16, 1, 1, LIVE_SAMPLE_RATE, LIVE_BYTES_PER_SECOND, 2, 16,
        b"data", len(pcm),
    )
    return header + pcm


class LiveSession:
    """One persistent ffmpeg reader for a live source feeding a PCM ring buffer.

    The reader follows the live edge and appends decoded PCM continuously.
    ``epochs`` records when each buffer position was produced so a sliced
    window can report the wall time its last sample hit the live edge; that
    timestamp is what lets the Lua side map the window back onto mpv's
    timeline via mpv's demuxer cache end.
    """

    def __init__(self, key: str, resolved: ResolvedAudio, spawn_args: list[str]) -> None:
        self.key = key
        self.resolved = resolved
        self.lock = threading.Lock()
        self.buffer = bytearray()
        self.base_frames = 0  # stream frame index currently at buffer[0]
        self.total_frames = 0  # cumulative frames appended since spawn
        self.epochs: list[tuple[int, float]] = []  # (total_frames, monotonic)
        self.served_until = 0.0  # seconds covered by the last served window
        self.last_append = time.monotonic()
        self.last_used = time.monotonic()
        self.started_at = time.monotonic()
        self.dead = False
        self.error = ""
        self._stderr_tail = ""
        self.process = subprocess.Popen(
            spawn_args,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            **process_flags(),
        )
        self._stdout_thread = threading.Thread(target=self._read_stdout, daemon=True)
        self._stderr_thread = threading.Thread(target=self._read_stderr, daemon=True)
        self._stdout_thread.start()
        self._stderr_thread.start()

    def _read_stdout(self) -> None:
        pending = b""
        try:
            while True:
                data = self.process.stdout.read(16384)
                if not data:
                    break
                data = pending + data
                usable = len(data) - (len(data) % 2)
                pending = data[usable:]
                if usable <= 0:
                    continue
                frames = usable // 2
                now = time.monotonic()
                with self.lock:
                    max_frames = int(LIVE_BUFFER_SECONDS * LIVE_SAMPLE_RATE)
                    excess = self.total_frames - self.base_frames + frames - max_frames
                    if excess > 0:
                        del self.buffer[: excess * 2]
                        self.base_frames += excess
                        while len(self.epochs) > 2 and self.epochs[1][0] <= self.base_frames:
                            self.epochs.pop(0)
                    self.buffer += data[:usable]
                    self.total_frames += frames
                    if not self.epochs or now - self.epochs[-1][1] >= 0.05:
                        self.epochs.append((self.total_frames, now))
                    self.last_append = now
        except OSError:
            pass
        finally:
            try:
                self._stderr_thread.join(timeout=2.0)
            except RuntimeError:
                pass
            with self.lock:
                if not self.dead:
                    self.dead = True
                    self.error = self._stderr_tail.strip()[-400:] or "live capture process exited"

    def _read_stderr(self) -> None:
        tail = b""
        try:
            while True:
                chunk = self.process.stderr.read(4096)
                if not chunk:
                    break
                tail = (tail + chunk)[-2000:]
            self._stderr_tail = tail.decode("utf-8", "replace")
        except OSError:
            pass

    def healthy(self) -> bool:
        with self.lock:
            if self.dead:
                return False
            now = time.monotonic()
            if now - self.started_at < LIVE_SPAWN_GRACE_SECONDS:
                return True
            return now - self.last_append < LIVE_STALL_SECONDS

    def fill_seconds(self) -> float:
        with self.lock:
            return self.total_frames / LIVE_SAMPLE_RATE

    def slice_window(self, start: float, end: float) -> tuple[bytes, float]:
        """Return PCM for [start, end] seconds plus the wall time of `end`."""
        with self.lock:
            f0 = max(self.base_frames, int(round(start * LIVE_SAMPLE_RATE)))
            f1 = min(self.total_frames, int(round(end * LIVE_SAMPLE_RATE)))
            if f1 <= f0:
                return b"", 0.0
            pcm = bytes(self.buffer[(f0 - self.base_frames) * 2 : (f1 - self.base_frames) * 2])
            return pcm, self._wall_at_frames_locked(f1)

    def _wall_at_frames_locked(self, frames: int) -> float:
        if not self.epochs:
            return self.last_append
        if frames >= self.epochs[-1][0]:
            # Past the last append: the buffer fills at real-time rate.
            return self.epochs[-1][1] + (frames - self.epochs[-1][0]) / LIVE_SAMPLE_RATE
        prev_frames, prev_wall = self.epochs[0]
        for cur_frames, cur_wall in self.epochs[1:]:
            if cur_frames >= frames:
                if cur_frames == prev_frames:
                    return cur_wall
                ratio = (frames - prev_frames) / (cur_frames - prev_frames)
                return prev_wall + (cur_wall - prev_wall) * ratio
            prev_frames, prev_wall = cur_frames, cur_wall
        return self.epochs[-1][1]

    def kill(self) -> None:
        with self.lock:
            self.dead = True
            if not self.error:
                self.error = "session killed"
        try:
            self.process.kill()
        except OSError:
            pass


@dataclass
class ResolvedAudio:
    source: str
    headers: dict[str, str]
    proxy: str | None
    selection: str
    is_live: bool
    expires_at: float
    is_web: bool
    map_spec: str | None
    is_hls_live: bool


@dataclass
class CapturedAudio:
    data: bytes
    started_at: float
    finished_at: float


def process_flags() -> dict[str, Any]:
    if os.name == "nt":
        return {"creationflags": getattr(subprocess, "CREATE_NO_WINDOW", 0)}
    return {}


def text(value: Any) -> str:
    return value if isinstance(value, str) else ""


def number(value: Any, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def normalized_language(value: Any) -> str:
    value = text(value).lower().replace("_", "-").strip()
    if not value:
        return ""
    base = value.split("-", 1)[0]
    aliases = {
        "chi": "zh", "zho": "zh", "chs": "zh", "cht": "zh", "sc": "zh", "tc": "zh",
        "eng": "en", "jpn": "ja", "kor": "ko", "fra": "fr", "fre": "fr", "deu": "de",
        "ger": "de", "spa": "es", "por": "pt", "rus": "ru", "ita": "it",
    }
    return aliases.get(base, base)


def header_map(*sources: Any) -> dict[str, str]:
    headers: dict[str, str] = {}
    for source in sources:
        if not isinstance(source, dict):
            continue
        values = source.get("http_headers")
        if not isinstance(values, dict):
            continue
        for name, value in values.items():
            if not isinstance(name, str) or not isinstance(value, (str, int, float)):
                continue
            clean_name = name.replace("\r", "").replace("\n", "").strip()
            clean_value = str(value).replace("\r", "").replace("\n", "").strip()
            if clean_name and clean_value:
                headers[clean_name] = clean_value
    return headers


def header_value(headers: dict[str, str], wanted: str) -> str:
    wanted = wanted.lower()
    for name, value in headers.items():
        if name.lower() == wanted:
            return value
    return ""


def set_header(headers: dict[str, str], name: str, value: str) -> None:
    for old_name in list(headers):
        if old_name.lower() == name.lower():
            headers[old_name] = value
            return
    headers[name] = value


def webpage_site(kind: str) -> str | None:
    if kind.startswith("bilibili"):
        return "bilibili"
    if kind.startswith("youtube"):
        return "youtube"
    return None


def host_matches(host: str, domain: str) -> bool:
    domain = domain.lstrip(".").lower()
    host = host.lower()
    return bool(domain) and (host == domain or host.endswith("." + domain))


def cookie_header(cookies: Any, *urls: str) -> str:
    hosts = [(urlparse(url).hostname or "").lower() for url in urls if url]
    pairs: list[str] = []
    seen: set[str] = set()
    if not isinstance(cookies, list):
        return ""
    for cookie in cookies:
        if not isinstance(cookie, dict):
            continue
        name, value, domain = text(cookie.get("name")), text(cookie.get("value")), text(cookie.get("domain"))
        if not name or not domain or not any(host_matches(host, domain) for host in hosts):
            continue
        pair = name + "=" + value
        if pair not in seen:
            seen.add(pair)
            pairs.append(pair)
    return "; ".join(pairs)


def ffmpeg_path() -> str:
    return shutil.which("ffmpeg") or r"C:\Program Files\ffmpeg\bin\ffmpeg.exe"


def ffmpeg_input_args(resolved: ResolvedAudio) -> list[str]:
    """Shared input-side options (proxy/headers/UA/referer) for ffmpeg reads."""
    args: list[str] = []
    scheme = urlparse(resolved.source).scheme.lower()
    if resolved.is_web and resolved.proxy and scheme in ("http", "https"):
        args.extend(["-http_proxy", resolved.proxy])
    safe_headers = []
    for name, value in resolved.headers.items():
        if name.lower() in ("host", "content-length", "transfer-encoding", "user-agent", "referer"):
            continue
        safe_headers.append(f"{name}: {value}")
    if safe_headers:
        args.extend(["-headers", "\r\n".join(safe_headers) + "\r\n"])
    user_agent = header_value(resolved.headers, "user-agent")
    referer = header_value(resolved.headers, "referer")
    if user_agent:
        args.extend(["-user_agent", user_agent])
    if referer:
        args.extend(["-referer", referer])
    return args


class WhisperBridge:
    def __init__(self) -> None:
        self._cache: dict[str, ResolvedAudio] = {}
        self._subtitle_cache: dict[str, str] = {}
        self._jobs: dict[str, subprocess.Popen[bytes]] = {}
        self._live_sessions: dict[str, LiveSession] = {}
        self._lock = threading.RLock()
        self._reaper = threading.Thread(target=self._reap_idle_sessions, daemon=True)
        self._reaper.start()

    def _reap_idle_sessions(self) -> None:
        while True:
            time.sleep(30.0)
            now = time.monotonic()
            with self._lock:
                stale = [
                    key for key, session in self._live_sessions.items()
                    if now - session.last_used > LIVE_IDLE_SECONDS
                    or (session.dead and now - session.last_used > 15.0)
                ]
                sessions = [self._live_sessions.pop(key) for key in stale]
            for session in sessions:
                session.kill()

    def put_subtitle(self, content: str, token: str | None = None) -> str:
        token = token or uuid.uuid4().hex
        with self._lock:
            self._subtitle_cache[token] = content
        return token

    def subtitle(self, token: str) -> str | None:
        with self._lock:
            return self._subtitle_cache.get(token)

    def remove_subtitle(self, token: str) -> None:
        with self._lock:
            self._subtitle_cache.pop(token, None)

    def clear_subtitles(self) -> None:
        with self._lock:
            self._subtitle_cache.clear()

    @staticmethod
    def cache_key(payload: dict[str, Any]) -> str:
        audio = payload.get("audio") if isinstance(payload.get("audio"), dict) else {}
        key = {
            "page": text(payload.get("page_url")),
            "kind": text(payload.get("web_kind")),
            "lang": normalized_language(audio.get("lang")),
            "title": text(audio.get("title")),
            "channels": text(audio.get("channels")),
            "proxy": text(payload.get("proxy")),
        }
        return json.dumps(key, sort_keys=True, ensure_ascii=True, separators=(",", ":"))

    def invalidate(self, payload: dict[str, Any]) -> None:
        with self._lock:
            key = self.cache_key(payload)
            self._cache.pop(key, None)
            session = self._live_sessions.pop(key, None)
        if session is not None:
            # The route this reader holds may be what just failed; force a
            # fresh resolve and respawn on the next request.
            session.kill()

    def cancel(self, request_id: str) -> bool:
        with self._lock:
            process = self._jobs.get(request_id)
        if process is None or process.poll() is not None:
            return False
        try:
            if os.name == "nt":
                subprocess.run(
                    ["taskkill.exe", "/PID", str(process.pid), "/T", "/F"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    check=False,
                    **process_flags(),
                )
            else:
                process.terminate()
            return True
        except OSError:
            return False

    def run_ytdlp(self, args: list[str]) -> dict[str, Any]:
        if not COOKIE_BRIDGE.is_file():
            raise BridgeError("mpv Cookie Bridge is unavailable", "resolve")
        command = [str(COOKIE_BRIDGE), *args]
        result = subprocess.run(
            command,
            cwd=str(WORKSPACE),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
            timeout=70,
            check=False,
            **process_flags(),
        )
        if result.returncode != 0:
            detail = result.stderr.decode("utf-8", "replace").strip()
            raise BridgeError(f"yt-dlp resolve failed ({result.returncode}): {detail[-900:]}", "resolve")
        try:
            data = json.loads(result.stdout.decode("utf-8", "replace"))
        except json.JSONDecodeError as error:
            raise BridgeError(f"yt-dlp returned invalid JSON: {error}", "resolve") from error
        if not isinstance(data, dict):
            raise BridgeError("yt-dlp returned no media object", "resolve")
        return data

    def cookie_context(self, site: str | None, page_url: str, source_url: str) -> str:
        if not site or not COOKIE_BRIDGE.is_file():
            return ""
        result = subprocess.run(
            [str(COOKIE_BRIDGE), "--get", site],
            cwd=str(WORKSPACE),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
            timeout=45,
            check=False,
            **process_flags(),
        )
        if result.returncode != 0:
            detail = result.stderr.decode("utf-8", "replace").strip()
            raise BridgeError(f"Cookie Bridge {site} context failed: {detail[-600:]}", "resolve")
        try:
            response = json.loads(result.stdout.decode("utf-8", "replace"))
        except json.JSONDecodeError as error:
            raise BridgeError(f"Cookie Bridge returned invalid JSON: {error}", "resolve") from error
        if not response.get("ok"):
            raise BridgeError("Cookie Bridge did not return authenticated cookies", "resolve")
        return cookie_header(response.get("cookies"), page_url, source_url)

    @staticmethod
    def choose_format(info: dict[str, Any], audio: dict[str, Any]) -> tuple[dict[str, Any], str]:
        formats = info.get("formats")
        if not isinstance(formats, list):
            raise BridgeError("yt-dlp returned no format list", "resolve")
        audio_candidates = [
            item for item in formats
            if isinstance(item, dict) and text(item.get("format_id"))
            and text(item.get("acodec")).lower() not in ("", "none")
        ]
        is_live = bool(info.get("is_live")) or text(info.get("live_status")).lower() in ("is_live", "post_live")
        # Bilibili live and a few other extractors expose a complete HLS/FLV
        # route without reliable codec metadata.  It is still decodable by
        # ffmpeg, so use it only as a live-stream fallback.
        live_route_candidates = [
            item for item in formats
            if isinstance(item, dict) and text(item.get("format_id")) and text(item.get("url"))
        ]
        candidates = audio_candidates or (live_route_candidates if is_live else [])
        if not candidates:
            raise BridgeError("yt-dlp returned no usable audio format", "resolve")

        requested = normalized_language(audio.get("lang"))
        language_matches = [
            item for item in candidates
            if requested and normalized_language(item.get("language")) == requested
        ]
        pool = language_matches or candidates

        def score(item: dict[str, Any]) -> tuple[int, float, float, float, float]:
            return (
                1 if text(item.get("vcodec")).lower() == "none" else 0,
                number(item.get("abr")),
                number(item.get("asr")),
                number(item.get("tbr")),
                number(item.get("filesize") or item.get("filesize_approx")),
            )

        chosen = max(pool, key=score)
        if language_matches:
            selection = "matched"
        elif requested:
            selection = "fallback"
        elif not audio_candidates:
            selection = "live-route"
        else:
            selection = "default"
        return chosen, selection

    @staticmethod
    def bilibili_live_room_id(page_url: str) -> str:
        parsed = urlparse(page_url)
        if parsed.hostname != "live.bilibili.com":
            raise BridgeError("Bilibili live page URL is invalid", "resolve")
        match = re.match(r"^/(?:blanc/)?(\d+)(?:/|$)", parsed.path)
        if not match:
            raise BridgeError("Bilibili live room ID is missing", "resolve")
        return match.group(1)

    def resolve_bilibili_live_api(self, payload: dict[str, Any], page_url: str) -> ResolvedAudio:
        """Resolve a Bilibili live route when yt-dlp's live extractor is empty.

        BiliLive occasionally reports an empty format list even while mpv is
        playing the room.  The documented room play-info endpoint exposes the
        same signed HLS/FLV routes and keeps this fallback fully in memory.
        """
        room_id = self.bilibili_live_room_id(page_url)
        api_url = (
            "https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo"
            f"?room_id={room_id}&protocol=0,1&format=0,1,2&codec=0,1"
            "&qn=10000&platform=web&ptype=8"
        )
        headers = {
            "Accept": "application/json, text/plain, */*",
            "Referer": "https://live.bilibili.com/",
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
            "(KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36",
        }
        cookies = self.cookie_context("bilibili", page_url, api_url)
        if cookies:
            headers["Cookie"] = cookies
        request = urllib.request.Request(api_url, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                data = json.loads(response.read().decode("utf-8", "replace"))
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
            raise BridgeError(f"Bilibili live play-info request failed: {error}", "resolve") from error

        if not isinstance(data, dict) or number(data.get("code"), -1) != 0:
            message = text(data.get("message")) if isinstance(data, dict) else "invalid response"
            raise BridgeError(f"Bilibili live play-info returned no route: {message}", "resolve")
        playurl = data.get("data")
        if isinstance(playurl, dict):
            playurl = playurl.get("playurl_info")
        if isinstance(playurl, dict):
            playurl = playurl.get("playurl")
        streams = playurl.get("stream") if isinstance(playurl, dict) else None
        if not isinstance(streams, list):
            raise BridgeError("Bilibili live play-info returned no stream list", "resolve")

        routes: list[tuple[tuple[int, int, int], str, bool]] = []
        for stream in streams:
            if not isinstance(stream, dict):
                continue
            protocol_name = text(stream.get("protocol_name")).lower()
            for fmt in stream.get("format") or []:
                if not isinstance(fmt, dict):
                    continue
                format_name = text(fmt.get("format_name")).lower()
                for codec in fmt.get("codec") or []:
                    if not isinstance(codec, dict):
                        continue
                    base_url = text(codec.get("base_url"))
                    if not base_url:
                        continue
                    for url_info in codec.get("url_info") or []:
                        if not isinstance(url_info, dict):
                            continue
                        host = text(url_info.get("host"))
                        extra = text(url_info.get("extra"))
                        if not host:
                            continue
                        source = host + base_url + extra
                        is_hls = (
                            "m3u8" in source.lower()
                            or format_name in ("fmp4", "m3u8")
                            or protocol_name in ("http_hls", "hls")
                        )
                        # HLS is normally the most reliable route for a
                        # second concurrent reader; retain FLV as fallback.
                        score = (
                            1 if is_hls else 0,
                            1 if text(codec.get("codec_name")).lower().startswith("avc") else 0,
                            number(codec.get("current_qn")),
                        )
                        routes.append((score, source, is_hls))
        if not routes:
            raise BridgeError("Bilibili live play-info returned no usable route", "resolve")
        # Multiple CDN URLs commonly share the same quality.  Keep their
        # ranking deterministic, then rotate on the bridge's retry attempt.
        # This avoids retrying the exact CDN that just returned 404/TLS EOF.
        ranked: list[tuple[tuple[int, int, int], str, bool]] = []
        seen: set[str] = set()
        for route in sorted(routes, key=lambda item: (item[0], item[1]), reverse=True):
            if route[1] not in seen:
                seen.add(route[1])
                ranked.append(route)
        route_attempt = max(0, int(number(payload.get("route_attempt"))))
        _, source, is_hls = ranked[route_attempt % len(ranked)]
        return ResolvedAudio(
            source=source,
            headers=headers,
            proxy=None,
            selection="bilibili-live-api",
            is_live=True,
            expires_at=time.monotonic() + 20.0,
            is_web=True,
            map_spec="0:a:0",
            is_hls_live=is_hls,
        )

    def resolve_web(self, payload: dict[str, Any], force_refresh: bool) -> ResolvedAudio:
        page_url = text(payload.get("page_url"))
        kind = text(payload.get("web_kind"))
        if not page_url or not kind:
            raise BridgeError("missing webpage context", "resolve")
        key = self.cache_key(payload)
        now = time.monotonic()
        with self._lock:
            cached = self._cache.get(key)
            if force_refresh:
                self._cache.pop(key, None)
                cached = None
            if cached and cached.expires_at > now:
                return cached

        proxy = text(payload.get("proxy")) or None
        # Bilibili intentionally bypasses the global YouTube proxy in the
        # existing Cookie Bridge facade; the ffmpeg side follows that rule.
        if kind.startswith("bilibili"):
            proxy = None
        common_args = ["--no-playlist", "--dump-single-json", "--no-warnings", "--skip-download"]
        if proxy:
            common_args.extend(["--proxy", proxy])
        prefer_bilibili_api = kind.startswith("bilibili-live") and bool(payload.get("prefer_bilibili_api"))
        if prefer_bilibili_api:
            try:
                resolved = self.resolve_bilibili_live_api(payload, page_url)
            except BridgeError:
                # Keep yt-dlp as a final fallback when the play-info API has
                # a transient failure of its own.
                resolved = None
            if resolved is not None:
                with self._lock:
                    self._cache[key] = resolved
                return resolved

        try:
            metadata = self.run_ytdlp([*common_args, page_url])
            audio = payload.get("audio") if isinstance(payload.get("audio"), dict) else {}
            chosen, selection = self.choose_format(metadata, audio)
            selected = metadata
            source = text(chosen.get("url"))
            # Normal yt-dlp JSON already carries each format's signed URL.  A
            # small number of extractors omit it in the format list, so resolve
            # just that selected format only when the direct in-memory result is
            # insufficient.
            if not source:
                selected = self.run_ytdlp([*common_args, "--format", text(chosen.get("format_id")), page_url])
                source = text(selected.get("url"))
            if not source:
                requested = selected.get("requested_formats")
                if isinstance(requested, list):
                    for item in requested:
                        if isinstance(item, dict) and text(item.get("acodec")).lower() != "none" and text(item.get("url")):
                            source = text(item.get("url"))
                            break
            if not source:
                raise BridgeError("yt-dlp selected audio has no stream URL", "resolve")
            headers = header_map(metadata, chosen, selected)
            cookies = self.cookie_context(webpage_site(kind), page_url, source)
            if cookies and not header_value(headers, "cookie"):
                set_header(headers, "Cookie", cookies)
            live_status = text(selected.get("live_status") or metadata.get("live_status")).lower()
            is_live = bool(selected.get("is_live") or metadata.get("is_live")) or live_status in ("is_live", "post_live")
            resolved = ResolvedAudio(
                source=source,
                headers=headers,
                proxy=proxy,
                selection=selection,
                is_live=is_live,
                expires_at=time.monotonic() + (20.0 if is_live else 300.0),
                is_web=True,
                # The resolved URL is a fresh audio route.  It is unrelated to
                # mpv's original container stream indices.
                map_spec="0:a:0",
            is_hls_live=is_live and (
                text(chosen.get("protocol")).lower().startswith("m3u8")
                or "hls" in text(chosen.get("protocol")).lower()
                or "m3u8" in source.lower()
            ),
            )
        except BridgeError as error:
            if not kind.startswith("bilibili-live"):
                raise
            try:
                resolved = self.resolve_bilibili_live_api(payload, page_url)
            except BridgeError as fallback:
                raise BridgeError(
                    f"yt-dlp: {error}; Bilibili live fallback: {fallback}", "resolve"
                ) from fallback
        with self._lock:
            self._cache[key] = resolved
        return resolved

    def source_for(self, payload: dict[str, Any], force_refresh: bool) -> ResolvedAudio:
        if text(payload.get("page_url")) and text(payload.get("web_kind")):
            return self.resolve_web(payload, force_refresh)
        source = text(payload.get("source"))
        if not source:
            raise BridgeError("missing media source", "capture")
        # Direct media must not inherit yt-dlp's proxy.  Passing an HTTP-only
        # protocol option before a local file makes ffmpeg reject that file.
        return ResolvedAudio(source, {}, None, "direct", False, time.monotonic(), False, None, False)

    def capture_audio(self, resolved: ResolvedAudio, payload: dict[str, Any], request_id: str) -> CapturedAudio:
        ffmpeg = ffmpeg_path()
        if not shutil.which(ffmpeg) and not Path(ffmpeg).is_file():
            raise BridgeError("ffmpeg was not found", "capture")
        # A DVR-capable mpv input can report itself as seekable even though a
        # freshly resolved live URL has no matching zero point. Never seek a
        # live capture source; it must start near its current live edge.
        seekable = bool(payload.get("seekable", True)) and not resolved.is_live
        start = max(0.0, number(payload.get("start")))
        duration = min(max(number(payload.get("duration"), 6.0), 1.0), 30.0)
        map_spec = resolved.map_spec or text(payload.get("map")) or "0:a:0"
        args = [ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-rw_timeout", "15000000"]
        args.extend(ffmpeg_input_args(resolved))
        if resolved.is_live and resolved.is_hls_live:
            args.extend(["-live_start_index", "-2"])
        capture_started = time.monotonic()
        args.extend(["-i", resolved.source])
        # Input-side seek can land on a container/keyframe boundary.  Audio
        # trimming after input is slower but gives the timeline its requested
        # sample position without affecting mpv's own demuxer.
        if seekable:
            args.extend(["-ss", f"{start:.3f}"])
        args.extend([
            "-map", map_spec,
            "-vn", "-sn", "-dn",
            "-t", f"{duration:.3f}",
            "-ac", "1", "-ar", "16000",
            "-c:a", "pcm_s16le", "-f", "wav", "pipe:1",
        ])
        process = subprocess.Popen(
            args,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            **process_flags(),
        )
        with self._lock:
            self._jobs[request_id] = process
        try:
            stdout, stderr = process.communicate(timeout=55)
        except subprocess.TimeoutExpired:
            self.cancel(request_id)
            stdout, stderr = process.communicate()
            raise BridgeError("ffmpeg capture timed out", "capture")
        finally:
            with self._lock:
                self._jobs.pop(request_id, None)
        capture_finished = time.monotonic()
        if process.returncode != 0:
            detail = stderr.decode("utf-8", "replace").strip()
            raise BridgeError(f"ffmpeg capture failed ({process.returncode}): {detail[-1200:]}", "capture")
        # Header-only / trivially short WAV means the audio stream ran out
        # before the requested window (e.g. a seek beyond EOF), not a capture
        # failure.  Mark it as empty so transcribe can return a clean result.
        if len(stdout) < MIN_AUDIO_BYTES:
            raise BridgeError("captured audio is empty", "capture", empty=True)
        return CapturedAudio(stdout, capture_started, capture_finished)

    @staticmethod
    def whisper(endpoint: str, audio: bytes) -> dict[str, Any]:
        boundary = "----mpvwhisper" + uuid.uuid4().hex
        body = bytearray()
        body.extend(f"--{boundary}\r\n".encode("ascii"))
        body.extend(b'Content-Disposition: form-data; name="file"; filename="mpv-whisper.wav"\r\n')
        body.extend(b"Content-Type: audio/wav\r\n\r\n")
        body.extend(audio)
        body.extend(b"\r\n")
        for name, value in (("response_format", "verbose_json"), ("language", "auto")):
            body.extend(f"--{boundary}\r\n".encode("ascii"))
            body.extend(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode("ascii"))
            body.extend(value.encode("utf-8"))
            body.extend(b"\r\n")
        body.extend(f"--{boundary}--\r\n".encode("ascii"))
        request = urllib.request.Request(
            endpoint,
            data=bytes(body),
            method="POST",
            headers={
                "Content-Type": f"multipart/form-data; boundary={boundary}",
                "Content-Length": str(len(body)),
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=95) as response:
                data = json.loads(response.read().decode("utf-8", "replace"))
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")
            raise BridgeError(f"Whisper HTTP {error.code}: {detail[-1200:]}", "whisper") from error
        except (urllib.error.URLError, TimeoutError) as error:
            raise BridgeError(f"Whisper request failed: {error}", "whisper") from error
        if not isinstance(data, dict):
            raise BridgeError("Whisper returned a non-object response", "whisper")
        return data

    def live_session_for(self, payload: dict[str, Any], force_fresh: bool) -> LiveSession | None:
        """Return a healthy persistent live reader for this source, if any.

        A healthy session is reused as-is (skipping yt-dlp resolution entirely)
        because the reader already holds a working route to the same audio.
        Returns None when the source turns out not to be live; the caller then
        falls back to the regular per-chunk capture path.
        """
        key = self.cache_key(payload)
        if not force_fresh:
            with self._lock:
                session = self._live_sessions.get(key)
                if session is not None and session.healthy():
                    return session
        resolved = self.source_for(payload, force_fresh)
        if not resolved.is_live:
            return None
        return self.spawn_live_session(key, resolved)

    def spawn_live_session(self, key: str, resolved: ResolvedAudio) -> LiveSession:
        ffmpeg = ffmpeg_path()
        if not shutil.which(ffmpeg) and not Path(ffmpeg).is_file():
            raise BridgeError("ffmpeg was not found", "capture")
        args = [ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-rw_timeout", "15000000"]
        args.extend(ffmpeg_input_args(resolved))
        if resolved.is_hls_live:
            # Start at the newest published segment: the reader then follows the
            # edge continuously, so no extra back-off segments are required.
            args.extend(["-live_start_index", "-1"])
        args.extend([
            "-i", resolved.source,
            "-map", resolved.map_spec or "0:a:0",
            "-vn", "-sn", "-dn",
            "-ac", "1", "-ar", "16000",
            "-c:a", "pcm_s16le", "-f", "s16le", "pipe:1",
        ])
        with self._lock:
            old = self._live_sessions.get(key)
        if old is not None:
            old.kill()
        session = LiveSession(key, resolved, args)
        with self._lock:
            self._live_sessions[key] = session
        return session

    def transcribe_live(
        self,
        session: LiveSession,
        endpoint: str,
        payload: dict[str, Any],
        attempt_payload: dict[str, Any],
        started: float,
    ) -> dict[str, Any]:
        t_recv = time.monotonic()
        chunk = min(max(number(payload.get("live_chunk"), 4.0), 2.0), 10.0)
        overlap = min(max(number(payload.get("live_overlap"), 1.2), 0.0), chunk / 2.0)
        respawned = False
        # Wait until the ring buffer holds a full new window.  The wait itself
        # paces the request cadence: each cycle consumes (chunk - overlap)
        # seconds of fresh audio, so coverage stays gapless.
        while True:
            if not session.healthy():
                if respawned:
                    raise BridgeError(f"live capture stopped: {session.error}", "capture")
                resolved = self.source_for(attempt_payload, True)
                if not resolved.is_live:
                    raise BridgeError("live source is no longer live", "capture")
                session = self.spawn_live_session(session.key, resolved)
                respawned = True
            start = max(0.0, session.served_until - overlap)
            need_end = start + chunk
            if session.fill_seconds() >= need_end:
                break
            if time.monotonic() - t_recv > 30.0:
                raise BridgeError("live capture stalled waiting for audio", "capture")
            time.sleep(0.08)
        pcm, edge_wall = session.slice_window(start, min(need_end, session.fill_seconds()))
        end = start + len(pcm) / LIVE_BYTES_PER_SECOND
        with session.lock:
            session.served_until = max(session.served_until, end)
            session.last_used = time.monotonic()
        if len(pcm) < MIN_AUDIO_BYTES:
            raise BridgeError("live window is empty", "capture", empty=True)
        response = self.whisper(endpoint, wav_bytes(pcm))
        response["ok"] = True
        response["live_persist"] = True
        response["t_recv"] = t_recv
        response["edge_wall"] = edge_wall
        response["window_duration"] = end - start
        response["capture_offset"] = t_recv - started
        response["capture_started_after"] = t_recv - started
        response["capture_finished_after"] = time.monotonic() - started
        response["capture_duration"] = end - start
        response["audio_selection"] = session.resolved.selection
        response["web_source"] = True
        response["is_live"] = True
        return response

    def transcribe(self, payload: dict[str, Any]) -> dict[str, Any]:
        endpoint = text(payload.get("endpoint"))
        request_id = text(payload.get("request_id")) or uuid.uuid4().hex
        if not endpoint:
            raise BridgeError("missing Whisper endpoint", "whisper")
        started = time.monotonic()
        is_web = bool(text(payload.get("page_url")) and text(payload.get("web_kind")))
        force_refresh = bool(payload.get("refresh_web"))
        last_error: BridgeError | None = None
        resolved: ResolvedAudio | None = None
        for attempt in range(2 if is_web else 1):
            try:
                attempt_payload = dict(payload)
                attempt_payload["route_attempt"] = attempt
                if attempt and text(attempt_payload.get("web_kind")).startswith("bilibili-live"):
                    attempt_payload["prefer_bilibili_api"] = True
                if is_web:
                    # A retry after a capture/resolve failure must rebuild the
                    # reader; after a whisper failure the existing reader is
                    # still good and must be kept.
                    refresh_session = attempt > 0 and last_error is not None and last_error.stage != "whisper"
                    session = self.live_session_for(attempt_payload, refresh_session)
                    if session is not None:
                        return self.transcribe_live(session, endpoint, payload, attempt_payload, started)
                resolved = self.source_for(attempt_payload, force_refresh or attempt > 0)
                audio = self.capture_audio(resolved, attempt_payload, request_id)
                response = self.whisper(endpoint, audio.data)
                response["ok"] = True
                response["capture_offset"] = audio.started_at - started
                response["capture_started_after"] = audio.started_at - started
                response["capture_finished_after"] = audio.finished_at - started
                response["capture_duration"] = max(0.0, (len(audio.data) - 44) / 32000.0)
                response["audio_selection"] = resolved.selection
                response["web_source"] = is_web
                response["is_live"] = resolved.is_live
                return response
            except BridgeError as error:
                last_error = error
                if error.empty:
                    # The audio stream is exhausted (seek past EOF).  Surface a
                    # clean empty transcription instead of a Whisper failure so
                    # the Lua script advances normally without error popups.
                    return {
                        "ok": True,
                        "segments": [],
                        "is_live": resolved.is_live if resolved is not None else True,
                        "audio_selection": resolved.selection if resolved is not None else "live",
                        "web_source": is_web,
                        "capture_offset": 0.0,
                        "capture_started_after": 0.0,
                        "capture_finished_after": 0.0,
                        "capture_duration": 0.0,
                    }
                if not is_web or attempt:
                    break
                if error.stage != "whisper":
                    # Whisper-side failures are unrelated to the resolved route;
                    # keep any live reader alive and just retry the inference.
                    self.invalidate(payload)
        raise last_error or BridgeError("Whisper bridge request failed", "bridge")


class Handler(BaseHTTPRequestHandler):
    server: "BridgeServer"

    def log_message(self, _format: str, *_args: Any) -> None:
        pass

    def json_response(self, status: int, data: dict[str, Any]) -> None:
        encoded = json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        try:
            self.wfile.write(encoded)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def text_response(self, status: int, content: str) -> None:
        encoded = content.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/x-subrip; charset=utf-8")
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        try:
            self.wfile.write(encoded)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0 or length > MAX_REQUEST_BYTES:
            raise BridgeError("invalid request length")
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise BridgeError(f"invalid JSON request: {error}") from error
        if not isinstance(payload, dict):
            raise BridgeError("request must be a JSON object")
        return payload

    def do_GET(self) -> None:
        if self.path == "/health":
            self.json_response(200, {"ok": True})
        elif self.path.startswith("/subtitle/"):
            token = self.path[len("/subtitle/"):].split("?", 1)[0]
            if token.endswith(".srt"):
                token = token[:-4]
            content = self.server.bridge.subtitle(token)
            if content is None:
                self.json_response(404, {"ok": False, "error": "subtitle not found"})
            else:
                self.text_response(200, content)
        else:
            self.json_response(404, {"ok": False, "error": "not found"})

    def do_POST(self) -> None:
        try:
            payload = self.read_json()
            if self.path == "/subtitle":
                content = text(payload.get("content"))
                if not content:
                    raise BridgeError("empty subtitle content", "subtitle")
                token = self.server.bridge.put_subtitle(content, text(payload.get("token")) or None)
                self.json_response(200, {
                    "ok": True,
                    "token": token,
                    "url": f"http://127.0.0.1:{self.server.server_port}/subtitle/{token}.srt",
                })
                return
            if self.path == "/cancel":
                request_id = text(payload.get("request_id"))
                self.json_response(200, {"ok": True, "cancelled": self.server.bridge.cancel(request_id)})
                return
            if self.path != "/transcribe":
                self.json_response(404, {"ok": False, "error": "not found"})
                return
            self.json_response(200, self.server.bridge.transcribe(payload))
        except BridgeError as error:
            self.json_response(502, {"ok": False, "stage": error.stage, "error": str(error)})
        except Exception as error:
            self.json_response(500, {"ok": False, "stage": "bridge", "error": f"bridge internal error: {error}"})

    def do_DELETE(self) -> None:
        if self.path == "/subtitle":
            self.server.bridge.clear_subtitles()
            self.json_response(200, {"ok": True})
            return
        if self.path.startswith("/subtitle/"):
            token = self.path[len("/subtitle/"):].split("?", 1)[0]
            if token.endswith(".srt"):
                token = token[:-4]
            self.server.bridge.remove_subtitle(token)
            self.json_response(200, {"ok": True})
            return
        self.json_response(404, {"ok": False, "error": "not found"})


class BridgeServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int]) -> None:
        super().__init__(address, Handler)
        self.bridge = WhisperBridge()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--port", type=int, default=18791)
    args = parser.parse_args()
    if not args.serve:
        parser.error("only --serve is supported")
    server = BridgeServer(("127.0.0.1", args.port))
    try:
        server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
