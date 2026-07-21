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
const fs         = require('fs');
const path       = require('path');

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

// ── 带背压感知的投递 ─────────────────────────────
// 关键：move 事件按设备合并（每台客户端仅缓存最新一帧，由定时器统一下发），
// 避免主控高速滑动时弱网手机 TCP 缓冲堆积、整段手势掉队；
// down / up / key 等"关键事件"始终立即直发，绝不被合并或丢弃。
const MOVE_FLUSH_MS = 16;
const HIGH_WATER = 512 * 1024; // 单客户端发送缓冲上限（字节），超过则丢弃该 move

function deliverTo(ws, obj) {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  if (obj && obj.type === 'touch' && obj.action === 'move') {
    // move 合并：仅缓存最新一帧，稍后由 flush 定时器统一下发
    ws._pendingMove = obj;
    return;
  }
  try { ws.send(JSON.stringify(obj)); } catch (e) { /* 客户端已断开或写失败，忽略 */ }
}

function broadcastToSlaves(obj) {
  for (const ws of slaves.keys()) deliverTo(ws, obj);
}

function broadcastToAllPhones(obj) {
  const all = new Set([...masters.keys(), ...slaves.keys()]);
  for (const ws of all) deliverTo(ws, obj);
}

// 定向：仅发给指定 deviceId 的手机（用于控制单台设备）
function sendToDevice(deviceId, obj) {
  for (const [ws, info] of [...masters, ...slaves]) {
    if (info.deviceId === deviceId) deliverTo(ws, obj);
  }
}

// 定向：按真实 IP 命中（弹窗未设主控时，用设备 IP 精确命中，
// 避免依赖 qkurl 的 id 与手机中继注册 deviceId 不一致导致触摸被丢弃）
function sendToDeviceByIp(targetIp, obj) {
  const ip = normalizeIp(targetIp);
  let found = false;
  for (const [ws, info] of [...masters, ...slaves]) {
    if (info.ip === ip) { deliverTo(ws, obj); found = true; }
  }
  return found;
}

// 全局 move 下发：每台客户端每帧至多下发一个合并后的 move，
// 背压过高时丢弃（down/up 走直发通道，不会进这里，故手势完整性不受影响）
setInterval(() => {
  const clients = new Set([...masters.keys(), ...slaves.keys()]);
  for (const ws of clients) {
    if (!ws._pendingMove) continue;
    const mv = ws._pendingMove;
    ws._pendingMove = null;
    if (ws.readyState !== WebSocket.OPEN) continue;
    if (ws.bufferedAmount > HIGH_WATER) continue; // 背压保护：丢弃过期 move
    try { ws.send(JSON.stringify(mv)); } catch (e) { /* ignore */ }
  }
}, MOVE_FLUSH_MS);

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

// 直接托管本地 PC 群控页（pc_group_control.html），不依赖手机连接状态
function serveControlPage(res) {
  const p = path.join(__dirname, '..', 'pc_group_control.html');
  fs.readFile(p, (err, data) => {
    if (err) {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(getFallbackHtml());
      return;
    }
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(data);
  });
}

// 归一化客户端 IP：剥离 IPv6 映射前缀 "::ffff:"（中继监听 :: 时
// socket.remoteAddress 会返回 "::ffff:1.2.3.4"，直接用于 http://host
// 会触发 Invalid URL 并让整个进程崩溃）。也兼容方括号 IPv6 写法。
function normalizeIp(ip) {
  if (!ip) return ip;
  let s = String(ip).trim();
  if (s.startsWith('::ffff:')) s = s.slice(7);
  if (s.startsWith('[') && s.endsWith(']')) s = s.slice(1, -1);
  return s;
}

// ── HTTP Server (port HTTP_PORT: screenshot proxy + status + group-control proxy) ──

