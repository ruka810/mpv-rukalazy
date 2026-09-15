#!/usr/bin/env python3
"""Fetch Bilibili AI subtitles (ai-zh / ai-en ...) and emit SRT to stdout.

Reuses the Chrome Cookie Bridge so SESSDATA never touches the filesystem.
Pipeline: view API (aid/cid) -> player API (subtitle list, WBI-signed) ->
subtitle_url JSON (body[]) -> SRT.

stdout: the SRT text only.
stderr: a single ``@meta <json>`` line (lan / lan_doc / title) on success, or
plain error text on failure. Exit code: 0 = ok, 2 = no usable subtitle
(not-logged-in / none available), 3 = network / anti-crawl / other.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "chrome_cookie_bridge"))

from bilibili_cookie_fetch import bridge_jar, decode_response_body  # noqa: E402

DEFAULT_REFERER = "https://www.bilibili.com"
DEFAULT_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/138.0.0.0 Safari/537.36"

# Bilibili WBI signature: permute img_key+sub_key by this table, then md5.
MIXIN_KEY_ENC_TAB = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
    33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
    61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
    36, 20, 34, 44, 52,
]

SUBTITLE_PRIORITY = ["ai-zh", "zh", "ai-en", "en"]


class FetchError(Exception):
    pass


def http_get(url: str, jar, ua: str, referer: str, timeout: float = 30) -> bytes:
    handlers = []
    if jar is not None:
        handlers.append(urllib.request.HTTPCookieProcessor(jar))
    handlers.insert(0, urllib.request.ProxyHandler({}))
    request = urllib.request.Request(
        url, headers={"User-Agent": ua, "Referer": referer})
    try:
        with urllib.request.build_opener(*handlers).open(request, timeout=timeout) as response:
            return decode_response_body(response.read(), response.headers.get("Content-Encoding"))
    except urllib.error.HTTPError as error:
        raise FetchError("HTTP %s for %s" % (error.code, url)) from error
    except (urllib.error.URLError, OSError) as error:
        raise FetchError("network error for %s: %s" % (url, error)) from error


def json_get(url: str, jar, ua: str, referer: str, timeout: float = 30) -> dict:
    body = http_get(url, jar, ua, referer, timeout)
    try:
        data = json.loads(body.decode("utf-8", "replace"))
    except json.JSONDecodeError as error:
        raise FetchError("bad JSON from %s (anti-crawl?)" % url) from error
    if not isinstance(data, dict):
        raise FetchError("unexpected payload from %s" % url)
    return data


def wbi_keys(ua: str) -> tuple[str, str]:
    data = json_get("https://api.bilibili.com/x/web-interface/nav", None, ua, DEFAULT_REFERER)
    wbi = ((data.get("data") or {}).get("wbi_img")) or {}
    img_url = wbi.get("img_url") or ""
    sub_url = wbi.get("sub_url") or ""
    img_key = img_url.rsplit("/", 1)[-1].split(".")[0]
    sub_key = sub_url.rsplit("/", 1)[-1].split(".")[0]
    if not img_key or not sub_key:
        raise FetchError("cannot obtain WBI keys from nav API")
    return img_key, sub_key


def enc_wbi(params: dict, img_key: str, sub_key: str) -> dict:
    mixin_key = "".join((img_key + sub_key)[i] for i in MIXIN_KEY_ENC_TAB)[:32]
    params = dict(params)
    params["wts"] = int(time.time())
    query = urllib.parse.urlencode(sorted(params.items()))
    params["w_rid"] = hashlib.md5((query + mixin_key).encode("utf-8")).hexdigest()
    return params


def pick_subtitle(subtitles: list) -> dict | None:
    def rank(item):
        lan = (item.get("lan") or "").lower()
        for index, prefix in enumerate(SUBTITLE_PRIORITY):
            if lan == prefix:
                return index
        if lan.startswith("zh"):
            return 1
        if lan.startswith("en"):
            return 3
        if lan.startswith("ai-"):
            return 4
        return 5

    if not subtitles:
        return None
    return min(subtitles, key=rank)


def format_timestamp(seconds: float) -> str:
    total_ms = max(0, int(round(float(seconds) * 1000)))
    hours, rem = divmod(total_ms, 3600000)
    minutes, rem = divmod(rem, 60000)
    secs, millis = divmod(rem, 1000)
    return "%02d:%02d:%02d,%03d" % (hours, minutes, secs, millis)


def build_srt(body: list) -> str:
    blocks = []
    for index, item in enumerate(body, 1):
        text = (item.get("content") or "").replace("\r", "").replace("\n", " ").strip()
        if not text:
            continue
        try:
            start = format_timestamp(item["from"])
            end = format_timestamp(item["to"])
        except (KeyError, TypeError, ValueError):
            continue
        blocks.append("%d\n%s --> %s\n%s" % (index, start, end, text))
    return "\n\n".join(blocks)


def fetch_subtitle(bvid: str, page: int, jar, ua: str, referer: str) -> tuple[str, dict]:
    view = json_get("https://api.bilibili.com/x/web-interface/view?bvid=%s" % urllib.parse.quote(bvid),
                    jar, ua, referer)
    if view.get("code") != 0:
        raise FetchError("view API error: %s" % view.get("message"))
    data = view.get("data") or {}
    aid = data.get("aid")
    pages = data.get("pages") or []
    cid = data.get("cid")
    if pages:
        page = max(1, min(page, len(pages)))
        cid = pages[page - 1].get("cid") or cid
    if not aid or not cid:
        raise FetchError("view API returned no aid/cid")

    player = None
    try:
        img_key, sub_key = wbi_keys(ua)
        signed = enc_wbi({"aid": aid, "cid": cid}, img_key, sub_key)
        wbi_url = "https://api.bilibili.com/x/player/wbi/v2?" + urllib.parse.urlencode(signed)
        player = json_get(wbi_url, jar, ua, referer)
    except FetchError:
        player = None
    if not player or player.get("code") != 0:
        player = json_get("https://api.bilibili.com/x/player/v2?aid=%s&cid=%s" % (aid, cid), jar, ua, referer)
    if player.get("code") != 0:
        raise FetchError("player API error: %s" % player.get("message"))

    player_data = player.get("data") or {}
    subtitles = ((player_data.get("subtitle") or {}).get("subtitles")) or []
    if not subtitles:
        if player_data.get("need_login_subtitle"):
            raise FetchError("未登录：需 Chrome 登录 B 站后才能获取 AI 字幕")
        raise FetchError("该视频无 B 站 AI 字幕")

    chosen = pick_subtitle(subtitles)
    if not chosen:
        raise FetchError("该视频无 B 站 AI 字幕")
    subtitle_url = chosen.get("subtitle_url") or ""
    if subtitle_url.startswith("//"):
        subtitle_url = "https:" + subtitle_url
    if not subtitle_url:
        raise FetchError("字幕条目缺少 subtitle_url")

    caption = json_get(subtitle_url, jar, ua, referer)
    body = caption.get("body") or []
    if not body:
        raise FetchError("字幕内容为空")
    srt = build_srt(body)
    if not srt:
        raise FetchError("字幕内容为空")
    meta = {
        "lan": chosen.get("lan") or "",
        "lan_doc": chosen.get("lan_doc") or chosen.get("lan") or "",
        "aid": aid,
        "cid": cid,
    }
    return srt, meta


def main() -> int:
    parser = argparse.ArgumentParser(description="Fetch Bilibili AI subtitles as SRT")
    parser.add_argument("--bvid", required=True)
    parser.add_argument("--page", type=int, default=1)
    parser.add_argument("--bridge", default="")
    parser.add_argument("--user-agent", default=DEFAULT_UA)
    args = parser.parse_args()

    jar = bridge_jar(args.bridge) if args.bridge else None
    try:
        srt, meta = fetch_subtitle(args.bvid, args.page, jar, args.user_agent, DEFAULT_REFERER)
    except FetchError as error:
        sys.stderr.write(str(error) + "\n")
        return 2 if "字幕" in str(error) or "登录" in str(error) else 3
    sys.stderr.write("@meta " + json.dumps(meta, ensure_ascii=False) + "\n")
    sys.stdout.write(srt + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
