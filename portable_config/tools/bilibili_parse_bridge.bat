@echo off
rem Launcher for bilibili_parse_bridge (detached background service).
rem The bridge must stay alive: the browser-side "Play in mpv" button posts
rem parsed links here. Double-start is harmless (single-instance guard).
rem
start "" "%~dp0..\..\pythonw.exe" "%~dp0bilibili_parse_bridge.py"
