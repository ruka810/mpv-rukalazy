#!/usr/bin/env python3
"""yt-dlp facade for either in-memory Chrome cookies or an exported cookie file."""

from __future__ import annotations

import argparse
import importlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
# yt-dlp discovers external providers from ``yt_dlp_plugins`` packages on
# sys.path.  Keep the provider beside this wrapper so its cache and all of its
# Node assets remain local to the mpv installation.
sys.path.insert(0, str(ROOT / "pot_provider"))
sys.path.insert(0, str(ROOT / "vendor"))


def is_youtube_request(argv: list[str]) -> bool:
    """Return whether this yt-dlp invocation targets a YouTube URL."""
    from urllib.parse import urlparse

    for value in reversed(argv):
        try:
            host = (urlparse(value).hostname or "").lower()
        except ValueError:
            continue
        if host == "youtu.be" or host == "youtube.com" or host.endswith(".youtube.com"):
            return True
    return False


def is_bilibili_request(argv: list[str]) -> bool:
    """Return whether this yt-dlp invocation targets a Bilibili URL.

    Bilibili's live APIs are reachable directly from this installation, but
    the global proxy configured for YouTube sometimes returns a valid-looking
    response with an empty ``durl`` list.  That makes yt-dlp report "No video
    formats found" and, more importantly, prevents mpv from ever reaching the
    live session where the original webpage context is preserved.
    """
    from urllib.parse import urlparse

    for value in reversed(argv):
        try:
            host = (urlparse(value).hostname or "").lower()
        except ValueError:
            continue
        if host == "bilibili.com" or host.endswith(".bilibili.com"):
            return True
    return False


def without_proxy(argv: list[str]) -> list[str]:
    """Remove CLI proxy options while preserving every unrelated yt-dlp arg."""
    output: list[str] = []
    index = 0
    while index < len(argv):
        value = argv[index]
        if value == "--proxy":
            index += 2
            continue
        if value.startswith("--proxy="):
            index += 1
            continue
        output.append(value)
        index += 1
    return output


def is_metadata_request(argv: list[str]) -> bool:
    """Playlist/title probes do not need playback challenge solving."""
    return any(value == "--flat-playlist" for value in argv)


