#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MatisuXCS / TrollVNC v3.83 noVNC 长会话稳定性 — 完整自动化测试

测试目标（针对 iOS 16 长时投屏假死的两处修复）：
  Fix 1 默认防休眠保活 (gKeepAliveSec=15)：有客户端时周期性 ACUnlock 保持显示常亮
  Fix 2 帧存活探针 (watchdog)：客户端在连且 60s 未产帧 -> exit(0) 交 launchd 监管重启

测试手段：
  - 连接一个真实 VNC(RFB) 客户端到 5901，使 gClientCount>0（激活 keepalive + capture + watchdog）
  - 通过设备 8182 REST API 的 /api/screen/lock 远程注入“屏幕冻结”场景
  - 后台线程监控 RFB socket 断开，精确捕获进程死亡时刻（watchdog 触发）
  - 观测 8182 在进程死后是否被 launchd 重新拉起（自愈）

设备: 192.69.0.99   VNC:5901   REST API:8182
"""
import socket, struct, time, json, datetime, os, sys, threading
import urllib.request, urllib.error

DEVICE = "192.69.0.99"
API_PORT = 8182
VNC_PORT = 5901
T1_IDLE = 180      # T1: 客户端连着、不锁屏、空闲时长(秒)，验证保活防假死
T2_WAIT = 150      # T2: 锁屏后最长等待自愈的时长(秒)
T3_WAIT = 30       # T3: 断开客户端后观测服务是否存活(秒)
POLL = 3           # 轮询间隔(秒)

OUT_DIR = os.path.dirname(os.path.abspath(__file__))
REPORT_JSON = os.path.join(OUT_DIR, "test_result_v3.83.json")
REPORT_MD = os.path.join(OUT_DIR, "novnc稳定性测试报告_v3.83.md")

results = {"device": DEVICE, "start": "", "phases": {}, "verdict": ""}


def log(msg):
    ts = datetime.datetime.now().strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)
    results.setdefault("_log", []).append(f"[{ts}] {msg}")


def api_get(path, timeout=5):
    url = f"http://{DEVICE}:{API_PORT}{path}"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        t0 = time.time()
        r = urllib.request.urlopen(req, timeout=timeout)
        body = r.read()
        return r.status, body, (time.time() - t0) * 1000.0
    except Exception as e:
        return None, str(e)[:140], None


def api_post(path, timeout=10):
    url = f"http://{DEVICE}:{API_PORT}{path}"
    try:
        req = urllib.request.Request(url, data=b"", method="POST",
                                     headers={"User-Agent": "Mozilla/5.0",
                                              "Content-Type": "application/json"})
        r = urllib.request.urlopen(req, timeout=timeout)
        return r.status, r.read().decode("utf-8", "ignore")
    except Exception as e:
        return None, str(e)[:140]


def connect_rfb():
    """完成 RFB 3.8 握手（None 认证），返回已连接的 socket（gClientCount 此时 >0）。"""
    s = socket.socket()
    s.settimeout(8)
    s.connect((DEVICE, VNC_PORT))
    banner = s.recv(12)
    if not banner.startswith(b"RFB "):
        raise RuntimeError(f"bad banner {banner!r}")
    s.sendall(b"RFB 003.008\n")
    nsec = s.recv(1)
    if not nsec:
        raise RuntimeError("no security types")
    n = nsec[0]
    types = s.recv(n)
    sec = list(types)
    if 1 not in sec:  # 1 = None
        raise RuntimeError(f"None auth not offered: {sec}")
    s.sendall(bytes([1]))
    res = s.recv(4)
    code = int.from_bytes(res, "big")
    if code != 0:
        raise RuntimeError(f"auth failed code={code}")
    s.sendall(bytes([1]))  # ClientInit: shared
    hdr = s.recv(24)
    w, h = struct.unpack(">HH", hdr[:4])
    namelen = struct.unpack(">I", hdr[20:24])[0]
    name = s.recv(namelen)
    log(f"RFB 客户端已连接 -> gClientCount 应 >0 | 分辨率 {w}x{h} 名称 {name.decode(errors='ignore')!r}")
    s.settimeout(None)  # 阻塞，交给监控线程检测断开
    return s


def watch_socket(sock, died_evt):
    """阻塞 recv(1)：进程退出时 socket 收 RST -> recv 返回 b'' -> 标记进程死亡。"""
    try:
        data = sock.recv(1)
        if data == b"":
            died_evt.set()
    except Exception:
        died_evt.set()


def status_ok():
    st, body, _ = api_get("/api/status", timeout=4)
    if st != 200 or not body:
        return False, None
    try:
        return True, json.loads(body)
    except Exception:
        return True, None


def save_shot(name):
    st, body, _ = api_get("/api/screenshot?format=jpeg&quality=0.35&scale=0.4", timeout=8)
    if st == 200 and body:
        p = os.path.join(OUT_DIR, name)
        with open(p, "wb") as f:
            f.write(body)
        return len(body)
    return 0


def main():
    results["start"] = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    log(f"=== 开始 v3.83 noVNC 稳定性完整测试 @ {DEVICE} ===")

    # ---- 预检 ----
    ok, st = status_ok()
    if not ok:
        log("✗ 设备 8182 API 不可达，终止")
        results["verdict"] = "ABORT: 设备不可达"
        return
    log(f"✓ 设备在线，/api/status = {st}")
    v0 = save_shot("shot_baseline.jpg")
    log(f"✓ 基线截图已存 shot_baseline.jpg ({v0} bytes)")

    # ===== T1: 客户端连着、不锁屏、空闲，验证防休眠保活 =====
    log("--- T1: 空闲防休眠测试 (客户端已连, 不锁屏, %ds) ---" % T1_IDLE)
    t1 = {"restarts": 0, "down_events": 0, "max_latency_ms": 0, "min_latency_ms": 999,
          "shots_served": 0, "start": time.time()}
    died_evt = threading.Event()
    rfb = connect_rfb()
    watch = threading.Thread(target=watch_socket, args=(rfb, died_evt), daemon=True)
    watch.start()
    t_end = time.time() + T1_IDLE
    last_down = False
    while time.time() < t_end:
        ok, _ = status_ok()
        if not ok:
            t1["down_events"] += 1
            if not last_down:
                t1["restarts"] += 1
                log("  ! 8182 不可达 (疑似重启)")
            last_down = True
        else:
            last_down = False
            _, shot, lat = api_get("/api/screenshot?format=jpeg&quality=0.2&scale=0.25", timeout=6)
            if lat is not None:
                t1["max_latency_ms"] = max(t1["max_latency_ms"], lat)
                t1["min_latency_ms"] = min(t1["min_latency_ms"], lat)
            if shot and len(shot) > 500:
                t1["shots_served"] += 1
        time.sleep(POLL)
    t1["client_died"] = died_evt.is_set()
    t1["duration_s"] = round(time.time() - t1["start"], 1)
    t1["pass"] = (t1["restarts"] == 0) and (not t1["client_died"])
    results["phases"]["T1_idle_keepalive"] = t1
    log(f"T1 结论: restarts={t1['restarts']} client_died={t1['client_died']} "
        f"shots={t1['shots_served']} latency=[{t1['min_latency_ms']:.0f},{t1['max_latency_ms']:.0f}]ms "
        f"-> {'PASS' if t1['pass'] else 'FAIL'}")

    # ===== T2: 锁屏注入冻结 -> 验证 watchdog 自杀 + launchd 自愈 =====
    log("--- T2: 冻结自愈测试 (锁屏注入冻结, 客户端保持连接) ---")
    t2 = {"lock_sent": 0, "process_died": False, "died_ts": None,
          "recovered": False, "alive_again_ts": None, "downtime_s": None, "start": time.time()}
    # 确保客户端仍连着
    if died_evt.is_set():
        log("  ! T1 后客户端已掉线，重连以激活 watchdog 路径")
        rfb = connect_rfb()
        died_evt = threading.Event()
        watch = threading.Thread(target=watch_socket, args=(rfb, died_evt), daemon=True)
        watch.start()
    st, body = api_post("/api/screen/lock")
    t2["lock_sent"] = time.time()
    log(f"  已发送 /api/screen/lock -> HTTP {st} {body[:80]}")
    # 轮询直到进程死亡(客户端socket断开) 且 8182 重新可达
    deadline = time.time() + T2_WAIT
    while time.time() < deadline:
        if died_evt.is_set() and not t2["process_died"]:
            t2["process_died"] = True
            t2["died_ts"] = time.time()
            log(f"  ✓ 检测到进程退出(watchdog 触发) t={time.time()-t2['start']:.1f}s")
        if t2["process_died"] and not t2["recovered"]:
            ok, _ = status_ok()
            if ok:
                t2["recovered"] = True
                t2["alive_again_ts"] = time.time()
                t2["downtime_s"] = round(t2["alive_again_ts"] - t2["died_ts"], 1)
                log(f"  ✓ 服务自愈完成, 停机时长约 {t2['downtime_s']}s")
                break
        time.sleep(POLL)
    if t2["process_died"] and t2["recovered"]:
        t2["pass"] = True
    elif t2["process_died"] and not t2["recovered"]:
        t2["pass"] = False
        log("  ✗ 进程退出但 8182 未恢复 -> 监管未拉起")
    else:
        t2["pass"] = False
        log("  ✗ 锁屏后 150s 内未检测到进程退出 -> watchdog 未触发(gClientCount 可能未>0 或逻辑异常)")
    results["phases"]["T2_freeze_selfheal"] = t2

    # 恢复设备屏幕
    st, body = api_post("/api/screen/unlock")
    log(f"  已发送 /api/screen/unlock -> HTTP {st} {body[:60]}")
    time.sleep(5)
    v1 = save_shot("shot_recovered.jpg")
    log(f"  恢复后截图 shot_recovered.jpg ({v1} bytes)")

    # ===== T3: 优雅断开客户端 -> 验证服务不崩 =====
    log("--- T3: 客户端优雅断开测试 ---")
    t3 = {"start": time.time(), "down_events": 0, "alive_end": False}
    try:
        rfb.close()
        log("  已关闭 RFB 客户端连接")
    except Exception as e:
        log(f"  关闭连接异常 {e}")
    t_end = time.time() + T3_WAIT
    while time.time() < t_end:
        ok, _ = status_ok()
        if not ok:
            t3["down_events"] += 1
        time.sleep(POLL)
    ok, _ = status_ok()
    t3["alive_end"] = ok
    t3["pass"] = ok and t3["down_events"] == 0
    t3["duration_s"] = round(time.time() - t3["start"], 1)
    results["phases"]["T3_client_disconnect"] = t3
    log(f"T3 结论: alive_end={t3['alive_end']} down_events={t3['down_events']} "
        f"-> {'PASS' if t3['pass'] else 'FAIL'}")

    # ===== 总判定 =====
    allpass = all(results["phases"][k]["pass"] for k in results["phases"])
    results["verdict"] = "PASS — v3.83 两处修复均生效" if allpass else "FAIL — 见各阶段明细"
    log(f"=== 总判定: {results['verdict']} ===")


if __name__ == "__main__":
    try:
        main()
    finally:
        with open(REPORT_JSON, "w", encoding="utf-8") as f:
            json.dump(results, f, ensure_ascii=False, indent=2)
        log(f"JSON 结果已写 {REPORT_JSON}")
