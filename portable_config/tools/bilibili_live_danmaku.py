#!/usr/bin/env python3
"""Small dependency-free Bilibili live danmaku receiver for mpv.

The helper deliberately writes newline-delimited JSON to a temporary file.  mpv
can poll that file without keeping a platform-specific pipe or a visible
console process alive.  The websocket implementation only uses the Python
standard library and requests Bilibili's zlib packet protocol (protover=2).
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.cookiejar
import json
import os
import random
import re
import select
import socket
import ssl
import struct
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import zlib


USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"
)
MIXIN_KEY_ENC_TAB = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
    27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
    37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
    22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
]
def emit(output: str, payload: dict) -> None:
    os.makedirs(os.path.dirname(output) or ".", exist_ok=True)
    with open(output, "a", encoding="utf-8", newline="\n") as stream:
        stream.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
        stream.flush()


def stopped(path: str) -> bool:
    return bool(path) and os.path.exists(path)


def bridge_cookie_jar(bridge: str) -> http.cookiejar.CookieJar:
    if not bridge:
        return http.cookiejar.CookieJar()
    creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    try:
        status = subprocess.run(
            [bridge, "--status"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, check=False, creationflags=creationflags, timeout=5,
        )
        status_payload = json.loads(status.stdout.decode("utf-8", "replace") or "{}")
        if not (status_payload.get("connected") or status_payload.get("cached")):
            return http.cookiejar.CookieJar()
        result = subprocess.run(
            [bridge, "--get", "bilibili"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, check=False, creationflags=creationflags, timeout=40,
        )
        payload = json.loads(result.stdout.decode("utf-8", "replace") or "{}")
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
        return http.cookiejar.CookieJar()
    if not payload.get("ok"):
        return http.cookiejar.CookieJar()
    jar = http.cookiejar.CookieJar()
    for item in payload.get("cookies") or []:
        if not all(isinstance(item.get(key), str) for key in ("name", "value")):
            continue
        # Chrome host-only cookies report an empty domain.  Fall back to the
        # Bilibili eTLD so SESSDATA / bili_jct are still sent to api/live
        # subdomains instead of being dropped by the cookie processor.
        domain = item.get("domain") or ""
        if domain == "":
            domain = "bilibili.com"
        expiry = item.get("expirationDate")
        try:
            expiry = int(expiry) if expiry is not None else None
        except (TypeError, ValueError):
            expiry = None
        jar.set_cookie(http.cookiejar.Cookie(
            0, item["name"], item["value"], None, False, domain, True,
            domain.startswith("."), item.get("path") or "/", True, bool(item.get("secure")),
            expiry, bool(item.get("session")) or expiry is None, None, None,
            {"HttpOnly": bool(item.get("httpOnly"))}, False,
        ))
    return jar


def build_opener(proxy: str, jar: http.cookiejar.CookieJar) -> urllib.request.OpenerDirector:
    handlers = []
    if proxy:
        handlers.append(urllib.request.ProxyHandler({"http": proxy, "https": proxy}))
    else:
        handlers.append(urllib.request.ProxyHandler({}))
    handlers.append(urllib.request.HTTPCookieProcessor(jar))
    return urllib.request.build_opener(*handlers)


def request_json(opener: urllib.request.OpenerDirector, url: str, referer: str) -> dict:
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Referer": referer,
            "Origin": "https://live.bilibili.com",
            "Accept": "application/json, text/plain, */*",
        },
    )
    with opener.open(request, timeout=20) as response:
        return json.loads(response.read().decode("utf-8", "replace"))


def checked_request_json(opener: urllib.request.OpenerDirector, url: str, referer: str) -> dict:
    payload = request_json(opener, url, referer)
    code = payload.get("code")
    if code not in (0, None):
        message = payload.get("message") or payload.get("msg") or f"Bilibili API 返回错误（code={code}）"
        raise RuntimeError(message)
    return payload


def wbi_signed_url(opener: urllib.request.OpenerDirector, room_id: int) -> str:
    nav = checked_request_json(opener, "https://api.bilibili.com/x/web-interface/nav", "https://www.bilibili.com/")
    images = ((nav.get("data") or {}).get("wbi_img") or {})
    img = os.path.basename(urllib.parse.urlparse(images.get("img_url", "")).path).split(".", 1)[0]
    sub = os.path.basename(urllib.parse.urlparse(images.get("sub_url", "")).path).split(".", 1)[0]
    mixin = "".join((img + sub)[index] for index in MIXIN_KEY_ENC_TAB)[:32]
    params = {"id": str(room_id), "type": "0", "wts": str(int(time.time()))}
    query = urllib.parse.urlencode(sorted(params.items()))
    query = re.sub(r"[!'()*]", "", query)
    params["w_rid"] = hashlib.md5((query + mixin).encode("utf-8")).hexdigest()
    return "https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo?" + urllib.parse.urlencode(params)


def room_and_token(opener: urllib.request.OpenerDirector, room_id: int) -> tuple[int, str, list[tuple[str, int]]]:
    init_url = "https://api.live.bilibili.com/room/v1/Room/room_init?id=" + str(room_id)
    init = checked_request_json(opener, init_url, "https://live.bilibili.com/")
    init_data = init.get("data") or {}
    real_room_id = int(init_data.get("room_id") or room_id)
    info = checked_request_json(opener, wbi_signed_url(opener, real_room_id), "https://live.bilibili.com/")
    data = info.get("data") or {}
    token = data.get("token") or ""
    hosts = data.get("host_list") or []
    endpoints: list[tuple[str, int]] = []
    for item in hosts:
        host = str(item.get("host") or "").strip()
        if not host:
            continue
        try:
            wss_port = int(item.get("wss_port") or 443)
        except (TypeError, ValueError):
            wss_port = 443
        endpoint = (host, wss_port)
        if endpoint not in endpoints:
            endpoints.append(endpoint)
    if not endpoints:
        endpoints.append(("broadcastlv.chat.bilibili.com", 443))
    if not token:
        raise RuntimeError("Bilibili 未返回直播弹幕连接参数")
    return real_room_id, token, endpoints


def cookie_identity(jar: http.cookiejar.CookieJar) -> tuple[int, str]:
    uid = 0
    buvid = ""
    for cookie in jar:
        if cookie.name == "DedeUserID":
            try:
                uid = int(cookie.value)
            except (TypeError, ValueError):
                pass
        elif cookie.name in ("buvid3", "buvid4") and not buvid:
            buvid = str(cookie.value or "")
    return uid, buvid


def recv_exact(sock: socket.socket, count: int) -> bytes:
    chunks = []
    remaining = count
    while remaining:
        part = sock.recv(remaining)
        if not part:
            raise ConnectionError("websocket closed")
        chunks.append(part)
        remaining -= len(part)
    return b"".join(chunks)


def websocket_frame(opcode: int, payload: bytes) -> bytes:
    mask = os.urandom(4)
    size = len(payload)
    if size < 126:
        head = struct.pack("!BB", 0x80 | opcode, 0x80 | size)
    elif size <= 0xFFFF:
        head = struct.pack("!BBH", 0x80 | opcode, 0x80 | 126, size)
    else:
        head = struct.pack("!BBQ", 0x80 | opcode, 0x80 | 127, size)
    body = bytes(payload[index] ^ mask[index % 4] for index in range(size))
    return head + mask + body


def websocket_read(sock: socket.socket) -> tuple[int, bytes]:
    first, second = struct.unpack("!BB", recv_exact(sock, 2))
    opcode = first & 0x0F
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", recv_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", recv_exact(sock, 8))[0]
    if second & 0x80:
        mask = recv_exact(sock, 4)
        payload = recv_exact(sock, length)
        payload = bytes(payload[index] ^ mask[index % 4] for index in range(length))
    else:
        payload = recv_exact(sock, length)
    return opcode, payload


def connect_websocket(host: str, port: int, proxy: str) -> ssl.SSLSocket:
    target_host, target_port = host, int(port)
    proxy_url = urllib.parse.urlparse(proxy) if proxy else None
    if proxy_url and proxy_url.hostname:
        proxy_port = proxy_url.port or 80
        sock = socket.create_connection((proxy_url.hostname, proxy_port), timeout=20)
        # Keep the proxy endpoint and the Bilibili WebSocket endpoint separate.
        # The old code overwrote `port` with 10809 and sent CONNECT to
        # host:10809 even when Bilibili had returned wss_port=2245.
        connect = f"CONNECT {target_host}:{target_port} HTTP/1.1\r\nHost: {target_host}:{target_port}\r\n\r\n".encode()
        sock.sendall(connect)
        response = b""
        while b"\r\n\r\n" not in response:
            response += sock.recv(4096)
            if len(response) > 65536:
                raise ConnectionError("代理 CONNECT 响应过长")
        if not response.startswith(b"HTTP/1.1 200") and not response.startswith(b"HTTP/1.0 200"):
            raise ConnectionError("代理无法连接 Bilibili 直播弹幕服务器")
    else:
        sock = socket.create_connection((target_host, target_port), timeout=20)

    context = ssl.create_default_context()
    secure = context.wrap_socket(sock, server_hostname=host)
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    handshake = (
        f"GET /sub HTTP/1.1\r\nHost: {target_host}:{target_port}\r\nUpgrade: websocket\r\n"
        f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
        f"Sec-WebSocket-Version: 13\r\nOrigin: https://live.bilibili.com\r\n"
        f"User-Agent: {USER_AGENT}\r\n\r\n"
    ).encode("ascii")
    secure.sendall(handshake)
    response = b""
    while b"\r\n\r\n" not in response:
        response += secure.recv(4096)
        if len(response) > 65536:
            raise ConnectionError("WebSocket 握手响应过长")
    if b" 101 " not in response.split(b"\r\n", 1)[0]:
        raise ConnectionError("Bilibili 直播弹幕 WebSocket 握手失败")
    secure.settimeout(1.0)
    return secure


def bilibili_packet(operation: int, body: bytes, version: int = 1) -> bytes:
    header = struct.pack("!IHHII", len(body) + 16, 16, version, operation, 1)
    return header + body


def websocket_send(sock: ssl.SSLSocket, operation: int, body: bytes, version: int = 1) -> None:
    sock.sendall(websocket_frame(2, bilibili_packet(operation, body, version)))


def parse_bilibili_packets(blob: bytes):
    offset = 0
    while offset + 16 <= len(blob):
        packet_len, header_len, version, operation, _sequence = struct.unpack(
            "!IHHII", blob[offset:offset + 16]
        )
        if packet_len < header_len or offset + packet_len > len(blob):
            return
        body = blob[offset + header_len:offset + packet_len]
        offset += packet_len
        if version in (2, 3):
            try:
                yield from parse_bilibili_packets(zlib.decompress(body))
            except zlib.error:
                # The receiver explicitly requests protover=2.  Ignore an
                # unexpected brotli frame rather than terminating the stream.
                continue
        else:
            yield operation, body


def parse_message(operation: int, body: bytes):
    if operation != 5:
        return None
    try:
        data = json.loads(body.decode("utf-8", "replace"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    command = str(data.get("cmd") or "")
    if command.startswith("DANMU_MSG"):
        info = data.get("info") or []
        text = str(info[1] if len(info) > 1 else "").strip()
        if not text:
            return None
        user = ""
        user_id = 0
        color = 0xFFFFFF
        if len(info) > 2 and isinstance(info[2], list):
            try:
                user_id = int(info[2][0])
            except (IndexError, TypeError, ValueError):
                pass
            user = str(info[2][1] if len(info[2]) > 1 else "")
        if len(info) > 0 and isinstance(info[0], list) and len(info[0]) > 3:
            try:
                color = int(info[0][3])
            except (TypeError, ValueError):
                pass
        return {"type": "normal", "text": text, "user": user, "user_id": user_id, "color": color}
    if command.startswith("SUPER_CHAT_MESSAGE"):
        message = data.get("data") or {}
        text = str(message.get("message") or "").strip()
        if not text:
            return None
        user_info = message.get("user_info") or {}
        duration = message.get("time") or 30
        price = message.get("price")
        try:
            duration = max(1, min(float(duration), 3600))
        except (TypeError, ValueError):
            duration = 30
        try:
            price = max(0, float(price))
        except (TypeError, ValueError):
            price = None
        return {
            "type": "superchat",
            "id": str(message.get("id") or f"{time.time_ns()}-{random.randrange(1000)}"),
            "text": text,
            "user": str(user_info.get("uname") or message.get("uname") or "醒目留言"),
            "color": str(message.get("background_color") or "#2A60B2"),
            "duration": duration,
            "price": price,
        }
    return None


def parse_auth_code(operation: int, body: bytes) -> int | None:
    """Return Bilibili's WebSocket authentication code, if this is op=8."""
    if operation != 8:
        return None
    try:
        payload = json.loads(body.decode("utf-8", "replace"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(payload, dict) or "code" not in payload:
        return None
    try:
        return int(payload["code"])
    except (TypeError, ValueError):
        return None


def authenticate(sock: ssl.SSLSocket, room_id: int, token: str, jar: http.cookiejar.CookieJar) -> None:
    uid, buvid = cookie_identity(jar)
    auth_data = {
        "uid": uid, "roomid": room_id, "protover": 2, "platform": "web",
        "type": 2, "key": token,
    }
    if buvid:
        auth_data["buvid"] = buvid
    websocket_send(sock, 7, json.dumps(auth_data, separators=(",", ":")).encode("utf-8"))

    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        readable, _, _ = select.select([sock], [], [], 1.0)
        if not readable:
            continue
        opcode, payload = websocket_read(sock)
        if opcode == 8:
            raise ConnectionError("Bilibili 直播弹幕认证连接已关闭")
        if opcode == 9:
            sock.sendall(websocket_frame(10, payload))
            continue
        if opcode != 2:
            continue
        for operation, body in parse_bilibili_packets(payload):
            code = parse_auth_code(operation, body)
            if code is None:
                continue
            if code != 0:
                raise ConnectionError(f"Bilibili 直播弹幕认证失败（code={code}）")
            return
    raise TimeoutError("等待 Bilibili 直播弹幕认证响应超时")


def receive(room_id: int, output: str, stop_file: str, proxy: str, jar: http.cookiejar.CookieJar) -> None:
    opener = build_opener(proxy, jar)
    real_room_id, token, endpoints = room_and_token(opener, room_id)
    user_id, _ = cookie_identity(jar)

    last_error = None
    sock = None
    for host, wss_port in endpoints:
        try:
            candidate = connect_websocket(host, wss_port, proxy)
            authenticate(candidate, real_room_id, token, jar)
            sock = candidate
            break
        except Exception as error:
            last_error = error
            try:
                candidate.close()
            except Exception:
                pass
    if sock is None:
        raise ConnectionError("无法连接任何 Bilibili 直播弹幕节点: " + str(last_error or "unknown error"))

    # Only report ready after the server has accepted the auth packet. This
    # prevents mpv from showing a false connected state while the socket is
    # already being rejected by Bilibili.
    emit(output, {"type": "ready", "room_id": real_room_id, "user_id": user_id})
    last_heartbeat = time.monotonic()
    try:
        while not stopped(stop_file):
            if time.monotonic() - last_heartbeat >= 25:
                websocket_send(sock, 2, b"[object Object]")
                last_heartbeat = time.monotonic()
            try:
                readable, _, _ = select.select([sock], [], [], 1.0)
                if not readable:
                    continue
                opcode, payload = websocket_read(sock)
            except socket.timeout:
                continue
            if opcode == 8:
                raise ConnectionError("直播弹幕连接已关闭")
            if opcode == 9:
                sock.sendall(websocket_frame(10, payload))
                continue
            if opcode != 2:
                continue
            for operation, body in parse_bilibili_packets(payload):
                event = parse_message(operation, body)
                if event:
                    emit(output, event)
    finally:
        try:
            sock.close()
        except Exception:
            pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--room", type=int, required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--stop", required=True)
    parser.add_argument("--proxy", default="")
    parser.add_argument("--bridge", default="")
    args = parser.parse_args()
    cookie_jar = None
    try:
        while not stopped(args.stop):
            try:
                # Fetch once at startup and keep the in-memory jar for the
                # lifetime of this live receiver.  A websocket reconnect must
                # not require Chrome to remain open after playback begins.
                if cookie_jar is None:
                    cookie_jar = bridge_cookie_jar(args.bridge)
                receive(args.room, args.output, args.stop, args.proxy, cookie_jar)
            except Exception as error:
                if stopped(args.stop):
                    break
                emit(args.output, {"type": "error", "message": str(error)})
                time.sleep(5)
    finally:
        try:
            os.remove(args.stop)
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
