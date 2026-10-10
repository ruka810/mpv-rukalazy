#!/usr/bin/env python3
"""Fetch and convert a Bilibili VOD danmaku stream in one sequential job."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


def write_error(path: str, message: str) -> None:
    Path(path).write_text(message, encoding="utf-8")


def run_child(args: list[str], label: str) -> None:
    creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    try:
        result = subprocess.run(
            args,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            creationflags=creationflags,
            timeout=45,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError(f"{label}: {exc}") from exc
    if result.returncode == 0:
        return
    details = result.stderr.decode("utf-8", "replace").strip()
    raise RuntimeError(f"{label} failed ({result.returncode})" + (f": {details}" if details else ""))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bvid", default=None)
    parser.add_argument("--page", type=int, required=True)
    parser.add_argument("--width", type=int, required=True)
    parser.add_argument("--height", type=int, required=True)
    parser.add_argument("--bridge", required=True)
    parser.add_argument("--fetcher", required=True)
    parser.add_argument("--converter", required=True)
    parser.add_argument("--api-output", required=True)
    parser.add_argument("--xml-output", required=True)
    parser.add_argument("--overlay-output", required=True)
    parser.add_argument("--error-output", required=True)
    parser.add_argument("--user-agent", required=True)
    parser.add_argument("--cid", type=int, default=None)
    args = parser.parse_args()

    try:
        fetch_base = [sys.executable, args.fetcher, "--bridge", args.bridge, "--user-agent", args.user_agent]
        if args.cid:
            # 直连模式：cid 已由浏览器侧直接提供（如 __INITIAL_STATE__），跳过 view API。
            cid = args.cid
        else:
            if not args.bvid:
                raise RuntimeError("neither --bvid nor --cid given")
            run_child(
                fetch_base + [
                    "--url", f"https://api.bilibili.com/x/web-interface/view?bvid={args.bvid}",
                    "--output", args.api_output,
                ],
                "Bilibili view API",
            )
            response = json.loads(Path(args.api_output).read_text(encoding="utf-8"))
            video = response.get("data") if response.get("code") == 0 else None
            pages = video.get("pages") if isinstance(video, dict) else None
            selected = pages[args.page - 1] if isinstance(pages, list) and 0 < args.page <= len(pages) else None
            cid = selected.get("cid") if isinstance(selected, dict) else (video.get("cid") if args.page == 1 and isinstance(video, dict) else None)
            if not cid:
                raise RuntimeError("Bilibili view API did not return a CID")

        run_child(
            fetch_base + ["--url", f"https://comment.bilibili.com/{cid}.xml", "--output", args.xml_output],
            "Bilibili danmaku XML",
        )
        # 默认显示区域：不保留底部留白，弹幕可铺满整个高度
        reserved = 0
        run_child(
            [
                sys.executable, args.converter, "-f", "Bilibili", "-s", f"{args.width}x{args.height}",
                "-fn", "Microsoft YaHei", "-fs", "45", "-a", "1.0", "-p", str(reserved),
                "-dm", "8", "-ds", "5", "-r", "--overlay-events", args.overlay_output, args.xml_output,
            ],
            "Bilibili danmaku conversion",
        )
    except (OSError, ValueError, json.JSONDecodeError, RuntimeError) as exc:
        write_error(args.error_output, str(exc))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