const httpServer = http.createServer((req, res) => {
  const parsedUrl = url.parse(req.url, true);
  const pathname  = parsedUrl.pathname;

  res.setHeader('Access-Control-Allow-Origin', '*');

  if (pathname === '/api/relay/info') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      httpPort: HTTP_PORT,
      wsPort: WS_PORT,
      ip: getLocalIp()
    }));
    return;
  }

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
    const targetIp = normalizeIp(parsedUrl.query.ip);
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
    let screenshotUrl;
    try {
      screenshotUrl = `http://${targetIp}:8182/api/screenshot${qs ? '?' + qs : ''}`;
    } catch (e) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: `Invalid ip: ${targetIp}` }));
      return;
    }
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
    const targetIp = normalizeIp(parsedUrl.query.ip);
    if (!targetIp) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Missing ip parameter' }));
      return;
    }
    // 代理到手机端 REST /api/device，取回真实设备名/型号/系统版本
    let deviceUrl;
    try {
      deviceUrl = `http://${targetIp}:8182/api/device`;
    } catch (e) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: `Invalid ip: ${targetIp}` }));
      return;
    }
    http.get(deviceUrl, (proxyRes) => {
      res.writeHead(proxyRes.statusCode, proxyRes.headers);
      proxyRes.pipe(res);
    }).on('error', (err) => {
      res.writeHead(502, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: `Device info proxy failed: ${err.message}` }));
    });
    return;
  }

  // 群控触摸/按键的 HTTP 网关：等价于 WS 广播，供浏览器端 WS 断开时的回退路径使用
  // 这样即使浏览器→中继 WS 临时掉线，主控滑动仍能扇出到所有手机（而非只打单台）
  if (pathname === '/api/group/touch' && req.method === 'POST') {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      let msg;
      try { msg = JSON.parse(body); } catch (e) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Invalid JSON' }));
        return;
      }
      if (msg.targetDeviceId) {
        sendToDevice(msg.targetDeviceId, msg);
        console.log(`[Relay] HTTP touch → device ${msg.targetDeviceId}`);
      } else if (msg.targetIp) {
        const ok = sendToDeviceByIp(msg.targetIp, msg);
        console.log(`[Relay] HTTP touch → ip ${msg.targetIp} ${ok ? 'ok' : '(no match)'}`);
      } else if (msg.scope === 'slaves') {
        broadcastToSlaves(msg);
        console.log(`[Relay] HTTP touch → ${slaves.size} slaves`);
      } else {
        broadcastToAllPhones(msg);
        console.log(`[Relay] HTTP touch → ${masters.size + slaves.size} phones`);
      }
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
    });
    return;
  }

  // Serve qkurl.txt device list (group-control page fetches it relative to 9527/)
  if (pathname === '/qkurl.txt') {
    const p = path.join(__dirname, '..', 'qkurl.txt');
    fs.readFile(p, (err, data) => {
      if (err) {
        res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
        res.end('qkurl.txt not found');
        return;
      }
      res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end(data);
    });
    return;
  }

  // Serve group-control HTML — always the local PC control page (pc_group_control.html)
  if (pathname === '/' || pathname === '/group-control') {
    serveControlPage(res);
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
  ws._relayIp       = normalizeIp(ip);

  console.log(`[Relay] New connection: role=${role} deviceId=${deviceId} ip=${normalizeIp(ip)}`);

  // ── 注册到对应集合 ─────────────────────
  if (role === 'master') {
    if (masters.size > 0) {
      console.log(`[Relay] WARNING: Multiple masters detected.`);
    }
    masters.set(ws, { deviceId, ip: normalizeIp(ip), role });
    ws._relayRole = role; ws._relayDeviceId = deviceId;
    // NOTE: do NOT send() immediately on connection — the iOS daemon's
    // hand-rolled WS client reads the 101 response only up to \r\n\r\n and
    // would swallow the first bytes of any frame sent in the same TCP segment,
    // corrupting frame alignment (observed as code=1006 on connect).
  } else if (role === 'slave') {
    slaves.set(ws, { deviceId, ip: normalizeIp(ip), role });
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
      broadcastToSlaves(msg);
      console.log(`[Relay] real_touch → ${slaves.size} slaves`);
    } else if (msg.type === 'touch' || msg.type === 'key') {
      // 定向单台：targetDeviceId / targetIp 指定时只发该设备
      if (msg.targetDeviceId) {
        sendToDevice(msg.targetDeviceId, msg);
        console.log(`[Relay] ${msg.type} → device ${msg.targetDeviceId}`);
      } else if (msg.targetIp) {
        const ok = sendToDeviceByIp(msg.targetIp, msg);
        console.log(`[Relay] ${msg.type} → ip ${msg.targetIp} ${ok ? 'ok' : '(no match)'}`);
      } else if (msg.scope === 'slaves') {
        // 仅镜像到从控
        broadcastToSlaves(msg);
        console.log(`[Relay] ${msg.type} → ${slaves.size} slaves`);
      } else {
        // 默认：广播到所有手机（控主控 → 镜像所有从控）
        broadcastToAllPhones(msg);
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

// ── [可选] WS 推帧（替代浏览器 HTTP 轮询）──────────────
// 默认关闭。启用：RELAY_WS_FRAMES=1。中继为每个已连浏览器 WS 周期性拉取所有设备截图，
// 并经该 WS 推送 {type:'frame', ip, data:<base64 jpeg>}，浏览器据此绘制并停止 HTTP 轮询。
const ENABLE_WS_FRAMES = process.env.RELAY_WS_FRAMES === '1';
const WS_FRAME_INTERVAL = parseInt(process.env.RELAY_WS_FRAME_INTERVAL || '1000', 10);

async function pushFramesToBrowser(ws) {
  if (ws.readyState !== WebSocket.OPEN) return;
  const devs = [];
  for (const [, info] of masters) devs.push(info);
  for (const [, info] of slaves) devs.push(info);
  for (const d of devs) {
    if (ws.readyState !== WebSocket.OPEN) return;
    const u = `http://${d.ip}:8182/api/screenshot?format=jpeg&quality=0.3&scale=0.15&rotation=90`;
    try {
      const buf = await new Promise((resolve, reject) => {
        const r = http.get(u, (res) => {
          if (res.statusCode !== 200) return reject(new Error('status ' + res.statusCode));
          const ch = [];
          res.on('data', (c) => ch.push(c));
          res.on('end', () => resolve(Buffer.concat(ch)));
        });
        r.on('error', reject);
      });
      if (buf.length < 200) continue; // 空帧跳过
      ws.send(JSON.stringify({ type: 'frame', ip: d.ip, data: buf.toString('base64'), w: 0, h: 0 }));
    } catch (e) { /* 单台失败忽略，不阻断其他设备 */ }
  }
}
if (ENABLE_WS_FRAMES) {
  setInterval(() => { for (const ws of browsers) pushFramesToBrowser(ws); }, WS_FRAME_INTERVAL);
  console.log('[Relay] WS 推帧已启用 (interval=' + WS_FRAME_INTERVAL + 'ms)');
}

// ── [默认开启] RFB 增量帧桥（对接手机 :5901 VNC，替代整图轮询）──────────────
// 默认开启（RELAY_RFB=0 可关闭）。中继为每台已连设备建 RFB 会话，只拉「变化矩形」(Raw 编码)，
// 经浏览器 WS 推送 {type:'rfb_frame', ip, x, y, w, h, fbw, fbh, data:<base64 RGBA>} 局部刷新。
// scrcpy/noVNC 同款，百台规模带宽/延迟远优于整图轮询。需 daemon VNC(:5901) 可达。仅支持 None 鉴权 + Raw 编码。
// 会话断开时向浏览器广播 {type:'rfb_stop', ip} 让前端回退 HTTP 轮询（自愈）。
const ENABLE_RFB = process.env.RELAY_RFB !== '0';
const RFB_PORT = parseInt(process.env.RFB_PORT || '5901', 10);
const net = require('net');

class RfbSession {
  constructor(ip, onFrame, onClose) {
    this.ip = ip; this.onFrame = onFrame; this.onClose = onClose;
    this.buf = Buffer.alloc(0);
    this.state = 'handshake-version';
    this.fbW = 0; this.fbH = 0; this.connected = false; this.closed = false;
    this.curRect = null; this.curRectNeed = 0; this.curRectData = Buffer.alloc(0);
    this.sock = net.connect(RFB_PORT, ip, () => { this._send(Buffer.from('RFB 003.008\n')); });
    this.sock.on('data', (d) => { this.buf = Buffer.concat([this.buf, d]); try { this._pump(); } catch (e) { console.log('[RFB] ' + this.ip + ' parse error: ' + e.message); this._close(); } });
    this.sock.on('error', (e) => { console.log('[RFB] ' + this.ip + ' error: ' + e.message); this._close(); });
    this.sock.on('close', () => this._close());
    this.sock.setTimeout(8000, () => { if (!this.connected) this._close(); });
  }
  _send(b) { try { this.sock.write(b); } catch (e) {} }
  _close() { if (this.closed) return; this.closed = true; try { this.sock.destroy(); } catch (e) {} if (this.onClose) this.onClose(this.ip); }
  _need(n) { return this.buf.length >= n; }
  _take(n) { const b = this.buf.slice(0, n); this.buf = this.buf.slice(n); return b; }
  _pump() {
    while (true) {
      if (this.state === 'handshake-version') {
        if (!this._need(12)) return;
        this._take(12); this._send(Buffer.from('RFB 003.008\n')); this.state = 'security-types';
      } else if (this.state === 'security-types') {
        if (!this._need(1)) return;
        const n = this._take(1)[0];
        if (n === 0) { this._close(); return; }
        if (!this._need(1 + n)) return;
        const types = this._take(n);
        if (!types.includes(1)) { console.log('[RFB] ' + this.ip + ' 仅支持 None(1) 鉴权'); this._close(); return; }
        this._send(Buffer.from([1])); this.state = 'security-result';
      } else if (this.state === 'security-result') {
        if (!this._need(4)) return;
        if (this._take(4).readUInt32BE(0) !== 0) { this._close(); return; }
        this._send(Buffer.from([1])); this.state = 'server-init';
      } else if (this.state === 'server-init') {
        if (!this._need(24)) return;
        const si = this._take(24);
        this.fbW = si.readUInt16BE(0); this.fbH = si.readUInt16BE(2);
        if (!this._need(4)) return;
        const nameLen = this._take(4).readUInt32BE(0);
        if (!this._need(nameLen)) return;
        this._take(nameLen);
        // 协商像素格式：32bpp, big-endian, true-color, 内存序 [R,G,B,0]
        const pf = Buffer.alloc(20);
        pf.writeUInt8(0, 0); pf.writeUInt8(32, 1); pf.writeUInt8(24, 2); pf.writeUInt8(1, 3); pf.writeUInt8(1, 4);
        pf.writeUInt16BE(255, 5); pf.writeUInt16BE(255, 7); pf.writeUInt16BE(255, 9);
        pf.writeUInt8(16, 11); pf.writeUInt8(8, 12); pf.writeUInt8(0, 13);
        this._send(pf);
        this.connected = true; this._requestUpdate(false); this.state = 'frame-update';
      } else if (this.state === 'frame-update') {
        if (!this._need(4)) return;
        const hdr = this._take(4);
        const numRects = hdr.readUInt16BE(2);
        if (numRects === 0) { this._requestUpdate(true); return; }
        this.state = 'rect-header';
      } else if (this.state === 'rect-header') {
        if (!this._need(12)) return;
        const r = this._take(12);
        const x = r.readUInt16BE(0), y = r.readUInt16BE(2), w = r.readUInt16BE(4), h = r.readUInt16BE(6);
        const enc = r.readInt32BE(8);
        if (enc !== 0) { console.log('[RFB] ' + this.ip + ' 不支持编码 ' + enc + ' (仅 Raw=0)'); this._close(); return; }
        this.curRect = { x, y, w, h }; this.curRectData = Buffer.alloc(0); this.curRectNeed = w * h * 4; this.state = 'rect-data';
      } else if (this.state === 'rect-data') {
        const need = this.curRectNeed - this.curRectData.length;
        if (!this._need(need)) return;
        this.curRectData = Buffer.concat([this.curRectData, this._take(need)]);
        const c = this.curRect;
        this.onFrame(this.ip, c.x, c.y, c.w, c.h, this.curRectData, this.fbW, this.fbH);
        this._requestUpdate(true); this.state = 'frame-update';
      } else { this._close(); return; }
    }
  }
  _requestUpdate(incremental) {
    const req = Buffer.alloc(10);
    req.writeUInt8(3, 0); req.writeUInt8(incremental ? 1 : 0, 1);
    req.writeUInt16BE(0, 2); req.writeUInt16BE(0, 4);
    req.writeUInt16BE(this.fbW, 6); req.writeUInt16BE(this.fbH, 8);
    this._send(req);
  }
}

const rfbSessions = new Map();
function startRfbFor(ip) {
  if (rfbSessions.has(ip)) return;
  try {
    const s = new RfbSession(ip,
      (ip2, x, y, w, h, data, fbw, fbh) => {
        const msg = JSON.stringify({ type: 'rfb_frame', ip: ip2, x, y, w, h, fbw, fbh, data: data.toString('base64') });
        for (const ws of browsers) { if (ws.readyState === WebSocket.OPEN) ws.send(msg); }
      },
      (ip2) => {
        rfbSessions.delete(ip2);
        // 通知浏览器该设备 RFB 会话已结束，前端回退 HTTP 轮询（自愈）
        const stop = JSON.stringify({ type: 'rfb_stop', ip: ip2 });
        for (const ws of browsers) { if (ws.readyState === WebSocket.OPEN) ws.send(stop); }
      });
    rfbSessions.set(ip, s);
  } catch (e) { console.log('[RFB] 启动失败 ' + ip + ': ' + e.message); }
}
if (ENABLE_RFB) {
  setInterval(() => {
    const ips = new Set();
    for (const [, info] of masters) ips.add(info.ip);
    for (const [, info] of slaves) ips.add(info.ip);
    for (const ip of ips) startRfbFor(ip);
  }, 5000);
  console.log('[Relay] RFB 增量帧桥已启用 (port=' + RFB_PORT + ')');
}

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
