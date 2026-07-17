#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
v3.85 回归验证监控：盯着 noVNC 客户端连接稳定性 + 截图响应延迟。
- 每 5 秒查一次 /api/clients，记录连接数
- 客户端从 >0 掉到 0 记为一次 "CLIENT_GONE"（即断连重连，对应之前的 ExtDesktopSize 断连 bug）
- 同时测截图延迟，捕捉服务端卡顿
用户在此期间跨屏点 app 触发 resize，观察是否还有 CLIENT_GONE / 卡死。
"""
import time, urllib.request, json, sys

API = "http://192.69.0.99:8182"

def getjson(path, timeout=8):
    try:
        with urllib.request.urlopen(API + path, timeout=timeout) as r:
            return json.load(r)
    except Exception as e:
        return {"error": str(e)}

print(f"[v3.85-monitor] start {time.strftime('%H:%M:%S')}", flush=True)
prev = 0
flaps = 0
N = int(sys.argv[1]) if len(sys.argv) > 1 else 120  # 默认 10 分钟
for i in range(N):
    t = time.strftime('%H:%M:%S')
    c = getjson("/api/clients")
    cnt = c.get("count", c.get("error", "?"))
    s = time.time()
    try:
        with urllib.request.urlopen(API + "/api/screenshot?format=jpeg&quality=0.1&scale=0.1", timeout=8) as r:
            r.read()
        lat = f"{round(time.time()-s, 3)}s"
    except Exception as e:
        lat = "ERR:" + str(e)[:25]
    if isinstance(cnt, int):
        if prev > 0 and cnt == 0:
            flaps += 1
            print(f"[{t}] *** CLIENT_GONE (flaps={flaps}) *** clients={cnt} shot={lat}", flush=True)
        elif prev == 0 and cnt > 0:
            print(f"[{t}] client connected clients={cnt}", flush=True)
        prev = cnt
    print(f"[{t}] clients={cnt} shot={lat}", flush=True)
    sys.stdout.flush()
    time.sleep(5)
print(f"[v3.85-monitor] done. total CLIENT_GONE={flaps}", flush=True)
