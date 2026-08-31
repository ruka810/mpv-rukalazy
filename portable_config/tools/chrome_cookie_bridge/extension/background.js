const BRIDGE_PROTOCOL = 2;
const NATIVE_HOST = 'com.mpv_lazy.cookie_bridge';
const HEALTH_URL = 'http://127.0.0.1:49814/health';
const BRIDGE_URL = 'ws://127.0.0.1:49814/bridge';
const SITE_DOMAINS = {
  bilibili: ['bilibili.com'],
  youtube: ['youtube.com', 'google.com', 'youtu.be'],
};

const RECONNECT_ALARM = 'mpv-cookie-bridge-reconnect';
const HEARTBEAT_MS = 15_000;
const FAST_RETRY_MS = 2_000;
const NATIVE_READY_TIMEOUT_MS = 5_000;
const HEALTH_TIMEOUT_MS = 1_500;

let socket;
let nativePort;
let nativeReady = false;
let nativeReadyPromise;
let resolveNativeReady;
let retryTimer;
let nativeReadyTimer;
let heartbeatTimer;
let connectInFlight = false;

function setBridgeState(state) {
  const details = {
    connected: { badge: '', title: 'mpv Chrome Cookie Bridge connected' },
    starting: { badge: '', title: 'mpv Chrome Cookie Bridge is waiting for the local bridge' },
    nativeError: { badge: '!', title: 'mpv Chrome Cookie Bridge cannot start the local bridge' },
  };
  const detail = details[state] || details.starting;
  void chrome.action.setBadgeText({ text: detail.badge });
  if (detail.badge) void chrome.action.setBadgeBackgroundColor({ color: '#b42318' });
  void chrome.action.setTitle({ title: detail.title });
}

function scheduleReconnect(delay = FAST_RETRY_MS) {
  clearTimeout(retryTimer);
  retryTimer = setTimeout(() => {
    retryTimer = undefined;
    void connect();
  }, delay);
}

function stopHeartbeat() {
  clearInterval(heartbeatTimer);
  heartbeatTimer = undefined;
}

function startHeartbeat() {
  stopHeartbeat();
  heartbeatTimer = setInterval(() => {
    if (!send({ type: 'ping' })) void connect();
  }, HEARTBEAT_MS);
}

function settleNativeReady(ready) {
  clearTimeout(nativeReadyTimer);
  nativeReadyTimer = undefined;
  const resolve = resolveNativeReady;
  resolveNativeReady = undefined;
  nativeReadyPromise = undefined;
  if (resolve) resolve(ready);
}

function markNativeUnavailable(port, showError) {
  if (nativePort !== port) return;
  nativePort = undefined;
  nativeReady = false;
  settleNativeReady(false);
  setBridgeState(showError ? 'nativeError' : 'starting');
}

function ensureNativeBridge() {
  if (nativeReady) return Promise.resolve(true);
  if (nativeReadyPromise) return nativeReadyPromise;

  nativeReadyPromise = new Promise((resolve) => {
    resolveNativeReady = resolve;
  });

  try {
    const port = chrome.runtime.connectNative(NATIVE_HOST);
    nativePort = port;
    nativeReadyTimer = setTimeout(() => {
      if (nativePort !== port || nativeReady) return;
      try { port.disconnect(); } catch (_) { }
      markNativeUnavailable(port, true);
      scheduleReconnect();
    }, NATIVE_READY_TIMEOUT_MS);
    port.onMessage.addListener((message) => {
      if (nativePort !== port || !message) return;
      if (message.type === 'bridge-ready' && Number(message.protocol) === BRIDGE_PROTOCOL) {
        nativeReady = true;
        settleNativeReady(true);
        return;
      }
      if (message.type === 'bridge-error') {
        markNativeUnavailable(port, true);
        scheduleReconnect();
      }
    });
    port.onDisconnect.addListener(() => {
      const disconnectedWithError = Boolean(chrome.runtime.lastError);
      markNativeUnavailable(port, disconnectedWithError);
      scheduleReconnect();
    });
    port.postMessage({ type: 'ensure-bridge', protocol: BRIDGE_PROTOCOL });
  } catch (_) {
    markNativeUnavailable(nativePort, true);
    scheduleReconnect();
  }

  return nativeReadyPromise;
}

