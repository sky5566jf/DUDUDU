#!/usr/bin/env node
/**
 * TrollVNC Group Control - Computer Relay Server
 * v1.3 - 彻底修复：upgrade 时把 role 写进 URL path，
 *         connection 里直接读 req.url 解析，100% 可靠
 */

const WebSocket = require('ws');
const http       = require('http');
const https      = require('https');
const url        = require('url');

const WS_PORT   = 8183;
const HTTP_PORT = 9527;

// ── 可选 WS 鉴权 ──────────────────────────────────
// 设置环境变量 RELAY_TOKEN 后，所有 WS 连接必须携带 ?token=XXX，否则 401 拒绝。
// 未设置则不校验（向后兼容历史客户端）。注意：手机端 WS URL 也需同步带上 token。
const RELAY_TOKEN = process.env.RELAY_TOKEN || '';

// ── State ─────────────────────────────────────────────
const masters  = new Map();  // ws → { deviceId, ip }
const slaves   = new Map();  // ws → { deviceId, ip }
const browsers = new Set();

let nextDeviceId = 1;
function genDeviceId() { return `device_${nextDeviceId++}`; }

// ── Helpers ──────────────────────────────────────────

function broadcastTo(wsSet, msg, excludeWs) {
  for (const ws of wsSet) {
    if (ws === excludeWs) continue;
    if (ws.readyState === WebSocket.OPEN) {
      try { ws.send(msg); } catch (e) { /* ignore */ }
    }
  }
}

function broadcastToSlaves(msg) {
  broadcastTo(slaves.keys(), msg, null);
}

function broadcastToAllPhones(msg) {
  const all = new Set([...masters.keys(), ...slaves.keys()]);
  for (const ws of all) {
    if (ws.readyState === WebSocket.OPEN) {
      try { ws.send(msg); } catch (e) { /* ignore */ }
    }
  }
}

// 定向：仅发给指定 deviceId 的手机（用于控制单台设备）
function sendToDevice(deviceId, msg) {
  for (const [ws, info] of [...masters, ...slaves]) {
    if (info.deviceId === deviceId && ws.readyState === WebSocket.OPEN) {
      try { ws.send(msg); } catch (e) { /* ignore */ }
    }
  }
}

function encodeWebSocketTextFrame(str) {
  const payload = Buffer.from(str, 'utf8');
  const len = payload.length;
  const buf = Buffer.alloc(2 + (len <= 125 ? 0 : 2) + len);
  buf[0] = 0x81; // FIN + text
  if (len <= 125) {
    buf[1] = len;
    payload.copy(buf, 2);
    return buf.slice(0, 2 + len);
  } else {
    buf[1] = 126;
    buf.writeUInt16BE(len, 2);
    payload.copy(buf, 4);
    return buf.slice(0, 4 + len);
  }
}

function getLocalIp() {
  const os = require('os');
  const nets = os.networkInterfaces();
  for (const name of Object.keys(nets)) {
    for (const net of nets[name]) {
      if (net.family === 'IPv4' && !net.internal) return net.address;
    }
  }
  return 'localhost';
}

function getFallbackHtml() {
  return `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>TrollVNC Relay</title></head>
<body style="font-family:sans-serif;text-align:center;padding:50px;">
  <h2>🎉 TrollVNC Group Control Relay</h2>
  <p>Relay server is running.</p>
  <p>Connect phones to this server's IP :${WS_PORT}.</p>
  <p>Make sure at least one phone is configured as <b>Master</b>.</p>
  <hr>
  <a href="/api/status">View Device Status (JSON)</a>
</body></html>`;
}

// ── HTTP Server (port HTTP_PORT: screenshot proxy + status + group-control proxy) ──