def find_node() -> str | None:
    """Prefer the locally installed Node runtime used by the PO provider."""
    import os
    import shutil

    candidates = [
        os.environ.get("MPV_LAZY_NODE"),
        shutil.which("node"),
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return str(Path(candidate))
    return None


def add_youtube_po_provider(argv: list[str]) -> list[str]:
    """Attach the local BgUtils provider only to YouTube requests.

    The provider is intentionally added here instead of mpv.conf: other site
    extractors must never receive YouTube-only extractor arguments.
    """
    if not is_youtube_request(argv):
        return argv

    # Flat playlist probes only need entry metadata. Starting Node and enabling
    # EJS/PO-token solving here made every titled playlist pay the full
    # playback authentication cost before mpv could show its list.
    if is_metadata_request(argv):
        return argv

    # The normal WEB client currently produces DASH URLs that YouTube often
    # rate-limits with HTTP 429 when mpv opens the first media segment through
    # the configured proxy.  WEB_SAFARI exposes YouTube's own muxed HLS
    # variants (up to the actually offered 1080p tier), which are materially
    # more reliable for live playback.  Do not override an explicit advanced
    # client choice supplied by the user.
    has_youtube_client = False
    for index, value in enumerate(argv):
        if value.startswith("--extractor-args=youtube:") and "player_client=" in value:
            has_youtube_client = True
            break
        if value == "--extractor-args" and index + 1 < len(argv):
            candidate = argv[index + 1]
            if candidate.startswith("youtube:") and "player_client=" in candidate:
                has_youtube_client = True
                break
    if not has_youtube_client:
        argv = ["--extractor-args", "youtube:player_client=web_safari", *argv]

    server_home = ROOT / "pot_provider_src" / "bgutil-ytdlp-pot-provider-1.3.1" / "server"
    generator = server_home / "build" / "generate_once.js"
    node = find_node()
    if not generator.is_file():
        print("[mpv-cookie-bridge] YouTube PO Token Provider is unavailable: generator is missing", file=sys.stderr)
        return argv
    if not node:
        print("[mpv-cookie-bridge] YouTube PO Token Provider is unavailable: Node.js was not found", file=sys.stderr)
        return argv

    # Do not duplicate settings supplied by an advanced user.  This keeps the
    # bridge composable with explicit yt-dlp command-line options.
    if not any(value == "--js-runtimes" or value.startswith("--js-runtimes=") for value in argv):
        argv = ["--js-runtimes", f"node:{node}", *argv]
    if not any("youtubepot-bgutilscript" in value for value in argv):
        argv = [
            "--extractor-args",
            "youtubepot-bgutilhttp:base_url=http://127.0.0.1:4416",
            "--extractor-args",
            f"youtubepot-bgutilscript:server_home={server_home}",
            *argv,
        ]
    # Do not fetch an EJS component pre-emptively.  `web_safari` does not need
    # it for normal playback, so forcing a GitHub request on every video only
    # makes startup slower.  An advanced caller may still explicitly request
    # an EJS component together with another player client.
    return argv


def cookie_jar(items: list[dict], cookie_class):
    jar = cookie_class()
    for item in items:
        name = item.get("name")
        value = item.get("value")
        domain = item.get("domain")
        if not isinstance(name, str) or not isinstance(value, str) or not isinstance(domain, str):
            continue
        expires = item.get("expirationDate")
        try:
            expires = int(expires) if expires is not None else None
        except (TypeError, ValueError):
            expires = None
        import http.cookiejar
        cookie = http.cookiejar.Cookie(
            version=0,
            name=name,
            value=value,
            port=None,
            port_specified=False,
            domain=domain,
            domain_specified=True,
            domain_initial_dot=domain.startswith("."),
            path=item.get("path") or "/",
            path_specified=True,
            secure=bool(item.get("secure")),
            expires=expires,
            discard=bool(item.get("session")) or expires is None,
            comment=None,
            comment_url=None,
            rest={"HttpOnly": bool(item.get("httpOnly")), "SameSite": item.get("sameSite") or "unspecified"},
            rfc2109=False,
        )
        jar.set_cookie(cookie)
    return jar


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--cookie-json-stdin", action="store_true")
    parser.add_argument("--cookie-file")
    known, argv = parser.parse_known_args()
    if known.cookie_json_stdin == bool(known.cookie_file):
        print("[mpv-cookie-bridge] Select exactly one Cookie source", file=sys.stderr)
        return 2

    cookies_module = importlib.import_module("yt_dlp.cookies")
    ydl_module = importlib.import_module("yt_dlp.YoutubeDL")
    cli_module = importlib.import_module("yt_dlp.__init__")
    if known.cookie_json_stdin:
        try:
            payload = json.load(sys.stdin)
        except Exception as error:
            print(f"[mpv-cookie-bridge] Invalid in-memory Cookie response: {error}", file=sys.stderr)
            return 2
        cookie_class = cookies_module.YoutubeDLCookieJar
        jar = cookie_jar(payload.get("cookies") or [], cookie_class)

        def load_memory_cookies(*_args, **_kwargs):
            return jar

        cookies_module.load_cookies = load_memory_cookies
        ydl_module.load_cookies = load_memory_cookies
    else:
        cookie_file = Path(known.cookie_file)
        if not cookie_file.is_file() or cookie_file.stat().st_size <= 64:
            print("[mpv-cookie-bridge] Exported Cookie file is unavailable", file=sys.stderr)
            return 2
        argv = ["--cookies", str(cookie_file), *argv]

    # The global mpv proxy is for YouTube.  Do not send Bilibili page and live
    # APIs through it: on this network it yields empty live format lists.  The
    # exception is intentionally made inside the memory-cookie facade so all
    # Bilibili call sites (normal playback, title probes and quality queries)
    # behave identically, while YouTube keeps its required proxy unchanged.
    if is_bilibili_request(argv):
        argv = without_proxy(argv)
    argv = add_youtube_po_provider(argv)
    try:
        return int(cli_module._real_main(argv) or 0)
    except SystemExit as exit_error:
        return int(exit_error.code or 0)


if __name__ == "__main__":
    raise SystemExit(main())