async function bridgeHealthy() {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), HEALTH_TIMEOUT_MS);
  try {
    const response = await fetch(HEALTH_URL, { cache: 'no-store', signal: controller.signal });
    if (!response.ok) return false;
    const health = await response.json();
    return health?.ready === true && Number(health.protocol) === BRIDGE_PROTOCOL;
  } catch (_) {
    return false;
  } finally {
    clearTimeout(timeout);
  }
}

async function connect() {
  if (connectInFlight || socket?.readyState === WebSocket.OPEN || socket?.readyState === WebSocket.CONNECTING) return;
  connectInFlight = true;
  setBridgeState('starting');
  try {
    const nativeAvailable = await ensureNativeBridge();
    if (!await bridgeHealthy()) {
      setBridgeState(nativeAvailable ? 'starting' : 'nativeError');
      scheduleReconnect();
      return;
    }

    const candidate = new WebSocket(BRIDGE_URL);
    socket = candidate;
    candidate.addEventListener('open', () => {
      if (socket !== candidate) return;
      candidate.send(JSON.stringify({ type: 'hello', version: BRIDGE_PROTOCOL }));
      setBridgeState('connected');
      startHeartbeat();
      void sendCookieSnapshot('bilibili');
      void sendCookieSnapshot('youtube');
    });
    candidate.addEventListener('message', (event) => {
      try { void handleBridgeMessage(JSON.parse(event.data)); } catch (_) { }
    });
    candidate.addEventListener('close', () => {
      if (socket !== candidate) return;
      socket = undefined;
      stopHeartbeat();
      setBridgeState('starting');
      scheduleReconnect();
    });
    candidate.addEventListener('error', () => {
      // A health check gates normal connection attempts. The close event owns recovery.
    });
  } catch (_) {
    socket = undefined;
    scheduleReconnect();
  } finally {
    connectInFlight = false;
  }
}

function cookieKey(cookie) {
  return [cookie.storeId, cookie.name, cookie.domain, cookie.path, cookie.partitionKey?.topLevelSite || ''].join('\u0001');
}

async function readCookies(site) {
  const domains = SITE_DOMAINS[site];
  if (!domains) throw new Error('Unsupported site');
  const groups = await Promise.all(domains.map((domain) => chrome.cookies.getAll({ domain })));
  const unique = new Map();
  for (const cookie of groups.flat()) unique.set(cookieKey(cookie), cookie);
  return [...unique.values()].map((cookie) => ({
    name: cookie.name,
    value: cookie.value,
    domain: cookie.domain,
    path: cookie.path,
    secure: cookie.secure,
    httpOnly: cookie.httpOnly,
    sameSite: cookie.sameSite,
    expirationDate: cookie.expirationDate,
    session: cookie.session,
  }));
}

function send(message) {
  if (socket?.readyState !== WebSocket.OPEN) return false;
  try {
    socket.send(JSON.stringify(message));
    return true;
  } catch (_) {
    return false;
  }
}

async function sendCookieSnapshot(site) {
  try {
    const cookies = await readCookies(site);
    send({ type: 'cookie_snapshot', site, cookies });
  } catch (_) {
    // Never log cookie-related values. A later request can still retry.
  }
}

async function handleBridgeMessage(message) {
  if (!message || message.type !== 'get_cookies' || !message.requestId) return;
  try {
    const cookies = await readCookies(message.site);
    send({ type: 'cookies', requestId: message.requestId, cookies });
  } catch (error) {
    send({ type: 'cookies', requestId: message.requestId, cookies: [], error: String(error?.message || error) });
  }
}

chrome.runtime.onInstalled.addListener(() => { void connect(); });
chrome.runtime.onStartup.addListener(() => { void connect(); });
chrome.alarms.create(RECONNECT_ALARM, { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === RECONNECT_ALARM && !send({ type: 'ping' })) void connect();
});

setBridgeState('starting');
void connect();
