#!/usr/bin/env python3
"""Fetch a Bilibili resource with Chrome Bridge cookies held only in memory."""

from __future__ import annotations

import argparse
import gzip
import http.cookiejar
import json
import os
import subprocess
import sys
import urllib.request
import zlib


def bridge_jar(bridge: str) -> http.cookiejar.CookieJar | None:
    creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    try:
        status = subprocess.run([bridge, "--status"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, check=False, creationflags=creationflags, timeout=5)
        status_payload = json.loads(status.stdout.decode("utf-8", "replace") or "{}")
        if not (status_payload.get("connected") or status_payload.get("cached")):
            return None
        result = subprocess.run([bridge, "--get", "bilibili"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, check=False, creationflags=creationflags, timeout=40)
        payload = json.loads(result.stdout.decode("utf-8", "replace") or "{}")
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
        return None
    if not payload.get("ok"):
        return None
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
        jar.set_cookie(http.cookiejar.Cookie(0, item["name"], item["value"], None, False, domain, True,
            domain.startswith("."), item.get("path") or "/", True, bool(item.get("secure")), expiry,
            bool(item.get("session")) or expiry is None, None, None, {"HttpOnly": bool(item.get("httpOnly"))}, False))
    return jar


def decode_response_body(body: bytes, content_encoding: str | None) -> bytes:
    encoding = (content_encoding or "").lower()
    if encoding == "gzip":
        return gzip.decompress(body)
    if encoding == "deflate":
        try:
            return zlib.decompress(body)
        except zlib.error:
            return zlib.decompress(body, -zlib.MAX_WBITS)
    return body


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bridge", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--output")
    parser.add_argument("--proxy", default="")
    parser.add_argument("--referer", default="https://www.bilibili.com/")
    parser.add_argument("--user-agent", required=True)
    args = parser.parse_args()
    handlers = []
    jar = bridge_jar(args.bridge)
    if jar is not None:
        handlers.append(urllib.request.HTTPCookieProcessor(jar))
    handlers.insert(0, urllib.request.ProxyHandler({"http": args.proxy, "https": args.proxy} if args.proxy else {}))
    # Do not advertise compressed responses here.  The Lua callers consume the
    # returned JSON/XML directly, and urllib does not transparently decode all
    # encodings that curl's --compressed handled in the previous implementation.
    request = urllib.request.Request(args.url, headers={"User-Agent": args.user_agent, "Referer": args.referer})
    with urllib.request.build_opener(*handlers).open(request, timeout=30) as response:
        body = decode_response_body(response.read(), response.headers.get("Content-Encoding"))
    if args.output:
        with open(args.output, "wb") as stream:
            stream.write(body)
    else:
        sys.stdout.buffer.write(body)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
