#!/usr/bin/env python3
"""Send one ordinary Bilibili Live danmaku using the in-memory Chrome bridge."""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

# The portable Python runtime uses an isolated module path, so sibling helpers
# are not added automatically when this script is launched by mpv.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from bilibili_live_danmaku import USER_AGENT, bridge_cookie_jar, build_opener, request_json


def response(ok: bool, **payload: object) -> int:
    print(json.dumps({"ok": ok, **payload}, ensure_ascii=False, separators=(",", ":")))
    return 0


def csrf_from_jar(jar) -> str:
    for cookie in jar:
        if cookie.name == "bili_jct" and cookie.value:
            return str(cookie.value)
    raise RuntimeError("未获取到 Bilibili 登录凭据，请确认 Chrome 已登录并且 Cookie Bridge 正在运行")


def resolve_room_id(opener, room_id: int) -> int:
    payload = request_json(
        opener,
        "https://api.live.bilibili.com/room/v1/Room/room_init?id=" + str(room_id),
        "https://live.bilibili.com/",
    )
    if payload.get("code") not in (0, None):
        raise RuntimeError(str(payload.get("message") or "无法确认直播间状态"))
    data = payload.get("data") or {}
    try:
        return int(data.get("room_id") or room_id)
    except (TypeError, ValueError) as error:
        raise RuntimeError("直播间编号无效") from error


def send_danmaku(opener, room_id: int, message: str, csrf: str) -> dict:
    body = urllib.parse.urlencode({
        "bubble": "0",
        "msg": message,
        "color": "16777215",
        "mode": "1",
        "fontsize": "25",
        "rnd": str(int(time.time())),
        "roomid": str(room_id),
        "csrf": csrf,
        "csrf_token": csrf,
    }).encode("utf-8")
    request = urllib.request.Request(
        "https://api.live.bilibili.com/msg/send",
        data=body,
        headers={
            "User-Agent": USER_AGENT,
            "Referer": "https://live.bilibili.com/" + str(room_id),
            "Origin": "https://live.bilibili.com",
            "Accept": "application/json, text/plain, */*",
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
            "X-Requested-With": "XMLHttpRequest",
        },
    )
    with opener.open(request, timeout=20) as raw:
        payload = json.loads(raw.read().decode("utf-8", "replace"))
    if payload.get("code") != 0:
        raise RuntimeError(str(payload.get("message") or "弹幕发送失败"))
    return payload


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--room", type=int, required=True)
    parser.add_argument("--message", required=True)
    parser.add_argument("--bridge", required=True)
    args = parser.parse_args()

    message = args.message.replace("\r", " ").replace("\n", " ")
    if not message.strip():
        return response(False, error="请输入弹幕")

    try:
        jar = bridge_cookie_jar(args.bridge)
        csrf = csrf_from_jar(jar)
        opener = build_opener("", jar)
        room_id = resolve_room_id(opener, args.room)
        send_danmaku(opener, room_id, message, csrf)
        return response(True, room_id=room_id)
    except Exception as error:
        return response(False, error=str(error) or "弹幕发送失败")


if __name__ == "__main__":
    raise SystemExit(main())