const httpServer = http.createServer((req, res) => {
  const parsedUrl = url.parse(req.url, true);
  const pathname  = parsedUrl.pathname;

  res.setHeader('Access-Control-Allow-Origin', '*');

  if (pathname === '/api/status') {
    const masterList = [];
    for (const [, info] of masters) masterList.push(info);
    const slaveList = [];
    for (const [, info] of slaves) slaveList.push(info);

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      masters: masterList,
      slaves:  slaveList,
      browsers: browsers.size,
    }));
    return;
  }

  if (pathname === '/api/screenshot' && req.method === 'GET') {
    const targetIp = parsedUrl.query.ip;
    if (!targetIp) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Missing ip parameter' }));
      return;
    }
    // Forward all query params (format/quality/scale/rotation) to phone
    const fwdParams = new URLSearchParams();
    for (const [key, val] of Object.entries(parsedUrl.query)) {
      if (key !== 'ip') fwdParams.set(key, val);
    }
    const qs = fwdParams.toString();
    const screenshotUrl = `http://${targetIp}:8182/api/screenshot${qs ? '?' + qs : ''}`;
    http.get(screenshotUrl, (proxyRes) => {
      res.writeHead(proxyRes.statusCode, proxyRes.headers);
      proxyRes.pipe(res);
    }).on('error', (err) => {
      res.writeHead(502, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: `Screenshot proxy failed: ${err.message}` }));
    });
    return;
  }

  if (pathname === '/api/device' && req.method === 'GET') {
    const targetIp = parsedUrl.query.ip;
    if (!targetIp) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Missing ip parameter' }));
      return;
    }
    // 代理到手机端 REST /api/device，取回真实设备名/型号/系统版本
    const deviceUrl = `http://${targetIp}:8182/api/device`;
    http.get(deviceUrl, (proxyRes) => {
      res.writeHead(proxyRes.statusCode, proxyRes.headers);
      proxyRes.pipe(res);
    }).on('error', (err) => {
      res.writeHead(502, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: `Device info proxy failed: ${err.message}` }));
    });
    return;
  }

  // Serve group-control HTML (proxy from master phone or serve static)
  if (pathname === '/' || pathname === '/group-control') {
    const masterInfo = masters.values().next().value;
    if (masterInfo && masterInfo.ip) {
      const controlUrl = `http://${masterInfo.ip}:8182/group-control`;
      http.get(controlUrl, (proxyRes) => {
        let body = '';
        proxyRes.on('data', chunk => body += chunk);
        proxyRes.on('end', () => {
          res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
          res.end(body);
        });
      }).on('error', () => {
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(getFallbackHtml());
      });
    } else {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(getFallbackHtml());
    }
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Not found' }));
});

httpServer.listen(HTTP_PORT, () => {
  console.log(`[Relay] HTTP server listening on http://${getLocalIp()}:${HTTP_PORT}`);
  console.log(`[Relay] Group control page: http://${getLocalIp()}:${HTTP_PORT}/group-control`);
});

// ── WebSocket Server ───────────────────────────────────────
const wss = new WebSocket.Server({ noServer: true });

/**
 * 解析 WS 连接 URL 中的 role / deviceId
 * 兼容两种格式（双端兼容，避免客户端改动）：
 *   1) path 参数（relay banner 推荐）：ws://host:8183/ws/{role}/{deviceId}?ts=xxx
 *   2) query 参数（iOS app 与 pc 前端现有格式）：ws://host:8183/?role=X&deviceId=Y
 * 优先 path，其次回退 query。
 */
function parseRelayRoleDeviceId(reqUrl) {
  if (!reqUrl) return { role: 'unknown', deviceId: null };
  const m = reqUrl.match(/^\/ws\/(\w+)\/([^\s?]+)/);
  if (m) return { role: m[1], deviceId: m[2] };
  const q = (url.parse(reqUrl, true).query) || {};
  if (q.role) return { role: String(q.role), deviceId: q.deviceId ? String(q.deviceId) : null };
  return { role: 'unknown', deviceId: null };
}

/**
 * 公共 upgrade 处理器
 */
