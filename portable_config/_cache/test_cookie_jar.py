import http.cookiejar
import urllib.request
import sys
sys.path.insert(0, 'E:/mpv-lazy/portable_config/tools')
from bilibili_live_danmaku import bridge_cookie_jar

# Simulate what Chrome Bridge might return for a host-only SESSDATA cookie
cookies = [
    {"name": "SESSDATA", "value": "test_sessdata", "domain": "", "path": "/", "secure": True, "httpOnly": True},
    {"name": "bili_jct", "value": "test_jct", "domain": "bilibili.com", "path": "/", "secure": False},
    {"name": "DedeUserID", "value": "12345", "domain": "", "path": "/", "secure": False},
]

# Patch bridge_cookie_jar to use simulated cookies without running subprocess
import json
import subprocess

def fake_run(*args, **kwargs):
    class R:
        stdout = json.dumps({"ok": True, "connected": True, "cookies": cookies}).encode()
    return R()

subprocess.run = fake_run

jar = bridge_cookie_jar("dummy.exe")
print("Cookies in jar:")
for c in jar:
    print(f"  {c.name}={c.value[:20]} domain={c.domain} path={c.path}")

# Test that cookies are sent to api.bilibili.com
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
req = urllib.request.Request("https://api.bilibili.com/x/web-interface/nav")
jar.add_cookie_header(req)
print("Cookie header for api.bilibili.com:", req.get_header("Cookie"))
