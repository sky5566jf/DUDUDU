#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MatisuXCS / TrollVNC noVNC 稳定性监控 + 本地实时仪表盘 (零依赖, 仅标准库)
========================================================================

原理:
    设备上的 TrollVNC 在 8182 端口提供一套 HTTP REST API (TVNCHttpServer):
      GET /api/status      -> {"status","httpPort","version"}    (存活 + 版本)
      GET /api/screenshot  -> JPEG 当前屏幕截图                   (冻结检测 + 实时画面)
      GET /api/clients     -> 客户端列表                          (连接数)
      POST /api/screen/lock|unlock -> 主动锁屏/解锁 (触发冻结场景)
    本脚本周期性轮询这些端点, 客观测量:
      - 服务存活 (alive / down)
      - HTTP 响应延迟 (latency)
      - 屏幕内容是否仍在变化 (content-change)  -> 辅助判断"活着但画面不动"
      - 自愈 (down 后自动恢复 = 进程被监管重启) -> 验证 v3.83 Fix2 帧存活探针
    并起一个本地 HTTP 仪表盘 (http://localhost:<dash>) 让你在浏览器实时"看"。

对应 v3.83 两处修复的验证:
      Fix1 默认防休眠保活 -> 长时无人操作, 服务应保持 alive、截图持续可拉
      Fix2 帧存活探针     -> 锁屏致 CADisplayLink 停摆 >60s, 进程自杀被监管拉起,
                             仪表盘会看到一次 down -> 自动 recover (自愈)

用法:
    python vnc_stability_monitor.py <设备IP> [选项]
    python vnc_stability_monitor.py 192.69.0.99
    python vnc_stability_monitor.py 192.69.0.99 --api-port 8182 --dash 8080

选项:
    --api-port PORT    设备 API 端口 (默认 8182)
    --dash PORT        本地仪表盘端口 (默认 8080)
    --interval SEC     状态轮询间隔 (默认 3)
    --shot-interval SEC 截图间隔 (默认 5)
    --freeze-sec SEC   截图连续不变超过此秒数(且 alive) 提示内容冻结 (默认 60)
"""

import sys
import os
import time
import json
import hashlib
import threading
import argparse
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ----------------------------- 配置 -----------------------------
DEVICE = "192.69.0.99"
API_PORT = 8182
DASH_PORT = 8080
INTERVAL = 3.0
SHOT_INTERVAL = 5.0
SHOT_TIMEOUT = 10
STATUS_TIMEOUT = 5
FREEZE_SEC = 60

# ----------------------------- 共享状态 -----------------------------
lock = threading.Lock()
stats = {
    "device": DEVICE,
    "api_port": API_PORT,
    "version": "?",
    "state": "init",            # init | alive | down
    "latency_ms": 0.0,
    "last_update": "",
    "uptime_s": 0,
    "heartbeats": 0,
    "screenshots": 0,
    "content_changes": 0,
    "recovers": 0,             # down 后自动恢复次数 (自愈)
    "downs": 0,                # 进入 down 次数
    "last_down_duration_s": 0.0,
    "down_since": 0.0,
    "last_shot_hash": None,
    "last_shot_change_t": time.time(),
    "shot_ts": 0,
    "start_time": time.time(),
}
latest_shot = {"data": b"", "ts": 0}


# ----------------------------- API 客户端 -----------------------------
def api_get(path, timeout):
    url = "http://%s:%d%s" % (DEVICE, API_PORT, path)
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    r = urllib.request.urlopen(req, timeout=timeout)
    return r.status, r.read()


def api_post(path, timeout=5):
    url = "http://%s:%d%s" % (DEVICE, API_PORT, path)
    req = urllib.request.Request(url, data=b"", method="POST",
                                 headers={"User-Agent": "Mozilla/5.0",
                                          "Content-Type": "application/json"})
    r = urllib.request.urlopen(req, timeout=timeout)
    return r.status, r.read()


# ----------------------------- 监控主循环 -----------------------------
def monitor_loop():
    last_shot_t = 0.0
    while True:
        now = time.time()
        try:
            t0 = time.time()
            st, body = api_get("/api/status", STATUS_TIMEOUT)
            latency = (time.time() - t0) * 1000.0
            with lock:
                prev = stats["state"]
                if prev == "down" and stats["down_since"]:
                    stats["recovers"] += 1
                    stats["last_down_duration_s"] = now - stats["down_since"]
                stats["state"] = "alive"
                stats["down_since"] = 0.0
                stats["latency_ms"] = round(latency, 1)
                stats["last_update"] = time.strftime("%H:%M:%S")
                stats["heartbeats"] += 1
                stats["uptime_s"] = int(now - stats["start_time"])
                try:
                    j = json.loads(body)
                    if "version" in j:
                        stats["version"] = j["version"]
                except Exception:
                    pass
            # 截图 (冻结检测 + 实时画面)
            if now - last_shot_t >= SHOT_INTERVAL:
                last_shot_t = now
                try:
                    _, sdata = api_get(
                        "/api/screenshot?format=jpeg&quality=0.4&scale=0.4",
                        SHOT_TIMEOUT)
                    h = hashlib.md5(sdata).hexdigest()
                    with lock:
                        stats["screenshots"] += 1
                        if stats["last_shot_hash"] != h:
                            stats["content_changes"] += 1
                            stats["last_shot_change_t"] = now
                            stats["last_shot_hash"] = h
                        stats["shot_ts"] = now
                    latest_shot["data"] = sdata
                    latest_shot["ts"] = now
                except Exception as e:
                    with lock:
                        stats["last_update"] = "截图失败:%s" % str(e)[:40]
        except Exception as e:
            with lock:
                prev = stats["state"]
                if prev == "alive":
                    stats["downs"] += 1
                    stats["down_since"] = now
                stats["state"] = "down"
                stats["last_update"] = "断连:%s" % str(e)[:40]
        time.sleep(INTERVAL)


# ----------------------------- 本地仪表盘 HTTP 服务 -----------------------------
PAGE = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MatisuXCS noVNC 稳定性监控</title>
<style>
  * { box-sizing: border-box; }
  body { margin:0; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"PingFang SC","Microsoft YaHei",sans-serif;
         background:#f4f6f9; color:#1f2d3d; }
  .wrap { max-width:1100px; margin:0 auto; padding:18px; }
  h1 { font-size:20px; margin:0 0 4px; }
  .sub { color:#8895a7; font-size:13px; margin-bottom:16px; }
  .grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(160px,1fr)); gap:12px; margin-bottom:16px; }
  .card { background:#fff; border-radius:12px; padding:14px 16px; box-shadow:0 1px 3px rgba(0,0,0,.08); }
  .card .k { font-size:12px; color:#8895a7; }
  .card .v { font-size:26px; font-weight:700; margin-top:4px; }
  .v.green { color:#1aa260; } .v.red { color:#e23c3c; } .v.amber { color:#e0a800; }
  .row { display:grid; grid-template-columns:1.3fr 1fr; gap:16px; }
  @media(max-width:760px){ .row{grid-template-columns:1fr;} }
  .panel { background:#fff; border-radius:12px; padding:14px; box-shadow:0 1px 3px rgba(0,0,0,.08); }
  .panel h2 { font-size:14px; margin:0 0 10px; color:#445; }
  #shot { width:100%; border-radius:8px; background:#111; display:block; min-height:200px; }
  #shot.stale { outline:3px solid #e23c3c; }
  canvas { width:100%; height:160px; display:block; }
  .btns { margin-top:10px; display:flex; gap:8px; flex-wrap:wrap; }
  button { border:0; border-radius:8px; padding:8px 14px; font-size:13px; cursor:pointer; color:#fff; }
  .b-lock{background:#e0a800;} .b-unlock{background:#1aa260;} .b-refresh{background:#3b82f6;}
  .dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:6px;vertical-align:middle;}
  .dot.alive{background:#1aa260;} .dot.down{background:#e23c3c;} .dot.init{background:#e0a800;}
  .log { font-size:12px; color:#667; margin-top:8px; }
  a { color:#3b82f6; }
</style>
</head>
<body>
<div class="wrap">
  <h1>MatisuXCS / TrollVNC · noVNC 稳定性监控</h1>
  <div class="sub" id="sub">连接中…</div>

  <div class="grid">
    <div class="card"><div class="k">服务状态</div><div class="v" id="c_state">—</div></div>
    <div class="card"><div class="k">运行版本</div><div class="v" id="c_ver">—</div></div>
    <div class="card"><div class="k">HTTP 延迟</div><div class="v" id="c_lat">—</div></div>
    <div class="card"><div class="k">自愈次数</div><div class="v" id="c_rec">0</div></div>
    <div class="card"><div class="k">断连次数</div><div class="v" id="c_down">0</div></div>
    <div class="card"><div class="k">最近重启耗时</div><div class="v" id="c_dd">—</div></div>
  </div>

  <div class="row">
    <div class="panel">
      <h2>实时截图 <span id="shot_state" class="dot init"></span></h2>
      <img id="shot" alt="设备截图">
      <div class="btns">
        <button class="b-lock"   onclick="act('/api/lock')">一键锁屏(触发冻结)</button>
        <button class="b-unlock" onclick="act('/api/unlock')">解锁</button>
        <button class="b-refresh" onclick="refreshShot()">立即刷新截图</button>
      </div>
      <div class="log" id="act_log"></div>
    </div>
    <div class="panel">
      <h2>HTTP 延迟曲线 (ms)</h2>
      <canvas id="chart"></canvas>
      <div class="log">心跳 <b id="l_hb">0</b> · 截图 <b id="l_sh">0</b> · 内容变化 <b id="l_cc">0</b></div>
      <div class="log">最近截图: <b id="l_shot">—</b></div>
    </div>
  </div>
  <div class="log">提示: 静置不操作测「保活」(应始终 alive); 点「一键锁屏」让屏幕停摆 >60s, 验证「自愈」(状态变红后自动恢复)。
    也可直接在浏览器连 noVNC: <a id="novnc" href="#" target="_blank">http://设备IP:5801/</a></div>
</div>

<script>
let hist = [];
const SHOT_INTERVAL = __SHOT_INTERVAL__;
function fmtDate(t){ if(!t) return '—'; const d=new Date(t*1000); return d.toLocaleTimeString(); }
function act(p){
  fetch(p,{method:'POST'}).then(r=>r.text()).then(t=>{
    document.getElementById('act_log').textContent = '['+new Date().toLocaleTimeString()+'] '+p+' -> '+t.slice(0,120);
  }).catch(e=>{ document.getElementById('act_log').textContent='请求失败:'+e; });
}
function refreshShot(){ const i=document.getElementById('shot'); i.src='/api/shot?t='+Date.now(); }
function draw(){
  const c=document.getElementById('chart'); const g=c.getContext('2d');
  const W=c.width=c.clientWidth, H=c.height=160; g.clearRect(0,0,W,H);
  if(hist.length<2) return;
  const maxV=Math.max(50, ...hist)*1.15;
  g.strokeStyle='#3b82f6'; g.lineWidth=2; g.beginPath();
  hist.forEach((v,i)=>{ const x=i/(hist.length-1)*W; const y=H-(v/maxV)*H; i?g.lineTo(x,y):g.moveTo(x,y); });
  g.stroke();
  g.fillStyle='#8895a7'; g.font='11px sans-serif';
  g.fillText(maxV.toFixed(0)+'ms',4,12); g.fillText('0',4,H-4);
}
function tick(){
  fetch('/api/metrics').then(r=>r.json()).then(m=>{
    const st=m.state;
    document.getElementById('sub').textContent =
      '设备 '+m.device+':'+m.api_port+' · 运行时长 '+m.uptime_s+'s · 最后更新 '+m.last_update;
    const sEl=document.getElementById('c_state');
    sEl.textContent = st==='alive'?'在线':(st==='down'?'重启中':st);
    sEl.className='v '+(st==='alive'?'green':(st==='down'?'red':'amber'));
    document.getElementById('c_ver').textContent=m.version;
    document.getElementById('c_lat').textContent=m.latency_ms+' ms';
    document.getElementById('c_rec').textContent=m.recovers;
    document.getElementById('c_down').textContent=m.downs;
    document.getElementById('c_dd').textContent=m.last_down_duration_s?m.last_down_duration_s.toFixed(1)+'s':'—';
    document.getElementById('l_hb').textContent=m.heartbeats;
    document.getElementById('l_sh').textContent=m.screenshots;
    document.getElementById('l_cc').textContent=m.content_changes;
    document.getElementById('l_shot').textContent=fmtDate(m.shot_ts);
    // 截图新鲜度
    const stale = st==='down' || (Date.now()/1000 - m.shot_ts) > SHOT_INTERVAL*3;
    document.getElementById('shot').className = stale?'stale':'';
    document.getElementById('shot_state').className='dot '+st;
    if(typeof m.latency_ms==='number'){ hist.push(m.latency_ms); if(hist.length>120) hist.shift(); }
    draw();
  }).catch(e=>{ /* ignore */ });
}
setInterval(tick,1000);
setInterval(refreshShot, SHOT_INTERVAL*1000);
refreshShot(); tick();
</script>
</body>
</html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        p = self.path.split("?")[0]
        if p in ("/", "/index.html"):
            self._send(200, PAGE.replace("__SHOT_INTERVAL__", str(SHOT_INTERVAL)), "text/html; charset=utf-8")
        elif p == "/api/metrics":
            with lock:
                m = dict(stats)
            m["shot_ts"] = latest_shot["ts"]
            self._send(200, json.dumps(m))
        elif p == "/api/shot":
            data = latest_shot["data"]
            if data:
                self._send(200, data, "image/jpeg")
            else:
                self._send(404, b"no shot yet")
        else:
            self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        p = self.path.split("?")[0]
        if p in ("/api/lock", "/api/unlock"):
            target = "/api/screen/lock" if p == "/api/lock" else "/api/screen/unlock"
            try:
                st, body = api_post(target)
                self._send(st, body)
            except Exception as e:
                self._send(502, json.dumps({"error": str(e)}))
        else:
            self._send(404, json.dumps({"error": "not found"}))


# ----------------------------- 入口 -----------------------------
def main():
    global DEVICE, API_PORT, DASH_PORT, INTERVAL, SHOT_INTERVAL, FREEZE_SEC
    ap = argparse.ArgumentParser(description="MatisuXCS/TrollVNC noVNC 稳定性监控 + 仪表盘")
    ap.add_argument("host", help="设备 IP")
    ap.add_argument("--api-port", type=int, default=8182)
    ap.add_argument("--dash", type=int, default=8080)
    ap.add_argument("--interval", type=float, default=3)
    ap.add_argument("--shot-interval", type=float, default=5)
    ap.add_argument("--freeze-sec", type=float, default=60)
    args = ap.parse_args()

    DEVICE = args.host
    API_PORT = args.api_port
    DASH_PORT = args.dash
    INTERVAL = args.interval
    SHOT_INTERVAL = args.shot_interval
    FREEZE_SEC = args.freeze_sec

    with lock:
        stats["device"] = DEVICE
        stats["api_port"] = API_PORT

    # 监控线程
    t = threading.Thread(target=monitor_loop, daemon=True)
    t.start()

    # 仪表盘服务
    port = DASH_PORT
    srv = None
    while port < DASH_PORT + 20:
        try:
            srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
            DASH_PORT = port
            break
        except OSError:
            port += 1
    if srv is None:
        print("无法绑定本地仪表盘端口 %d+，退出。" % DASH_PORT)
        sys.exit(1)

    print("=" * 56)
    print("  MatisuXCS/TrollVNC noVNC 稳定性监控已启动")
    print("  设备: %s:%d  (API 端口)" % (DEVICE, API_PORT))
    print("  仪表盘: http://localhost:%d" % DASH_PORT)
    print("  在浏览器打开上面的地址即可实时查看")
    print("  测试建议:")
    print("    - 静置不操作 -> 验证防休眠保活 (应始终 在线)")
    print("    - 点「一键锁屏」让屏幕停摆>60s -> 验证自愈 (变红后自动恢复)")
    print("  按 Ctrl+C 停止")
    print("=" * 56)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止。")


if __name__ == "__main__":
    main()
