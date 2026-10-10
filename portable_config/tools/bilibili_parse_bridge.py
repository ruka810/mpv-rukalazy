#!/usr/bin/env python3
"""bilibili_parse_bridge —— 接收油猴脚本解析出的 B 站直链并在本地 mpv 中新开窗口播放。

配合文件:
  bilibili_parse_relay.user.js   浏览器侧: 往 injahow「bilibili视频下载」面板注入
                                 「在 mpv 播放」按钮, 点击后把直链 POST 到本桥。
  bilibili_parse_bridge.lua      mpv 启动时 detached 拉起本桥(仅拉起, 不随 mpv 退出停止)。

接口:
  GET  /health   -> {"ok": true}
  POST /play     -> {"title": str, "video": str, "audio": str, "ua": str}
                    校验通过后 spawn 一个新 mpv.exe 窗口播放; 返回 {"ok": true, "pid": ...}

安全: 只绑定 127.0.0.1 回环; 仅放行 bilibili 相关域名的 http(s) 直链, 防止本地
端口被其它网页滥用去拉起任意 URL。

日志: 写在脚本所在目录 bilibili_parse_bridge.log。
"""

from __future__ import annotations

import json
import logging
import os
import re
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent
PROJECT_ROOT = ROOT.parent.parent  # e:\mpv-lazy
MPV_EXE = PROJECT_ROOT / "mpv.exe"
LOG_FILE = ROOT / "bilibili_parse_bridge.log"

HOST = "127.0.0.1"
PORT = 8322

# B 站直链 CDN 域名(含港区番剧的 biliintl 域)。
ALLOWED_HOST_SUFFIXES = (
    ".bilivideo.com",
    ".bilivideo.cn",
    ".bilibili.com",
    ".biliintl.com",
    ".akamaized.net",
    ".hdslb.com",
)

DEFAULT_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)

# 自动退出: 桥拉起的 mpv 窗口全部关闭后, 再等这么久退出(给快速二次点击留缓冲)。
SPAWN_GRACE_SECONDS = 8

LOCK_FILE = ROOT / "bilibili_parse_bridge.lock"

MAX_PAYLOAD_BYTES = 64 * 1024

_log = logging.getLogger("bilibili_parse_bridge")

# 由本桥 spawn 的 mpv 进程跟踪(用于"关闭后自动关桥")。
_spawned_mpvs: set[subprocess.Popen] = set()
_spawned_mpvs_lock = threading.Lock()
_ever_spawned = False


def _has_bilibili_signature(query: str) -> bool:
    """识别 B 站 playurl 直链的强特征(第三方镜像如 mountaintoys 也用同一套签名)。

    包含 deadline 时间戳 + gen=playurl(v3) + mid/bvc 三者才放行, 普通任意 URL 不具备。
    """
    q = query.lower()
    return (
        "deadline=" in q
        and ("gen=playurlv3" in q or "gen=playurl" in q)
        and ("mid=" in q or "bvc=vod" in q)
    )


def _is_allowed_url(raw: str) -> bool:
    """只放行 B 站直链: 已知 CDN 域名, 或带 playurl 签名的第三方镜像。"""
    if not raw:
        return False
    try:
        parts = urlsplit(raw)
    except ValueError:
        return False
    if parts.scheme not in ("http", "https"):
        return False
    host = (parts.hostname or "").lower()
    if not host:
        return False
    if any(host == s or host.endswith(s) for s in ALLOWED_HOST_SUFFIXES):
        return True
    # 远程解析服务的镜像域(如 rq3a904j.edge.mountaintoys.cn): 仅凭签名放行。
    return _has_bilibili_signature(parts.query)


def _sanitize_title(title: str) -> str:
    title = (title or "").strip() or "bilibili"
    title = re.sub(r"[\r\n\t]+", " ", title)
    title = title[:80]
    return title


def _extract_cid_from_url(raw: str) -> int | None:
    """B 站直链 CDN 路径里自带 cid: .../{cid}/{cid}-{qn}-{frag}.mp4|m4s。

    油猴脚本未更新 / 提取不到 cid 时, 用路径兜底, 保证弹幕可用。
    """
    if not raw:
        return None
    try:
        path = urlsplit(raw).path
    except ValueError:
        return None
    m = re.search(r"/(\d+)(?:-\d+[-\w]*)?\.(?:mp4|m4s|flv)$", path, re.IGNORECASE)
    return int(m.group(1)) if m else None


def _spawn_mpv(video: str, audio: str, title: str, ua: str, cid: int | None) -> int:
    if not MPV_EXE.exists():
        raise FileNotFoundError(f"mpv.exe 不存在: {MPV_EXE}")

    if not cid or cid <= 0:
        cid = _extract_cid_from_url(video)

    args = [str(MPV_EXE)]
    args.append(video)
    if audio:
        args.append(f"--audio-file={audio}")
    args.append(f"--user-agent={ua or DEFAULT_UA}")
    args.append("--referrer=https://www.bilibili.com")
    args.append(f"--title={_sanitize_title(title)}")
    args.append("--force-window=yes")
    args.append("--keep-open=yes")
    if cid and cid > 0:
        # 直链本身不是 bilibili 网页 URL, 弹幕脚本无法反解 cid; 通过 script-opts
        # 预注入 cid, 让 bilibili_danmaku 直接走 comment.bilibili.com/{cid}.xml。
        # 注意: mpv read_options 用原样键名匹配, 键必须用下划线 preload_cid。
        args.append(f"--script-opts=bilibili_danmaku-preload_cid={cid}")

    # 新开窗口, 独立于桥进程; mpv-lazy 的 portable_config 由可执行文件位置决定,
    # 这里再显式指定 cwd 到项目根以保证便携配置与 python.exe 的解析行为一致。
    proc = subprocess.Popen(args, cwd=str(PROJECT_ROOT))
    with _spawned_mpvs_lock:
        global _ever_spawned
        _ever_spawned = True
        _spawned_mpvs.add(proc)
    _log.info("spawned mpv pid=%s title=%r cid=%s audio=%s video=%s", proc.pid, title, cid, audio, video)
    return proc.pid