function handleUpgrade(req, socket, head) {
  // 从 req.url 解析 role/deviceId（兼容 path 与 query 两种格式）
  const { role, deviceId } = parseRelayRoleDeviceId(req.url);
  const ip       = socket.remoteAddress || '';

  // ── 可选 WS 鉴权（仅当设置了 RELAY_TOKEN 时强制）──
  if (RELAY_TOKEN) {
    const q = url.parse(req.url, true).query || {};
    const token = q.token ? String(q.token) : null;
    if (token !== RELAY_TOKEN) {
      console.log(`[Relay] Auth rejected: role=${role} deviceId=${deviceId} (bad/missing token)`);
      try {
        socket.write('HTTP/1.1 401 Unauthorized\r\nContent-Type: text/plain\r\nContent-Length: 0\r\n\r\n');
      } catch (e) { /* ignore */ }
      socket.destroy();
      return;
    }
  }


  // 挂到 req 上供 connection 事件读取（双重保险）
  req._relayRole     = role;
  req._relayDeviceId = deviceId;
  req._relayIp       = ip;

  wss.handleUpgrade(req, socket, head, (...args) => {
    // ws v8.21.0 回调签名是 (ws, req)，不会自动 emit 'connection'
    const ws  = args[0] instanceof WebSocket ? args[0] : null;
    const req2 = args[1] && args[1].constructor && args[1].constructor.name === 'IncomingMessage' ? args[1] : req;
    if (!ws) { socket.end(); return; }
    wss.emit('connection', ws, req2);
  });
}

// HTTP Server (port HTTP_PORT) → 用于浏览器从 9527 连 WS
httpServer.on('upgrade', handleUpgrade);

// 独立 WS Server (port WS_PORT) → 用于手机从 8183 连 WS
const wsHttpServer = http.createServer();
wsHttpServer.on('upgrade', handleUpgrade);
wsHttpServer.listen(WS_PORT, () => {
  console.log(`[Relay] WebSocket server listening on ws://${getLocalIp()}:${WS_PORT}`);
});

