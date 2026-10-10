// ==UserScript==
// @name         bilibili 解析直链 → 本地 mpv 播放
// @namespace    local.bilibili-mpv-relay
// @version      0.1.0
// @description  在 injahow「bilibili视频下载」面板中新增「在 mpv 播放」按钮；点击后把当前解析出的直链交给本地桥 bilibili_parse_bridge，新开一个 mpv 窗口播放。不做自动跳转，按钮未解析时置灰。
// @match        *://www.bilibili.com/video/*
// @match        *://www.bilibili.com/bangumi/play/*
// @match        *://www.bilibili.com/cheese/play/*
// @match        *://www.bilibili.com/list/*
// @match        *://www.bilibili.com/festival/*
// @grant        GM_xmlhttpRequest
// @connect      127.0.0.1
// @connect      localhost
// @run-at       document-idle
// ==/UserScript==

(function () {
    'use strict';

    var BRIDGE = 'http://127.0.0.1:8322';
    var SCHEME = 'bilibili-mpv://start';
    var BTN_ID = 'bp_relay_mpv';
    var FLOAT_ID = 'bp_relay_mpv_float';
    var BUTTON_TEXT = '在 mpv 播放';
    var BASE_STYLE = [
        'padding:2px 10px',
        'border:1px solid #00a1d6',
        'background:#00a1d6',
        'color:#fff',
        'border-radius:4px',
        'cursor:pointer',
        'font-size:13px',
        'line-height:20px',
        'user-select:none'
    ].join(';');

    function hrefOf(sel) {
        var el = document.querySelector(sel);
        if (!el) return '#';
        var href = el.getAttribute('href') || '';
        return href;
    }

    function videoHref() { return hrefOf('#video_url'); }
    function audioHref() { return hrefOf('#video_url_2'); }

    // 从页面初始状态提取当前视频的 cid（弹幕接口 comment.bilibili.com/{cid}.xml 用）。
    // 普通视频/番剧在 __INITIAL_STATE__.videoData.pages[p-1].cid，部分番剧页在 epInfo.cid。
    function extractCid() {
        var s = window.__INITIAL_STATE__;
        if (!s) return null;
        var vd = s.videoData;
        if (vd && Array.isArray(vd.pages) && vd.pages.length) {
            var p = Number(new URLSearchParams(location.search).get('p')) || Number(s.p) || 1;
            var pg = vd.pages[p - 1] || vd.pages[0];
            if (pg && pg.cid) return Number(pg.cid);
        }
        if (vd && vd.cid) return Number(vd.cid);
        if (s.epInfo && s.epInfo.cid) return Number(s.epInfo.cid);
        return null;
    }

    function bridgeUp(cb) {
        GM_xmlhttpRequest({
            method: 'GET',
            url: BRIDGE + '/health',
            timeout: 1500,
            onload: function (r) { cb(r.status === 200); },
            onerror: function () { cb(false); },
            ontimeout: function () { cb(false); }
        });
    }

    // 浏览器无法静默启动本地进程; 通过自定义协议 bilibili-mpv:// 让 Windows 拉起桥。
    // 首次使用 Chrome 会弹"打开应用?"确认框, 勾选"始终允许"后即静默。
    function startBridgeThen(cb) {
        bridgeUp(function (up) {
            if (up) { cb(); return; }
            window.open(SCHEME, '_blank');
            var deadline = Date.now() + 5000;
            (function poll() {
                bridgeUp(function (ok) {
                    if (ok) { cb(); return; }
                    if (Date.now() < deadline) { setTimeout(poll, 400); return; }
                    alert('本地桥未能自动启动：请先运行 install_bridge_scheme.ps1 注册自动启动，或双击 bilibili_parse_bridge.bat。');
                });
            })();
        });
    }

    function doPost(payload) {
        GM_xmlhttpRequest({
            method: 'POST',
            url: BRIDGE + '/play',
            headers: { 'Content-Type': 'application/json' },
            data: JSON.stringify(payload),
            timeout: 6000,
            onload: function (r) {
                if (r.status !== 200) {
                    alert('投递失败: ' + String(r.responseText || r.status).slice(0, 200));
                }
            },
            onerror: function () {
                alert('本地桥未运行。请先双击启动 portable_config/tools/bilibili_parse_bridge.bat，或先打开一次 mpv。');
            },
            ontimeout: function () {
                alert('本地桥无响应。请确认 bilibili_parse_bridge 在运行（127.0.0.1:8322）。');
            }
        });
    }

    function onClick() {
        var video = videoHref();
        var audio = audioHref();
        if (video === '#' || video === '') {
            alert('尚未解析出地址，请先点击 injahow 脚本的「请求地址」');
            return;
        }
        var title = (document.title || 'bilibili').replace(/[\r\n\t]+/g, ' ').slice(0, 80);
        var payload = {
            title: title,
            video: video,
            audio: audio === '#' ? '' : audio,
            ua: navigator.userAgent
        };
        var cid = extractCid();
        if (cid) { payload.cid = cid; }
        startBridgeThen(function () { doPost(payload); });
    }

    function applyState(btn) {
        var ok = videoHref() !== '#';
        btn.disabled = !ok;
        btn.style.opacity = ok ? '1' : '0.45';
        btn.title = ok ? '将当前解析出的直链投递给本地 mpv' : '尚未解析，先点「请求地址」';
    }

    function makeButton() {
        var btn = document.createElement('button');
        btn.id = BTN_ID;
        btn.type = 'button';
        btn.textContent = BUTTON_TEXT;
        btn.style.cssText = BASE_STYLE;
        btn.addEventListener('click', onClick);
        return btn;
    }

    function injectIntoToolbar() {
        // injahow 的工具栏 #bp_toolbar 会在切换视频时被重建；找不到就退回浮动按钮。
        var toolbar = document.getElementById('bp_toolbar');
        if (!toolbar) return false;

        var existing = document.getElementById(BTN_ID);
        if (existing && existing.parentElement === toolbar) {
            applyState(existing);
            return true;
        }
        if (existing) { existing.remove(); }

        var btn = makeButton();
        toolbar.appendChild(btn);
        applyState(btn);
        // 工具栏已可用时，撤掉之前可能挂出来的浮动按钮，避免两处重复。
        var floatBtn = document.getElementById(FLOAT_ID);
        if (floatBtn) { floatBtn.remove(); }
        return true;
    }

    function ensureFloatButton() {
        var btn = document.getElementById(FLOAT_ID);
        if (!btn) {
            btn = document.createElement('button');
            btn.id = FLOAT_ID;
            btn.type = 'button';
            btn.textContent = BUTTON_TEXT;
            btn.style.cssText = BASE_STYLE + ';position:fixed;right:16px;bottom:90px;z-index:2147483000;box-shadow:0 2px 8px rgba(0,0,0,.3)';
            btn.addEventListener('click', onClick);
            document.body.appendChild(btn);
        }
        applyState(btn);
    }

    // injahow 面板加载是异步的(等 nav-searchform 出现后注入)，轮询即可。
    setInterval(function () {
        if (!injectIntoToolbar()) {
            // 工具栏不存在时，先确认 injahow 面板已出现(#bp_root)再放浮动按钮，
            // 避免在纯非目标页误显示。
            if (document.getElementById('bp_root')) {
                ensureFloatButton();
            }
        }
    }, 1000);
})();