def _watchdog() -> None:
    """后台线程: 本桥曾拉起过的 mpv 窗口全部关闭后, 再宽限几秒自动退出。

    由 Lua/.bat 常驻启动、但从未服务过点击的桥不受影响(保持常驻)。
    """
    last_empty_since: float | None = None
    while True:
        time.sleep(2)
        with _spawned_mpvs_lock:
            for p in [p for p in _spawned_mpvs if p.poll() is not None]:
                _spawned_mpvs.remove(p)
            spawned_now = bool(_spawned_mpvs)
            ever = _ever_spawned
        if spawned_now:
            last_empty_since = None
            continue
        if not ever:
            continue
        now = time.monotonic()
        if last_empty_since is None:
            last_empty_since = now
        elif now - last_empty_since >= SPAWN_GRACE_SECONDS:
            _log.info("all spawned mpv closed, shutting down bridge")
            _release_lock()
            os._exit(0)


class _Handler(BaseHTTPRequestHandler):
    # 关闭默认的请求日志(避免污染 stderr/控制台), 错误与投递日志统一走文件。
    def log_message(self, *_args) -> None:
        pass

    def _send_json(self, status: int, obj: dict) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/health":
            self._send_json(200, {"ok": True})
        else:
            self._send_json(404, {"error": "not found"})

    def do_POST(self) -> None:
        if self.path != "/play":
            self._send_json(404, {"error": "not found"})
            return

        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_PAYLOAD_BYTES:
            self._send_json(400, {"error": "bad content-length"})
            return
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            if not isinstance(payload, dict):
                raise ValueError("payload must be an object")
        except Exception as exc:  # noqa: BLE001
            _log.warning("bad /play payload: %s", exc)
            self._send_json(400, {"error": f"bad json: {exc}"})
            return

        video = (payload.get("video") or "").strip()
        audio = (payload.get("audio") or "").strip()
        title = _sanitize_title(payload.get("title") or "bilibili")
        ua = (payload.get("ua") or "").strip()
        cid = payload.get("cid")
        if cid is not None:
            if not (isinstance(cid, int) or (isinstance(cid, str) and cid.isdigit())):
                self._send_json(400, {"error": "bad cid"})
                return
            cid = int(cid)
        else:
            cid = None

        if not _is_allowed_url(video) or (audio and not _is_allowed_url(audio)):
            _log.warning("rejected url: video=%r audio=%r", video, audio)
            self._send_json(400, {"error": "url not allowed"})
            return

        try:
            pid = _spawn_mpv(video, audio, title, ua, cid)
        except Exception as exc:  # noqa: BLE001
            _log.exception("spawn mpv failed")
            self._send_json(500, {"error": str(exc)})
            return

        self._send_json(200, {"ok": True, "pid": pid})


def _port_in_use_by_this_bridge() -> bool:
    """端口已被本桥占用时返回 True(健康检查可达)。"""
    try:
        with urllib.request.urlopen(f"http://{HOST}:{PORT}/health", timeout=2) as resp:  # noqa: S310
            if resp.status == 200:
                return True
    except Exception:  # noqa: BLE001
        pass
    return False


def _acquire_lock() -> bool:
    """独占创建锁文件; 失败说明可能已有实例在跑(或锁文件残留)。"""
    try:
        fd = os.open(LOCK_FILE, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        return False
    try:
        os.write(fd, str(os.getpid()).encode("ascii"))
    except OSError:
        pass
    os.close(fd)
    return True


def _release_lock() -> None:
    try:
        os.remove(LOCK_FILE)
    except OSError:
        pass


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=[logging.FileHandler(LOG_FILE, encoding="utf-8")],
        force=True,
    )
    if not _acquire_lock():
        if _port_in_use_by_this_bridge():
            # 已有实例在正常服务 → 静默退出(双启动无害)。
            return
        # 锁文件残留(实例被强杀)但端口没人监听 → 清理后重试一次。
        _release_lock()
        if not _acquire_lock():
            _log.error("lock file busy: %s", LOCK_FILE)
            sys.exit(1)
    try:
        server = ThreadingHTTPServer((HOST, PORT), _Handler)
    except OSError:
        _release_lock()
        _log.exception("failed to bind %s:%s", HOST, PORT)
        sys.exit(1)

    server.daemon_threads = True
    threading.Thread(target=_watchdog, daemon=True).start()
    _log.info("listening on http://%s:%s (mpv=%s)", HOST, PORT, MPV_EXE)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        _log.info("shutting down")
    finally:
        _release_lock()


if __name__ == "__main__":
    main()