// ── connection 事件处理器 ─────────────────────────────────
wss.on('connection', (ws, req) => {
  // ★ 终极可靠方案：直接在 connection 里解析 req.url
  //   handleUpgrade 里设的 _relayRole 可能因为 wss 内部重建 req 而丢失
  //   req.url 是 100% 可靠的，因为 upgrade 请求的 URL 不会变
  let role = 'unknown';
  let deviceId = null;
  let ip = (req && req.socket && req.socket.remoteAddress) || 'unknown';

  if (req && req.url) {
    // 兼容 path(/ws/{role}/{id}) 与 query(?role=x&deviceId=y) 两种格式
    const parsed = parseRelayRoleDeviceId(req.url);
    role = parsed.role;
    deviceId = parsed.deviceId;
  }
  if (!deviceId) deviceId = genDeviceId();

  // 把身份信息挂到 ws 对象，供心跳检测器和日志使用
  ws._relayRole     = role;
  ws._relayDeviceId = deviceId;
  ws._relayIp       = ip;

  console.log(`[Relay] New connection: role=${role} deviceId=${deviceId} ip=${ip}`);

  // ── 注册到对应集合 ─────────────────────
  if (role === 'master') {
    if (masters.size > 0) {
      console.log(`[Relay] WARNING: Multiple masters detected.`);
    }
    masters.set(ws, { deviceId, ip, role });
    ws._relayRole = role; ws._relayDeviceId = deviceId;
    // NOTE: do NOT send() immediately on connection — the iOS daemon's
    // hand-rolled WS client reads the 101 response only up to \r\n\r\n and
    // would swallow the first bytes of any frame sent in the same TCP segment,
    // corrupting frame alignment (observed as code=1006 on connect).
  } else if (role === 'slave') {
    slaves.set(ws, { deviceId, ip, role });
    ws._relayRole = role; ws._relayDeviceId = deviceId;
    // (event notifications to phones removed: the iOS daemon's hand-rolled
    // WS client breaks the connection when it receives frames other than
    // touch/key/ping; the browser console uses qkurl.txt for the device
    // list and does not consume these events anyway.)
  } else if (role === 'browser') {
    browsers.add(ws);
    ws._relayRole = role; ws._relayDeviceId = deviceId;
  } else {
    try {
      ws.send(JSON.stringify({ error: 'Unknown role. Use /ws/master/xxx or /ws/slave/xxx' }), (err) => {
        if (err) console.log(`[Relay] error send failed:`, err.message);
      });
    } catch (e) {}
    ws.close();
    return;
  }

  // ── Heartbeat ─────────────────────────────────────
  const heartbeat = setInterval(() => {
    if (ws.readyState === WebSocket.OPEN) {
      try { ws.ping(); } catch (e) { /* ignore */ }
    }
  }, 30000);

  ws._alive = true;
  ws.on('pong', () => { ws._alive = true; });

  // ── 消息路由 ──────────────────────────────
  ws.on('message', (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw);
    } catch (e) {
      console.log(`[Relay] Invalid JSON from ${role}/${deviceId}:`, raw.toString().slice(0, 100));
      return;
    }

    if (msg.type === 'touch' && msg.source === 'real_touch') {
      // Master reports real touch → broadcast to SLAVES only
      const eventStr = JSON.stringify(msg);
      broadcastToSlaves(eventStr);
      console.log(`[Relay] real_touch → ${slaves.size} slaves`);
    } else if (msg.type === 'touch' || msg.type === 'key') {
      const eventStr = JSON.stringify(msg);
      // 定向单台：targetDeviceId 指定时只发该设备
      if (msg.targetDeviceId) {
        sendToDevice(msg.targetDeviceId, eventStr);
        console.log(`[Relay] ${msg.type} → device ${msg.targetDeviceId}`);
      } else if (msg.scope === 'slaves') {
        // 仅镜像到从控
        broadcastToSlaves(eventStr);
        console.log(`[Relay] ${msg.type} → ${slaves.size} slaves`);
      } else {
        // 默认：广播到所有手机（控主控 → 镜像所有从控）
        broadcastToAllPhones(eventStr);
        console.log(`[Relay] ${msg.type} → ${masters.size + slaves.size} phones`);
      }
    } else if (msg.type === 'register') {
      console.log(`[Relay] register: ${deviceId} role=${msg.role}`);
    } else {
      console.log(`[Relay] Unknown message type: ${msg.type} from ${role}/${deviceId}`);
    }
  });

  // ── 断开处理 ──────────────────────────────
  ws.on('close', (code, reason) => {
    clearInterval(heartbeat);
    const reasonStr = (reason && reason.length > 0) ? reason.toString() : '(no reason)';
    console.log(`[Relay] ${role} disconnected: ${deviceId}, code=${code}, reason=${reasonStr}`);

    if (role === 'master') {
      masters.delete(ws);
    } else if (role === 'slave') {
      slaves.delete(ws);
    } else if (role === 'browser') {
      browsers.delete(ws);
    }
  });

  ws.on('error', (err) => {
    console.log(`[Relay] WS error (${role}/${deviceId}):`, err.message);
  });
});

// ── Dead connection checker ─────────────────────────────
setInterval(() => {
  const allClients = new Set([...masters.keys(), ...slaves.keys(), ...browsers]);
  for (const ws of allClients) {
    if (ws._alive === false) {
      console.log(`[Relay] Terminating dead connection: ${ws._relayRole}/${ws._relayDeviceId}`);
      ws.terminate();
      continue;
    }
    ws._alive = false;
    try { ws.ping(); } catch (e) { /* ignore */ }
  }
}, 30000);

// ── Startup banner ───────────────────────────────────
console.log(`
╔══════════════════════════════════════════════════════════╗
║   TrollVNC Group Control - Computer Relay Server  v1.3        ║
╠══════════════════════════════════════════════════════════╣
║  WS Server  : ${getLocalIp()}:${WS_PORT}                      ║
║  HTTP Server: ${getLocalIp()}:${HTTP_PORT} (status + proxy)  ║
║                                                              ║
║  Phone connection URL (v1.3+ 路径格式）:                 ║
║    ws://YOUR_COMPUTER_IP:${WS_PORT}/ws/master/你的deviceId      ║
║    ws://YOUR_COMPUTER_IP:${WS_PORT}/ws/slave/你的deviceId       ║
║    ws://YOUR_COMPUTER_IP:${WS_PORT}/ws/browser                ║
╚══════════════════════════════════════════════════════════╝
`);
